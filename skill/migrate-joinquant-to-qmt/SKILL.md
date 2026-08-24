---
name: migrate-joinquant-to-qmt
description: 将聚宽（JoinQuant/JQData）量化交易策略尽可能无损地迁移为迅投 QMT 内置 Python 策略，并审计事件生命周期、行情与财务数据、证券代码及标的名称、复权、停牌填充、调度、账户持仓、下单语义、K 线时间日志、回测撮合和 Python 3.6 兼容性。用于把聚宽策略源码或项目转换为 QMT 策略、评审已有迁移结果、修复“未知名称”或日志时间错误、排查两平台回测差异，或生成迁移映射与验收报告；适用于股票、ETF、基金、指数、期货、期权及多因子策略。
---

# 聚宽策略迁移到 QMT

以“交易意图和时序语义等价”为目标迁移策略。保留原策略，不顺手优化选股、择时、风控或参数；将任何无法直接等价的部分显式列为差异、假设或待验证项。

## 先加载资源

1. 当运行时安装、发现、调用方式或工具可用性会影响工作时，先读取 [references/runtime-compatibility.md](references/runtime-compatibility.md)。从当前运行时提供的技能根目录解析本技能的 `scripts/` 和 `references/`，而不是假定当前工作目录或专有工具名。
2. 始终读取 [references/mapping-guide.md](references/mapping-guide.md)。
3. 涉及数据字段、QMT 枚举或平台行为时，读取 [references/official-sources.md](references/official-sources.md)，并重新核对相关官方页面。
4. 开始验证前读取 [references/parity-checklist.md](references/parity-checklist.md)。
5. 需要规范化交付说明时读取 [references/migration-report-template.md](references/migration-report-template.md)。
6. 生成或检查日志、证券代码和标的名称时读取 [references/observability-and-symbols.md](references/observability-and-symbols.md)。
7. 涉及实盘行情、历史下载、`subscribe`、`get_full_tick`、动态股票池或停牌判断时，读取 [references/market-data-and-subscriptions.md](references/market-data-and-subscriptions.md)。
8. 涉及 LIVE 调度、启动/重连、`is_last_bar`、`quickTrade`、委托/成交回报或滑点统计时，读取 [references/live-scheduling-and-execution.md](references/live-scheduling-and-execution.md)。

## 工作流

### 1. 保护输入并建立基线

- 保留聚宽源码原文件；另建 QMT 文件，不覆盖输入。
- 记录策略品种、周期、回测区间、初始资金、基准、手续费、滑点、复权、成交量限制和运行模式。
- 未提供的平台参数使用显式配置常量或 `TODO(QMT配置)`，不要猜账号、券商权限、数据授权或实盘报价方式。
- 若输入包含多文件、动态导入、研究文件或自定义数据，先列出依赖与入口文件。

### 2. 静态盘点聚宽依赖

使用当前运行时提供的命令执行能力，从本技能根目录运行：

```bash
python3 scripts/audit_jq_strategy.py path/to/jq_strategy.py --format markdown
```

需要机器可读结果时使用 `--format json`。结合人工检查确认：

- 生命周期与定时任务；
- 聚宽 API、数据表、查询 DSL、因子与第三方库；
- 证券代码和交易品种；
- 持仓、订单、撤单、成交回报与状态依赖；
- 当前 bar/上一根已完成 bar 的引用；
- Python 3.6 不兼容语法。

静态审计只用于发现迁移面，不证明策略正确或 API 已等价。

### 3. 建立语义映射表

为每个聚宽特性记录：

| 聚宽语义 | QMT实现 | 等价级别 | 风险/验证 |
|---|---|---|---|
| 原调用或行为 | 目标调用、适配器或调度器 | 直接/适配/无等价 | 数据时点、单位、返回形状、回测/实盘差异 |

优先级依次为：

1. 防止未来数据和 bar 偏移；
2. 保持调度时间与每次仅执行一次；
3. 保持复权、停牌、缺失值和成分股时点；
4. 保持下单目标、单位、可卖数量与成交假设；
5. 保持指标公式、排序、筛选和 tie-break；
6. 最后处理日志、绘图和非交易输出。

