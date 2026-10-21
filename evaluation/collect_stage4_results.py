"""Research-only post-execution audit. Never loaded by the diagnostic Agent."""
from copy import deepcopy
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "scripts")]
from bailian_client import load_tools, read_api_key, read_json, sha256
from controlled_loop import system_message
from basic_case_rules import FINAL_PHASE_MESSAGE
from stage4_case_rules import evidence_ready_stage4
from report_contract import check_report, decode_report, repair_message, ID_PATTERN
from tool_executor import canonical
from run_stage4_agent import load_frozen

BASE = ROOT / "results/EXP-20261020-020"


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def equal(value, expected, *, relative=0, absolute=0):
    if expected == [] or expected is None:
        return value is None or value == []
    if isinstance(expected, bool):
        return type(value) is bool and value == expected
    if isinstance(expected, (int, float)):
        return type(value) in (int, float) and math.isclose(value, expected, rel_tol=relative, abs_tol=absolute)
    if isinstance(expected, list):
        return isinstance(value, list) and len(value) == len(expected) and all(
            equal(a, b, relative=relative, absolute=absolute) for a, b in zip(value, expected))
    return value == expected


def numerical(channels, reference, intervals, *, report):
    rows = {c["quantity"]: c for c in channels}
    checks = []
    for quantity, expected in reference["expected_channels"].items():
        actual = rows.get(quantity, {})
        for key, value in {**expected, "valid_motion_intervals_s": intervals}.items():
            absolute = (0.0005 if report else 1e-12) if key in (
                "first_alarm_s", "first_exceed_s", "valid_motion_intervals_s") else 0
            relative = (0.005 if report else 1e-12) if key in ("threshold", "valid_max_abs", "valid_rms") else 0
            checks.append({"quantity": quantity, "field": key, "expected": value,
                           "actual": actual.get(key), "passed": key in actual and equal(
                               actual[key], value, relative=relative, absolute=absolute)})
    return {"passed": all(c["passed"] for c in checks), "passed_count": sum(c["passed"] for c in checks),
            "check_count": len(checks), "checks": checks}


def actual_bundle(records, reference):
    bundle = next((e["response"]["result"] for e in records if e["tool"] == "compute_residual_bundle"
                   and e["response"].get("result", {}).get("bundle_id") == reference["bundle_id"]), None)
    alarms = next((e["response"]["result"] for e in records if e["tool"] == "locate_anomalies"
                   and e["response"].get("result", {}).get("residual_evidence_id") == reference["bundle_id"]), None)
    if not bundle or not alarms:
        return {"passed": False, "reason": "REQUIRED_BUNDLE_OR_ALARMS_MISSING"}
    rows = []
    for alarm in alarms["channels"]:
        residual = next(c for c in bundle["channels"] if c["quantity"] == alarm["quantity"])
        rows.append({**alarm, "valid_max_abs": residual["valid_max_abs"], "valid_rms": residual["valid_rms"],
                     "valid_motion_intervals_s": alarms["analysis_scope"]["valid_motion_intervals_s"]})
    result = numerical(rows, reference, reference["valid_motion_intervals_s"], report=False)
    result["binding_passed"] = (bundle["load_assumption"] == reference["load_assumption"]
        and equal(alarms["analysis_scope"]["effective_interval_s"], reference["analysis_interval_s"], absolute=1e-12))
    result["passed"] &= result["binding_passed"]
    return result


