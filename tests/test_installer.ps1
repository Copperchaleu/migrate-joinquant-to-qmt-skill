$ErrorActionPreference = 'Stop'

$Repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Installer = Join-Path $Repo 'installers/install.ps1'
$PlatformPaths = Join-Path $Repo 'tests/platform-paths.json'
$SkillName = 'migrate-joinquant-to-qmt'
$PowerShellExe = (Get-Process -Id $PID).Path
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('jq2qmt-ps-test.' + [guid]::NewGuid().ToString('N'))
$HttpProcess = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
}

function Invoke-Installer {
    param(
        [string[]]$InstallerArguments,
        [hashtable]$Environment = @{}
    )

    $savedEnvironment = @{}
    foreach ($name in $Environment.Keys) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], 'Process')
    }

    try {
        $output = & $PowerShellExe -NoProfile -File $Installer @InstallerArguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }
    finally {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
}

function Get-BackupCount {
    param([string]$Target)
    $parent = Split-Path -Parent $Target
    $name = Split-Path -Leaf $Target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        return 0
    }
    return @(Get-ChildItem -LiteralPath $parent -Directory -Filter ($name + '.backup.*')).Count
}

function Get-TreeSnapshot {
    param([string]$Root)
    return @(
        Get-ChildItem -LiteralPath $Root -Force -Recurse |
            Sort-Object FullName |
            ForEach-Object { $_.FullName.Substring($Root.Length) }
    ) -join "`n"
}

function Write-Checksum {
    param([string]$Archive, [string]$Checksum)
    & python3 -c 'import hashlib,pathlib,sys; a=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(hashlib.sha256(a.read_bytes()).hexdigest()+"  "+a.name+"\n", encoding="ascii")' $Archive $Checksum
    Assert-True ($LASTEXITCODE -eq 0) 'could not write test checksum'
}