### 4. 改写运行骨架

- 将 `initialize` 改为 `init(C)`，将逐 bar 逻辑接入 `handlebar(C)`。
- 将聚宽 `g` 状态迁入自定义全局状态类；不要默认存入 `ContextInfo`，其盘中逐 K 线回退机制可能丢弃修改。
- 用 `C.get_bar_timetag(C.barpos)` 与 `timetag_to_datetime` 获取当前回测 bar 时间。
- 定义并强制使用统一的 `qmt_strategy_name(C)`、`qmt_bar_time(C)` 与 `qmt_log(C, level, message)`。`qmt_strategy_name` 优先读取 QMT 在调用用户 `init(C)` 前注入的运行时模型标题 `C.title`；兼容回退顺序为 `C._param['title']`、`C.user_script` 文件名、显式 `STRATEGY_NAME`。不要臆造官方未公开的 `get_strategy_name()` 方法。所有策略主动输出的日志都必须使用 `[策略名=...] [K线时间=...] [LEVEL] ...` 前缀；禁止在业务函数里直接调用 `print`、`log.*`、`logging.*` 或 `traceback.print_exc`。
- 定时器、行情回调和交易回报回调没有直接传入 `C` 时，显式传入或缓存最近一次已确认的 K 线时间。不要用系统墙上时钟冒充 K 线时间。
- 初始化阶段尚无有效 bar 时，避免主动输出日志；确需输出时明确记录 `K线时间=无可用K线`，不得伪造时间。
- 从当前 QMT“变量约定”核对回测/实盘状态字段；不要假设 `C.do_back_test` 等属性必然存在。无法确认时使用显式 `RUN_MODE` 配置。
- 为 `run_daily/run_weekly/run_monthly`、开盘前和收盘后任务建立统一的 `handlebar` 调度器。LIVE 与 BACKTEST 都只使用当前 K 线时间：当 `context.current_dt.strftime("%H:%M") >= target_time` 且任务尚未执行时运行，否则跳过。
- 在全局状态中维护当日已执行任务集合（例如 `g.executed_routines`）；检测到 K 线日期变化时清空。每根 bar 必须按源策略注册顺序和业务依赖顺序逐项检查，保证晚于目标时间启动时从当天最早的到期任务开始顺序执行，未到时间的任务不提前执行。
- 不要为日任务另建 LIVE 墙钟调度分支、`live_target_time`、精确分钟条件、`LIVE补运行` 特殊路径或交易日历缓存。调度判断不得读取本机时间；系统墙钟只用于 LIVE 行情新鲜度和事件诊断，策略日志前缀仍保留真实 K 线时间。
- LIVE 不能只检查 `C.is_last_bar()`：它只表示最右侧 K 线。还要解析 `C.get_bar_timetag(C.barpos)`，确认 bar 日期等于本机日期，并使用固定双向窗口 `abs((runtime - bar_time).total_seconds()) <= 180` 校验行情新鲜度。`-180` 与 `+180` 秒边界均通过，超出任一方向都失败关闭；不得改成单向差值、按主图周期变化的阈值或其他秒数。当前简化调度不再依赖 `get_trading_calendar` 或 `C.get_trading_dates`。
- 明确报告内存幂等边界：任务集合只能保证当前 Python 进程内不重复；客户端重启后集合重建，所有按当前 K 线时间已经到期的任务会再次执行。交易任务必须结合账户/持仓新快照、同方向在途委托、目标仓位差额和订单唯一键防止重复报单。
- 在 `handlebar` 入口和最终下单适配器中各执行一次 LIVE 新鲜度检查，形成纵深保护；旧 bar 即使绕过调度器也不能到达 `passorder`。
- `get_bar_timetag` 返回 `0`、空值或无法解析时必须视为“无可用K线”，不得显示成 `1970-01-01`。

### 5. 迁移数据层

