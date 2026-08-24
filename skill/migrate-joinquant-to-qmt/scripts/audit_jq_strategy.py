#!/usr/bin/env python3
"""Inventory JoinQuant dependencies before a QMT migration."""

from __future__ import print_function

import argparse
import ast
import json
import re
import sys
from pathlib import Path


API_GROUPS = {
    "lifecycle": {
        "initialize", "process_initialize", "after_code_changed",
        "before_trading_start", "handle_data", "after_trading_end",
        "run_daily", "run_weekly", "run_monthly",
    },
    "market_data": {
        "history", "attribute_history", "get_price", "get_bars",
        "get_current_data", "get_extras", "get_ticks", "get_call_auction",
    },
    "fundamental_factor": {
        "query", "get_fundamentals", "get_fundamentals_continuously",
        "get_factor_values", "get_factor_kanban_values",
    },
    "universe_calendar": {
        "get_index_stocks", "get_industry_stocks", "get_concept_stocks",
        "get_all_securities", "get_security_info", "get_trade_days",
        "get_all_trade_days",
    },
    "trading": {
        "order", "order_value", "order_target", "order_target_value",
        "cancel_order", "get_orders", "get_open_orders", "get_trades",
    },
    "configuration": {
        "set_benchmark", "set_option", "set_order_cost", "set_commission",
        "set_slippage", "set_universe", "set_subportfolios",
    },
    "platform_services": {
        "record", "send_message", "read_file", "write_file",
    },
}

RISK_RULES = {
    "get_fundamentals": (
        "high",
        "财务查询必须保持公告可知日、报告期、单位和修订值语义。",
    ),
    "get_factor_values": (
        "high",
        "聚宽因子可能没有 QMT 直接等价项；核对公式与截面处理。",
    ),
    "get_index_stocks": (
        "high",
        "必须使用历史时点成分股，不能用当前成分回填历史。",
    ),
    "get_current_data": (
        "medium",
        "核对停牌、涨跌停、快照时点与实时订阅行为。",
    ),
    "run_daily": (
        "high",
        "QMT 定时器与回测生命周期不完全等价，需要 bar 驱动调度与去重。",
    ),
    "run_weekly": (
        "high",
        "核对周内交易日选择及节假日周的触发规则。",
    ),
    "run_monthly": (
        "high",
        "核对月内交易日选择及月初/月末不足交易日的规则。",
    ),
    "order_target_value": (
        "high",
        "需用账户快照和增量委托保持目标市值语义，并处理异步成交。",
    ),
    "order_target": (
        "high",
        "需扣除当前持仓与在途委托，防止重复下单。",
    ),
    "read_file": (
        "medium",
        "聚宽云端文件需迁移为 QMT 本地可访问文件并处理路径与编码。",
    ),
    "write_file": (
        "medium",
        "聚宽云端写入需迁移为 QMT 本地持久化并确认权限。",
    ),
}

CODE_PATTERN = re.compile(
    r"(?P<code>\d{5,6})\.(?P<market>XSHG|XSHE|XBSE|CCFX|XSGE|XDCE|XZCE)"
)


