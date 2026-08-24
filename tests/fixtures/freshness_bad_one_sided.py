#coding:gbk
from datetime import datetime

LIVE_FRESHNESS_SECONDS = 180


def init(C):
    qmt_instrument_name(C, "000001.SZ")


def qmt_strategy_name(C):
    return getattr(C, "title", "strategy")


def qmt_bar_time(C):
    timetag = C.get_bar_timetag(C.barpos)
    if not timetag:
        return None
    return timetag_to_datetime(timetag)


def qmt_log(C, level, message):
    print("[strategy=%s] [bar=%s] [%s] %s" % (
        qmt_strategy_name(C), qmt_bar_time(C), level, message))


def qmt_instrument_name(C, code):
    return C.get_instrument_detail(code).get("InstrumentName", code)


def qmt_live_bar_fresh(C):
    runtime = datetime.now()
    bar_time = qmt_bar_time(C)
    delta = (runtime - bar_time).total_seconds()
    return (C.is_last_bar() and bar_time.date() == runtime.date()
            and delta <= LIVE_FRESHNESS_SECONDS)


def submit_order(C):
    if not qmt_live_bar_fresh(C):
        return
    latest_reference_price = 1.0
    passorder(23, 1101, C.accountid, "000001.SZ", 42, 0,
              100, "strategy", 1, "order-1", C)
    qmt_log(C, "INFO", "latest_reference_price=%s" % latest_reference_price)


def handlebar(C):
    if not qmt_live_bar_fresh(C):
        return
    submit_order(C)


def deal_callback(C, deal):
    final_deal_price = deal.m_dPrice
    volume = deal.m_nVolume
    trade_id = deal.m_strTradeID
    remark = deal.m_strRemark
    qmt_log(C, "INFO", "slippage final_deal_price=%s %s %s %s" % (
        final_deal_price, volume, trade_id, remark))