- 先统一代码格式：`.XSHG → .SH`、`.XSHE → .SZ`；其他交易所逐项核对。
- 定义统一的 `qmt_instrument_name(C, code)` 并缓存结果。优先调用当前接口 `C.get_instrument_detail(code)`，从返回字典读取 `InstrumentName`；仅为兼容旧客户端才回退 `C.get_instrumentdetail(code)`。不要使用计划废弃的 `C.get_stock_name` 作为主路径。
- 在查名称前把标的规范化为 QMT 的 `symbol.market`，并核对交易所内部后缀：股票使用 `.SH/.SZ/.BJ`；期货内部后缀及大小写按 QMT 变量约定处理，不能把展示后缀如 `SHFE/CFFEX` 直接当作内部代码。
- 禁止把名称失败静默显示为“未知名称”或 `unknown`。名称为空时，用 `qmt_log` 输出 K 线时间、原代码、规范化代码、接口返回值或异常；将该标的列入迁移报告并在验收阶段视为失败。
- 至少用 `000001.SZ → 平安银行` 验证名称接口，再验证策略股票池、持仓和委托中每个标的均能得到非空名称。
- 使用 `C.get_market_data_ex` 适配行情，明确 `period`、`end_time`、`count`、`dividend_type`、`fill_data` 和 `subscribe`。
- 回测读取本地数据时显式使用 `subscribe=False`，并在交付说明中列出需要预下载的基础周期和品种。
- 不得把 `subscribe` 机械写成 `RUN_MODE == "LIVE"` 并套用到所有行情请求。按数据用途显式分层：截至前一交易日的历史日线/分钟线使用 `subscribe=False`；当日连续 K 线只为受控候选池订阅；最新价格、当日累计成交量和证券状态优先使用无需逐标的订阅的 `C.get_full_tick`。
- 大范围历史查询不得建立实时订阅。全市场 ETF 历史成交额、历史价格、均线和回看窗口必须读取已下载的本地数据，并对代码分批查询；本地数据缺失时记录下载要求，不得临时改成全市场 `subscribe=True`。
- 需要连续盘中 K 线时，优先用 `C.subscribe_quote` 显式订阅并保存订阅号；股票池变化或策略停止时调用 `C.unsubscribe_quote` 释放。候选池形成后尽早订阅，不要等到交易判断时才逐只懒订阅并立即读取最近 N 根 K 线。
- 订阅数受客户端权限限制，不同品种与周期分别占用额度。记录请求数、成功订阅数、失败数和失败样本；未成功订阅或 K 线不足必须标记为“行情不可用”，不得用零值、前值填充或空表继续生成交易信号。
- 停牌检测必须区分 `ACTIVE`、`SUSPENDED`、`DATA_UNAVAILABLE`。只有取得至少 N 根时间有效、属于当前交易日的真实分钟线，并确认这些线成交量均为零时，才可判为疑似临时停牌；空数据、少于 N 根、订阅失败和时间戳异常均属于数据不可用。用于此判断时禁用停牌填充，避免合成零成交量 K 线。
- 迁移“全市场 ETF / 场内基金”宇宙时，必须依次查询 QMT 的六个实际板块名：`沪深基金`、`沪深ETF`、`沪市基金`、`沪市ETF`、`深市基金`、`深市ETF`。对每个返回代码先规范化为 QMT 内部 `symbol.market`，再按代码去重；日志须分别记录每个板块的原始数量、规范化数量和最终并集数量。
- 当前内置 Python 官方原型为 `C.get_stock_list_in_sector(sectorname, realtime)`，其中 `realtime` 是可选的毫秒级时间戳；它不是名为 `timetag` 的公开关键字参数。可以把 `C.get_bar_timetag(C.barpos)` 作为第二个位置参数传入，但不得据此假定所有板块都提供历史快照。
- 板块查询的“返回空列表”与“抛出 `TypeError`”必须分开处理。历史调用返回空列表时，不能只等待异常回退；应记录 `历史板块为空`，再按显式策略决定是否查询无时间参数的最新板块。最新板块仅适用于实盘或明确授权的降级模式；在历史回测中它可能包含未来上市/当前分类数据，必须标记为潜在未来数据，不能静默当作历史等价数据。
- 若需要严格的历史 ETF 宇宙，而六个板块在历史时间戳均为空，标记为“QMT 无历史板块等价数据”，改用经验证的本地历史快照/外部导入快照；不得以当前板块成员替代。若用户选择可运行但非严格等价的降级方案，至少按回测日的上市日、退市日过滤，并在报告中说明剩余分类时点风险。
- 保留 ETF 来源板块与完整合约详情的独立缓存。不要让一次普通 `get_instrument_detail(code)` 的缓存覆盖后续 `get_instrument_detail(code, True)`；部分客户端普通详情中的 `ProductType` 会是 `-1`。当 `ProductType` 不能可靠识别时，记录来源板块和详情返回值，不得仅因名称不含 `ETF` 就静默丢弃来自 ETF 板块的代码。
- 区分合约详情中的静态字段和交易日动态字段。`InstrumentName` 等静态字段可以长期缓存；`UpStopPrice`、`DownStopPrice` 等当日字段不得跨交易日复用。检测到 K 线日期切换时清空动态详情缓存；LIVE 买入计算数量和最终调用 `passorder` 前都必须强制刷新当日 `UpStopPrice`。
- 将聚宽 DataFrame/Panel/对象返回值适配为策略原先期望的索引、列名、排序和标量类型；不要在业务逻辑中散落平台形状差异。
- 迁移财务、因子、行业、概念和历史成分股时验证“可知日/公告日”语义。QMT 只有当前快照或缺少等价字段时，不得用当前数据回填历史。
- 不要为板块或数据接口臆造历史日期参数。只有当前官方签名明确支持时才传入；否则要求历史快照数据或标记“无等价”。
- 明确成交量、成交额、手/股、元/%、时间戳和时区单位。

