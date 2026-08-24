[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('codex','claude','opencode','openclaw','hermes','all')]
    [string]$Platform,
    [ValidateSet('user','project')]
    [string]$Scope = 'user',
    [string]$ProjectDir = (Get-Location).Path,
    [string]$Version,
    [string]$Source,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$SkillName = 'migrate-joinquant-to-qmt'
$Repository = 'Copperchaleu/migrate-joinquant-to-qmt-skill'
$ReleaseRoot = if ($env:JQ2QMT_RELEASE_ROOT) { $env:JQ2QMT_RELEASE_ROOT.TrimEnd('/') } else { "https://github.com/$Repository/releases/download" }
$LatestUrl = if ($env:JQ2QMT_LATEST_URL) { $env:JQ2QMT_LATEST_URL } else { "https://github.com/$Repository/releases/latest" }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$TemporaryDirectory = $null

function Throw-InstallerError {
    param([string]$Message, [int]$ExitCode = 1)
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['ExitCode'] = $ExitCode
    throw $exception
}

function Get-FullPath {
    param([string]$Path)
    try {
        return [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        Throw-InstallerError "invalid path: $Path"
    }
}

function Test-ReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Resolve-Target {
    param([string]$SelectedPlatform, [string]$SelectedScope, [string]$ResolvedProjectDir)

    if ($SelectedScope -eq 'user') {
        $homePath = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
        if ([string]::IsNullOrWhiteSpace($homePath)) {
            Throw-InstallerError 'USERPROFILE or HOME is required for user-scope installation'
        }
        if (-not [System.IO.Path]::IsPathRooted($homePath)) {
            Throw-InstallerError 'USERPROFILE or HOME must be an absolute path'
        }
        $homePath = Get-FullPath $homePath
        switch ($SelectedPlatform) {
            'codex' { $targetRoot = Join-Path $homePath '.codex/skills' }
            'claude' { $targetRoot = Join-Path $homePath '.claude/skills' }
            'opencode' { $targetRoot = Join-Path $homePath '.config/opencode/skills' }
            'openclaw' { $targetRoot = Join-Path $homePath '.openclaw/skills' }
            'hermes' { $targetRoot = Join-Path $homePath '.hermes/skills' }
            default { Throw-InstallerError "unsupported platform: $SelectedPlatform" }
        }
    }
    else {
        switch ($SelectedPlatform) {
            'codex' { $targetRoot = Join-Path $ResolvedProjectDir '.agents/skills' }
            'claude' { $targetRoot = Join-Path $ResolvedProjectDir '.claude/skills' }
            'opencode' { $targetRoot = Join-Path $ResolvedProjectDir '.opencode/skills' }
            'openclaw' { $targetRoot = Join-Path $ResolvedProjectDir 'skills' }
            'hermes' {
                Throw-InstallerError '错误：Hermes Agent 不支持项目级安装；请使用 -Scope user。 Error: Hermes Agent project scope is unsupported; use -Scope user.' 2
            }
            default { Throw-InstallerError "unsupported platform: $SelectedPlatform" }
        }
    }

    $targetRoot = Get-FullPath $targetRoot
    return [pscustomobject]@{
        Root = $targetRoot
        Target = Get-FullPath (Join-Path $targetRoot $SkillName)
    }
}

function Assert-ExactTarget {
    param([pscustomobject]$TargetInfo)
    $expected = Get-FullPath (Join-Path $TargetInfo.Root $SkillName)
    if (-not [string]::Equals($TargetInfo.Target, $expected, [System.StringComparison]::Ordinal)) {
        Throw-InstallerError "refusing unsafe target path: $($TargetInfo.Target)"
    }
    if ((Split-Path -Leaf $TargetInfo.Target) -cne $SkillName) {
        Throw-InstallerError "refusing unsafe target name: $($TargetInfo.Target)"
    }
    if (Test-ReparsePoint $TargetInfo.Root) {
        Throw-InstallerError "refusing reparse-point target root: $($TargetInfo.Root)"
    }
}

function Test-Skill {
    param([string]$SourcePath)
    $requiredFiles = @(
        'SKILL.md',
        'scripts/audit_jq_strategy.py',
        'scripts/check_qmt_strategy.py',
        'references/official-sources.md'
    )
    foreach ($relative in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $SourcePath $relative) -PathType Leaf)) {
            Throw-InstallerError "invalid skill source; missing $relative"
        }
    }

    $lines = @(Get-Content -LiteralPath (Join-Path $SourcePath 'SKILL.md'))
    if ($lines.Count -eq 0 -or $lines[0] -cne '---') {
        Throw-InstallerError "SKILL.md frontmatter must contain exact name: $SkillName"
    }
    $foundName = $false
    $closed = $false
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -ceq '---') {
            $closed = $true
            break
        }
        if ($lines[$index] -ceq "name: $SkillName") {
            $foundName = $true
        }
    }
    if (-not $closed -or -not $foundName) {
        Throw-InstallerError "SKILL.md frontmatter must contain exact name: $SkillName"
    }
}

