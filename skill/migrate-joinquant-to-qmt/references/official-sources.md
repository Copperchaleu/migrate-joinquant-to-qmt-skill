# 官方资料路由

迁移前重新访问与实际策略相关的页面。平台文档会更新；本 skill 内的摘要只用于定位，不替代当前官方定义。

## 核心入口

| 来源 | URL | 用途 |
|---|---|---|
| 聚宽 API | https://www.joinquant.com/help/api/help#name:api | 生命周期、行情、财务、订单、账户对象 |
| 聚宽 API PDF | https://cdn.joinquant.com/help/img/JoinQuantAPI.pdf | 网页无法检索时核对完整 API 与运行时序 |
| 聚宽数据字典 | https://www.joinquant.com/data | 数据品类、覆盖范围、字段入口 |
| QMT 内置 Python API | https://dict.thinktrader.net/innerApi/start_now.html?id=lwfP9S | 运行机制与内置策略入口 |
| QMT 数据字典 | https://dict.thinktrader.net/dictionary/?id=lwfP9S | 行情、财务、特色数据字段与权限 |
| XtQuant | https://dict.thinktrader.net/nativeApi/start_now.html?id=lwfP9S | 以Python库的形式提供策略交易所需要的行情和交易相关的API接口 |
| 官方迁移指南 | https://dict.thinktrader.net/strategy/JoinQuant2QMT.html?id=lwfP9S | 聚宽到 QMT 基础示例 |

若带 `id` 的链接无法打开，移除查询参数后访问同一路径。

## QMT 重点页

- 系统函数：<https://dict.thinktrader.net/innerApi/system_function.html>
- 行情函数：<https://dict.thinktrader.net/innerApi/data_function.html>
- 变量与证券代码约定：<https://dict.thinktrader.net/innerApi/variable_convention.html>
- 交易函数：<https://dict.thinktrader.net/innerApi/trading_function.html>
- 数据结构：<https://dict.thinktrader.net/innerApi/data_structure.html>
- 枚举常量：<https://dict.thinktrader.net/innerApi/enum_constants.html>
- 成交回报回调：<https://dict.thinktrader.net/innerApi/callback_function.html>
- 使用须知：<https://dict.thinktrader.net/innerApi/user_attention.html>
- 常见问题：<https://dict.thinktrader.net/innerApi/question_answer.html>
- 股票与财务数据：<https://dict.thinktrader.net/dictionary/stock.html>

## ETF 板块接口：2026-07-31 已核对

- 内置 Python：`ContextInfo.get_stock_list_in_sector(sectorname, realtime)`；`realtime` 为毫秒级时间戳，支持客户端左侧板块和自定义板块。官方示例也展示省略第二参数的最新查询。
- 原生 `xtdata`：文档中的 `xtdata.get_stock_list_in_sector(sector_name)` 使用板块名查询，且板块列表/成分依赖已下载的板块分类信息；`xtdata.get_sector_list()` 可用于发现本机实际名称。
- 场内基金文档以 `沪深基金` 为示例；实测客户端还可能提供 `沪深ETF`、`沪市基金`、`沪市ETF`、`深市基金`、`深市ETF`。策略不得只依赖一个名称。
- `ContextInfo` 的第二参数能被接受不表示历史 ETF 板块快照一定可用。历史调用返回空列表时，先记录该事实；禁止把无参数最新结果静默视为历史结果。

## 行情订阅机制：2026-08-01 已核对

- QMT 区分本地数据、全推最新快照和指定品种订阅数据。`get_market_data_ex(subscribe=False)` 只读本地；`get_full_tick` 取无需逐标的订阅的最新全推快照；连续当日 K 线使用订阅数据。
- 订阅有权限上限，不同品种与周期分别计数。超限可能返回前值填充或不更新的数据，不能继续据此判断成交量或停牌。
- `get_market_data_ex(subscribe=True)` 会自动订阅，但没有订阅号，停止策略前无法主动释放。动态股票池优先 `ContextInfo.subscribe_quote` 保存返回的订阅号，并用 `ContextInfo.unsubscribe_quote` 释放。
- `ContextInfo.subscribe_quote(stock_code, period, dividend_type, result_type, callback)` 返回订阅号；`ContextInfo.unsubscribe_quote(subId)` 负责反订阅。
- 官方建议大股票池使用历史下载/本地读取与 `get_full_tick` 组合，避免把全市场历史请求变成实时订阅。