def audit(task, rubric, folder, registration, config, protocol):
    trace = read_json(folder / "trace.json")
    summary = read_json(folder / "summary.json")
    checks = []
    def check(name, passed, detail=None):
        checks.append({"name": name, "passed": bool(passed), "detail": detail})
    check("task_case_group_binding", all(summary[k] == task[k] == rubric[k] for k in ("task_id", "case_id", "group_id"))
          and trace["case_id"] == task["case_id"])
    check("registered_before_execution", registration["registered_at_utc"] < summary["registered_at_utc"] < trace["timestamp_utc"])
    check("real_official_model_trace", trace["response_source"] == "deepseek_official_live"
          and trace["purpose"] == "stage4_complex_development")
    check("frozen_config_and_prompt", read_json(folder / "config_snapshot.json") == config
          and read_json(folder / "runtime_manifest.json")["system_message"] == system_message(True, True, True)
          and trace["provider_config_sha256"] == sha256(ROOT / "configs/llm_stage4_frozen_v1.json")
          and trace["tool_registry_sha256"] == sha256(ROOT / protocol["registry"]))
    reconstructed = [{"role": "system", "content": system_message(True, True, True)},
                     {"role": "user", "content": task["question"]}]
    check("fresh_public_initial_context", trace["messages"][:2] == reconstructed)
    tools = load_tools(ROOT / "tools/registry_stage4")
    records, models = [], []
    index = 0
    matching_inputs = matching_backend = automatic = matching_checker = matching_gate = True
    tool_call_binding = True
    pending = {}
    phase = False
    last_check = None
    report_attempts = []
    for event in trace["events"]:
        if event["type"] == "model_response":
            models.append(event)
            request = event["request"]
            matching_inputs &= (request["messages"] == reconstructed and request["tools"] == tools
                and request["model"] == config["model"] and event["model_returned"] == config["model"]
                and request.get("thinking") == {"type": "disabled"}
                and request["temperature"] == 0 and request["max_tokens"] == 4096 and request["stream"] is False)
            automatic &= request.get("tool_choice", "auto") == ("none" if phase else "auto")
            pending.update({c["id"]: c["function"] for c in event["message"].get("tool_calls", [])})
            reconstructed.append(event["message"])
        elif event["type"] == "tool_result":
            call = pending.pop(event["tool_call_id"], {})
            tool_call_binding &= call.get("name") == event["tool"] and json.loads(call.get("arguments", "null")) == event["arguments"]
            records.append(event)
            if event["backend_executed"]:
                index += 1
                envelope = read_json(folder / "worker_records" / f"response_{index:04d}.json")
                req = read_json(folder / "worker_records" / f"request_{index:04d}.json")
                matching_backend &= (envelope["bridge_status"] == "ok" and envelope["response"] == event["response"]
                    and req["tool"] == event["tool"] and req["arguments"] == event["arguments"] and req["sequence"] == index)
            reconstructed.append({"role": "tool", "tool_call_id": event["tool_call_id"], "content": canonical(event["response"])})
        elif event["type"] == "report_phase":
            matching_gate &= not phase and evidence_ready_stage4(records) and event["message"] == {"role": "user", "content": FINAL_PHASE_MESSAGE}
            phase = True
            reconstructed.append(event["message"])
        elif event["type"] == "report_check":
            last_check = check_report(reconstructed[-1]["content"], records, task["case_id"])
            matching_checker &= last_check == event["result"]
            text = reconstructed[-1]["content"]
            decoded = decode_report(text)
            report_attempts.append({"attempt": event["attempt"], "evidence_check_passed": last_check["passed"],
                "frozen_baseline_binding": decoded["bundle_id"] == rubric["baseline"]["bundle_id"]
                    and decoded["load_assumption"] == rubric["baseline"]["load_assumption"],
                "numbers": numerical(decoded["channels"], rubric["baseline"], rubric["baseline"]["valid_motion_intervals_s"], report=True)})
            check("original_report_attempt_" + str(event["attempt"]) + "_preserved", (folder / f"report_attempt_{event['attempt']:02d}.txt").read_text(encoding="utf-8") == text)
        elif event["type"] == "report_feedback":
            matching_checker &= event["message"] == {"role": "user", "content": repair_message(last_check)}
            reconstructed.append(event["message"])
    check("all_requests_reconstruct_from_public_inputs_actual_tools_and_program_feedback", matching_inputs and reconstructed == trace["messages"])
    check("actual_model_tool_calls_match_executed_arguments", tool_call_binding and not pending)
    check("automatic_tool_selection_until_report_phase", automatic)
    check("report_gate_reproduces_from_public_evidence", matching_gate and phase == trace["report_phase_started"])
    check("program_checks_and_feedback_reproduce", matching_checker)
    check("archived_worker_requests_and_responses_match", matching_backend and index == trace["matlab_backend_calls"])
    check("all_six_capabilities_obtained", {r["tool"] for r in records} == {t["function"]["name"] for t in tools})
    check("same_case_only_successful_real_tools", all(r["backend_executed"] and r["response"]["status"] == "ok"
          and r["response"]["case_id"] == task["case_id"] for r in records))
    source_ids = set(re.findall(ID_PATTERN, canonical([r["response"] for r in records])))
    cited = set(re.findall(ID_PATTERN, trace["final_text"]))
    check("final_full_ids_obtained_in_this_run", bool(cited) and cited.issubset(source_ids), {"unknown_ids": sorted(cited-source_ids)})
    final = decode_report(trace["final_text"])
    check("final_evidence_check", check_report(trace["final_text"], records, task["case_id"])["passed"])
    check("final_frozen_baseline_mode_and_bundle", final["bundle_id"] == rubric["baseline"]["bundle_id"]
          and final["load_assumption"] == rubric["baseline"]["load_assumption"])
    check("same_baseline_plot", final["plot"]["residual_evidence_id"] == rubric["baseline"]["bundle_id"])
    check("unknown_independent_information_retained", all(any(u["condition"] == name and u["state"] == "unknown"
          for u in final["unknowns"]) for name in ("independent_normal_load", "independent_initial_reference")))
    check("unchanged_original_final_saved", (folder / "final_response.md").read_text(encoding="utf-8") == trace["final_text"]
          and read_json(folder / "report.json") == final)
    budget = protocol["per_task_budget"]
    check("registered_budgets", trace["model_http_attempts"] <= budget["model_http_attempts"]
          and trace["tool_call_attempts"] <= budget["tool_call_attempts"]
          and trace["elapsed_s"] <= budget["diagnostic_loop_wall_time_s"]
          and trace["report_repairs"] <= budget["program_report_repairs_max"])
    check("completion_counts_match", trace["model_responses"] == len(models) == summary["llm_calls"]
          and index == summary["real_tool_calls"] and trace["model_http_attempts"] == summary["model_http_attempts"])
    check("no_truncated_or_error_response", all(e["finish_reason"] in ("stop", "tool_calls") for e in models)
          and not any(e["type"] == "model_error" for e in trace["events"]))
    check("worker_closed", summary["worker_stopped_cleanly"] and read_json(folder / "worker_records/stopped.json")["status"] == "stopped")
    check("no_simulation", trace["new_physical_simulations"] == summary["new_physical_simulations"] == 0
          and summary["matlab_runtime"]["simulation_executed"] is False)
    key = read_api_key("DEEPSEEK_API_KEY")
    check("credential_absent_from_saved_trace", bool(key) and key not in (folder / "trace.json").read_text(encoding="utf-8"))
    baseline = actual_bundle(records, rubric["baseline"])
    comparison = actual_bundle(records, rubric["comparison"]) if rubric["comparison_required"] else None
    check("required_comparison_actually_obtained", comparison is None or comparison["passed"])
    usage = {k: sum(e["usage"].get(k, 0) for e in models) for k in ("prompt_tokens", "completion_tokens", "total_tokens")}
    return {"task_id": task["task_id"], "case_id": task["case_id"], "group_id": task["group_id"],
        "reference_class_private": rubric["reference_class"], "source_trace_sha256": sha256(folder / "trace.json"),
        "source_final_sha256": sha256(folder / "final_response.md"), "run_directory": folder.relative_to(ROOT).as_posix(),
        "provenance": {"checks": checks, "passed_count": sum(c["passed"] for c in checks), "check_count": len(checks), "passed": all(c["passed"] for c in checks)},
        "tool_baseline_numbers": baseline, "tool_required_comparison_numbers": comparison, "report_attempts": report_attempts,
        "numeric_evidence_passed": all(c["passed"] for c in checks) and baseline["passed"] and all(
            a["evidence_check_passed"] and a["frozen_baseline_binding"] and a["numbers"]["passed"] for a in report_attempts),
        "http_attempts": trace["model_http_attempts"], "model_responses": len(models), "real_tool_calls": index,
        "report_repairs": trace["report_repairs"], "usage_returned": usage, "unreturned_requests": trace["model_http_attempts"]-len(models),
        "diagnostic_loop_s": trace["elapsed_s"], "end_to_end_s": summary["end_to_end_s"],
        "tool_order": [r["tool"] for r in records], "semantic_scoring": "Separate manual review required; this audit does not grade physical explanations."}


