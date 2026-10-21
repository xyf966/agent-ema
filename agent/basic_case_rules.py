"""Shared physical/reporting rules and a public-evidence completion gate.

No case IDs, reference classes, injected values, labels or private rubrics.
"""

VERSION = "EMA-BASIC-RULES-1.1"
SHARED_RULES = """
本轮所有案例统一使用的补充规则EMA-BASIC-RULES-1.1：
1. 独立负载未知与规定指令假设计算是两回事。若工况工具提供规定指令补偿，可显式选择prescribed_command计算条件下的转矩残差，并同时保留实际负载unknown；不能把该选择说成独立测量。尽可能覆盖现有数据和明确假设下可计算的三通道；不必为此先重复一遍无补偿计算。
2. 位置差分与速度积分比较的是运动学关系。参考建立前已有且之后不变的偏置会完全抵消，只能保留与其他异常共存的可能；新增非零残差需要解释参考建立后的不一致。负载或摩擦变化本身不破坏该关系，不能仅凭转矩接近阈值就把机械/负载原因列为位置不一致的支持候选。
3. 未报警只说明当前判据未检出对应不一致，不能用来排除未实际检查的共同源干扰或证明采集独立/整体健康。采集方式及独立性来自元数据。
4. 相电流与由其变换的dq电流共享来源，多个残差可能交叉响应。比较共同原因与替代解释，不能按报警数确定故障数；三相和本身也不能唯一确认故障相别。转矩不一致需要区分负载、参数和测量影响，不凭单项报警唯一确诊。
5. 候选只保留有观测与方法依据的机理，不能重复报警事实或泛列任何可能。适用性用简短文字说明已满足的计算/采集前提、假设与未核实条件。
6. 工具顺序由你决定，不重复相同参数。查到足够的三通道检测、工况、相关方法及同包图后直接交付约定JSON；简短写出发现、证据和限制，不输出长篇整理稿。无报警可以没有故障候选，但仍说明当前未检出与不能确认的边界。
7. 差分代数必须在整份答复中一致：若y(t)=x(t)+b+d(t)，则y(t)-y(0)=x(t)-x(0)+d(t)-d(0)，恒定b完全抵消。未知b是否存在，不影响这条关系；只能说b可能共存，不能把它当作新增差分残差的来源。具体位置/速度/参数来源未确诊，不等于初始恒定b能够解释当前相对不一致。
8. 查询/分析窗effective_interval_s包含可能被排除的点；实际有效运动段必须逐段照录valid_motion_intervals_s，不得在finding或scope中把前者叫作有效运动区间。assumptions是单个字符串，load_assumption只填工具原枚举，其他说明另写。unknowns只填有真实条件名和对应证据的unknown，硬件尚未验证等已知限制写scope/assumptions。
"""

FINAL_PHASE_MESSAGE = """本案例已通过通用的证据齐备检查：实际取得数据、工况、方法、三通道适用检测和同一BUNDLE图件。
现在进入答复交付阶段，不再调用工具。请直接输出EMA-REPORT-1.1的完整JSON，发现、候选、假设和限制保持简短；所有数字和引用仍来自本轮真实返回。不写内部整理过程。提交前逐项核对：assumptions为字符串；load_assumption为原枚举；unknown条件名与证据对应；查询窗和有效运动分段分开；恒定初始偏置只可共存，不会留在初值差分中。"""


def evidence_ready(records):
    responses = [r["response"] for r in records if r.get("backend_executed") and isinstance(r.get("response"), dict)]
    required = {"inspect_case", "query_operating_context", "lookup_method_conditions",
                "compute_residual_bundle", "locate_anomalies", "plot_evidence"}
    if not required.issubset({r.get("tool") for r in responses}):
        return False
    quantities = {"x_consistency_m", "phase_sum_A", "torque_known_load_Nm"}
    for response in responses:
        if response.get("tool") != "compute_residual_bundle" or response.get("status") not in ("ok", "insufficient_data"):
            continue
        bundle = response.get("result", {})
        bundle_id = bundle.get("bundle_id")
        if not isinstance(bundle_id, str):
            continue
        for alarm in responses:
            result = alarm.get("result", {})
            if (alarm.get("tool") != "locate_anomalies" or alarm.get("status") != "ok"
                    or result.get("residual_evidence_id") != bundle_id):
                continue
            channels = result.get("channels", [])
            if (len(channels) != 3 or {c.get("quantity") for c in channels} != quantities
                    or any(c.get("status") != "ok" or not isinstance(c.get("alarmed"), bool) for c in channels)
                    or result.get("analysis_scope", {}).get("effective_interval_s") != bundle.get("time_range_s")):
                continue
            if any(p.get("tool") == "plot_evidence" and p.get("status") == "ok"
                   and p.get("result", {}).get("residual_evidence_id") == bundle_id for p in responses):
                return True
    return False