function Get-TreeHash {
    param([string]$TreePath)
    $root = (Get-FullPath $TreePath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Throw-InstallerError "skill tree does not exist: $root"
    }
    if (Test-ReparsePoint $root) {
        Throw-InstallerError "refusing reparse-point skill tree: $root"
    }

    $items = @(Get-ChildItem -LiteralPath $root -Force -Recurse)
    foreach ($item in $items) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-InstallerError "skill tree contains a reparse point: $($item.FullName)"
        }
    }

    $relativePaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in ($items | Where-Object { -not $_.PSIsContainer -and $_.Name -cne '.jq2qmt-install' })) {
        $relative = $file.FullName.Substring($root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $relative = $relative.Replace([System.IO.Path]::DirectorySeparatorChar, '/')
        $relativePaths.Add($relative)
    }
    $paths = $relativePaths.ToArray()
    [Array]::Sort($paths, [System.StringComparer]::Ordinal)

    $manifest = New-Object System.Text.StringBuilder
    foreach ($relative in $paths) {
        $nativeRelative = $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        try {
            $digest = (Get-FileHash -LiteralPath (Join-Path $root $nativeRelative) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        catch {
            Throw-InstallerError "failed to hash file: $relative"
        }
        if ($digest -notmatch '^[0-9a-f]{64}$') {
            Throw-InstallerError "invalid file hash for: $relative"
        }
        [void]$manifest.Append($digest).Append('  ./').Append($relative).Append("`n")
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $Utf8NoBom.GetBytes($manifest.ToString())
        $hashBytes = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Install-LocalSkill {
    param(
        [string]$SourcePath,
        [pscustomobject]$TargetInfo,
        [string]$SelectedPlatform,
        [string]$SelectedScope,
        [string]$SelectedVersion,
        [string]$SourceDescription
    )

    $sourceHash = Get-TreeHash $SourcePath
    $targetExists = $false
    $plannedAction = 'install'
    if (Test-ReparsePoint $TargetInfo.Target) {
        Throw-InstallerError "refusing reparse-point target: $($TargetInfo.Target)"
    }
    if (Test-Path -LiteralPath $TargetInfo.Target -PathType Container) {
        $targetExists = $true
        $targetHash = Get-TreeHash $TargetInfo.Target
        if ([string]::Equals($sourceHash, $targetHash, [System.StringComparison]::Ordinal)) {
            Write-Output "already installed: platform=$SelectedPlatform scope=$SelectedScope target=$($TargetInfo.Target) hash=$sourceHash"
            return
        }
        if (-not $Force) {
            Throw-InstallerError "target has different content; rerun with -Force to create a backup: $($TargetInfo.Target)"
        }
        $plannedAction = 'backup-and-replace'
    }
    elseif (Test-Path -LiteralPath $TargetInfo.Target) {
        Throw-InstallerError "target exists and is not a directory: $($TargetInfo.Target)"
    }

    $markerVersion = if ($SelectedVersion) { $SelectedVersion } else { 'local' }
    if ($DryRun) {
        Write-Output "dry-run: source=$SourcePath version=$markerVersion platform=$SelectedPlatform scope=$SelectedScope target=$($TargetInfo.Target) action=$plannedAction hash=$sourceHash"
        return
    }

    Assert-ExactTarget $TargetInfo
    New-Item -ItemType Directory -Path $TargetInfo.Root -Force | Out-Null
    Assert-ExactTarget $TargetInfo
    $stage = Join-Path $TargetInfo.Root ('.jq2qmt.' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        Get-ChildItem -LiteralPath $SourcePath -Force | Copy-Item -Destination $stage -Recurse -Force
        $marker = @(
            "platform=$SelectedPlatform",
            "scope=$SelectedScope",
            "version=$markerVersion",
            "source=$SourceDescription",
            "content_hash=$sourceHash"
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $stage '.jq2qmt-install'), $marker + "`n", $Utf8NoBom)

        if ($targetExists) {
            if (-not (Test-Path -LiteralPath $TargetInfo.Target -PathType Container) -or (Test-ReparsePoint $TargetInfo.Target)) {
                Throw-InstallerError 'target changed while the update was being staged'
            }
            $backup = $TargetInfo.Target + '.backup.' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
            if (Test-Path -LiteralPath $backup) {
                Throw-InstallerError "backup path already exists: $backup"
            }
            Move-Item -LiteralPath $TargetInfo.Target -Destination $backup
            try {
                Move-Item -LiteralPath $stage -Destination $TargetInfo.Target
                $stage = $null
            }
            catch {
                if (-not (Test-Path -LiteralPath $TargetInfo.Target) -and (Test-Path -LiteralPath $backup)) {
                    Move-Item -LiteralPath $backup -Destination $TargetInfo.Target
                }
                throw
            }
            Write-Output "installed: platform=$SelectedPlatform scope=$SelectedScope target=$($TargetInfo.Target) hash=$sourceHash backup=$backup"
        }
        else {
            if (Test-Path -LiteralPath $TargetInfo.Target) {
                Throw-InstallerError 'target appeared while the install was being staged'
            }
            Move-Item -LiteralPath $stage -Destination $TargetInfo.Target
            $stage = $null
            Write-Output "installed: platform=$SelectedPlatform scope=$SelectedScope target=$($TargetInfo.Target) hash=$sourceHash"
        }
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
            $stageName = Split-Path -Leaf $stage
            $stageParent = Get-FullPath (Split-Path -Parent $stage)
            if ($stageName.StartsWith('.jq2qmt.', [System.StringComparison]::Ordinal) -and
                [string]::Equals($stageParent, $TargetInfo.Root, [System.StringComparison]::Ordinal)) {
                Remove-Item -LiteralPath $stage -Recurse -Force
            }
        }
    }
}

function Remove-InstalledSkill {
    param([pscustomobject]$TargetInfo, [string]$SelectedPlatform, [string]$SelectedScope)
    Assert-ExactTarget $TargetInfo
    if (Test-ReparsePoint $TargetInfo.Target) {
        Throw-InstallerError "refusing to uninstall a reparse-point target: $($TargetInfo.Target)"
    }
    if (-not (Test-Path -LiteralPath $TargetInfo.Target -PathType Container)) {
        Write-Output "not installed: platform=$SelectedPlatform scope=$SelectedScope target=$($TargetInfo.Target)"
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $TargetInfo.Target '.jq2qmt-install') -PathType Leaf) -and -not $Force) {
        Throw-InstallerError "install marker is missing; refusing uninstall without -Force: $($TargetInfo.Target)"
    }
    if ($DryRun) {
        Write-Output "dry-run: platform=$SelectedPlatform scope=$SelectedScope target=$($TargetInfo.Target) action=uninstall"
        return
    }
    if (-not $Yes) {
        if ([Console]::IsInputRedirected) {
            Throw-InstallerError 'noninteractive uninstall requires -Yes'
        }
        $answer = Read-Host "Uninstall $($TargetInfo.Target)? [y/N]"
        if ($answer -notmatch '^(?i:y|yes)$') {
            Throw-InstallerError 'Uninstall cancelled'
        }
    }
    Assert-ExactTarget $TargetInfo
    Remove-Item -LiteralPath $TargetInfo.Target -Recurse -Force
    Write-Output "uninstalled: platform=$SelectedPlatform scope=$SelectedScope target=$($TargetInfo.Target)"
}