def dotted_name(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        prefix = dotted_name(node.value)
        return (prefix + "." if prefix else "") + node.attr
    return ""


class InventoryVisitor(ast.NodeVisitor):
    def __init__(self):
        self.calls = []
        self.definitions = []
        self.imports = []
        self.context_attrs = set()
        self.global_attrs = set()

    def visit_Call(self, node):
        name = dotted_name(node.func)
        if name:
            self.calls.append({"name": name, "line": node.lineno})
        self.generic_visit(node)

    def visit_FunctionDef(self, node):
        self.definitions.append({"name": node.name, "line": node.lineno})
        self.generic_visit(node)

    def visit_AsyncFunctionDef(self, node):
        self.definitions.append({"name": node.name, "line": node.lineno})
        self.generic_visit(node)

    def visit_Import(self, node):
        for item in node.names:
            self.imports.append({"name": item.name, "line": node.lineno})

    def visit_ImportFrom(self, node):
        module = node.module or ""
        self.imports.append({"name": module, "line": node.lineno})

    def visit_Attribute(self, node):
        name = dotted_name(node)
        if name.startswith("context."):
            self.context_attrs.add(name)
        if name.startswith("g."):
            self.global_attrs.add(name)
        self.generic_visit(node)


def py36_check(source, filename):
    try:
        ast.parse(source, filename=filename, feature_version=(3, 6))
        return {"compatible": True, "error": None}
    except TypeError:
        try:
            ast.parse(source, filename=filename, feature_version=6)
            return {"compatible": True, "error": None}
        except TypeError:
            return {
                "compatible": None,
                "error": "当前 Python 不支持 feature_version，未执行 3.6 专项检查。",
            }
        except SyntaxError as exc:
            return {"compatible": False, "error": syntax_message(exc)}
    except SyntaxError as exc:
        return {"compatible": False, "error": syntax_message(exc)}


def syntax_message(exc):
    return "line {0}: {1}".format(exc.lineno or "?", exc.msg)


def group_calls(calls, definitions):
    result = {}
    for group, names in API_GROUPS.items():
        hits = []
        if group == "lifecycle":
            for definition in definitions:
                if definition["name"] in names:
                    hits.append({
                        "name": definition["name"],
                        "line": definition["line"],
                        "kind": "definition",
                    })
        for call in calls:
            leaf = call["name"].split(".")[-1]
            if leaf in names:
                hits.append({
                    "name": call["name"],
                    "line": call["line"],
                    "kind": "call",
                })
        if hits:
            result[group] = hits
    return result


def build_findings(visitor, source, py36):
    findings = []
    seen = set()
    for call in visitor.calls:
        leaf = call["name"].split(".")[-1]
        if leaf in RISK_RULES and (leaf, call["line"]) not in seen:
            severity, message = RISK_RULES[leaf]
            findings.append({
                "severity": severity,
                "line": call["line"],
                "symbol": call["name"],
                "message": message,
            })
            seen.add((leaf, call["line"]))

    jq_imports = [
        item for item in visitor.imports
        if item["name"].split(".")[0] in {"jqdata", "jqdatasdk", "jqfactor"}
    ]
    for item in jq_imports:
        findings.append({
            "severity": "high",
            "line": item["line"],
            "symbol": item["name"],
            "message": "聚宽专用模块不能在 QMT 直接导入。",
        })

    if visitor.context_attrs:
        findings.append({
            "severity": "medium",
            "line": None,
            "symbol": "context.*",
            "message": "逐项映射聚宽 context/portfolio/position 字段。",
        })
    if visitor.global_attrs:
        findings.append({
            "severity": "medium",
            "line": None,
            "symbol": "g.*",
            "message": "迁移到自定义全局状态；不要默认存入 QMT ContextInfo。",
        })
    if py36["compatible"] is False:
        findings.append({
            "severity": "high",
            "line": None,
            "symbol": "python-3.6",
            "message": py36["error"],
        })
    if re.search(r"\b(high_limit|low_limit|paused|is_st)\b", source):
        findings.append({
            "severity": "medium",
            "line": None,
            "symbol": "current-data-fields",
            "message": "核对停牌、ST、涨跌停字段及无涨跌停品种的 NaN/0 行为。",
        })
    return findings


def audit(path):
    raw = path.read_bytes()
    encoding = "utf-8"
    try:
        source = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        encoding = "gb18030"
        source = raw.decode("gb18030")

    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError as exc:
        return {
            "file": str(path),
            "encoding": encoding,
            "parse_error": syntax_message(exc),
            "python36": {"compatible": False, "error": syntax_message(exc)},
            "imports": [],
            "definitions": [],
            "api_groups": {},
            "security_codes": [],
            "context_attributes": [],
            "global_state": [],
            "findings": [{
                "severity": "high",
                "line": exc.lineno,
                "symbol": "syntax",
                "message": syntax_message(exc),
            }],
        }

    visitor = InventoryVisitor()
    visitor.visit(tree)
    py36 = py36_check(source, str(path))
    codes = []
    for match in CODE_PATTERN.finditer(source):
        old = match.group(0)
        market = match.group("market")
        mapped = {
            "XSHG": "SH",
            "XSHE": "SZ",
        }.get(market)
        codes.append({
            "source": old,
            "qmt_candidate": (
                match.group("code") + "." + mapped if mapped else None
            ),
        })

    return {
        "file": str(path),
        "encoding": encoding,
        "parse_error": None,
        "python36": py36,
        "imports": visitor.imports,
        "definitions": visitor.definitions,
        "api_groups": group_calls(visitor.calls, visitor.definitions),
        "security_codes": sorted(
            {json.dumps(item, ensure_ascii=False): item for item in codes}.values(),
            key=lambda item: item["source"],
        ),
        "context_attributes": sorted(visitor.context_attrs),
        "global_state": sorted(visitor.global_attrs),
        "findings": build_findings(visitor, source, py36),
    }


def markdown(report):
    lines = [
        "# 聚宽策略静态审计",
        "",
        "- 文件：`{0}`".format(report["file"]),
        "- 检测编码：`{0}`".format(report["encoding"]),
        "- Python 3.6 语法：{0}".format(
            "通过" if report["python36"]["compatible"] is True
            else "未确认" if report["python36"]["compatible"] is None
            else "不通过"
        ),
        "",
    ]
    if report["parse_error"]:
        lines.extend(["## 解析错误", "", report["parse_error"], ""])

    lines.extend(["## API 盘点", ""])
    if not report["api_groups"]:
        lines.append("- 未识别到内置映射表中的聚宽 API。")
    for group, hits in report["api_groups"].items():
        rendered = ", ".join(
            "`{0}`(L{1})".format(item["name"], item["line"])
            for item in hits
        )
        lines.append("- **{0}**：{1}".format(group, rendered))

    lines.extend(["", "## 证券代码", ""])
    if not report["security_codes"]:
        lines.append("- 未发现常见聚宽后缀代码。")
    for item in report["security_codes"]:
        target = item["qmt_candidate"] or "需查 QMT 合约字典"
        lines.append("- `{0}` → `{1}`".format(item["source"], target))

    lines.extend(["", "## 风险发现", ""])
    if not report["findings"]:
        lines.append("- 未命中规则；仍需人工语义审查。")
    for item in report["findings"]:
        location = " L{0}".format(item["line"]) if item["line"] else ""
        lines.append(
            "- **{0}** `{1}`{2}：{3}".format(
                item["severity"], item["symbol"], location, item["message"]
            )
        )

    lines.extend(["", "## 状态与上下文字段", ""])
    lines.append("- `g`：{0}".format(
        ", ".join("`{0}`".format(x) for x in report["global_state"]) or "无"
    ))
    lines.append("- `context`：{0}".format(
        ", ".join("`{0}`".format(x) for x in report["context_attributes"]) or "无"
    ))
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Inventory JoinQuant APIs and migration risks."
    )
    parser.add_argument("strategy", type=Path, help="JoinQuant Python source file")
    parser.add_argument(
        "--format", choices=("markdown", "json"), default="markdown"
    )
    args = parser.parse_args(argv)

    if not args.strategy.is_file():
        parser.error("strategy file does not exist: {0}".format(args.strategy))

    report = audit(args.strategy)
    if args.format == "json":
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        sys.stdout.write(markdown(report))
    return 1 if report["parse_error"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