def main():
    tasks, config, protocol, manifest = load_frozen()
    progress = read_json(BASE / "progress.json")
    assert progress["status"] == "five_attempts_finished_pending_evaluation"
    registration = read_json(BASE / "preregistration.json")
    private = ROOT / "data/evaluation_private/EXP-20261020-019/rubric.json"
    assert sha256(private) == registration["private_rubric_sha256"]
    rubric = read_json(private)
    runs = list((BASE / "runs").glob("*/summary.json"))
    assert len(runs) == len(tasks) == 5
    results = []
    for task in tasks:
        matches = [p.parent for p in runs if read_json(p)["task_id"] == task["task_id"]]
        assert len(matches) == 1
        results.append(audit(task, next(r for r in rubric["tasks"] if r["task_id"] == task["task_id"]),
                             matches[0], registration, config, protocol))
    protected = read_json(BASE / "protected_hashes_before.json")
    drift = [name for name, expected in protected.items() if sha256(ROOT / name) != expected]
    out = {"scope": "Post-execution research audit; no LLM, no new simulation, no semantic auto-grading.",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(), "experiment_id": "EXP-20261020-020",
        "actual_execution_date_local": "2026-10-21", "planned_id_date_retained": True,
        "private_rubric_sha256": sha256(private), "frozen_files_unchanged": len(manifest["frozen_files_sha256"]),
        "preexisting_protected_count": len(protected), "preexisting_protected_drift": drift,
        "tasks": results, "numeric_evidence_tasks_passed": sum(r["numeric_evidence_passed"] for r in results),
        "totals": {k: sum(r[k] for r in results) for k in ("http_attempts", "model_responses", "real_tool_calls", "report_repairs", "unreturned_requests")},
        "usage_returned": {k: sum(r["usage_returned"][k] for r in results) for k in ("prompt_tokens", "completion_tokens", "total_tokens")},
        "new_physical_simulations": 0, "formal_generalization_accuracy": None}
    write(BASE / "evaluation/deterministic_audit.json", out)
    print(json.dumps({k: out[k] for k in ("numeric_evidence_tasks_passed", "totals", "usage_returned", "preexisting_protected_drift")}))
    for result in results:
        print(json.dumps({"task": result["task_id"], "provenance": [result["provenance"]["passed_count"], result["provenance"]["check_count"]],
            "failed": [c["name"] for c in result["provenance"]["checks"] if not c["passed"]],
            "report_numbers": [(a["numbers"]["passed_count"], a["numbers"]["check_count"]) for a in result["report_attempts"]]}))
    return 0 if not drift and all(r["numeric_evidence_passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
