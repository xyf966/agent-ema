"""Research-only task/protocol/rubric freeze. Never imported by the Agent."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import load_tools, read_json, sha256
from controlled_loop import system_message

OUT = ROOT / "results/EXP-20261020-019"
PUBLIC = ROOT / "data/agent_visible/tasks_stage4_v1"
PRIVATE = ROOT / "data/evaluation_private/EXP-20261020-019"


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")


def expected_case(records, mode):
    responses = [r["response"] for r in records]
    bundle = next(r["result"] for r in responses if r["tool"] == "compute_residual_bundle" and r["result"]["load_assumption"] == mode)
    alarm = next(r["result"] for r in responses if r["tool"] == "locate_anomalies" and r["result"]["residual_evidence_id"] == bundle["bundle_id"])
    stats = {c["quantity"]: c for c in bundle["channels"]}
    channels = {}
    for c in alarm["channels"]:
        channels[c["quantity"]] = {k: c[k] for k in ["unit", "status", "alarmed", "first_exceed_s", "first_alarm_s", "threshold", "valid_points"]}
        channels[c["quantity"]].update({k: stats[c["quantity"]][k] for k in ["valid_max_abs", "valid_rms"]})
    return {"bundle_id": bundle["bundle_id"], "load_assumption": mode,
            "expected_channels": channels, "valid_motion_intervals_s": alarm["analysis_scope"]["valid_motion_intervals_s"],
            "analysis_interval_s": alarm["analysis_scope"]["effective_interval_s"]}


def main():
    if PUBLIC.exists() or PRIVATE.exists() or (ROOT / "configs/stage4_protocol_v1.json").exists():
        raise SystemExit("FROZEN_RELEASE_EXISTS_CREATE_A_NEW_VERSION_TO_CHANGE")
    runtime_paths = [p for p in (OUT / "runtime_checks").glob("*/acceptance.json") if read_json(p)["passed"]]
    assert len(runtime_paths) == 1
    runtime = runtime_paths[0].parent
    observations = read_json(runtime / "tool_records.json")
    original = read_json(ROOT / "data/evaluation_private/EXP-20261019-004/case_mapping.json")
    mapping = [r for r in original if r["profile"] == "linear_ramp"] + read_json(ROOT / "data/evaluation_private/EXP-20261020-018/case_mapping.json")
    by_case = {c["case_id"]: c for c in observations}
    assert len(mapping) == len(by_case) == 5
    provider = read_json(ROOT / "configs/llm_stage4_frozen_v1.json")
    tools = load_tools(ROOT / "tools/registry_stage4")
    names = [t["function"]["name"] for t in tools]
    question = (
        "请分析{case_id}在现有观测范围内是否存在异常及其随时间的变化。"
        "检查数据、方法前提和有效运动段，报告各可用残差的关键数值、首次连续报警时刻及报警区间。"
        "若工况工具提供单独记录的诊断补偿设定，先按该设定分析；若仅有规定指令，则按规定指令假设分析。"
        "若单独诊断设定与可获得的规定指令不同，还需在同一观测上按规定指令计算和检测，比较对结论的影响。"
        "最终报告的三通道与证据图以先前诊断设定的主分析为准，比较结果另在发现或候选分析中说明。"
        "解释相容原因、尚不能确定的内容及需要补充的信息，区分指令、假设和独立测量，引用本次实际取得的工具证据和图件。"
        "缺数据或不适用时明确说明。"
    )
    specific = {
        "F1": {"required": ["解释相对位置-速度不一致及实际支持的时间变化；位置和速度侧为相容候选。", "恒定初始偏置会被初值相减抵消，不能单独解释新增相对残差。"],
               "forbidden": ["由报警时间确诊真实注入起点、精确幅值或线性注入参数。", "无额外依据把机械负载变化当成位置一致性异常的已证实原因。"]},
        "F2": {"required": ["电流和与补偿转矩报警、位置未报警；解释共享电流来源带来的跨通道响应。", "不能根据两个报警认定两个独立故障。"],
               "forbidden": ["仅凭电流和唯一确认故障相别。", "仅因两通道报警确诊电流和机械双故障。"]},
        "F3": {"required": ["解释补偿转矩异常和可见趋势，位置/电流未报警不构成整体健康证明。", "保留附加阻力、正常外载差异或补偿误差等有依据候选，缺独立负载证据时不唯一确诊。"],
               "forbidden": ["将等效阻力模型称为已验证真实润滑退化过程。", "将电流和说成对三相同向共模偏差不敏感。"]},
        "F1_initial_constant_offset": {"required": ["三通道在有效运动段未报警，仅说明当前判据未检出。", "说明初值相减可抵消初始恒定偏置，缺独立初始参考时不能排除；也不能凭盲区就断言该案例存在偏置。", "使用本例407个有效点及本例分段，不能沿用其他案例408点。"],
               "forbidden": ["凭未报警证明位置绝对健康，或仅凭私有标签确认具体初始偏置。", "将单个残差盲区扩展为全部可见信号绝对不可观测。"]},
        "healthy_load_compensation_mismatch": {"required": ["主分析使用recorded_assumption：仅转矩于0.029 s首次连续报警。", "从工况证据区分1800 N规定指令与1500 N诊断设定，并解释两者相差300 N的补偿影响。", "比较prescribed_command下三通道未报警的实际结果，引用该比较BUNDLE/报警证据。", "指令不是实际负载的独立测量；不能唯一确诊机械故障或声称已经独立证明设备绝对健康。"],
               "forbidden": ["只用正确补偿的无报警结果覆盖原诊断设定下的异常。", "把1500 N诊断假设写成真实1800 N运行的原始规定指令。", "把同一观测的两次计算当两条独立物理样本。"]},
    }
    tasks, rubrics = [], []
    for item in sorted(mapping, key=lambda x: x["case_id"]):
        task_id = "TASK-" + uuid.uuid4().hex
        cid = item["case_id"]
        run = by_case[cid]
        tasks.append({"task_id": task_id, "case_id": cid, "group_id": item["group_id"],
                      "question": question.format(case_id=cid), "allowed_tools": names,
                      "information_condition": "approved_observations_command_records_and_available_recorded_diagnostic_setting"})
        reference = expected_case(run["records"], run["baseline_mode"])
        requirements = specific[item["reference_class"]]
        comparison = expected_case(run["records"], "prescribed_command") if run["comparison_required"] else None
        rubrics.append({"task_id": task_id, **item, "baseline": reference, "comparison_required": run["comparison_required"],
                        "comparison": comparison,
                        "required_claims": ["报告三通道状态、数值、单位、有效段和适用条件，报警时间不能称真值起点。", "保留独立负载与初始参考unknown，引用本轮真实证据。", "明确理想仿真阈值；不扩展噪声、实物和全工况结论。"] + requirements["required"],
                        "forbidden_claims": ["读取或虚构私有真值、标签、额外测量或未取得的证据。", "由未报警排除全部传感器故障或证明采集独立。"] + requirements["forbidden"],
                        "required_evidence": ["inspection", "operating_context_and_source_roles", "method_conditions", "baseline_bundle_and_anomalies", "same_baseline_plot"] + (["comparison_bundle_and_anomalies"] if comparison else []),
                        "numeric_tolerances": {"tool_time_comparison_abs_s": 1e-12, "report_rounded_time_abs_s": 0.0005,
                                               "reported_scalar_relative": 0.005, "reported_scalar_absolute_floor": 0},
                        "reference_origin": "stage4_step3_real_guarded_tool_integration_not_LLM_answers",
                        "reference_tool_records": (runtime / "tool_records.json").relative_to(ROOT).as_posix()})
    write(PUBLIC / "tasks.json", {"task_set_version": "EMA-STAGE4-TASKS-1.0", "partition": "development",
          "tool_registry_version": "EMA-TOOLS-STAGE4-1.1", "repeats_per_task": 1, "tasks": tasks})
    write(PRIVATE / "rubric.json", {"rubric_version": "EMA-STAGE4-RUBRIC-1.0", "tasks": rubrics,
          "scoring": {"whole_task_pass": "All numerical/provenance checks and mandatory semantic claims pass; any forbidden claim fails.",
                      "separate_dimensions": ["execution_completion", "numeric_and_evidence_delivery", "physical_explanation", "information_boundary_handling"],
                      "semantic_scoring": "Research-side manual review of unchanged original text; no claim of independent blinded grading.",
                      "failure_categories": ["tool_execution", "orchestration", "evidence_binding", "physical_explanation", "overconfirmation", "unsupported_healthy_exclusion", "unnecessary_abstention", "budget_or_delivery"],
                      "failed_or_truncated_attempts": "Retain as failures; no per-case prompt changes or replacement attempts in the frozen batch.",
                      "prohibited_aggregation": "No cross-batch cherry-picking; five development tasks are five physical groups, not formal generalization accuracy."}})
    protocol = {"version": "EMA-STAGE4-PROTOCOL-1.0", "partition": "development", "task_count": 5,
                "physical_groups": 5, "physical_runs_total_in_project": 9, "repeats_per_task": 1,
                "worker_profile": "stage4", "dispatcher": "ema_tool_stage4", "registry": "tools/registry_stage4/tool_registry_v1.json",
                "provider_config": "configs/llm_stage4_frozen_v1.json", "model": provider["model"],
                "model_weights_snapshot_frozen": False, "generation_settings": provider["generation_settings"],
                "per_task_budget": {"model_http_attempts": 12, "tool_call_attempts": 20, "diagnostic_loop_wall_time_s": 300,
                                    "worker_startup_timeout_s": 90, "output_tokens_per_response": 4096,
                                    "program_report_repairs_max": 1, "automatic_network_retries": 0, "new_simulations": 0,
                                    "executor_rejections_max": 2},
                "information_condition": "Authentic prescribed command records are available; separately recorded diagnostic assumptions when present are also available. Neither is independent actual-load measurement.",
                "hidden_command_variant_included": False, "independent_load_measurement_available": False,
                "independent_initial_reference_available": False, "initial_context": "Fresh context per task; no prior case answer or private rubric.",
                "evidence_gate_version": "EMA-STAGE4-RULES-1.0", "report_contract": "EMA-REPORT-1.1",
                "checker_revision": "EMA-REPORT-CHECK-1.1.1", "threshold_version": "EMA-DETECTOR-IDEAL-1.0",
                "planned_diagnostic_experiment": "EXP-20261020-020", "new_diagnostic_runs_in_step3": 0,
                "freeze_timestamp_utc": datetime.now(timezone.utc).isoformat()}
    write(ROOT / "configs/stage4_protocol_v1.json", protocol)
    # Only runtime sources and approved data are listed in the public manifest.
    # Private truth, reference records, and rubrics are absent.
    runtime_files = set()
    for folder in ["agent", "tools"]:
        runtime_files.update(p for p in (ROOT / folder).rglob("*") if p.is_file() and p.suffix in {".py", ".m", ".json"}
                             and "__pycache__" not in p.parts and not p.name.startswith(("test_", "verify_")))
    for folder in ["data/agent_visible/observations_v1", "data/agent_visible/observations_boundary_v1"]:
        runtime_files.update(p for p in (ROOT / folder).rglob("*") if p.is_file())
    runtime_files.update([PUBLIC / "tasks.json", ROOT / "configs/llm_stage4_frozen_v1.json", ROOT / "configs/stage4_protocol_v1.json", ROOT / "scripts/run_stage4_agent.py"])
    frozen = {p.relative_to(ROOT).as_posix(): sha256(p) for p in sorted(runtime_files)}
    prompt = system_message(True, True, True)
    write(PUBLIC / "manifest.json", {"task_set_version": "EMA-STAGE4-TASKS-1.0", "frozen_files_sha256": frozen,
          "system_message_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
          "data_boundary": "Only approved observations and generic rules; no private evaluation artifacts."})
    write(OUT / "freeze_receipt.json", {"experiment_id": "EXP-20261020-019", "task_count": 5,
          "runtime_file_count": len(frozen), "public_manifest_sha256": sha256(PUBLIC / "manifest.json"),
          "private_rubric_sha256": sha256(PRIVATE / "rubric.json"), "protocol_sha256": sha256(ROOT / "configs/stage4_protocol_v1.json"),
          "system_message": prompt, "new_simulations": 0, "new_agent_diagnoses": 0,
          "runtime_verification": runtime_paths[0].relative_to(ROOT).as_posix()})
    print(json.dumps({"status": "frozen", "tasks": 5, "runtime_files": len(frozen), "private_rubric": True}))


if __name__ == "__main__":
    main()