## LIVE 驱动与成交回报：2026-08-03 已核对

- 非交易时间行情服务准备、重启或重订阅可能把最新合并数据推入缓存并触发 `handlebar`；只触发最右侧 bar，不回放整个历史区间。`C.is_last_bar()` 只说明该 bar 位于最右侧，不能证明属于当前交易日或足够新鲜。
- `quickTrade=2` 在任何 bar 状态下调用都会立即报单，官方通常不建议在逐 bar 的 `handlebar` 中使用；若业务确需立即报单，必须先通过 LIVE bar 日期、延迟和幂等守卫。
- `passorder` 是异步且无返回值。调用返回不代表柜台接受或成交；委托、成交、持仓和账户由客户端后台更新。
- `userOrderId` 长度小于 24 字符，并通过委托/成交对象 `m_strRemark` 返回，可用于关联回报。`Deal` 的官方成交字段为 `m_dPrice`、`m_nVolume`、`m_strTradeID`、`m_dTradeAmount`。
- 核对页面：常见问题、系统函数、交易函数、数据结构、成交回报回调和完整示例。

## 沪深股票市价委托：2026-08-04 已核对

- QMT `prType=5 (PRTP_LATEST)` 是最新价限价，不等于市价委托。
- 官方股票示例中，沪市 `prType=42` 为“最优五档即时成交剩余撤销申报”；深市对应共同语义使用 `prType=47`“最优五档即时成交剩余撤销委托”。两者均可能部分成交后撤销剩余量。
- 市价类型的 `price` 是保护限价；传 `0` 时由 QMT 自动使用对应涨跌停价。策略仍须在报单前读取 `get_full_tick.lastPrice` 作为滑点基准，但不得把该价格传成实际限价。
- 因 `price=0` 会使用对应交易日的涨跌停价，`get_instrument_detail` 返回的 `UpStopPrice`、`DownStopPrice` 只能作为当日动态值使用，不能跨交易日缓存后继续用于买入验资或数量计算。
- 股票、ETF、期货、期权及不同交易所支持的市价类型不同；迁移时按品种和市场核对当前枚举，不能统一使用一个数值。

## 核对顺序

1. 从源代码提取实际使用的 API、字段、品种和周期。
2. 在聚宽文档确认参数默认值、返回形状、数据时点、复权和运行时序。
3. 在 QMT API 页确认函数签名与运行模式。
4. 在 QMT 数据字典确认字段、单位、历史范围和权限。
5. 在枚举页确认每个下单数字，不从其他品种示例类推。
6. 记录访问日期和无法访问/需要登录的页面。

## 已知高风险官方差异

- 聚宽分钟 `handle_data` 通常看到上一已完成分钟；QMT `handlebar` 盘中由 tick 驱动，必须显式控制只在目标 bar/时间执行。
- QMT 回测主要读取本地下载数据；缺失的基础周期会改变可用历史。
- `get_market_data_ex` 的 `dividend_type`、`fill_data`、`subscribe` 会改变结果口径。
- QMT `ContextInfo` 具有逐 K 线保存/回退机制，不等同于普通 Python 全局状态。
- QMT `passorder` 为异步委托；账户查询读取客户端缓存，不保证紧随委托即时更新。
- QMT 内置 Python 文档以 3.6.8 为基线，策略文件通常要求 GBK 编码。
- `ContextInfo.get_stock_name` 已标为计划废弃；名称优先从 `ContextInfo.get_instrument_detail(code)` 返回的 `InstrumentName` 读取，旧客户端接口名为 `get_instrumentdetail`。
- QMT 合约代码使用内部 `symbol.market` 后缀；期货内部后缀与界面展示后缀可能不同，且 symbol 大小写敏感。
