# 聚宽到 QMT 语义映射

## 目录

1. 生命周期与状态
2. 行情与数据
3. 账户与交易
4. 证券代码与名称
5. 日志时间
6. 不可机械转换的部分

## 1. 生命周期与状态

| 聚宽 | QMT 候选 | 迁移要求 |
|---|---|---|
| `initialize(context)` | `init(C)` | 只做可在 QMT 初始化阶段调用的设置；受限数据调用移到 `after_init` |
| `process_initialize` | `after_init(C)` 或显式重启恢复 | 生命周期不完全相同，逐项验证 |
| `handle_data(context, data)` | `handlebar(C)` | 对齐当前/上一根 bar，并在盘中 tick 重复触发时去重 |
| `before_trading_start` | `handlebar` 时间守卫或实盘调度 | 无通用直接等价；同时支持回测时优先 bar 驱动 |
| `after_trading_end` | `handlebar` 收盘状态机或实盘调度 | `stop` 是策略停止，不是每日收盘 |
| `run_daily/weekly/monthly` | 自定义 bar 调度器；实盘可用 `schedule_run` | `run_time` 回测无效，不可用于回测等价 |
| `g.xxx` | 自定义全局状态实例 | 不默认写入 `ContextInfo`，避免逐 K 线回退 |
| `context.current_dt` | `get_bar_timetag` + `timetag_to_datetime` | 明确时区、bar 起止含义 |

推荐把所有任务登记为 `(频率, 交易日选择, 触发时间, 函数)`，以 `(任务名, 交易日期/周/月)` 做幂等键。

LIVE 与 BACKTEST 默认使用同一个 `handlebar` 调度时钟。每根 bar 按注册/依赖顺序扫描任务；当 `context.current_dt.strftime("%H:%M") >= target_time` 且任务名不在 `g.executed_routines` 时执行，并在 K 线日期变化时清空集合。不要另建 LIVE 墙钟分支、`live_target_time`、精确分钟判断或交易日历调度缓存。LIVE 启动和行情重连可能把缓存中的最右侧 bar 再次推给 `handlebar`，而 `is_last_bar=True` 不代表 bar 属于今天；因此调度前仍要验证 bar 日期等于本机日期且延迟在允许范围内，并在下单适配器再次验证。进程重启会丢失内存任务集合，已经到期的任务会重新执行，交易任务还须检查账户、持仓和在途委托。

## 2. 行情与数据

| 聚宽 | QMT 候选 | 必查语义 |
|---|---|---|
| `attribute_history` | `C.get_market_data_ex` | 单标的形状、`count`、结束 bar、跳过停牌、复权 |
| `history` / `get_price` | `C.get_market_data_ex` | 多标的列结构、区间边界、是否包含当前 bar |
| `get_bars` | `C.get_market_data_ex` 后适配 ndarray/记录数组 | dtype、字段名与排序 |
| `get_current_data` | tick/全推或最新行情接口 | 快照时点、涨跌停、停牌、是否订阅 |
| `get_extras` | 数据字典对应特色数据 | 字段权限和历史覆盖 |
| `get_fundamentals` | `C.get_financial_data` + 本地筛选 | 公告日、报告期、单位、修订值、查询 DSL |
| `get_index_stocks` | 官方确认支持历史日期的成分接口，或本地历史成分数据 | 当前成分不能替代历史成分；不得给当前板块接口臆加日期参数 |
| `get_industry_stocks` / `get_concept_stocks` | 板块接口 | 分类体系、发布日期、历史快照 |
| 因子库/API | QMT 对应因子或自行计算 | 公式版本、去极值、标准化、缺失值、截面范围 |

### ETF / 场内基金宇宙

QMT 客户端中的 ETF 与场内基金不应假定只有一个板块名。查询下列六个名称并在代码规范化后去重：

```python
QMT_ETF_SECTORS = [
    "沪深基金", "沪深ETF", "沪市基金", "沪市ETF", "深市基金", "深市ETF",
]
```

- 内置 Python 使用 `C.get_stock_list_in_sector(sectorname, realtime)`；第二参数是可选毫秒级时间戳，位置传入 `C.get_bar_timetag(C.barpos)` 合法。
- 对每个名称分别记录“历史返回数、最新返回数、异常信息”，再对规范化后的代码并集去重；不要因其中一个名称为空就停止。
- 历史调用不报错但返回空列表时，不等于 API 不支持第二参数，只能说明该客户端/数据源没有该板块在该时间点的成分。它必须触发显式的空结果分支。
- 实测的 ETF 历史回测中，六个板块可能全部历史为空、最新查询却非空。此时无时间参数的结果只能视为最新快照：实盘可以使用；回测必须标记为非 point-in-time，或改用本地历史快照。
- 基金板块可能同时包含 ETF、LOF 等合约。保留 `source_sectors`；优先使用完整合约详情确认类型，但普通详情若返回 `ProductType=-1`，不能因为名称不含 `ETF` 而无日志地删除 ETF 板块来源代码。

参数对齐：

- 聚宽 `fq='pre'` 不可只按名称映射；核对 `set_option('use_real_price')` 后的真实含义。
- QMT 可选 `none/front/back/front_ratio/back_ratio`，以数值样本确认。
- 聚宽 `skip_paused=True` 与 QMT `fill_data=True` 可能产生相反的行保留行为。
- 日线取数是否包含当日、分钟线是否包含当前未完成 bar 必须用时间戳断言。
- 对每个关键序列保存 `timestamp/code/value` 样本做跨平台比较。

### 历史与实时行情分层