### 6. 迁移账户与交易层

- 用 `get_trade_detail_data` 构造账户与持仓快照；区分总持仓 `m_nVolume` 与可用数量 `m_nCanUseVolume`。
- 将聚宽目标数量/目标市值下单封装为 QMT 适配器：读取快照、计算增量、按市场最小单位取整、限制可卖数量，再调用 `passorder`。
- 按官方枚举确认 `opType`、`orderType`、`prType`、`quickTrade` 和 `volume` 单位；不要凭示例数字推断其他品种。
- 聚宽普通 `order/order_target/order_target_value` 未显式指定限价样式时，按市价委托语义迁移，不能使用 QMT `prType=5`“最新价限价”代替。普通沪深股票/ETF 的共同五档即成剩撤语义分别使用沪市 `42`、深市 `47`；`price=0` 让 QMT 使用涨跌停价作为保护限价。其他市场和品种重新核对枚举，不得照搬。
- 保留聚宽“目标仓位”语义，不要把 `order_target_value` 简化成无条件全额买入。
- 将异步委托、部分成交、撤单、冻结资金和缓存延迟纳入状态机。下单后立刻查询到的账户状态不保证已更新。
- `price=0` 的沪深市价买入会按当日涨停价作为保护限价并参与柜台验资。买入数量必须基于强制刷新的当日 `UpStopPrice`、最新可用资金和费用向下取整；最终报单适配器还要再次刷新保护价，必要时缩量，不能沿用启动前或上一交易日的缓存值。
- 零成交委托若以“资金不足/insufficient funds”终态结束，必须清除该标的动态详情缓存并释放信号键；重试前重新读取保护价、可用资金和可买数量，并至少再减少一个最小交易单位。禁止按相同保护价和相同数量机械重复报单。
- LIVE 市价报单前通过 `get_full_tick` 记录方向、数量和 `latest_reference_price`。该最新价只作为滑点基准，不作为限价传给 `passorder`。使用 `passorder` 时生成小于 24 字符且运行期唯一的 `userOrderId`；序号容量耗尽时拒绝新单，禁止取模、截断或重启计数造成 ID 复用。官方会把它放入委托/成交对象的 `m_strRemark`，用它关联回报，不要只按代码匹配。
- 通过 `C.set_account(account)` 启用主推，并实现 `order_callback` 与 `deal_callback`。成交价格读取 `Deal.m_dPrice`、成交量读取 `m_nVolume`、成交编号读取 `m_strTradeID`，按成交编号去重并按成交量加权得到最终成交价；同时用 `DEAL` 查询对账，覆盖回调遗漏。
- 滑点以市价报单前最后确认的 `latest_reference_price` 为基准：买入 `(final_deal_price-latest_reference_price)/latest_reference_price`，卖出 `(latest_reference_price-final_deal_price)/latest_reference_price`，正值统一表示不利滑点。逐笔记录本次成交价/数量，终态记录成交量加权 `final_deal_price`、绝对滑点、比例和基点；部分成交后撤单也必须结算实际成交部分。
- `passorder` 无返回值且异步；“调用未抛异常”只能记录为“委托已报送”，不能记录为已接受或已成交。
- 仅在明确的回调/定时器/`after_init` 即时委托场景使用 `quickTrade=2`；逐 K 线语义通常使用 `0`，最新 bar 即时触发按需求核对 `1`。
- 不填写或输出真实账号；优先使用 QMT 模型交易界面注入的账号变量或显式占位配置。