function Test-ReleaseTag {
    param([string]$Candidate)
    return ($Candidate -cmatch '^v[0-9]+\.[0-9]+\.[0-9]+$')
}

function Invoke-WebRequestCompat {
    param([string]$Uri, [string]$OutFile)
    $parameters = @{ Uri = $Uri; UseBasicParsing = $true }
    if ($OutFile) {
        $parameters['OutFile'] = $OutFile
    }
    return Invoke-WebRequest @parameters
}

function Resolve-ReleaseTag {
    param([string]$RequestedVersion)
    if ($RequestedVersion) {
        if (-not (Test-ReleaseTag $RequestedVersion)) {
            Throw-InstallerError '-Version must match vMAJOR.MINOR.PATCH' 64
        }
        return $RequestedVersion
    }

    try {
        $response = Invoke-WebRequestCompat -Uri $LatestUrl
    }
    catch {
        Throw-InstallerError 'could not resolve latest release'
    }
    $finalUri = $null
    if ($null -ne $response.BaseResponse) {
        if ($response.BaseResponse.PSObject.Properties.Name -contains 'ResponseUri') {
            $finalUri = $response.BaseResponse.ResponseUri
        }
        elseif ($null -ne $response.BaseResponse.RequestMessage) {
            $finalUri = $response.BaseResponse.RequestMessage.RequestUri
        }
    }
    if ($null -eq $finalUri) {
        Throw-InstallerError 'latest release did not expose its final redirect URI'
    }
    $segments = $finalUri.AbsolutePath.TrimEnd('/').Split('/')
    $resolved = $segments[$segments.Length - 1]
    if (-not (Test-ReleaseTag $resolved)) {
        Throw-InstallerError 'latest release did not resolve to a SemVer tag'
    }
    return $resolved
}

