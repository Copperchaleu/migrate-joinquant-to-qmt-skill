#!/usr/bin/env python3
"""Check a migrated QMT strategy for common static compatibility errors."""

from __future__ import print_function

import argparse
import ast
import json
import re
import sys
from pathlib import Path


JQ_TOKENS = {
    "initialize", "process_initialize", "before_trading_start",
    "handle_data", "after_trading_end", "run_daily", "run_weekly",
    "run_monthly", "attribute_history", "get_price", "history",
    "get_current_data", "get_fundamentals", "get_index_stocks",
    "order", "order_value", "order_target", "order_target_value",
    "set_benchmark", "set_option", "set_order_cost", "set_slippage",
}

JQ_MODULES = {"jqdata", "jqdatasdk", "jqfactor"}
NON_QMT_CODE_PATTERN = re.compile(
    r"\b[A-Za-z0-9-]+\.(?:XSHG|XSHE|XBSE|CFFEX|SHFE|DCE|CZCE|GFEX)\b"
)
LOG_METHODS = {
    "debug", "info", "warning", "warn", "error", "exception", "critical",
}
UNKNOWN_NAME_PATTERN = re.compile(
    r"(?:未知名称|名称未知|unknown(?:\s+name)?)", re.IGNORECASE
)
LIVE_FRESHNESS_SECONDS = 180


