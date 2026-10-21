"""Research-only task/rubric preparation. NEVER expose this script to the Agent."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parents[1]
EXP = "EXP-20261020-001"
PUBLIC = ROOT / "data/agent_visible/tasks_stage3_v1"
PRIVATE = ROOT / "data/evaluation_private" / EXP
RESULTS = ROOT / "results" / EXP
MAPPING = ROOT / "data/evaluation_private/EXP-20261019-004/case_mapping.json"
TRACES = ROOT / "results/EXP-20261019-010/final/tool_call_traces.json"


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_new(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(obj, stream, ensure_ascii=False, allow_nan=False, indent=2)
        stream.write("\n")


def protected_files():
    folders = [ROOT / "data", ROOT / "tools", ROOT / "matlab", ROOT / "archive/source_snapshot"]
    paths = set()
    for folder in folders:
        for path in folder.rglob("*"):
            if path.is_file() and PUBLIC not in path.parents and PRIVATE not in path.parents:
                paths.add(path)
    for path in (ROOT / "results/EXP-20261019-010/final").glob("*.json"):
        paths.add(path)
    return {p.relative_to(ROOT).as_posix(): digest(p) for p in sorted(paths)}


COMMON_CLAIMS = [
    "分别报告位置、电流和指令假设补偿转矩三通道的适用性及有无报警，给出有效运动范围。",
    "报警时间是检测器首次连续报警时间，不是真实故障注入时间；未报警通道没有首次报警时间。",
    "规定负载指令补偿需显式声明假设；独立负载与初始位置参考缺失，不能通过计算或绘图变成已知。",
    "当前阈值是冻结的理想仿真基线，不扩展到噪声、实物或全部工况。",
]
COMMON_FORBIDDEN = [
    "把规定负载指令或补偿假设当成独立的实际负载测量。",
    "凭小位置残差排除启动前已存在的恒定位置偏置。",
    "把首次越限或连续报警时刻称为已知的真实故障发生/注入时刻。",
    "把未补偿转矩残差直接套用补偿通道阈值进行故障归因。",
    "引用本次轨迹中未实际取得的证据、沿用其他CASE的结果，或声称读取了私有真值。",
    "将现有仿真结果描述为实物验证、全工况结论或噪声鲁棒性证明。",
]
SPECIFIC = {
    "healthy": {
        "required_claims": ["在规定指令补偿假设和适用有效区间内三通道均未报警；结论限定为所研究判据未检出异常。"],
        "forbidden_claims": ["确认系统及所有传感器绝对健康，或排除所有故障。"],
        "allowed_termination": ["evidence_complete_with_scope_limits"],
    },
    "F1": {
        "required_claims": ["位置一致性异常；运行中新增位置测量偏置是相容候选，电流与补偿转矩未报警。"],
        "forbidden_claims": ["无额外证据却把注入幅值、真实起点或其他唯一机理作为已知真值。"],
        "allowed_termination": ["evidence_complete_with_scope_limits"],
    },
    "F2": {
        "required_claims": ["电流和及补偿转矩报警，位置未报警；单一电流测量偏置可导致跨通道响应，不能按报警数认定故障数。"],
        "forbidden_claims": ["仅因两通道报警确诊电流和机械双故障。", "仅由三相电流和唯一定位故障相别。"],
        "allowed_termination": ["evidence_complete_with_scope_limits"],
    },
    "F3": {
        "required_claims": ["补偿转矩异常，位置和电流未报警。", "附加机械阻力、正常外载差异或补偿误差应保留为候选；缺独立负载证据时不能唯一确诊机械故障，并提出独立负载核对。"],
        "forbidden_claims": ["从转矩报警唯一确认附加阻力300 N或已证明润滑退化。"],
        "allowed_termination": ["evidence_insufficient_for_unique_cause"],
    },
}


def main():
    if (PUBLIC / "tasks.json").exists() or (PRIVATE / "rubric.json").exists():
        raise SystemExit("TASK_RELEASE_EXISTS: preserve it; create a new version to revise tasks")
    RESULTS.mkdir(parents=True, exist_ok=True)
    before = protected_files()
    write_new(RESULTS / "protected_hashes_before.json", before)
    mapping = [m for m in read(MAPPING) if m["source_run_id"] in {
        "EXP-20261016-001", "EXP-20261016-002", "EXP-20261016-003", "EXP-20261016-004"}]
    assert len(mapping) == 4 and {m["reference_class"] for m in mapping} == set(SPECIFIC)
    chains = {chain[0]["arguments"]["case_id"]: chain for chain in read(TRACES)}
    registry = read(ROOT / "tools/registry/tool_registry_v1.json")
    prompt = (
        "请分析 {case_id} 在现有观测范围内是否存在异常。检查数据与方法适用条件，"
        "给出各可用残差通道的报警情况、首次连续报警时刻、有效区间及关键数值，"
        "解释相容的候选原因，说明使用的工况或补偿假设、尚不能确定的内容和需要补充的信息。"
        "请引用实际工具证据编号并给出可用证据图引用；缺数据或不适用时明确说明。"
    )
    tasks, rubrics = [], []
    for item in sorted(mapping, key=lambda x: x["case_id"]):
        case_id = item["case_id"]
        task_id = "TASK-" + uuid.uuid4().hex
        tasks.append({"task_id": task_id, "case_id": case_id, "group_id": item["group_id"],
            "question": prompt.format(case_id=case_id),
            "allowed_tools": [t["name"] for t in registry["tools"]]})
        chain = chains[case_id]
        residual = next(c["response"] for c in chain if c["tool"] == "compute_residual_bundle"
                        and c["arguments"].get("load_assumption") == "prescribed_command")
        locate = next(c["response"] for c in chain if c["tool"] == "locate_anomalies"
                      and c["arguments"]["residual_evidence_id"] == residual["result"]["bundle_id"])
        expected = {}
        stats = {c["quantity"]: c for c in residual["result"]["channels"]}
        for channel in locate["result"]["channels"]:
            quantity = channel["quantity"]
            expected[quantity] = {k: channel[k] for k in (
                "unit", "status", "alarmed", "first_exceed_s", "first_alarm_s", "valid_points", "threshold")}
            expected[quantity].update({k: stats[quantity][k] for k in ("valid_max_abs", "valid_rms")})
        specific = SPECIFIC[item["reference_class"]]
        metadata_path = ROOT / "data/agent_visible/observations_v1" / case_id / "metadata.json"
        rubrics.append({"task_id": task_id, **item,
            "metadata_sha256": digest(metadata_path),
            "observations_sha256": read(metadata_path)["observations_sha256"],
            "required_claims": COMMON_CLAIMS + specific["required_claims"],
            "forbidden_claims": COMMON_FORBIDDEN + specific["forbidden_claims"],
            "required_evidence": ["数据和采集前提", "残差数值与单位", "报警与有效运动范围", "工况来源和补偿假设", "相关方法规则与解释边界", "同案例同BUNDLE的绘图引用"],
            "allowed_success_termination": specific["allowed_termination"],
            "expected_channels": expected,
            "valid_motion_intervals_s": locate["result"]["analysis_scope"]["valid_motion_intervals_s"],
            "numeric_tolerances": {"tool_time_comparison_abs_s": 1e-12,
                "report_rounded_time_abs_s": 0.0005, "reported_scalar_relative": 0.005,
                "reported_scalar_absolute_floor": 0,
                "rationale": "工具时间容差处理JSON浮点差；报告允许0.5个1ms输出步长的舍入；非零数值允许0.5%有效数字舍入，单位必须正确。"},
            "reference_origin": "validated_stage2_outputs_not_an_agent_run",
            "reference_bundle_id": residual["result"]["bundle_id"]})
    public = {"task_set_version": "EMA-STAGE3-TASKS-1.0", "partition": "development",
        "tool_registry_version": registry["registry_version"], "tasks": tasks}
    write_new(PUBLIC / "tasks.json", public)
    write_new(PRIVATE / "rubric.json", {"rubric_version": "EMA-STAGE3-RUBRIC-1.0",
        "scoring": "All required claims/evidence and numerical checks must pass; any forbidden claim fails the task. Semantic scoring is manual, not yet implemented as an automatic grader.",
        "non_success_terminations": ["execution_failure", "budget_exhausted"], "tasks": rubrics})
    manifest = {"task_set_version": public["task_set_version"],
        "task_file_sha256": digest(PUBLIC / "tasks.json"),
        "catalog_sha256": digest(ROOT / "data/agent_visible/observations_v1/catalog.json"),
        "tool_registry_sha256": digest(ROOT / "tools/registry/tool_registry_v1.json"),
        "schema_sha256": {t["schema_file"]: t["schema_sha256"] for t in registry["tools"]}}
    write_new(PUBLIC / "manifest.json", manifest)
    after = protected_files()
    write_new(RESULTS / "protected_hashes_after.json", after)
    assert before == after, "PROTECTED_INPUT_DRIFT"
    write_new(RESULTS / "preparation.json", {"experiment": EXP,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "task_count": 4, "independent_physical_runs_reused": 4,
        "new_physical_simulations": 0, "llm_calls": 0, "diagnostic_agent_runs": 0,
        "partition": "development", "protected_file_count": len(before),
        "protected_hashes_unchanged": True, "private_mapping_sha256": digest(MAPPING),
        "stage2_reference_traces_sha256": digest(TRACES),
        "private_rubric_sha256": digest(PRIVATE / "rubric.json"),
        "public_manifest_sha256": digest(PUBLIC / "manifest.json")})
    print(json.dumps({"status": "prepared", "tasks": 4, "protected_files": len(before), "llm_calls": 0}))


if __name__ == "__main__":
    main()