function New-PrivateTemporaryDirectory {
    $temporaryRoot = Get-FullPath ([System.IO.Path]::GetTempPath())
    if (-not (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
        Throw-InstallerError "temporary directory does not exist: $temporaryRoot"
    }
    $path = Join-Path $temporaryRoot ('jq2qmt.' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return Get-FullPath $path
}

function Test-ZipEntries {
    param([string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($zip.Entries.Count -eq 0) {
            Throw-InstallerError 'release archive is empty'
        }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $normalized = $name.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($name) -or
                [System.IO.Path]::IsPathRooted($name) -or
                $normalized.StartsWith('/', [System.StringComparison]::Ordinal) -or
                $normalized -match '^[A-Za-z]:/' -or
                -not $normalized.StartsWith($SkillName + '/', [System.StringComparison]::Ordinal)) {
                Throw-InstallerError "release archive contains an unsafe or unexpected path: $name"
            }
            $parts = @($normalized.Split('/') | Where-Object { $_ -ne '' })
            if ($parts -contains '..') {
                Throw-InstallerError "release archive contains an unsafe path: $name"
            }
            $externalAttributes = [int64]$entry.ExternalAttributes
            if ($externalAttributes -lt 0) {
                $externalAttributes += 4294967296
            }
            $unixMode = ($externalAttributes -shr 16) -band 0xFFFF
            $windowsAttributes = $externalAttributes -band 0xFFFF
            if (($unixMode -band 0xF000) -eq 0xA000) {
                Throw-InstallerError "release archive contains a symbolic link: $name"
            }
            if (($windowsAttributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-InstallerError "release archive contains a reparse point: $name"
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Expand-VerifiedRelease {
    param([string]$ResolvedVersion)
    $script:TemporaryDirectory = New-PrivateTemporaryDirectory
    $archiveName = "$SkillName-$ResolvedVersion.zip"
    $archiveUrl = "$ReleaseRoot/$ResolvedVersion/$archiveName"
    $checksumUrl = "$ReleaseRoot/$ResolvedVersion/SHA256SUMS"
    $archivePath = Join-Path $script:TemporaryDirectory $archiveName
    $checksumPath = Join-Path $script:TemporaryDirectory 'SHA256SUMS'
    try {
        Invoke-WebRequestCompat -Uri $archiveUrl -OutFile $archivePath | Out-Null
        Invoke-WebRequestCompat -Uri $checksumUrl -OutFile $checksumPath | Out-Null
    }
    catch {
        Throw-InstallerError 'could not download release assets'
    }

    $expectedHashes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in (Get-Content -LiteralPath $checksumPath)) {
        if ($line -match '^([0-9A-Fa-f]{64})\s+(\S+)\s*$' -and
            [string]::Equals($Matches[2], $archiveName, [System.StringComparison]::Ordinal)) {
            $expectedHashes.Add($Matches[1].ToLowerInvariant())
        }
    }
    if ($expectedHashes.Count -ne 1) {
        Throw-InstallerError "SHA256SUMS does not contain exactly one valid checksum for $archiveName"
    }
    try {
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch {
        Throw-InstallerError 'could not hash downloaded release archive'
    }
    if (-not [string]::Equals($actualHash, $expectedHashes[0], [System.StringComparison]::Ordinal)) {
        Throw-InstallerError 'release archive checksum mismatch'
    }

    Test-ZipEntries $archivePath
    $extractRoot = Join-Path $script:TemporaryDirectory 'extracted'
    New-Item -ItemType Directory -Path $extractRoot | Out-Null
    try {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
    }
    catch {
        Throw-InstallerError 'could not extract release archive'
    }
    $sourcePath = Join-Path $extractRoot $SkillName
    Test-Skill $sourcePath
    return [pscustomobject]@{ Path = $sourcePath; Description = $archiveUrl }
}

function Get-DetectedPlatforms {
    $detected = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @('codex', 'claude', 'opencode', 'openclaw', 'hermes')) {
        if (Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue) {
            $detected.Add($candidate)
        }
    }
    return $detected.ToArray()
}

function Invoke-InstallerMain {
    $resolvedProject = Get-FullPath $ProjectDir
    if (-not (Test-Path -LiteralPath $resolvedProject -PathType Container)) {
        Throw-InstallerError "project directory does not exist: $ProjectDir" 64
    }

    $sourcePath = $null
    $sourceDescription = $null
    $resolvedVersion = $Version
    if (-not $Uninstall) {
        if ($Source) {
            $sourcePath = Get-FullPath $Source
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
                Throw-InstallerError "source directory does not exist: $Source" 64
            }
            if ($resolvedVersion -and -not (Test-ReleaseTag $resolvedVersion)) {
                Throw-InstallerError '-Version must match vMAJOR.MINOR.PATCH' 64
            }
            Test-Skill $sourcePath
            $sourceDescription = $sourcePath
        }
        else {
            $resolvedVersion = Resolve-ReleaseTag $resolvedVersion
            $release = Expand-VerifiedRelease $resolvedVersion
            $sourcePath = $release.Path
            $sourceDescription = $release.Description
        }
    }

    $selectedPlatforms = @()
    if (-not $Platform) {
        $detected = @(Get-DetectedPlatforms)
        if ($detected.Count -ne 1) {
            Throw-InstallerError "detected $($detected.Count) supported platform CLIs; specify -Platform explicitly"
        }
        $selectedPlatforms = $detected
    }
    elseif ($Platform -eq 'all') {
        $selectedPlatforms = @(Get-DetectedPlatforms)
        if ($selectedPlatforms.Count -eq 0) {
            Throw-InstallerError '-Platform all found no supported platform CLI'
        }
    }
    else {
        $selectedPlatforms = @($Platform)
    }

    $successfulTargets = 0
    foreach ($selectedPlatform in $selectedPlatforms) {
        try {
            $targetInfo = Resolve-Target $selectedPlatform $Scope $resolvedProject
            if ($Uninstall) {
                Remove-InstalledSkill $targetInfo $selectedPlatform $Scope
            }
            else {
                Install-LocalSkill $sourcePath $targetInfo $selectedPlatform $Scope $resolvedVersion $sourceDescription
            }
            $successfulTargets++
        }
        catch {
            $code = if ($_.Exception.Data.Contains('ExitCode')) { [int]$_.Exception.Data['ExitCode'] } else { 1 }
            if ($Platform -eq 'all' -and $selectedPlatform -eq 'hermes' -and $Scope -eq 'project' -and $code -eq 2) {
                [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
                continue
            }
            throw
        }
    }
    if ($successfulTargets -eq 0) {
        Throw-InstallerError 'no supported installation target succeeded'
    }
}

$installerExitCode = 0
try {
    Invoke-InstallerMain
}
catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    if ($_.Exception.Data.Contains('ExitCode')) {
        $installerExitCode = [int]$_.Exception.Data['ExitCode']
    }
    else {
        $installerExitCode = 1
    }
}
finally {
    if ($TemporaryDirectory -and (Test-Path -LiteralPath $TemporaryDirectory -PathType Container)) {
        $tempName = Split-Path -Leaf $TemporaryDirectory
        if ($tempName.StartsWith('jq2qmt.', [System.StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

exit $installerExitCode