def dotted_name(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        prefix = dotted_name(node.value)
        return (prefix + "." if prefix else "") + node.attr
    return ""


def literal_value(node):
    if isinstance(node, ast.Constant):
        return node.value
    if node is not None and node.__class__.__name__ == "Str":
        return getattr(node, "s", None)
    if node is not None and node.__class__.__name__ == "NameConstant":
        return getattr(node, "value", None)
    return None


def referenced_names(node):
    if node is None:
        return set()
    return set(
        item.id for item in ast.walk(node) if isinstance(item, ast.Name)
    )


def function_source_text(source, node, function_nodes):
    get_segment = getattr(ast, "get_source_segment", None)
    if get_segment is not None:
        segment = get_segment(source, node)
        if segment:
            return segment
    lines = source.splitlines()
    start = max(0, node.lineno - 1)
    later_lines = [
        item.lineno - 1 for item in function_nodes
        if item.lineno > node.lineno
    ]
    end = min(later_lines) if later_lines else len(lines)
    return "\n".join(lines[start:end])


def is_absolute_time_delta(node):
    """Return True for abs((runtime - bar_time).total_seconds())."""
    if not (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "abs"
            and len(node.args) == 1):
        return False
    seconds_call = node.args[0]
    return bool(
        isinstance(seconds_call, ast.Call)
        and isinstance(seconds_call.func, ast.Attribute)
        and seconds_call.func.attr == "total_seconds"
        and isinstance(seconds_call.func.value, ast.BinOp)
        and isinstance(seconds_call.func.value.op, ast.Sub)
    )


def live_freshness_window_is_exact(node, constants):
    """Recognize an inclusive absolute time window of exactly +/-180 seconds."""
    absolute_delta_names = set()
    for item in ast.walk(node):
        if isinstance(item, ast.Assign) and is_absolute_time_delta(item.value):
            for target in item.targets:
                if isinstance(target, ast.Name):
                    absolute_delta_names.add(target.id)

    def is_delta(value):
        return (
            is_absolute_time_delta(value)
            or (
                isinstance(value, ast.Name)
                and value.id in absolute_delta_names
            )
        )

    def resolved_number(value):
        direct = literal_value(value)
        if direct is not None:
            return direct
        if isinstance(value, ast.Name):
            return constants.get(value.id)
        return None

    for item in ast.walk(node):
        if not isinstance(item, ast.Compare) or len(item.ops) != 1:
            continue
        left, op, right = item.left, item.ops[0], item.comparators[0]
        if (
                is_delta(left)
                and isinstance(op, ast.LtE)
                and resolved_number(right) == LIVE_FRESHNESS_SECONDS):
            return True
        if (
                resolved_number(left) == LIVE_FRESHNESS_SECONDS
                and isinstance(op, ast.GtE)
                and is_delta(right)):
            return True
    return False


class QmtVisitor(ast.NodeVisitor):
    def __init__(self):
        self.definitions = set()
        self.calls = []
        self.imports = []
        self.function_stack = []
        self.string_literals = []
        self.function_nodes = []
        self.constant_assignments = {}

    def visit_Assign(self, node):
        value = literal_value(node.value)
        for target in node.targets:
            if isinstance(target, ast.Name) and value is not None:
                self.constant_assignments[target.id] = value
        self.generic_visit(node)

    def visit_FunctionDef(self, node):
        self.definitions.add(node.name)
        self.function_nodes.append(node)
        self.function_stack.append(node.name)
        try:
            self.generic_visit(node)
        finally:
            self.function_stack.pop()

    def visit_AsyncFunctionDef(self, node):
        self.definitions.add(node.name)
        self.function_nodes.append(node)
        self.function_stack.append(node.name)
        try:
            self.generic_visit(node)
        finally:
            self.function_stack.pop()

    def visit_Call(self, node):
        name = dotted_name(node.func)
        if name:
            self.calls.append({
                "name": name,
                "line": node.lineno,
                "function": (
                    self.function_stack[-1] if self.function_stack else None
                ),
                "args": list(node.args),
                "keywords": dict(
                    (item.arg, item.value)
                    for item in node.keywords if item.arg is not None
                ),
            })
        self.generic_visit(node)

    def visit_Import(self, node):
        for item in node.names:
            self.imports.append({"name": item.name, "line": node.lineno})

    def visit_ImportFrom(self, node):
        self.imports.append({"name": node.module or "", "line": node.lineno})

    def visit_Constant(self, node):
        if isinstance(node.value, str):
            self.string_literals.append({
                "value": node.value,
                "line": getattr(node, "lineno", None),
                "function": (
                    self.function_stack[-1] if self.function_stack else None
                ),
            })

    def visit_Str(self, node):
        self.string_literals.append({
            "value": node.s,
            "line": getattr(node, "lineno", None),
            "function": (
                self.function_stack[-1] if self.function_stack else None
            ),
        })


def syntax_message(exc):
    return "line {0}: {1}".format(exc.lineno or "?", exc.msg)


def parse_py36(source, filename):
    try:
        return ast.parse(source, filename=filename, feature_version=(3, 6)), None
    except TypeError:
        try:
            return ast.parse(source, filename=filename, feature_version=6), None
        except TypeError:
            try:
                return ast.parse(source, filename=filename), (
                    "当前 Python 不支持 feature_version；只完成当前版本语法解析。"
                )
            except SyntaxError as exc:
                return None, syntax_message(exc)
        except SyntaxError as exc:
            return None, syntax_message(exc)
    except SyntaxError as exc:
        return None, syntax_message(exc)


def check(path):
    raw = path.read_bytes()
    decode_encoding = "utf-8"
    try:
        source = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        decode_encoding = "gb18030"
        source = raw.decode("gb18030")

    findings = []
    first_two = source.splitlines()[:2]
    encoding_declared = any(
        re.search(r"coding[:=]\s*[-\w.]+", line) for line in first_two
    )
    if not encoding_declared:
        findings.append({
            "severity": "error",
            "line": 1,
            "symbol": "encoding",
            "message": "前两行未声明 #coding:gbk。",
        })
    elif not any("gbk" in line.lower() for line in first_two):
        findings.append({
            "severity": "warning",
            "line": 1,
            "symbol": "encoding",
            "message": "QMT 内置策略通常使用 GBK；当前声明不是 GBK。",
        })

    try:
        source.encode("gbk")
        gbk_encodable = True
    except UnicodeEncodeError as exc:
        gbk_encodable = False
        findings.append({
            "severity": "error",
            "line": source.count("\n", 0, exc.start) + 1,
            "symbol": "gbk",
            "message": "源码包含无法编码为 GBK 的字符。",
        })

    tree, syntax_note = parse_py36(source, str(path))
    if tree is None:
        findings.append({
            "severity": "error",
            "line": None,
            "symbol": "python-3.6",
            "message": syntax_note,
        })
        visitor = QmtVisitor()
    else:
        visitor = QmtVisitor()
        visitor.visit(tree)

    for required in (
        "init", "handlebar", "qmt_strategy_name", "qmt_bar_time", "qmt_log",
        "qmt_instrument_name",
    ):
        if required not in visitor.definitions:
            findings.append({
                "severity": "error",
                "line": None,
                "symbol": required,
                "message": (
                    "缺少必需函数 {0}；迁移策略必须统一记录策略名、K 线时间"
                    "并解析标的名称。"
                ).format(required),
            })

    for item in visitor.imports:
        if item["name"].split(".")[0] in JQ_MODULES:
            findings.append({
                "severity": "error",
                "line": item["line"],
                "symbol": item["name"],
                "message": "仍在导入聚宽专用模块。",
            })

    for call in visitor.calls:
        leaf = call["name"].split(".")[-1]
        if leaf in JQ_TOKENS:
            findings.append({
                "severity": "error",
                "line": call["line"],
                "symbol": call["name"],
                "message": "发现可能尚未迁移的聚宽调用。",
            })

    passorder_calls = [
        call for call in visitor.calls
        if call["name"].split(".")[-1] == "passorder"
    ]

    scheduler_node = next(
        (item for item in visitor.function_nodes
         if item.name == "_run_daily_once"), None
    )
    if scheduler_node is not None:
        scheduler_source = function_source_text(
            source, scheduler_node, visitor.function_nodes
        )
        if re.search(
                r"runtime_minute\s*!=\s*effective_time|"
                r"effective_time\s*!=\s*runtime_minute",
                scheduler_source):
            findings.append({
                "severity": "error",
                "line": scheduler_node.lineno,
                "symbol": "live-catch-up",
                "message": (
                    "日任务调度仍要求精确分钟；默认应在每根bar上判断"
                    "K线时间是否大于等于目标时间。"
                ),
            })
        if (
                "context.current_dt" not in scheduler_source
                or "target_time" not in scheduler_source):
            findings.append({
                "severity": "error",
                "line": scheduler_node.lineno,
                "symbol": "routine-handlebar-time",
                "message": (
                    "日任务调度必须只使用 context.current_dt 的 K线时间"
                    "与 target_time 判断是否到期。"
                ),
            })
        if "executed_routines" not in scheduler_source:
            findings.append({
                "severity": "error",
                "line": scheduler_node.lineno,
                "symbol": "routine-executed-state",
                "message": (
                    "日任务调度缺少 g.executed_routines 当日执行集合；"
                    "每个到期任务必须在当前进程内只执行一次。"
                ),
            })
        if any(item in scheduler_source for item in (
                "_runtime_datetime", "live_target_time", "LIVE补运行")):
            findings.append({
                "severity": "error",
                "line": scheduler_node.lineno,
                "symbol": "routine-wall-clock",
                "message": (
                    "日任务调度包含 LIVE 墙钟或补运行特殊分支；默认应由"
                    "handlebar K线时间统一驱动。"
                ),
            })
        handlebar_node = next(
            (item for item in visitor.function_nodes
             if item.name == "handlebar"), None
        )
        handlebar_source = function_source_text(
            source, handlebar_node, visitor.function_nodes
        ) if handlebar_node is not None else ""
        if (
                "executed_routines = set" not in handlebar_source
                or "active_date" not in handlebar_source):
            findings.append({
                "severity": "error",
                "line": scheduler_node.lineno,
                "symbol": "routine-daily-reset",
                "message": (
                    "handlebar 未在 K线日期变化时清空 executed_routines；"
                    "日任务状态会错误延续到下一交易日。"
                ),
            })

    uses_dynamic_detail_cache = (
        "instrument_detail_cache" in source
        and (
            "UpStopPrice" in source
            or "DownStopPrice" in source
        )
    )
    if uses_dynamic_detail_cache:
        dynamic_handlebar_node = next(
            (item for item in visitor.function_nodes
             if item.name == "handlebar"), None
        )
        dynamic_handlebar_source = function_source_text(
            source, dynamic_handlebar_node, visitor.function_nodes
        ) if dynamic_handlebar_node is not None else ""
        has_dynamic_cache_reset = (
            "_invalidate_instrument_detail_cache" in dynamic_handlebar_source
            or bool(re.search(
                r"instrument_detail_cache\s*=\s*\{\s*\}",
                dynamic_handlebar_source,
            ))
        )
        if not has_dynamic_cache_reset:
            findings.append({
                "severity": "error",
                "line": (
                    dynamic_handlebar_node.lineno
                    if dynamic_handlebar_node is not None else None
                ),
                "symbol": "dynamic-detail-daily-reset",
                "message": (
                    "策略缓存合约详情并使用 UpStopPrice/DownStopPrice，"
                    "但 handlebar 未在 K线日期变化时清空动态详情缓存。"
                ),
            })
        force_refresh_calls = [
            call for call in visitor.calls
            if call["name"].split(".")[-1] == "_instrument_detail"
            and literal_value(call["keywords"].get("refresh")) is True
            and literal_value(call["keywords"].get("iscomplete")) is True
        ]
        if len(force_refresh_calls) < 2:
            findings.append({
                "severity": "error",
                "line": None,
                "symbol": "dynamic-detail-refresh",
                "message": (
                    "LIVE 使用涨跌停价时，买入定量和最终报单前必须分别"
                    "以完整详情强制刷新当日 UpStopPrice/DownStopPrice。"
                ),
            })

    if passorder_calls:
        call_names = set(
            item["name"].split(".")[-1] for item in visitor.calls
        )
        freshness_node = next(
            (item for item in visitor.function_nodes
             if item.name == "qmt_live_bar_fresh"), None
        )
        freshness_source = function_source_text(
            source, freshness_node, visitor.function_nodes
        ) if freshness_node is not None else ""
        freshness_call_functions = set(
            item["function"] for item in visitor.calls
            if item["name"].split(".")[-1] == "qmt_live_bar_fresh"
        )
        if (
                freshness_node is None
                or not live_freshness_window_is_exact(
                    freshness_node, visitor.constant_assignments
                )):
            findings.append({
                "severity": "error",
                "line": (
                    freshness_node.lineno if freshness_node is not None
                    else passorder_calls[0]["line"]
                ),
                "symbol": "live-bar-window",
                "message": (
                    "LIVE 行情新鲜度必须使用包含边界的绝对时间差："
                    "abs((runtime - bar_time).total_seconds()) <= 180；"
                    "不得使用单向、按周期变化或其他阈值。"
                ),
            })
        freshness_has_last_bar = bool(
            freshness_node is not None
            and any(
                isinstance(item, ast.Call)
                and dotted_name(item.func).split(".")[-1] == "is_last_bar"
                for item in ast.walk(freshness_node)
            )
        )
        freshness_has_same_date = bool(re.search(
            r"\.date\s*\(\s*\)\s*(?:==|!=)|"
            r"(?:==|!=)\s*[^\n]*\.date\s*\(",
            freshness_source,
        ))
        passorder_functions = set(
            item["function"] for item in passorder_calls
        )
        missing_depth_functions = sorted(
            str(item) for item in ({"handlebar"} | passorder_functions)
            if item not in freshness_call_functions
        )
        if (
                not freshness_has_last_bar
                or not freshness_has_same_date
                or missing_depth_functions):
            details = (
                "；缺少守卫的函数：{0}".format(
                    ", ".join(missing_depth_functions)
                ) if missing_depth_functions else ""
            )
            findings.append({
                "severity": "error",
                "line": (
                    freshness_node.lineno if freshness_node is not None
                    else passorder_calls[0]["line"]
                ),
                "symbol": "live-bar-depth",
                "message": (
                    "qmt_live_bar_fresh 必须同时检查 is_last_bar、同一日期，"
                    "并在 handlebar 入口和每个最终 passorder 适配函数中调用"
                    + details + "。"
                ),
            })
        if "is_last_bar" not in call_names:
            findings.append({
                "severity": "error",
                "line": passorder_calls[0]["line"],
                "symbol": "live-bar-freshness",
                "message": (
                    "存在 passorder，但未检查 C.is_last_bar；LIVE 历史/缓存 bar"
                    "可能触发真实委托。"
                ),
            })
        has_runtime_clock = bool(re.search(
            r"\b(?:datetime\s*\.\s*now|date\s*\.\s*today)\s*\(",
            source,
        ))
        has_date_comparison = bool(re.search(
            r"\.date\s*\(\s*\)\s*(?:==|!=)|(?:==|!=)\s*[^\n]*\.date\s*\(",
            source,
        ))
        if not has_runtime_clock or not has_date_comparison:
            findings.append({
                "severity": "error",
                "line": passorder_calls[0]["line"],
                "symbol": "live-bar-date",
                "message": (
                    "存在 passorder，但未发现 bar 日期与 LIVE 运行日期的显式比较；"
                    "is_last_bar=True 不代表是当前交易日。"
                ),
            })
        if "deal_callback" not in visitor.definitions:
            findings.append({
                "severity": "error",
                "line": passorder_calls[0]["line"],
                "symbol": "deal_callback",
                "message": "LIVE 委托必须用成交回报确认实际成交价格和数量。",
            })
        for field in ("m_strRemark", "m_dPrice", "m_nVolume", "m_strTradeID"):
            if field not in source:
                findings.append({
                    "severity": "error",
                    "line": passorder_calls[0]["line"],
                    "symbol": field,
                    "message": (
                        "LIVE 成交关联/滑点统计缺少官方 Deal 字段 {0}。"
                    ).format(field),
                })
        if "slippage" not in source.lower() and "滑点" not in source:
            findings.append({
                "severity": "error",
                "line": passorder_calls[0]["line"],
                "symbol": "live-slippage",
                "message": "LIVE 委托未记录参考价、最终成交价和方向化滑点。",
            })
        for field in ("latest_reference_price", "final_deal_price"):
            if field not in source:
                findings.append({
                    "severity": "error",
                    "line": passorder_calls[0]["line"],
                    "symbol": field,
                    "message": (
                        "市价单滑点日志必须同时记录 {0}。"
                    ).format(field),
                })
        for call in passorder_calls:
            pr_type_node = (
                call["args"][4] if len(call["args"]) > 4
                else call["keywords"].get("prType")
            )
            pr_type_value = literal_value(pr_type_node)
            if (
                    pr_type_value is None
                    and isinstance(pr_type_node, ast.Name)):
                pr_type_value = visitor.constant_assignments.get(
                    pr_type_node.id
                )
            if pr_type_value == 5:
                findings.append({
                    "severity": "error",
                    "line": call["line"],
                    "symbol": "latest-price-limit",
                    "message": (
                        "prType=5 是最新价限价，不是聚宽默认市价单；"
                        "普通沪深股票/ETF 应按市场核对 42/47 等市价类型。"
                    ),
                })
            user_order_id = (
                call["args"][9] if len(call["args"]) > 9
                else call["keywords"].get("userOrderId")
            )
            if user_order_id is None or literal_value(user_order_id) == "":
                findings.append({
                    "severity": "error",
                    "line": call["line"],
                    "symbol": "userOrderId",
                    "message": (
                        "passorder 必须提供非空、少于24字符的 userOrderId，"
                        "并通过 Deal.m_strRemark 关联成交。"
                    ),
                })

    market_data_calls = [
        call for call in visitor.calls
        if call["name"].split(".")[-1] == "get_market_data_ex"
    ]
    for call in market_data_calls:
        subscribe_node = call["keywords"].get("subscribe")
        if subscribe_node is None and len(call["args"]) >= 9:
            subscribe_node = call["args"][8]
        if subscribe_node is None:
            findings.append({
                "severity": "error",
                "line": call["line"],
                "symbol": call["name"],
                "message": (
                    "get_market_data_ex 必须显式指定 subscribe；"
                    "历史读取与盘中订阅不能依赖默认值。"
                ),
            })
            continue
        if "RUN_MODE" in referenced_names(subscribe_node):
            findings.append({
                "severity": "error",
                "line": call["line"],
                "symbol": "subscribe",
                "message": (
                    "禁止仅按 RUN_MODE 为所有行情请求决定订阅；"
                    "LIVE 中的历史请求仍须 subscribe=False。"
                ),
            })

        period_node = call["keywords"].get("period")
        if period_node is None and len(call["args"]) >= 3:
            period_node = call["args"][2]
        end_node = call["keywords"].get("end_time")
        if end_node is None and len(call["args"]) >= 5:
            end_node = call["args"][4]
        period_value = literal_value(period_node)
        subscribe_value = literal_value(subscribe_node)
        end_value = literal_value(end_node)
        has_historical_end = end_node is not None and end_value != ""
        if (
            period_value in ("1d", "daily")
            and subscribe_value is True
            and has_historical_end
        ):
            findings.append({
                "severity": "error",
                "line": call["line"],
                "symbol": "historical-subscribe",
                "message": (
                    "带历史结束时间的日线请求不应 subscribe=True；"
                    "预下载后从本地读取，避免占用实时订阅额度。"
                ),
            })

    subscribe_calls = [
        call for call in visitor.calls
        if call["name"].split(".")[-1] == "subscribe_quote"
    ]
    unsubscribe_calls = [
        call for call in visitor.calls
        if call["name"].split(".")[-1] == "unsubscribe_quote"
    ]
    if subscribe_calls and not unsubscribe_calls:
        findings.append({
            "severity": "error",
            "line": subscribe_calls[0]["line"],
            "symbol": "subscription-lifecycle",
            "message": (
                "使用 subscribe_quote 后必须保存订阅号，并在换池或 stop 中"
                "调用 unsubscribe_quote 释放。"
            ),
        })

    for call in visitor.calls:
        if call["name"].split(".")[-1] == "set_universe":
            findings.append({
                "severity": "warning",
                "line": call["line"],
                "symbol": call["name"],
                "message": (
                    "set_universe 属于不可按订阅号释放的旧股票池订阅路径；"
                    "动态池优先显式 subscribe_quote/unsubscribe_quote。"
                ),
            })

    for function_node in visitor.function_nodes:
        name_lower = function_node.name.lower()
        if "suspend" not in name_lower and "pause" not in name_lower:
            continue
        function_source = function_source_text(
            source, function_node, visitor.function_nodes
        )
        if "volume" not in function_source:
            continue
        if re.search(
            r"if\s+[^\n]*(?:is\s+None|\.empty)[^:]*:\s*\n\s*return\s+True",
            function_source,
        ):
            findings.append({
                "severity": "error",
                "line": function_node.lineno,
                "symbol": function_node.name,
                "message": (
                    "空分钟行情属于 DATA_UNAVAILABLE，不能直接判为停牌。"
                ),
            })
        if re.search(
            r"(?:fill_data|fill_paused)\s*=\s*True",
            function_source,
        ):
            findings.append({
                "severity": "error",
                "line": function_node.lineno,
                "symbol": function_node.name,
                "message": (
                    "成交量停牌判断必须禁用 K 线填充，避免缺失数据合成零量。"
                ),
            })
        if ".all()" in function_source and "DATA_UNAVAILABLE" not in function_source:
            findings.append({
                "severity": "error",
                "line": function_node.lineno,
                "symbol": function_node.name,
                "message": (
                    "成交量停牌判断必须区分 ACTIVE/SUSPENDED/DATA_UNAVAILABLE，"
                    "并验证至少 N 根当前交易日真实 K 线。"
                ),
            })

    direct_logs = []
    for call in visitor.calls:
        name = call["name"]
        leaf = name.split(".")[-1]
        is_print = name == "print"
        is_traceback = name == "traceback.print_exc"
        is_logger = (
            leaf in LOG_METHODS
            and (
                name.startswith("log.")
                or name.startswith("logger.")
                or name.startswith("logging.")
            )
        )
        if (
            (is_print or is_traceback or is_logger)
            and call["function"] != "qmt_log"
        ):
            direct_logs.append(call)
            findings.append({
                "severity": "error",
                "line": call["line"],
                "symbol": name,
                "message": (
                    "策略日志必须经 qmt_log 输出并记录 QMT 策略名和"
                    "触发日志的 K 线时间。"
                ),
            })

    qmt_log_calls = [
        item for item in visitor.calls if item["function"] == "qmt_log"
    ]
    qmt_log_strings = [
        item["value"] for item in visitor.string_literals
        if item["function"] == "qmt_log"
    ]
    if (
        "qmt_log" in visitor.definitions
        and not any(
            item["name"].split(".")[-1] == "qmt_bar_time"
            for item in qmt_log_calls
        )
    ):
        findings.append({
            "severity": "error",
            "line": None,
            "symbol": "qmt_log",
            "message": "qmt_log 未调用 qmt_bar_time，无法保证日志带 K 线时间。",
        })
    if (
        "qmt_log" in visitor.definitions
        and not any(
            item["name"].split(".")[-1] == "qmt_strategy_name"
            for item in qmt_log_calls
        )
    ):
        findings.append({
            "severity": "error",
            "line": None,
            "symbol": "qmt_log",
            "message": "qmt_log 未调用 qmt_strategy_name，无法区分多策略日志。",
        })
    if (
        "qmt_log" in visitor.definitions
        and not any("K线时间" in value for value in qmt_log_strings)
    ):
        findings.append({
            "severity": "error",
            "line": None,
            "symbol": "qmt_log",
            "message": "qmt_log 的输出格式未包含“K线时间”字段。",
        })
    if (
        "qmt_log" in visitor.definitions
        and not any("策略名" in value for value in qmt_log_strings)
    ):
        findings.append({
            "severity": "error",
            "line": None,
            "symbol": "qmt_log",
            "message": "qmt_log 的输出格式未包含“策略名”字段。",
        })

    strategy_name_node = next(
        (item for item in visitor.function_nodes
         if item.name == "qmt_strategy_name"), None
    )
    if strategy_name_node is not None:
        strategy_name_source = function_source_text(
            source, strategy_name_node, visitor.function_nodes
        )
        if "title" not in strategy_name_source:
            findings.append({
                "severity": "error",
                "line": strategy_name_node.lineno,
                "symbol": "qmt_strategy_name",
                "message": "策略名解析器必须优先读取 QMT 运行时 C.title。",
            })
        if "STRATEGY_NAME" not in strategy_name_source:
            findings.append({
                "severity": "error",
                "line": strategy_name_node.lineno,
                "symbol": "qmt_strategy_name",
                "message": "策略名解析器必须提供显式 STRATEGY_NAME 安全回退。",
            })

    bar_time_calls = [
        item["name"].split(".")[-1] for item in visitor.calls
        if item["function"] == "qmt_bar_time"
    ]
    for required_call in ("get_bar_timetag", "timetag_to_datetime"):
        if (
            "qmt_bar_time" in visitor.definitions
            and required_call not in bar_time_calls
        ):
            findings.append({
                "severity": "error",
                "line": None,
                "symbol": "qmt_bar_time",
                "message": (
                    "qmt_bar_time 必须通过 C.get_bar_timetag(C.barpos)"
                    "与 timetag_to_datetime 获取 K 线时间。"
                ),
            })
    bar_time_node = next(
        (item for item in visitor.function_nodes
         if item.name == "qmt_bar_time"), None
    )
    if bar_time_node is not None:
        bar_time_source = function_source_text(
            source, bar_time_node, visitor.function_nodes
        )
        if not re.search(
                r"\bif\s+not\s+(?:timetag|value)\b|"
                r"(?:timetag|value)[^\n]*(?:>|!=|not)[^\n]*0|"
                r"_valid_[A-Za-z_]*timetag",
                bar_time_source):
            findings.append({
                "severity": "error",
                "line": bar_time_node.lineno,
                "symbol": "zero-timetag",
                "message": (
                    "qmt_bar_time 必须拒绝 0/空 timetag，避免记录为1970年时间。"
                ),
            })

    name_helper_calls = [
        item for item in visitor.calls
        if item["function"] == "qmt_instrument_name"
    ]
    name_helper_strings = [
        item["value"] for item in visitor.string_literals
        if item["function"] == "qmt_instrument_name"
    ]
    if (
        "qmt_instrument_name" in visitor.definitions
        and not any(
            item["name"].split(".")[-1] == "get_instrument_detail"
            for item in name_helper_calls
        )
    ):
        findings.append({
            "severity": "error",
            "line": None,
            "symbol": "qmt_instrument_name",
            "message": (
                "名称解析主路径必须调用 C.get_instrument_detail(code)"
                "并读取 InstrumentName。"
            ),
        })
    if (
        "qmt_instrument_name" in visitor.definitions
        and "InstrumentName" not in name_helper_strings
    ):
        findings.append({
            "severity": "error",
            "line": None,
            "symbol": "qmt_instrument_name",
            "message": (
                "名称解析器必须从合约详情字典读取 InstrumentName 字段。"
            ),
        })

    if (
        "qmt_instrument_name" in visitor.definitions
        and not any(
            item["name"].split(".")[-1] == "qmt_instrument_name"
            and item["function"] != "qmt_instrument_name"
            for item in visitor.calls
        )
    ):
        findings.append({
            "severity": "error",
            "line": None,
            "symbol": "qmt_instrument_name",
            "message": "定义了名称解析器但策略从未调用它。",
        })

    for call in visitor.calls:
        if call["name"].split(".")[-1] == "get_stock_name":
            findings.append({
                "severity": "error",
                "line": call["line"],
                "symbol": call["name"],
                "message": (
                    "get_stock_name 已被官方标为计划废弃；"
                    "改用 get_instrument_detail(code)['InstrumentName']。"
                ),
            })

    for item in visitor.string_literals:
        if UNKNOWN_NAME_PATTERN.search(item["value"]):
            findings.append({
                "severity": "error",
                "line": item["line"],
                "symbol": "instrument-name",
                "message": (
                    "禁止把名称查询失败静默显示为“未知名称/unknown”；"
                    "记录代码、接口返回或异常并修复根因。"
                ),
            })

    instrument_name_node = next(
        (item for item in visitor.function_nodes
         if item.name == "qmt_instrument_name"), None
    )
    if instrument_name_node is not None:
        code_fallback = False
        for item in ast.walk(instrument_name_node):
            if not isinstance(item, ast.Return):
                continue
            value = item.value
            if isinstance(value, ast.Name) and value.id == "code":
                code_fallback = True
            elif isinstance(value, ast.BoolOp) and isinstance(value.op, ast.Or):
                code_fallback = any(
                    isinstance(part, ast.Name) and part.id == "code"
                    for part in value.values[1:]
                )
            elif isinstance(value, ast.IfExp):
                code_fallback = (
                    isinstance(value.orelse, ast.Name)
                    and value.orelse.id == "code"
                )
            elif (
                    isinstance(value, ast.Call)
                    and isinstance(value.func, ast.Attribute)
                    and value.func.attr == "get"
                    and value.args
                    and literal_value(value.args[0]) == "InstrumentName"
                    and len(value.args) > 1
                    and isinstance(value.args[1], ast.Name)
                    and value.args[1].id == "code"):
                code_fallback = True
            if code_fallback:
                findings.append({
                    "severity": "error",
                    "line": item.lineno,
                    "symbol": "instrument-name",
                    "message": (
                        "名称查询失败时不得静默回退为证券代码；"
                        "应记录接口返回或异常并修复根因。"
                    ),
                })
                break

    for match in NON_QMT_CODE_PATTERN.finditer(source):
        findings.append({
            "severity": "error",
            "line": source.count("\n", 0, match.start()) + 1,
            "symbol": match.group(0),
            "message": (
                "发现非 QMT 内部证券代码后缀；名称接口要求 symbol.market，"
                "期货不能使用界面展示后缀。"
            ),
        })

    if re.search(r"\bC\.[A-Za-z_]\w*\s*=", source):
        findings.append({
            "severity": "warning",
            "line": None,
            "symbol": "ContextInfo-state",
            "message": "发现向 C 写入属性；确认该状态可接受逐 K 线回退。",
        })

    errors = sum(item["severity"] == "error" for item in findings)
    return {
        "file": str(path),
        "decoded_as": decode_encoding,
        "encoding_declared": encoding_declared,
        "gbk_encodable": gbk_encodable,
        "python36_parse": tree is not None,
        "python36_note": syntax_note if tree is not None else None,
        "definitions": sorted(visitor.definitions),
        "errors": errors,
        "findings": findings,
    }


def markdown(report):
    lines = [
        "# QMT 策略静态检查",
        "",
        "- 文件：`{0}`".format(report["file"]),
        "- GBK 声明：{0}".format("有" if report["encoding_declared"] else "无"),
        "- GBK 可编码：{0}".format("是" if report["gbk_encodable"] else "否"),
        "- Python 3.6 解析：{0}".format(
            "通过" if report["python36_parse"] else "不通过"
        ),
        "- 错误数：{0}".format(report["errors"]),
        "",
        "## 发现",
        "",
    ]
    if not report["findings"]:
        lines.append("- 未发现静态问题；仍需 QMT 客户端运行与回测验证。")
    for item in report["findings"]:
        location = " L{0}".format(item["line"]) if item["line"] else ""
        lines.append(
            "- **{0}** `{1}`{2}：{3}".format(
                item["severity"], item["symbol"], location, item["message"]
            )
        )
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check migrated QMT strategy source."
    )
    parser.add_argument("strategy", type=Path, help="QMT Python source file")
    parser.add_argument(
        "--format", choices=("markdown", "json"), default="markdown"
    )
    args = parser.parse_args(argv)
    if not args.strategy.is_file():
        parser.error("strategy file does not exist: {0}".format(args.strategy))

    report = check(args.strategy)
    if args.format == "json":
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        sys.stdout.write(markdown(report))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
