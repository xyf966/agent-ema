"""Common rules based only on obtained public tool data, with no case labels."""
from basic_case_rules import evidence_ready

VERSION = "EMA-STAGE4-RULES-1.0"
STAGE4_RULES = """
本轮所有案例统一的任务约定EMA-STAGE4-RULES-1.0：
1. query_operating_context的load_command是规定指令记录；load_compensation若来自recorded_diagnostic_assumption，是单独保存的诊断设定，不能把二者混为实际负载测量。
2. 若存在单独诊断设定，先选recorded_assumption作为本题主分析；若只有规定指令补偿，选prescribed_command。最终channels、bundle_id、load_assumption和plot都对应此主分析，不能悄悄改用另一个补偿版本覆盖问题。
3. 若工具提供的规定指令与单独诊断设定的负载幅值不同，还须用prescribed_command计算并检测同一观测，比较其对转矩报警的影响，在finding或candidate_assessment中用实际数值和证据解释。比较结果属于同一物理运行的条件计算，不是新增测量或新仿真，也不能证明真实实际负载。
4. 观察趋势只在实际数据和有效运动段支持的范围描述。报警时间不是注入起点，不能从题目或一个报警时间推断精确故障波形。
5. 三相各增加共同偏差b时，电流和增加3b；不得把三相电流和说成对共模偏差不敏感。没有电流报警也不能排除所有抵消型或其他未检验干扰。
6. 无报警仍需说明初始参考和独立负载的未知边界；不能仅因存在某种盲区就断言该案例一定有该故障。所有案例共用以上规则，不获取私有配置或标准答案。
"""


def public_compensation_requirement(records):
    """Select a baseline and comparison requirement from observed source roles."""
    contexts = [r["response"] for r in records if r.get("backend_executed")
                and r.get("response", {}).get("tool") == "query_operating_context"
                and r["response"].get("status") == "ok"]
    rows = [row for c in contexts for row in c["result"].get("records", [])]
    commands = [r for r in rows if r.get("name") == "load_command" and r.get("status") == "ok"]
    assumptions = [r for r in rows if r.get("name") == "load_compensation" and r.get("status") == "ok"
                   and r.get("source_kind") == "recorded_diagnostic_assumption"]
    if not assumptions:
        return "prescribed_command", False
    mismatch = False
    if commands:
        keys = ("force_min_N", "force_max_N", "direct_torque_min_Nm", "direct_torque_max_Nm")
        # Current tools expose extrema, not arbitrary-series equivalence.
        mismatch = any(commands[-1].get("value", {}).get(k) != assumptions[-1].get("value", {}).get(k)
                       for k in keys if k in commands[-1].get("value", {}) and k in assumptions[-1].get("value", {}))
    return "recorded_assumption", mismatch


def evidence_ready_stage4(records):
    if not evidence_ready(records):
        return False
    mode, comparison = public_compensation_requirement(records)
    good = [r["response"] for r in records if r.get("backend_executed")
            and r.get("response", {}).get("status") == "ok"]

    def complete_mode(wanted, require_plot):
        bundles = [r["result"] for r in good if r.get("tool") == "compute_residual_bundle"
                   and r.get("result", {}).get("load_assumption") == wanted]
        for bundle in bundles:
            identity = bundle.get("bundle_id")
            alarms = [r["result"] for r in good if r.get("tool") == "locate_anomalies"
                      and r.get("result", {}).get("residual_evidence_id") == identity]
            for alarm in alarms:
                channels = alarm.get("channels", [])
                if (len(channels) != 3 or any(c.get("status") != "ok" or type(c.get("alarmed")) is not bool for c in channels)
                        or alarm.get("analysis_scope", {}).get("effective_interval_s") != bundle.get("time_range_s")):
                    continue
                if not require_plot or any(r.get("tool") == "plot_evidence" and r.get("result", {}).get("residual_evidence_id") == identity for r in good):
                    return True
        return False

    return complete_mode(mode, True) and (not comparison or complete_mode("prescribed_command", False))