try {
    New-Item -ItemType Directory -Path $TestRoot | Out-Null
    $Source = Join-Path $TestRoot ('source/' + $SkillName)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Source) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Repo ('skill/' + $SkillName)) -Destination $Source -Recurse
    $Source = [System.IO.Path]::GetFullPath($Source)

    # A wrong target mapping or an omitted marker breaks a literal shared vector.
    $mappingHome = Join-Path $TestRoot 'mapping-home'
    $mappingProject = Join-Path $TestRoot 'mapping-project'
    New-Item -ItemType Directory -Path $mappingHome, $mappingProject | Out-Null
    $vectorLines = & python3 -c 'import json,sys; [print("\t".join((v["platform"],v["scope"],v["relative"]))) for v in json.load(open(sys.argv[1], encoding="utf-8"))]' $PlatformPaths
    Assert-True ($LASTEXITCODE -eq 0) 'could not read shared path vectors'
    Assert-True (@($vectorLines).Count -eq 9) 'shared path vector count changed unexpectedly'
    foreach ($line in $vectorLines) {
        $parts = $line -split "`t", 3
        Assert-True ($parts.Count -eq 3) "invalid shared path vector: $line"
        $platform = $parts[0]
        $scope = $parts[1]
        $relative = $parts[2]
        $base = if ($scope -eq 'user') { $mappingHome } else { $mappingProject }
        $target = Join-Path $base $relative
        $result = Invoke-Installer -InstallerArguments @(
            '-Platform', $platform, '-Scope', $scope,
            '-ProjectDir', $mappingProject, '-Source', $Source
        ) -Environment @{ HOME = $mappingHome; USERPROFILE = $mappingHome }
        Assert-True ($result.ExitCode -eq 0) "install failed for ${platform}:${scope}: $($result.Output)"
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'SKILL.md') -PathType Leaf) "missing SKILL.md for ${platform}:${scope}"
        Assert-True (Test-Path -LiteralPath (Join-Path $target '.jq2qmt-install') -PathType Leaf) "missing marker for ${platform}:${scope}"
    }

    # Hermes has no project target and must return its documented special status.
    $hermes = Invoke-Installer -InstallerArguments @(
        '-Platform', 'hermes', '-Scope', 'project',
        '-ProjectDir', $mappingProject, '-Source', $Source
    ) -Environment @{ HOME = $mappingHome; USERPROFILE = $mappingHome }
    Assert-True ($hermes.ExitCode -eq 2) "Hermes project scope returned $($hermes.ExitCode) instead of 2"
    Assert-True ($hermes.Output -match 'Hermes') 'Hermes rejection was not actionable'
    Assert-True ($hermes.Output -match 'user|用户级') 'Hermes rejection omitted user-scope guidance'

    # Dry-run validates content and resolves a target without writing anything.
    $dryRoot = Join-Path $TestRoot 'dry-run'
    $dryHome = Join-Path $dryRoot 'home'
    $dryProject = Join-Path $dryRoot 'project'
    $runtimeHome = Join-Path $TestRoot 'powershell-runtime-home'
    New-Item -ItemType Directory -Path $dryHome, $dryProject, $runtimeHome | Out-Null
    $before = Get-TreeSnapshot $dryRoot
    $dry = Invoke-Installer -InstallerArguments @(
        '-Platform', 'codex', '-ProjectDir', $dryProject,
        '-Source', $Source, '-DryRun'
    ) -Environment @{ HOME = $runtimeHome; USERPROFILE = $dryHome }
    $after = Get-TreeSnapshot $dryRoot
    Assert-True ($dry.ExitCode -eq 0) "dry-run failed: $($dry.Output)"
    Assert-True ($before -ceq $after) 'dry-run wrote to the filesystem'

    # Same content is a no-op; changed content is refused; Force makes one backup.
    $lifeHome = Join-Path $TestRoot 'lifecycle-home'
    $lifeProject = Join-Path $TestRoot 'lifecycle-project'
    $lifeTarget = Join-Path $lifeHome ('.codex/skills/' + $SkillName)
    New-Item -ItemType Directory -Path $lifeHome, $lifeProject | Out-Null
    $lifeArguments = @('-Platform', 'codex', '-Scope', 'user', '-ProjectDir', $lifeProject, '-Source', $Source)
    $first = Invoke-Installer -InstallerArguments $lifeArguments -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    Assert-True ($first.ExitCode -eq 0) "initial lifecycle install failed: $($first.Output)"
    $markerPath = Join-Path $lifeTarget '.jq2qmt-install'
    $marker = Get-Content -LiteralPath $markerPath -Raw
    Assert-True ($marker -match '(?m)^platform=codex$') 'marker omitted platform'
    Assert-True ($marker -match '(?m)^scope=user$') 'marker omitted scope'
    Assert-True ($marker -match '(?m)^version=local$') 'marker omitted local version'
    Assert-True ($marker -match '(?m)^content_hash=[0-9a-f]{64}$') 'marker omitted SHA-256 tree hash'
    $markerHashBefore = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash
    $same = Invoke-Installer -InstallerArguments $lifeArguments -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    $markerHashAfter = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash
    Assert-True ($same.ExitCode -eq 0) "same-content install failed: $($same.Output)"
    Assert-True ($same.Output -match 'already installed') 'same-content no-op was not reported'
    Assert-True ($markerHashBefore -ceq $markerHashAfter) 'same-content install rewrote its marker'
    Assert-True ((Get-BackupCount $lifeTarget) -eq 0) 'same-content install made a backup'

    Add-Content -LiteralPath (Join-Path $Source 'SKILL.md') -Value "`n# lifecycle change" -Encoding UTF8
    $installedHashBefore = (Get-FileHash -LiteralPath (Join-Path $lifeTarget 'SKILL.md') -Algorithm SHA256).Hash
    $changed = Invoke-Installer -InstallerArguments $lifeArguments -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    $installedHashAfter = (Get-FileHash -LiteralPath (Join-Path $lifeTarget 'SKILL.md') -Algorithm SHA256).Hash
    Assert-True ($changed.ExitCode -ne 0) 'changed-content install succeeded without Force'
    Assert-True ($installedHashBefore -ceq $installedHashAfter) 'refused update changed installed content'
    Assert-True ((Get-BackupCount $lifeTarget) -eq 0) 'refused update made a backup'

    $forced = Invoke-Installer -InstallerArguments ($lifeArguments + '-Force') -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    Assert-True ($forced.ExitCode -eq 0) "forced update failed: $($forced.Output)"
    Assert-True ((Get-BackupCount $lifeTarget) -eq 1) 'forced update did not create exactly one backup'
    Assert-True ((Get-Content -LiteralPath (Join-Path $lifeTarget 'SKILL.md') -Raw) -match '# lifecycle change') 'forced update did not activate changed content'

    # Noninteractive removal is opt-in, marker guarded, and exact-target only.
    $unconfirmed = Invoke-Installer -InstallerArguments @(
        '-Platform', 'codex', '-Scope', 'user', '-ProjectDir', $lifeProject, '-Uninstall'
    ) -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    Assert-True ($unconfirmed.ExitCode -ne 0) 'noninteractive uninstall succeeded without Yes'
    Assert-True (Test-Path -LiteralPath $lifeTarget -PathType Container) 'unconfirmed uninstall removed target'
    $removed = Invoke-Installer -InstallerArguments @(
        '-Platform', 'codex', '-Scope', 'user', '-ProjectDir', $lifeProject, '-Uninstall', '-Yes'
    ) -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    Assert-True ($removed.ExitCode -eq 0) "confirmed uninstall failed: $($removed.Output)"
    Assert-True (-not (Test-Path -LiteralPath $lifeTarget)) 'confirmed uninstall left target behind'

    $reinstall = Invoke-Installer -InstallerArguments $lifeArguments -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    Assert-True ($reinstall.ExitCode -eq 0) 'could not prepare unmanaged uninstall case'
    Remove-Item -LiteralPath (Join-Path $lifeTarget '.jq2qmt-install') -Force
    $unmanaged = Invoke-Installer -InstallerArguments @(
        '-Platform', 'codex', '-Scope', 'user', '-ProjectDir', $lifeProject, '-Uninstall', '-Yes'
    ) -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    Assert-True ($unmanaged.ExitCode -ne 0) 'unmanaged target was removed without Force'
    Assert-True (Test-Path -LiteralPath $lifeTarget -PathType Container) 'unmanaged target disappeared'
    $forcedRemoval = Invoke-Installer -InstallerArguments @(
        '-Platform', 'codex', '-Scope', 'user', '-ProjectDir', $lifeProject,
        '-Uninstall', '-Yes', '-Force'
    ) -Environment @{ HOME = $lifeHome; USERPROFILE = $lifeHome }
    Assert-True ($forcedRemoval.ExitCode -eq 0) "forced uninstall failed: $($forcedRemoval.Output)"
    Assert-True (-not (Test-Path -LiteralPath $lifeTarget)) 'forced uninstall left exact target behind'

    # Versioned and latest installs use real release bytes over loopback HTTP.
    & python3 (Join-Path $Repo 'scripts/build_release.py') --tag v1.0.0
    Assert-True ($LASTEXITCODE -eq 0) 'release fixture build failed'
    $archiveName = $SkillName + '-v1.0.0.zip'
    $serverRoot = Join-Path $TestRoot 'server'
    $releaseDir = Join-Path $serverRoot 'releases/download/v1.0.0'
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
    $archive = Join-Path $releaseDir $archiveName
    $checksum = Join-Path $releaseDir 'SHA256SUMS'
    Copy-Item -LiteralPath (Join-Path $Repo ('dist/' + $archiveName)) -Destination $archive
    Copy-Item -LiteralPath (Join-Path $Repo 'dist/SHA256SUMS') -Destination $checksum
    $originalArchive = Join-Path $TestRoot 'original-release.zip'
    Copy-Item -LiteralPath $archive -Destination $originalArchive

    $port = & python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
    Assert-True ($LASTEXITCODE -eq 0) 'could not allocate loopback test port'
    $httpLog = Join-Path $TestRoot 'http.log'
    $httpError = Join-Path $TestRoot 'http.err'
    $HttpProcess = Start-Process -FilePath python3 -ArgumentList @(
        (Join-Path $Repo 'tests/fixtures/release_server.py'), '--port', [string]$port,
        '--directory', $serverRoot, '--tag', 'v1.0.0'
    ) -RedirectStandardOutput $httpLog -RedirectStandardError $httpError -PassThru
    $releaseRoot = "http://127.0.0.1:$port/releases/download"
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            Invoke-WebRequest -Uri ($releaseRoot + '/v1.0.0/SHA256SUMS') -UseBasicParsing | Out-Null
            $ready = $true
            break
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }
    Assert-True $ready 'loopback release server did not become ready'

    $remoteHome = Join-Path $TestRoot 'remote-home'
    New-Item -ItemType Directory -Path $remoteHome | Out-Null
    $remote = Invoke-Installer -InstallerArguments @('-Platform', 'codex', '-Version', 'v1.0.0') -Environment @{
        HOME = $remoteHome; USERPROFILE = $remoteHome; JQ2QMT_RELEASE_ROOT = $releaseRoot
    }
    $remoteTarget = Join-Path $remoteHome ('.codex/skills/' + $SkillName)
    Assert-True ($remote.ExitCode -eq 0) "fixed-version remote install failed: $($remote.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $remoteTarget 'SKILL.md') -PathType Leaf) 'remote install missed SKILL.md'
    Assert-True ((Get-Content -LiteralPath (Join-Path $remoteTarget '.jq2qmt-install') -Raw) -match '(?m)^version=v1.0.0$') 'remote marker omitted immutable version'

    $latestHome = Join-Path $TestRoot 'latest-home'
    New-Item -ItemType Directory -Path $latestHome | Out-Null
    $latest = Invoke-Installer -InstallerArguments @('-Platform', 'codex') -Environment @{
        HOME = $latestHome; USERPROFILE = $latestHome; JQ2QMT_RELEASE_ROOT = $releaseRoot;
        JQ2QMT_LATEST_URL = "http://127.0.0.1:$port/releases/latest"
    }
    Assert-True ($latest.ExitCode -eq 0) "latest redirect install failed: $($latest.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $latestHome ('.codex/skills/' + $SkillName + '/.jq2qmt-install')) -Raw) -match '(?m)^version=v1.0.0$') 'latest install did not pin the redirect tag'

    [System.IO.File]::AppendAllText($archive, 'corrupt release bytes')
    $corruptHome = Join-Path $TestRoot 'corrupt-home'
    New-Item -ItemType Directory -Path $corruptHome | Out-Null
    $corrupt = Invoke-Installer -InstallerArguments @('-Platform', 'codex', '-Version', 'v1.0.0') -Environment @{
        HOME = $corruptHome; USERPROFILE = $corruptHome; JQ2QMT_RELEASE_ROOT = $releaseRoot
    }
    Assert-True ($corrupt.ExitCode -ne 0) 'corrupt release passed checksum verification'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $corruptHome '.codex'))) 'checksum failure created a target root'

    # Checksum-valid traversal and symlink entries are rejected before extraction.
    & python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("migrate-joinquant-to-qmt/../escape","unsafe"); z.close()' $archive
    Assert-True ($LASTEXITCODE -eq 0) 'could not create traversal fixture'
    Write-Checksum $archive $checksum
    $traversalHome = Join-Path $TestRoot 'traversal-home'
    New-Item -ItemType Directory -Path $traversalHome | Out-Null
    $traversal = Invoke-Installer -InstallerArguments @('-Platform', 'codex', '-Version', 'v1.0.0') -Environment @{
        HOME = $traversalHome; USERPROFILE = $traversalHome; JQ2QMT_RELEASE_ROOT = $releaseRoot
    }
    Assert-True ($traversal.ExitCode -ne 0) 'archive traversal entry was accepted'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $traversalHome '.codex'))) 'unsafe archive created a target root'

    & python3 -c 'import stat,sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); i=zipfile.ZipInfo("migrate-joinquant-to-qmt/link"); i.create_system=3; i.external_attr=(stat.S_IFLNK|0o777)<<16; z.writestr(i,"../../outside"); z.close()' $archive
    Assert-True ($LASTEXITCODE -eq 0) 'could not create symlink fixture'
    Write-Checksum $archive $checksum
    $linkHome = Join-Path $TestRoot 'link-home'
    New-Item -ItemType Directory -Path $linkHome | Out-Null
    $link = Invoke-Installer -InstallerArguments @('-Platform', 'codex', '-Version', 'v1.0.0') -Environment @{
        HOME = $linkHome; USERPROFILE = $linkHome; JQ2QMT_RELEASE_ROOT = $releaseRoot
    }
    Assert-True ($link.ExitCode -ne 0) 'ZIP symlink entry was accepted'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $linkHome '.codex'))) 'ZIP symlink created a target root'

    Write-Output "PowerShell installer tests passed (shared path vectors: $(@($vectorLines).Count))"
}
finally {
    if ($null -ne $HttpProcess -and -not $HttpProcess.HasExited) {
        Stop-Process -Id $HttpProcess.Id -Force -ErrorAction SilentlyContinue
        $HttpProcess.WaitForExit()
    }
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
