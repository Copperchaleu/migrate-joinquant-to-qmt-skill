# 策略名、K 线日志与标的名称

## 目录

1. 统一日志与策略名
2. 规范化 QMT 代码
3. 获取名称
4. 名称失败诊断
5. 验收样本

## 1. 统一日志与策略名

所有由策略代码主动产生的 `INFO/WARN/ERROR/DEBUG` 输出都经 `qmt_log`，并包含 QMT 当前运行模型标题和该输出对应的 K 线时间。平台自身日志不在策略控制范围内。

QMT 运行框架会在调用用户 `init(C)` 前设置 `C.title`：优先使用启动参数中的 `title`，为空时使用策略脚本文件名。因此策略名解析优先读取 `C.title`。旧客户端兼容回退顺序为 `C._param['title']`、`C.user_script` 的无扩展名文件名、显式 `STRATEGY_NAME`。不要假定存在未在当前官方系统函数文档公开的 `C.get_strategy_name()`。

推荐骨架：

```python
import os


def _qmt_runtime_text(value):
    if isinstance(value, bytes):
        for encoding in ("gbk", "utf-8"):
            try:
                return value.decode(encoding).strip()
            except Exception:
                pass
        return ""
    try:
        return str(value or "").strip()
    except Exception:
        return ""


def qmt_strategy_name(C):
    context = C if C is not None else getattr(g, "context_info", None)
    if context is not None:
        title = _qmt_runtime_text(getattr(context, "title", ""))
        if not title:
            params = getattr(context, "_param", None)
            if isinstance(params, dict):
                title = _qmt_runtime_text(params.get("title", ""))
        if not title:
            user_script = _qmt_runtime_text(
                getattr(context, "user_script", "")
            )
            if user_script:
                normalized_path = user_script.replace("\\", "/")
                title = os.path.splitext(os.path.basename(normalized_path))[0]
        if title:
            g.runtime_strategy_name = title
            return title
    cached = _qmt_runtime_text(getattr(g, "runtime_strategy_name", ""))
    return cached if cached else STRATEGY_NAME


def qmt_bar_time(C):
    try:
        timetag = C.get_bar_timetag(C.barpos)
        value = timetag_to_datetime(timetag, "%Y-%m-%d %H:%M:%S")
        return str(value) if value else "无可用K线"
    except Exception:
        return "无可用K线"


def qmt_log(C, level, message, bar_time=None):
    value = bar_time if bar_time else qmt_bar_time(C)
    print("[策略名={0}] [K线时间={1}] [{2}] {3}".format(
        qmt_strategy_name(C), value, level, message
    ))
```

执行要求：

- 在 `handlebar` 开头只计算一次当前 K 线时间；同一轮调用的日志复用该值。
- `init(C)`、`handlebar(C)`、定时器和交易回报回调都把当前 `C` 传给 `qmt_log`；无直接 `C` 的业务函数从全局状态读取最近一次有效上下文。
- 不把固定常量作为首选日志策略名。QMT 返回非空 `C.title` 时，每条日志必须原样使用该标题；只有运行时信息不可用时才回退。
- 在定时器、订阅或交易回报回调注册时，让闭包保留 `C`，或从全局状态读取最近一次已确认的 K 线时间。
- 不使用 `datetime.now()`、`time.time()` 或委托回报时间替代 K 线时间。需要事件时间时另设 `事件时间=` 字段，但仍保留 `K线时间=`。
- 不直接调用 `print`、`log.info/warning/error/debug`、`logging.*` 或 `traceback.print_exc`。捕获异常后将异常类型与信息交给 `qmt_log`。
- 初始化尚无 bar 时尽量不输出；必须输出时使用 `K线时间=无可用K线`。
- `get_bar_timetag` 返回 `0` 时必须先判无效，不能交给 `timetag_to_datetime` 后记录成 `1970-01-01`。
- LIVE 新鲜度检查可读取本机时间，但只能作为消息中的 `runtime/事件时间`；日志前缀仍保留真实 bar 时间。

## 2. 规范化 QMT 代码

名称接口要求 `symbol.market` 格式。常用映射：

| 聚宽 | QMT 内部代码 |
|---|---|
| `.XSHG` | `.SH` |
| `.XSHE` | `.SZ` |
| `.XBSE` | `.BJ` |

QMT 的期货内部市场后缀为 `IF/SF/DF/ZF/INE/GF`，与界面展示的 `CFFEX/SHFE/DCE/CZCE/INE/GFEX` 不完全相同。期货 symbol 大小写敏感。股票期权还可能使用 `.SHO/.SZO`；以当前数据字典为准。

禁止仅删除后缀或把展示后缀直接拼到 symbol 上。

## 3. 获取名称

优先使用当前内置 Python 接口：

```python
def qmt_instrument_name(C, code, cache):
    if code in cache:
        return cache[code]

    detail = None
    try:
        detail = C.get_instrument_detail(code)
    except AttributeError:
        # 兼容旧客户端；旧接口名没有下划线。
        detail = C.get_instrumentdetail(code)
    except Exception as exc:
        qmt_log(
            C,
            "ERROR",
            "标的名称查询异常 code={0} error={1}".format(code, exc),
        )
        return ""

    name = detail.get("InstrumentName", "") if isinstance(detail, dict) else ""
    name = name.strip() if isinstance(name, str) else ""
    if not name:
        qmt_log(
            C,
            "ERROR",
            "标的名称查询失败 code={0} detail={1}".format(code, detail),
        )
        return ""

    cache[code] = name
    return name
```

不要把 `C.get_stock_name` 作为主路径：官方文档已标为计划废弃，并建议改用 `get_instrument_detail(...)[\"InstrumentName\"]`。

## 4. 名称失败诊断

按顺序检查：

1. 代码是否完整包含内部市场后缀；
2. 是否仍使用 `.XSHG/.XSHE/.XBSE`；
3. 是否误用 `CFFEX/SHFE/DCE/CZCE/GFEX` 等展示后缀；
4. 期货 symbol 大小写是否正确；
5. 当前客户端是否提供 `get_instrument_detail`，旧版是否需要 `get_instrumentdetail`；
6. 返回对象是否为字典且含非空 `InstrumentName`；
7. 客户端合约基础信息是否已更新，标的是否属于当前权限/市场。

禁止统一回退为“未知名称”。失败日志必须保留代码、返回值或异常，迁移报告必须列出失败标的。

## 5. 验收样本

- `000001.SZ` 应解析为 `平安银行`。
- 对策略静态股票池、当日动态股票池、持仓、委托和成交代码逐个解析。
- 检查每一条策略主动日志均包含 `策略名=` 与 `K线时间=`；抽样确认策略名等于 QMT `C.title`，K 线时间等于触发该输出的 bar。
