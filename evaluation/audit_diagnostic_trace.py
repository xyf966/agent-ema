"""Research-only audit of recorded diagnostic evidence; not a semantic grader.

Reads a pre-registered private rubric only AFTER execution. Never an Agent tool.
"""

import argparse
import ast
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "scripts")]
from bailian_client import load_tools, read_api_key, read_json, sha256
from controlled_loop import SYSTEM_MESSAGE
from run_controlled_agent import experiment_id, public_tasks
from tool_executor import canonical
from report_contract import check_report, decode_report, repair_message
from basic_case_rules import FINAL_PHASE_MESSAGE, evidence_ready

ID_PATTERN = r"(?:EV|CTX|METHOD|ANOM|BUNDLE|PLOT)-[0-9a-f]{64}(?:-(?:[0-9]+|scope))?"


def collect_ids(value):
    found = set()
    if isinstance(value, dict):
        for child in value.values():
            found.update(collect_ids(child))
    elif isinstance(value, list):
        for child in value:
            found.update(collect_ids(child))
    elif isinstance(value, str) and re.fullmatch(ID_PATTERN, value):
        found.add(value)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-id", required=True, type=experiment_id)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt-plan", help="Optional attempt_NN.json in this experiment, never a path")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{32}", args.run_id):
        raise SystemExit("INVALID_RUN_ID")
    base = ROOT / "results" / args.experiment_id
    folder = base / "runs" / args.run_id
    trace = read_json(folder / "trace.json")
    summary = read_json(folder / "summary.json")
    if args.attempt_plan and not re.fullmatch(r"attempt_[0-9]{2}\.json", args.attempt_plan):
        raise SystemExit("INVALID_ATTEMPT_PLAN")
    plan = read_json(base / (args.attempt_plan or "preregistration.json"))
    private_path = ROOT / "data/evaluation_private" / args.experiment_id / "pre_registered_rubric.json"
    rubric_file = read_json(private_path)
    task_id = plan.get("task_id", summary["task_id"])
    if "task_ids" in plan and task_id not in plan["task_ids"]:
        raise SystemExit("TASK_NOT_REGISTERED")
    rubric = rubric_file["task"] if "task" in rubric_file else next(t for t in rubric_file["tasks"] if t["task_id"] == task_id)
    task = next(t for t in public_tasks() if t["task_id"] == task_id)
    checks = []

    def check(name, passed, detail=None):
        value = {"name": name, "passed": bool(passed)}
        if detail is not None:
            value["detail"] = detail
        checks.append(value)

    check("rubric_registered_before_run_and_unchanged", sha256(private_path) == plan["private_rubric_sha256"]
          and plan["created_utc"] < trace["timestamp_utc"])
    check("task_and_group_binding", summary["task_id"] == task["task_id"] == rubric["task_id"]
          and summary["group_id"] == task["group_id"] == rubric["group_id"]
          and trace["case_id"] == task["case_id"] == rubric["case_id"])
    expected_source = plan.get("response_source", "bailian_live")
    allowed_source = (expected_source == "bailian_live" or
                      expected_source == "deepseek_official_live" and plan.get("provider") == "deepseek_official")
    check("real_model_trace_not_fixture", allowed_source and trace["response_source"] == expected_source
          and summary["diagnostic_run"])
    check("model_finished_without_truncation_or_budget_failure", trace["termination_reason"] in ("model_finished", "report_evidence_checked"))
    if "system_message" in plan:
        expected_system = plan["system_message"]
    else:
        # Original attempt used a single literal assignment, preserved before execution.
        tree = ast.parse((base / "implementation_snapshot/agent/controlled_loop.py").read_text(encoding="utf-8"))
        expected_system = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                               and any(isinstance(t, ast.Name) and t.id == "SYSTEM_MESSAGE" for t in node.targets))
    check("private_answers_not_in_initial_context", trace["messages"][:2] == [
        {"role": "system", "content": expected_system}, {"role": "user", "content": task["question"]}])
    reconstructed = deepcopy(trace["messages"][:2])
    tools = load_tools()
    source_ids = set()
    backend_index = 0
    backend_equal = True
    model_requests_equal = True
    automatic = True
    report_checks_match = True
    recorded_tools = []
    last_report_check = None
    report_phase = False
    report_phase_matches = True
    for event in trace["events"]:
        if event["type"] == "model_response":
            request = event["request"]
            model_requests_equal &= (request["messages"] == reconstructed and request["tools"] == tools
                                     and request["model"] == plan["model"])
            if plan.get("provider") == "deepseek_official":
                model_requests_equal &= (request.get("thinking") == {"type": "disabled"}
                                         and "enable_thinking" not in request
                                         and event.get("model_returned") == plan["model"])
            automatic &= request.get("tool_choice", "auto") == ("none" if report_phase else "auto")
            reconstructed.append(event["message"])
        elif event["type"] == "tool_result":
            recorded_tools.append(event)
            result = event["response"]
            if event["backend_executed"]:
                backend_index += 1
                envelope = read_json(folder / "worker_records" / f"response_{backend_index:04d}.json")
                backend_equal &= envelope["bridge_status"] == "ok" and envelope["response"] == result
            reconstructed.append({"role": "tool", "tool_call_id": event["tool_call_id"], "content": canonical(result)})
            source_ids.update(collect_ids(result))
        elif event["type"] == "report_check":
            last_report_check = check_report(reconstructed[-1]["content"], recorded_tools, task["case_id"])
            report_checks_match &= last_report_check == event["result"]
        elif event["type"] == "report_feedback":
            expected_feedback = {"role": "user", "content": repair_message(last_report_check)} if last_report_check else None
            report_checks_match &= event["message"] == expected_feedback
            reconstructed.append(event["message"])
        elif event["type"] == "report_phase":
            report_phase_matches &= (not report_phase and trace.get("shared_basic_rules")
                                     and evidence_ready(recorded_tools)
                                     and event["message"] == {"role": "user", "content": FINAL_PHASE_MESSAGE})
            report_phase = True
            reconstructed.append(event["message"])
    check("all_model_inputs_reconstruct_from_public_task_and_actual_results", model_requests_equal and reconstructed == trace["messages"])
    check("no_forced_tool_sequence", automatic)
    if trace.get("shared_basic_rules"):
        check("report_phase_only_after_actual_three_channel_evidence", report_phase_matches
              and report_phase == trace["report_phase_started"])
    if trace.get("report_checks_enabled"):
        check("report_checks_and_feedback_reproduce_from_actual_public_results", report_checks_match)
        check("final_structured_report_evidence_check_passes", check_report(trace["final_text"], recorded_tools, task["case_id"])["passed"])
        check("report_repair_and_all_requests_within_registered_limits", trace["report_repairs"] <= 1
              and trace["model_http_attempts"] <= plan["call_budget"]["diagnostic_model_responses_per_task"]
              and trace["tool_call_attempts"] <= plan["call_budget"]["diagnostic_tool_calls_per_task"]
              and trace["elapsed_s"] <= plan["call_budget"]["diagnostic_wall_time_limit_s"])
    check("all_forwarded_backend_results_equal_archived_matlab_outputs", backend_equal and backend_index == trace["matlab_backend_calls"])
    citations = set(re.findall(ID_PATTERN, trace["final_text"]))
    check("final_report_contains_actual_evidence_ids", bool(citations))
    check("no_unobtained_full_evidence_ids_in_final", citations.issubset(source_ids), {"citations": len(citations), "unobtained": sorted(citations - source_ids)})
    events = [e for e in trace["events"] if e["type"] == "tool_result"]
    check("only_registered_case_scoped_tools", all(e["tool"] in {t["function"]["name"] for t in tools}
          and e["response"].get("case_id") in (task["case_id"], "") for e in events))
    comp = next((e["response"] for e in events if e["tool"] == "compute_residual_bundle"
                 and e.get("arguments", {}).get("load_assumption") == "prescribed_command"), None)
    alarms = next((e["response"] for e in events if e["tool"] == "locate_anomalies"
                   and comp and e.get("arguments", {}).get("residual_evidence_id") == comp["result"].get("bundle_id")), None)
    check("explicit_command_assumption_observed_not_silently_filled", comp is not None)
    check("compensated_anomaly_evidence_obtained", alarms is not None)
    if comp and alarms:
        values = {c["quantity"]: c for c in comp["result"]["channels"]}
        alerts = {c["quantity"]: c for c in alarms["result"]["channels"]}
        for quantity, expected in rubric["expected_channels"].items():
            check("tool_numerical_reference_" + quantity, all(
                math.isclose(values[quantity][key], expected[key], rel_tol=1e-12, abs_tol=0)
                for key in ("valid_max_abs", "valid_rms")) and alerts[quantity]["alarmed"] == expected["alarmed"]
                and (alerts[quantity]["first_alarm_s"] == expected["first_alarm_s"]
                     if isinstance(expected["first_alarm_s"], list) else
                     math.isclose(alerts[quantity]["first_alarm_s"], expected["first_alarm_s"], rel_tol=0,
                                  abs_tol=rubric["numeric_tolerances"]["tool_time_comparison_abs_s"])))
        plots = [e["response"] for e in events if e["tool"] == "plot_evidence"
                 and e.get("arguments", {}).get("residual_evidence_id") == comp["result"]["bundle_id"]]
        check("same_bundle_compensated_plot_obtained", bool(plots) and plots[0]["status"] == "ok")
    context = next((e["response"] for e in events if e["tool"] == "query_operating_context"), None)
    if context:
        conditions = {v["name"]: v["state"] for v in context["preconditions"]}
        check("unknown_independent_information_not_filled", conditions.get("independent_normal_load") == "unknown"
              and conditions.get("independent_initial_reference") == "unknown")
    else:
        check("unknown_independent_information_not_filled", False)
    check("all_six_evidence_capabilities_used", {e["tool"] for e in events} == {t["function"]["name"] for t in tools})
    protected = read_json(base / "protected_before.json")
    check("all_preexisting_protected_files_unchanged", all(sha256(ROOT / name) == value for name, value in protected.items()), len(protected))
    check("owned_matlab_worker_stopped", summary["worker_stopped_cleanly"] and read_json(folder / "worker_records/stopped.json")["status"] == "stopped")
    check("no_new_physical_simulation", trace["new_physical_simulations"] == summary["new_physical_simulations"] == 0)
    key = read_api_key()
    check("actual_key_not_present_in_saved_trace", not key or key not in (folder / "trace.json").read_text(encoding="utf-8"))
    model_events = [e for e in trace["events"] if e["type"] == "model_response"]
    report = {"scope": "deterministic_trace_and_tool_evidence_audit_not_semantic_task_scoring",
        "experiment": args.experiment_id, "run_id": args.run_id, "source_trace_sha256": sha256(folder / "trace.json"),
        "checks": checks, "checks_passed": sum(c["passed"] for c in checks), "checks_total": len(checks),
        "all_passed": all(c["passed"] for c in checks),
        "model_responses": trace["model_responses"], "matlab_backend_calls": trace["matlab_backend_calls"],
        "usage": {key: sum(e["usage"][key] for e in model_events) for key in ("prompt_tokens", "completion_tokens", "total_tokens")},
        "tool_order": [e["tool"] for e in events], "semantic_review_required": True}
    output = base / "audits" / uuid.uuid4().hex
    output.mkdir(parents=True)
    (output / "audit.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("all_passed", "checks_passed", "checks_total", "model_responses", "matlab_backend_calls", "usage")}))
    print(str(output.relative_to(ROOT)))
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
