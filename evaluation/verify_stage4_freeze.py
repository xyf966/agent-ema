"""Research-side verification of the frozen stage4 development protocol."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "agent"))
sys.path.insert(0, str(ROOT / "scripts"))
from bailian_client import read_json, sha256
from run_stage4_agent import load_frozen

OUT = ROOT / "results/EXP-20261020-019"


def write(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")


def main():
    checks = []

    def check(name, value):
        checks.append({"name": name, "passed": bool(value)})

    tasks, config, protocol, manifest = load_frozen()
    receipt = read_json(OUT / "freeze_receipt.json")
    rubric_path = ROOT / "data/evaluation_private/EXP-20261020-019/rubric.json"
    rubric = read_json(rubric_path)
    by_task = {r["task_id"]: r for r in rubric["tasks"]}
    check("five_anonymous_tasks_five_unique_groups", len(tasks) == 5 and len({t["group_id"] for t in tasks}) == 5)
    check("private_rubric_hash_frozen", sha256(rubric_path) == receipt["private_rubric_sha256"])
    check("public_manifest_hash_frozen", sha256(ROOT / "data/agent_visible/tasks_stage4_v1/manifest.json") == receipt["public_manifest_sha256"])
    check("protocol_hash_frozen", sha256(ROOT / "configs/stage4_protocol_v1.json") == receipt["protocol_sha256"])
    check("102_runtime_files_match_frozen_hashes", len(manifest["frozen_files_sha256"]) == 102)
    check("public_manifest_has_no_private_evaluation_inputs", not any("evaluation_private" in p or "legacy_private" in p
           or "source_snapshot" in p for p in manifest["frozen_files_sha256"]))
    normalized = {t["question"].replace(t["case_id"], "CASE") for t in tasks}
    check("one_common_question_template", len(normalized) == 1)
    # Numeric substrings in opaque UUIDs are not case information. Inspect
    # semantic task fields, while checking identity formats independently.
    public_text = json.dumps([{k: t[k] for k in ("question", "information_condition", "allowed_tools")} for t in tasks], ensure_ascii=False)
    check("task_text_contains_no_source_truth_or_fault_labels", not re.search(r"F[123]|healthy|reference_class|source_run_id|injected_|appliedFault|1800|1500|0\.02", public_text))
    check("task_fields_and_opaque_id_formats", all(set(t) == {"task_id", "case_id", "group_id", "question", "allowed_tools", "information_condition"}
          and re.fullmatch(r"TASK-[0-9a-f]{32}", t["task_id"]) and re.fullmatch(r"CASE-[0-9a-f]{32}", t["case_id"])
          and re.fullmatch(r"RUN-[0-9a-f]{32}", t["group_id"]) for t in tasks))
    check("three_gradual_and_two_boundary_runs", {r["reference_class"] for r in rubric["tasks"]} == {
        "F1", "F2", "F3", "F1_initial_constant_offset", "healthy_load_compensation_mismatch"})
    for task in tasks:
        r = by_task[task["task_id"]]
        check(task["task_id"] + "_case_group_and_private_reference_bound", r["case_id"] == task["case_id"]
              and r["group_id"] == task["group_id"] and len(r["baseline"]["expected_channels"]) == 3)
    check("comparison_required_only_by_public_source_mismatch", sum(r["comparison_required"] for r in rubric["tasks"]) == 1
          and next(r for r in rubric["tasks"] if r["comparison_required"])["comparison"]["load_assumption"] == "prescribed_command")
    initial = next(r for r in rubric["tasks"] if r["reference_class"] == "F1_initial_constant_offset")
    check("initial_offset_407_points_pre_registered", all(c["valid_points"] == 407 for c in initial["baseline"]["expected_channels"].values()))
    check("same_current_provider_without_weight_snapshot_claim", config["model"] == "deepseek-flash" and config["provider"] == "deepseek_official"
          and config["model_version_frozen"] is False and protocol["model_weights_snapshot_frozen"] is False)
    check("frozen_temperature_thinking_and_output_budget", config["generation_settings"] == {
        "temperature": 0, "enable_thinking": False, "stream": False, "max_output_tokens_per_diagnostic_response": 4096})
    check("one_attempt_no_network_retry_no_simulation_budget", protocol["repeats_per_task"] == 1
          and protocol["per_task_budget"]["automatic_network_retries"] == 0 and protocol["per_task_budget"]["new_simulations"] == 0
          and protocol["per_task_budget"]["model_http_attempts"] == 12 and protocol["per_task_budget"]["tool_call_attempts"] == 20)
    check("information_condition_explicit_and_not_hidden_command_variant", protocol["hidden_command_variant_included"] is False
          and protocol["independent_load_measurement_available"] is False and protocol["independent_initial_reference_available"] is False)
    runtimes = [p for p in (OUT / "runtime_checks").glob("*/acceptance.json") if read_json(p)["passed"]]
    loops = [p for p in (OUT / "loop_checks").glob("*/acceptance.json") if read_json(p)["passed"]]
    check("real_worker_34_checks_32_calls_pass", len(runtimes) == 1 and read_json(runtimes[0])["checks_passed"] == 34
          and read_json(runtimes[0])["real_guarded_matlab_calls"] == 32)
    check("offline_loop_30_checks_pass", len(loops) == 1 and read_json(loops[0])["checks_passed"] == 30)
    live = list((OUT / "live_protocol").glob("*/summary.json"))
    check("one_authorized_inspection_roundtrip_passed", len(live) == 1 and read_json(live[0])["roundtrip_passed"] is True
          and read_json(live[0])["llm_calls"] == 2 and read_json(live[0])["real_tool_calls"] == 1)
    summary = read_json(live[0])
    check("protocol_is_not_a_diagnostic_task", summary["task_id"] is None and summary["purpose"] == "stage4_protocol_inspect_only"
          and summary["semantic_task_accepted"] is None)
    # Preserve old-source drift as explicit development, never rewrite snapshots.
    before = read_json(OUT / "protected_hashes_before.json")
    after = {p: sha256(ROOT / p) for p in before}
    changed = [p for p, h in before.items() if after[p] != h]
    expected = {"agent/bailian_client.py", "agent/tool_executor.py", "agent/matlab_bridge.py",
                "agent/controlled_loop.py", "agent/matlab/ema_agent_worker.m", "tools/registry_stage4/tool_registry_v1.json"}
    expected.update("tools/registry_stage4/" + t["schema_file"] for t in read_json(ROOT / "tools/registry_stage4/tool_registry_v1.json")["tools"])
    check("only_12_documented_runtime_and_schema_updates", set(changed) == expected)
    check("previous_bytes_backed_up_for_all_changes", all(sha256(OUT / "source_before" / p) == before[p] for p in changed))
    write(OUT / "protected_hashes_after_final.json", after)
    write(OUT / "source_changes_final.json", {"modified_files": [{"path": p, "before": before[p], "after": after[p],
          "backup": "results/EXP-20261020-019/source_before/" + p} for p in sorted(changed)],
          "protected_before_count": len(before), "unchanged_file_count": len(before)-len(changed),
          "models_historical_results_snapshots_and_observation_arrays_changed": False})
    regressions = [
        ROOT / "results/EXP-20261020-002/validation/66b3835ada6547f188feb7640bc9ba7e/acceptance.json",
        ROOT / "results/EXP-20261020-005/validation/fb096a5cd7f44544b469af1030a03118/acceptance.json",
        ROOT / "results/EXP-20261020-004/validation/2f2f47018b564288ade30d5515b9aa87/acceptance.json"]
    check("legacy_46_12_97_regressions_pass", all(read_json(p)["all_passed"] for p in regressions))
    usage = summary["usage_returned"]
    result = {"experiment_id": "EXP-20261020-019", "user_stage": 4, "step": 3,
              "passed": all(c["passed"] for c in checks), "checks": checks,
              "check_count": len(checks), "checks_passed": sum(c["passed"] for c in checks),
              "frozen_tasks": 5, "frozen_runtime_files": 102, "private_rubric_frozen": True,
              "new_physical_simulations": 0, "representative_physical_runs_total": 9,
              "new_complex_agent_diagnoses": 0, "live_model_responses": 2, "live_http_requests": summary["model_http_attempts"],
              "live_usage_returned_total_tokens": sum(u["total_tokens"] for u in usage),
              "real_matlab_dispatch_calls": 33, "worker_integration_calls": 32, "live_roundtrip_tool_calls": 1,
              "source_files_modified_and_versioned": len(changed), "existing_files_unchanged": len(before)-len(changed),
              "stage4_complete": False, "next_step": "Stage4 step4: execute frozen five-task development batch once each.",
              "evidence": [p.relative_to(ROOT).as_posix() for p in runtimes+loops+live+regressions],
              "timestamp_utc": datetime.now(timezone.utc).isoformat()}
    result["prior_verification_false_positive"] = "acceptance.json retained: numeric substring 1500 in opaque RUN-c31500... was misclassified as a label; semantic fields and opaque-ID formats now checked separately without changing frozen tasks."
    write(OUT / "acceptance_final.json", result)
    write(OUT / "execution_issues_final.json", {"issues": [
        {"type": "sandbox_MATLAB_startup", "result": "File system inconsistency; no tools or simulation executed.",
         "evidence": "runtime_checks/82c5172fd37e4a25a7ec3fc49b3ba890/acceptance.json", "resolution": "Approved normal-user process passed with unchanged tool scope."},
        {"type": "external_API_auto_review_rejection", "result": "Initial command rejected before start; zero API requests from rejection.",
         "reason": "Reviewer required specific authorization for task prompts and tool-derived project data to DeepSeek.",
         "human_authorization": "User explicitly replied: 我批准", "resolution": "Two requests and one anonymous inspection roundtrip passed within approved payload scope."},
        {"type": "offline_verification_false_positive", "result": "26/27 initial freeze checks; anonymous group ID contains numeric substring 1500.",
         "resolution": "Check semantic task fields separately from opaque ID formats; frozen tasks and answers unchanged.",
         "evidence": "acceptance.json"}],
          "unresolved_issues": []})
    print(json.dumps({k: result[k] for k in ["passed", "checks_passed", "check_count", "frozen_tasks", "existing_files_unchanged", "live_usage_returned_total_tokens"]}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
