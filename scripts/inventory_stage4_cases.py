"""Research-only stage 4 step 1 inventory; never register as an Agent tool.

Uses byte hashes to reconnect current files to prior MATLAB inspections.
Does not load MAT contents, execute MATLAB, release tasks, or call an LLM.
"""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parents[1]
EXP = "EXP-20261020-015"
OUT = ROOT / "results" / EXP
PRIVATE = ROOT / "data/evaluation_private" / EXP
CHECKS = []
SOURCES = {}


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load(relative):
    path = ROOT / relative
    SOURCES[path.relative_to(ROOT).as_posix()] = sha(path)
    return json.loads(path.read_text(encoding="utf-8-sig"))


def check(name, condition):
    CHECKS.append({"name": name, "passed": bool(condition)})


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, allow_nan=False, indent=2)
        stream.write("\n")


def protected():
    paths = []
    for folder in ["data", "results", "tools", "matlab", "archive/source_snapshot",
                   "agent", "evaluation", "configs", "scripts", "provenance"]:
        for path in (ROOT / folder).rglob("*"):
            if path.is_file() and OUT not in path.parents and PRIVATE not in path.parents:
                paths.append(path)
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(set(paths))}


def main():
    if OUT.exists() or PRIVATE.exists():
        raise SystemExit("EXPERIMENT_EXISTS: preserve evidence; use a new experiment ID")
    before = protected()
    write(OUT / "protected_hashes_before.json", before)
    mapping = load("data/evaluation_private/EXP-20261019-004/case_mapping.json")
    catalog = load("data/agent_visible/observations_v1/catalog.json")
    manifest = load("tools/registry/observations_v1_manifest.json")
    registry = load("tools/registry/tool_registry_v1.json")
    chains = load("results/EXP-20261019-010/final/tool_call_traces.json")
    prior_acceptance = load("results/EXP-20261019-010/final/acceptance.json")
    old_inventory = load("results/EXP-20261019-003/mat_inventory.json")
    old_hashes = load("results/EXP-20261019-003/source_hashes_after.json")
    context = load("data/agent_visible/observations_v1/operating_context.json")
    contract = load("data/agent_visible/observations_v1/channel_contract.json")
    check("prior_tool_acceptance_passed", prior_acceptance["passed"])
    manifest_checks = []
    for entry in manifest["files"]:
        path = ROOT / "data/agent_visible/observations_v1" / entry["path"]
        manifest_checks.append({"path": path.relative_to(ROOT).as_posix(),
                                "sha256": sha(path), "expected_sha256": entry["sha256"]})
    check("all_19_observation_release_hashes_match",
          len(manifest_checks) == 19 and all(x["sha256"] == x["expected_sha256"] for x in manifest_checks))
    check("exactly_seven_existing_physical_groups",
          len(mapping) == 7 and len({x["group_id"] for x in mapping}) == 7)
    check("context_has_no_independent_load_measurement",
          context["independent_load_measurement_available"] is False)
    check("initial_reference_not_independent", contract["initial_reference_independent"] is False)
    for entry in registry["tools"]:
        path = ROOT / "tools/registry" / entry["schema_file"]
        check("schema_hash_" + entry["name"], sha(path) == entry["schema_sha256"])

    question = (
        "请分析 {case_id} 在现有观测范围内是否存在异常及其随时间的变化。"
        "检查数据、有效运动范围和方法适用条件，报告各可用残差通道的关键数值、"
        "首次连续报警时刻与报警区间；说明这些现象是否足以确定唯一原因。"
        "请核对工况记录来源和补偿假设，解释相容候选、判断限制及需要补充的信息，"
        "引用本次实际取得的工具证据和配套图件。缺数据或不适用时明确说明。"
    )
    cases, tasks, references = [], [], []
    by_case = {chain[0]["arguments"]["case_id"]: chain for chain in chains}
    for item in sorted((x for x in mapping if x["profile"] == "linear_ramp"),
                       key=lambda x: x["reference_class"]):
        cid, label = item["case_id"], item["reference_class"]
        chain = by_case[cid]
        inspection = next(x["response"] for x in chain if x["tool"] == "inspect_case")
        residual = next(x["response"] for x in chain if x["tool"] == "compute_residual_bundle"
                        and x["arguments"].get("load_assumption") == "prescribed_command")
        bid = residual["result"]["bundle_id"]
        anomaly = next(x["response"] for x in chain if x["tool"] == "locate_anomalies"
                       and x["arguments"]["residual_evidence_id"] == bid)
        plot = next(x["response"] for x in chain if x["tool"] == "plot_evidence")
        md = load(f"data/agent_visible/observations_v1/{cid}/metadata.json")
        bmd = load(f"data/agent_visible/derived_v1/{bid}/metadata.json")
        pid = plot["result"]["plot_id"]
        pmd = load(f"data/agent_visible/figures_v1/{pid}/metadata.json")
        bdir = ROOT / "data/agent_visible/derived_v1" / bid
        pdir = ROOT / "data/agent_visible/figures_v1" / pid
        residual_files = list(bdir.glob("*.mat"))
        check(label + "_case_group_binding", {"case_id": cid, "group_id": item["group_id"]} in catalog["cases"]
              and md["group_id"] == item["group_id"] == bmd["group_id"])
        channels = inspection["result"]["channels"]
        check(label + "_seven_complete_channels_in_prior_inspection",
              len(channels) == 7 and all(x["present"] and x["finite"] and x["aligned"] for x in channels))
        check(label + "_coverage_160001_points_0_to_0p8",
              md["sample_count"] == 160001 and md["time_range_s"] == [0, 0.8])
        check(label + "_residual_artifact_hash_matches_prior_trace",
              len(residual_files) == 1 and sha(residual_files[0]) == bmd["artifact_sha256"]
              == residual["result"]["artifact_sha256"])
        check(label + "_plot_case_bundle_binding",
              pmd["case_id"] == cid and pmd["residual_evidence_id"] == bid
              and plot["result"]["residual_evidence_id"] == bid
              and pmd["residual_artifact_sha256"] == bmd["artifact_sha256"]
              and pmd["anomaly_input_hash"] == anomaly["input_hash"])
        for ext in ["png", "fig"]:
            check(label + "_" + ext + "_hash", sha(pdir / ("overview." + ext))
                  == pmd[ext + "_sha256"] == plot["result"][ext + "_sha256"])
        check(label + "_six_tools_previously_executed",
              {x["tool"] for x in chain} == {x["name"] for x in registry["tools"]})
        check(label + "_compensation_explicit_not_independent",
              bmd["load_assumption"] == "prescribed_command" and not bmd["independent_load_supported"])
        alarm_channels = [x["quantity"] for x in anomaly["result"]["channels"] if x["alarmed"] is True]
        check(label + "_previous_alarm_pattern", alarm_channels == {
            "F1": ["x_consistency_m"], "F2": ["phase_sum_A", "torque_known_load_Nm"],
            "F3": ["torque_known_load_Nm"]}[label])
        task = {"draft_id": "DRAFT-" + uuid.uuid4().hex, "case_id": cid,
                "group_id": item["group_id"], "status": "draft_not_released",
                "question": question.format(case_id=cid),
                "allowed_tools": [x["name"] for x in registry["tools"]]}
        tasks.append(task)
        expected = {x["quantity"]: {k: x[k] for k in ["status", "unit", "alarmed", "first_exceed_s",
                    "first_alarm_s", "alarm_intervals_s", "valid_points", "threshold"]}
                    for x in anomaly["result"]["channels"]}
        references.append({"draft_id": task["draft_id"], **item, "expected_channels": expected,
                           "analysis_scope": anomaly["result"]["analysis_scope"],
                           "residual_channel_statistics": residual["result"]["channels"],
                           "reference_bundle_id": bid, "reference_plot_id": pid,
                           "origin": "prior_validated_stage2_outputs_not_new_execution"})
        cases.append({**item, "availability": "existing_evidence_integrity_verified",
                      "metadata": md, "inspection_channels": channels,
                      "prior_analysis_scope": anomaly["result"]["analysis_scope"],
                      "reference_bundle_id": bid, "reference_plot_id": pid,
                      "prior_first_alarm_s": {q: x["first_alarm_s"] for q, x in expected.items()},
                      "new_simulation_needed": False})

    # Reuse historical field inspection only after matching each source MAT hash.
    boundary_specs = [
        ("F1_initial_constant_offset", "F1启动已有偏置0.02mm_健康与运行中注入对照.mat"),
        ("healthy_1800N_compensated_as_1500N", "正常外载1800N与1500N加F3阻力300N_混淆对照.mat")]
    old_by_path = {x["path"].replace("\\", "/"): x for x in old_hashes}
    for label, filename in boundary_specs:
        path = ROOT / "data/legacy_private/2026.10.9" / filename
        relative = path.relative_to(ROOT).as_posix()
        header = next(x for x in old_inventory["files"] if x["file"] == relative)
        record = old_by_path[relative]
        check(label + "_source_matches_historical_MAT_inspection", sha(path) == record["sha256"].lower())
        matching_observations = [x for x in old_inventory["observation_checks"] if x["file"] == relative]
        check(label + "_no_complete_observations_in_historical_inspection", not matching_observations)
        tasks.append({"draft_id": "DRAFT-" + uuid.uuid4().hex, "case_id": None, "group_id": None,
                      "status": "blocked_pending_generation_export_and_tool_context_support",
                      "question_template": question, "allowed_tools": [x["name"] for x in registry["tools"]]})
        cases.append({"research_case": label, "source_file": relative, "source_sha256": sha(path),
                      "prior_top_level_variables": header["variables"],
                      "prior_field_paths": [x["field"] for x in old_inventory["fields"] if x["file"] == relative],
                      "availability": "historical_residuals_only_observation_generation_needed",
                      "case_id": None, "group_id": None, "new_simulation_needed": True,
                      "numeric_expectations": "pending_actual_generation_and_validation"})
    aligned_paths = sorted(p.relative_to(ROOT).as_posix()
                           for p in (ROOT / "results").rglob("observations_aligned.mat"))
    check("only_seven_named_aligned_observation_runs_present", len(aligned_paths) == 7)
    check("five_drafts_three_bound_two_unbound", len(tasks) == 5
          and sum(x["case_id"] is not None for x in tasks) == 3)
    check("no_new_physical_group_ids_assigned", all(x["group_id"] in {m["group_id"] for m in mapping}
          for x in tasks if x["group_id"] is not None))
    for i, task in enumerate(tasks):
        text = task.get("question", task.get("question_template", ""))
        check("neutral_question_without_case_truth_" + str(i + 1),
              not any(word in text for word in ["F1", "F2", "F3", "1800", "0.02", "渐变", "注入"]))
    # Missing-case drafts stay private and cannot be consumed by the runtime.
    write(PRIVATE / "task_drafts.json", {"version": "EMA-STAGE4-DRAFT-0.1", "status": "not_frozen_not_released",
          "partition": "development", "tasks": tasks})
    write(PRIVATE / "reference_expectations.json", {"status": "draft_reference_not_frozen_rubric",
          "references": references,
          "common_requirements": [
              "分别核对数值、证据、物理解释和结论边界；报告有效运动段及补偿假设。",
              "首次连续报警时间不是真值注入时间；无效区间不作健康结论。",
              "渐变趋势只能在实际观测及残差支持的区间描述，不能凭报警时间证明精确注入规律。",
              "没有独立初始位置参考或负载测量时保持unknown，不用指令代替独立测量。",
              "保留初次答复、失败、反馈及成本；本轮开发结果不作泛化准确率。"],
          "case_requirements": {
              "F1_gradual": "位置一致性异常；考虑位置和速度侧，不能凭此唯一确诊具体幅值/注入曲线。",
              "F2_gradual": "联合解释电流和转矩跨通道响应；不能按报警数推断独立故障数或唯一相别。",
              "F3_gradual": "转矩异常保留附加阻力、外载或补偿差异候选；不宣称已证明真实润滑退化。",
              "F1_initial_constant_offset": "初值相减可抵消恒定偏置；未报警不能排除，亦不能仅凭任务身份断言存在。",
              "healthy_1800N_compensated_as_1500N": "仅凭转矩异常不能唯一确诊机械故障；区分指令、实际负载与补偿来源。"},
          "additional_physics_review": "若三相分别增加相同偏差b，电流和增加3b；不得沿用阶段3F3共模解释错误。",
          "pending_freeze": ["两条边界数值参考", "任务发布及CASE/RUN绑定", "信息条件及工况来源",
                             "模型配置及预算快照", "正式评分条目"]})
    gaps = [
        {"id": "G1", "case": "F1_initial_constant_offset",
         "finding": "paper_run_f1_position_bias accepts start time but runs both 0N/1500N and returns residuals only; severity entry exports observations but hardcodes 0.03s onset.",
         "next_action": "Create a research-only single-1500N boundary entry retaining full/native observations and generation inputs; use SimulationInput and verify bias present at t=0.",
         "evidence_files": ["matlab/fixed/paper_run_f1_position_bias.m", "matlab/fixed/paper_run_f1_severity_1500N.m"]},
        {"id": "G2", "case": "healthy_1800N_compensated_as_1500N",
         "finding": "Healthy external-load entry returns observations and correctly compensates its own supplied load; a separate 1500N diagnosis assumption must be constructed and recorded.",
         "next_action": "Run healthy 1800N once, retain actual source inputs privately, then compute diagnosis using an explicitly distinct 1500N assumption. Preserve authentic command provenance according to the frozen information condition.",
         "evidence_files": ["matlab/fixed/paper_run_healthy_external_load.m"]},
        {"id": "G3", "case": "both_new_boundaries",
         "finding": "Current observation release uses shared context CTX-PRESCRIBED-1.0 and common operating_context.mat; schema only allows none/prescribed_command. New cases and differing command/compensation provenance are not yet released or supported.",
         "next_action": "Version the observation release and necessary context/selection support; verify same-case binding and truth isolation before Agent use. Do not overwrite observations_v1 or claim 1500N is the true 1800N run command.",
         "evidence_files": ["tools/private/read_residual_input.m", "tools/private/inspect_case_core.m",
                            "tools/private/query_context_core.m", "tools/registry/compute_residual_bundle.schema.json",
                            "scripts/export_stage2_cases.m"]},
        {"id": "G4", "case": "all_five_tasks",
         "finding": "Task and evaluation drafts exist; budgets/model settings/information conditions are not frozen.",
         "next_action": "After two boundary observation exports and context support checks, freeze common settings and private rubric before any LLM diagnosis."}]
    for gap in gaps:
        for name in gap.get("evidence_files", []):
            SOURCES[name] = sha(ROOT / name)
    write(OUT / "case_inventory.json", {"experiment": EXP, "user_stage": 4, "step": 1,
          "inspection_mode": "current_file_hashes_and_bindings_with_prior_MATLAB_field_inspection",
          "fresh_mat_content_read": False, "fresh_residual_calculation": False,
          "agent_performance_evaluated": False, "cases": cases,
          "aligned_observation_paths": aligned_paths, "gaps": gaps})
    write(OUT / "release_integrity.json", {"files": manifest_checks})
    write(OUT / "evidence_manifest.json", {"files": [{"path": p, "sha256": h} for p, h in sorted(SOURCES.items())]})
    after = {name: sha(ROOT / name) for name in before}
    write(OUT / "protected_hashes_after.json", after)
    check("all_existing_protected_files_unchanged", before == after)
    check("no_stage4_tasks_released_to_agent", not (ROOT / "data/agent_visible/tasks_stage4_v1").exists())
    write(OUT / "acceptance.json", {"experiment": EXP, "user_stage": 4, "step": 1,
          "passed": all(x["passed"] for x in CHECKS), "check_count": len(CHECKS),
          "checks_passed": sum(x["passed"] for x in CHECKS), "checks": CHECKS,
          "protected_file_count": len(before), "protected_hashes_unchanged": before == after,
          "llm_calls": 0, "new_matlab_tool_calls": 0, "new_physical_simulations": 0,
          "new_agent_diagnoses": 0, "existing_gradual_runs_reused": 3,
          "boundary_runs_pending_generation": 2, "task_drafts": 5,
          "tasks_frozen": False, "stage4_complete": False,
          "timestamp_utc": datetime.now(timezone.utc).isoformat()})
    failures = [x["name"] for x in CHECKS if not x["passed"]]
    print(json.dumps({"passed": not failures, "checks": len(CHECKS), "failures": failures,
                      "protected_files": len(before), "task_drafts": len(tasks)}))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