- 不要把 `RUN_MODE == "LIVE"` 直接作为所有 `get_market_data_ex` 请求的 `subscribe` 值。LIVE 中的历史请求仍应 `subscribe=False`。
- 截至前一交易日的日线/分钟线从已下载的本地数据读取；全市场历史查询分批但不订阅。
- 最新价格、当日累计成交量和证券状态优先从 `get_full_tick` 读取；只有确实需要当日连续 K 线的受控候选池才订阅对应周期。
- 动态池使用 `subscribe_quote` 保存订阅号，池变化及策略停止时 `unsubscribe_quote`。具体流程见 [market-data-and-subscriptions.md](market-data-and-subscriptions.md)。
- 停牌判断必须把空表、K 线不足、订阅失败识别为 `DATA_UNAVAILABLE`，不得直接当成 `SUSPENDED`。

## 3. 账户与交易

| 聚宽 | QMT 候选 | 必查语义 |
|---|---|---|
| `context.portfolio.cash` | Account `m_dAvailable` | 冻结资金与缓存延迟 |
| `portfolio_value` | 账户总资产/净资产字段 | 定义因账号类型不同而异 |
| Position `total_amount` | `m_nVolume` | 股/手单位 |
| Position `closeable_amount` / `sellable_amount` | `m_nCanUseVolume` | T+1、冻结和在途委托 |
| `order(security, amount)` | `passorder` 按数量增量下单 | 买卖方向、最小单位 |
| `order_value` | `passorder` 按金额或自行换算数量 | 金额单位、价格与取整 |
| `order_target` | 查询持仓后按目标差额下单 | 挂单和异步回报造成重复单 |
| `order_target_value` | 目标市值适配器 | 估值价格、现金、卖后买顺序 |
| `cancel_order` | `cancel` | 委托号、账号类型、异步结果 |
| 订单/成交查询 | `get_trade_detail_data` 与回调 | 客户端缓存并非柜台同步查询 |

股票示例中的 `opType=23/24`、`orderType=1101` 等仅可用于文档明确的股票场景。期货、期权、信用、ETF 申赎和组合交易必须重新查枚举。

聚宽普通 `order` 系列没有显式限价样式时是市价语义。QMT `prType=5` 是“最新价限价”，不是市价单。普通沪深股票/ETF 若选择共同的最优五档即时成交剩余撤销语义，按代码后缀使用 `.SH -> prType=42`、`.SZ -> prType=47`，并传 `price=0` 作为自动涨跌停保护价。报单前 `get_full_tick.lastPrice` 单独保存为 `latest_reference_price`，不得把它作为限价传入。

目标仓位适配器至少处理：

1. 当前总持仓、可用持仓、未完成委托；
2. 目标与当前的差额；
3. 买入向下取整到市场单位，卖出不超过可用量；
4. 同一信号幂等键；
5. 异步成交后的再平衡；
6. 涨跌停、停牌、价格笼子与无有效报价。

LIVE 委托与成交关联使用 `passorder(..., userOrderId, C)` 的 `userOrderId`；它在 `Order/Deal.m_strRemark` 中返回且长度应小于 24 字符。以 `latest_reference_price`、方向和请求数量建立记录，使用 `Deal.m_dPrice`、`m_nVolume`、`m_strTradeID` 去重并累计成交额/成交量。`final_deal_price` 为成交量加权均价；买入滑点为 `(final-latest)/latest`，卖出滑点为 `(latest-final)/latest`，正值表示不利。

合约详情缓存必须按字段时效分层。`InstrumentName`、品种等静态元数据可以长期缓存；`UpStopPrice`、`DownStopPrice` 属于交易日动态数据，不得跨交易日沿用。LIVE 检测到日期变化时清空动态详情缓存，买入数量计算和最终报单前分别强制刷新当日完整合约详情。

沪深 `price=0` 市价买入由 QMT 使用当日涨停价作为保护限价并按此验资，因此可买数量必须按“当日 `UpStopPrice` + 最新可用资金 + 费用”向下取整。零成交废单原因含资金不足时，清除该标的动态缓存并释放信号键；下一次重试重新定价、查资金、算数量，并至少减少一个最小交易单位，禁止相同数量原样重报。

## 4. 证券代码与名称

| 聚宽后缀 | 常见 QMT 后缀 |
|---|---|
| `.XSHG` | `.SH` |
| `.XSHE` | `.SZ` |
| `.XBSE` | `.BJ` |

北交所、期货、期权、港股和场外基金不要只做字符串替换；使用 QMT 合约详情或数据字典核对。

名称统一使用 `C.get_instrument_detail(code)` 返回字典中的 `InstrumentName`。旧客户端仅在当前接口不存在时回退 `C.get_instrumentdetail(code)`；不要把计划废弃的 `C.get_stock_name` 作为主路径。名称为空必须诊断代码后缀、大小写、返回值与客户端合约数据，不得静默写成“未知名称”。

## 5. 日志时间

所有策略主动日志统一经过 `qmt_log`，前缀固定为 `[策略名=...] [K线时间=...] [LEVEL] ...`。策略名优先读取 QMT 运行时 `C.title`，K 线时间使用 `timetag_to_datetime(C.get_bar_timetag(C.barpos), ...)`。定时或交易回调另有事件时间时，将其作为消息字段记录，不能替代策略名或 K 线时间。

## 6. 不可机械转换的部分

以下情况必须报告为“适配”或“无等价”，不能静默近似：

- 聚宽专有因子、另类数据、研究环境文件和云端对象；
- point-in-time 财务数据或历史行业/指数成分，而 QMT 只有当前快照；
- 聚宽模拟盘持久化与 QMT 客户端重启状态；
- 两平台撮合、手续费、滑点、涨跌停和订单成交模型；
- 聚宽消息、文件、对象存储、训练模型服务；
- QMT 券商版本缺少的权限、数据或第三方库。