### 7. 保持运行环境兼容

- 在 QMT 文件首行写 `#coding:gbk`，确保文件实际可用 GBK 编码保存；无法编码的字符改为 ASCII/可编码文本。
- 以 QMT 内置 Python 3.6.8 为兼容上限，避免海象运算符、`match`、`dataclasses`、内置泛型注解和新版本 pandas 专属 API。
- 仅在当前官方文档确认函数、属性、参数和返回字段后生成具体 QMT 调用。无法核实时隔离到命名适配器并加入 `TODO(QMT API签名)`，同时把运行状态标为未验证。
- 核对第三方库是否随客户端提供或已加入券商白名单。
- 避免线程、多进程和阻塞式循环。

### 8. 验证并交付

至少执行：

1. 聚宽源文件静态审计；
2. 使用当前运行时提供的命令执行能力，从本技能根目录执行 QMT 文件兼容检查：

```bash
python3 scripts/check_qmt_strategy.py path/to/qmt_strategy.py --format markdown
```

3. 证券代码与未迁移聚宽标识符扫描；
4. 所有主动日志的 QMT 运行时策略名与 K 线时间覆盖检查，以及所有策略标的的名称解析检查；
5. LIVE 旧日最右 bar、时间差 `-180/+180` 秒边界通过、任一方向超过 180 秒拒绝、按 K 线时间顺序执行到期任务、未到时不提前、当日任务集合去重、跨日重置和下单二次守卫测试；
6. LIVE 单笔成交、重复回调、部分成交、部分撤单及买卖双方向滑点测试；
7. 沪市 `prType=42, price=0` 与深市 `prType=47, price=0` 的市价报单参数测试，并确认日志同时含 `latest_reference_price` 与 `final_deal_price`；
8. LIVE 跨交易日详情缓存清理、当日 `UpStopPrice` 强制刷新、保护价验资缩量，以及零成交资金不足后减一手重试测试；
9. 固定输入下的指标/选股/目标仓位单元对照；
10. 同区间、同参数、同数据口径的回测对照；
11. 逐笔或逐信号差异定位。

没有 QMT 客户端或相同授权数据时，明确标记“静态迁移完成，QMT 运行未验证”，并给出用户可执行的下载、参数和回测步骤。不要宣称未实际完成的回测或实盘验证。

交付：

- 独立 QMT 策略文件；
- 迁移报告：直接映射、适配映射、无等价项、假设和配置；
- 验证结果：已通过、失败、未运行；
- 剩余风险：按“可能改变交易信号/只影响绩效数值/仅影响展示”分级。

## 禁止事项

- 不为提高收益而修改原策略。
- 不以当前成分股、当前财务数据替代历史时点数据。
- 不忽略复权、停牌、涨跌停、手续费、滑点、最小交易单位和 T+1。
- 不输出缺少 QMT 运行时策略名或 K 线时间的策略日志，不用系统时间代替 K 线时间。
- 不把名称查询失败掩盖为“未知名称”，不使用错误交易所后缀调用名称接口。
- 不把回测撮合等同于实盘成交。
- 不在缺少用户授权时发送实盘委托、写入账号或连接交易柜台。
