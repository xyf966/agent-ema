"""Unit/control and real MATLAB checks. Fixtures are never live LLM results."""

from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "scripts")]
from bailian_client import ClientError, load_config, read_json
from controlled_loop import parse_final_object, run_loop
from matlab_bridge import MatlabBridge
from run_controlled_agent import public_tasks
from tool_executor import GuardError, ToolExecutor, strict_json, validate_response

EXP = "EXP-20261020-002"
CASE = public_tasks()[0]["case_id"]
OTHER = public_tasks()[1]["case_id"]
BUNDLE = "BUNDLE-" + "a" * 64


def fake_response(tool="inspect_case", status="ok", case_id=CASE):
    versions = {t["name"]: t["version"] for t in read_json(ROOT / "tools/registry/tool_registry_v1.json")["tools"]}
    return {"tool": tool, "tool_version": versions[tool], "case_id": case_id,
        "status": status, "error_code": "", "input_hash": "unit_fixture", "preconditions": [],
        "result": {"bundle_id": BUNDLE} if tool == "compute_residual_bundle" else {},
        "evidence": [], "warnings": [], "duration_ms": 0}


class FakeBackend:
    def __init__(self, status="ok", fail=False):
        self.calls = []
        self.status, self.fail = status, fail

    def call(self, tool, args, timeout_s=45):
        self.calls.append((tool, args))
        if self.fail:
            raise RuntimeError("UNIT_ONLY_PRIVATE_PATH_CANNOT_ESCAPE")
        result = fake_response(tool, self.status)
        if tool in {"locate_anomalies", "plot_evidence"}:
            result["result"]["residual_evidence_id"] = args["residual_evidence_id"]
        return result


def model_message(calls=None, content="", finish="stop"):
    message = {"role": "assistant", "content": content}
    if calls:
        message["tool_calls"] = [{"id": identifier, "type": "function", "function": {"name": name, "arguments": arguments}}
                                 for identifier, name, arguments in calls]
    return {"id": "UNIT_FIXTURE_ONLY", "model": "SCRIPTED_UNIT_FIXTURE_NOT_LLM",
        "usage": None, "choices": [{"message": message, "finish_reason": finish}]}


class ScriptedModel:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.messages = []

    def __call__(self, config, messages, **kwargs):
        self.messages.append(deepcopy(messages))
        response = next(self.responses)
        if isinstance(response, Exception):
            raise response
        return {"model": "SCRIPTED_UNIT_FIXTURE_NOT_LLM", "messages": messages}, response


def unit_checks(folder):
    checks = []

    def check(name, value):
        checks.append({"name": name, "passed": bool(value)})

    rejects = [
        ("unknown_tool", "eval_matlab", {}, "UNREGISTERED_TOOL"),
        ("path_argument", "inspect_case", {"case_id": CASE, "path": "private"}, "EXTRA_ARGUMENT"),
        ("cross_case", "inspect_case", {"case_id": OTHER}, "CROSS_CASE_ACCESS"),
        ("bad_case_syntax", "inspect_case", {"case_id": "../private"}, "ARGUMENT_SCHEMA_MISMATCH"),
        ("missing_case", "inspect_case", {}, "MISSING_REQUIRED_ARGUMENT"),
        ("wrong_case_type", "inspect_case", {"case_id": 123}, "ARGUMENT_SCHEMA_MISMATCH"),
        ("unknown_context_field", "query_operating_context", {"case_id": CASE, "fields": ["ground_truth"]}, "ARGUMENT_ENUM_MISMATCH"),
        ("repeated_context_field", "query_operating_context", {"case_id": CASE, "fields": ["independent_load"] * 2}, "DUPLICATE_ARRAY_ITEM"),
        ("reversed_interval", "query_operating_context", {"case_id": CASE, "time_range_s": [0.5, 0.1]}, "REVERSED_TIME_INTERVAL"),
        ("boolean_time", "query_operating_context", {"case_id": CASE, "time_range_s": [False, 0.5]}, "ARGUMENT_SCHEMA_MISMATCH"),
        ("compute_before_inspect", "compute_residual_bundle", {"case_id": CASE}, "INSPECTION_REQUIRED"),
        ("unowned_bundle", "locate_anomalies", {"residual_evidence_id": BUNDLE}, "BUNDLE_NOT_OBTAINED_IN_THIS_RUN"),
        ("unsupported_threshold", "locate_anomalies", {"residual_evidence_id": BUNDLE, "threshold_version": "new"}, "ARGUMENT_ENUM_MISMATCH"),
    ]
    for label, tool, args, expected in rejects:
        backend = FakeBackend()
        result = ToolExecutor(CASE, backend).execute(tool, json.dumps(args))
        check(label + "_rejected_without_backend", result["error_code"] == expected and not backend.calls)
    for label, raw, expected in [("duplicate_json", '{"case_id":"x","case_id":"y"}', "DUPLICATE_JSON_KEY"),
                                  ("nan_json", '{"case_id":NaN}', "NONFINITE_JSON_NUMBER"),
                                  ("broken_json", '{', "INVALID_ARGUMENT_JSON")]:
        backend = FakeBackend()
        result = ToolExecutor(CASE, backend).execute("inspect_case", raw)
        check(label, result["error_code"] == expected and not backend.calls)
    executor = ToolExecutor(CASE, FakeBackend())
    check("inspect_then_compute_then_locate", executor.execute("inspect_case", json.dumps({"case_id": CASE}))["status"] == "ok"
          and executor.execute("compute_residual_bundle", json.dumps({"case_id": CASE}))["status"] == "ok"
          and executor.execute("locate_anomalies", json.dumps({"residual_evidence_id": BUNDLE}))["status"] == "ok")
    check("duplicate_execution_prevented", executor.execute("inspect_case", json.dumps({"case_id": CASE}))["error_code"] == "DUPLICATE_TOOL_CALL"
          and executor.backend_calls == 3)
    for status in ["insufficient_data", "not_applicable", "execution_error"]:
        result = ToolExecutor(CASE, FakeBackend(status)).execute("inspect_case", json.dumps({"case_id": CASE}))
        check(status + "_preserved", result["status"] == status and not result["result"])
    for label, mutate, code in [
        ("private_key", lambda r: r["result"].update({"config": {}}), "PRIVATE_FIELD_IN_TOOL_RESPONSE"),
        ("private_path", lambda r: r["result"].update({"path": "C:/private/source"}), "PRIVATE_PATH_IN_TOOL_RESPONSE"),
        ("wrong_response_case", lambda r: r.update({"case_id": OTHER}), "TOOL_RESPONSE_CASE_MISMATCH"),
        ("wrong_response_version", lambda r: r.update({"tool_version": "wrong"}), "TOOL_RESPONSE_VERSION_MISMATCH"),
    ]:
        response = fake_response()
        mutate(response)
        try:
            validate_response(response, "inspect_case", CASE, "EMA-INSPECT-1.0")
            check(label, False)
        except GuardError as error:
            check(label, str(error) == code)
    response = fake_response()
    response["result"] = {"value_ref": "evidence://" + BUNDLE, "png_ref": "figure://PLOT-abc/overview.png"}
    try:
        validate_response(response, "inspect_case", CASE, "EMA-INSPECT-1.0")
        check("evidence_and_figure_uris_are_not_local_paths", True)
    except GuardError:
        check("evidence_and_figure_uris_are_not_local_paths", False)
    config = load_config()
    limits = {"model_calls": 4, "tool_calls": 3, "wall_time_s": 5, "max_tokens": 128, "max_rejected_calls": 2}

    def loop(label, responses, backend=None, override=None):
        model = ScriptedModel(responses)
        execution = ToolExecutor(CASE, backend or FakeBackend())
        trace = run_loop("UNIT FIXTURE; NOT A DIAGNOSTIC TASK", execution, config, folder / label,
            budget=override or limits, model_call=model,
            purpose="scripted_unit_test_not_live", response_source="scripted_unit_fixture")
        return trace, execution, model

    args = json.dumps({"case_id": CASE})
    trace, execution, model = loop("feedback", [model_message([("c1", "inspect_case", args)]), model_message(content="unit final")])
    check("tool_output_returned_with_matching_call_id", trace["termination_reason"] == "model_finished"
          and model.messages[1][-1]["role"] == "tool" and model.messages[1][-1]["tool_call_id"] == "c1"
          and json.loads(model.messages[1][-1]["content"])["input_hash"] == "unit_fixture")
    trace, _, model = loop("repair", [model_message([("c1", "inspect_case", '{}')]),
        model_message([("c2", "inspect_case", args)]), model_message(content="unit final")])
    check("one_bad_call_can_be_corrected", trace["termination_reason"] == "model_finished" and trace["rejected_calls"] == 1
          and trace["matlab_backend_calls"] == 1 and len(model.messages) == 3)
    trace, _, _ = loop("inapplicable", [model_message([("c1", "inspect_case", args)]), model_message(content="unit unavailable")], FakeBackend("not_applicable"))
    check("inapplicable_is_feedback_not_healthy", trace["messages"][-2]["role"] == "tool"
          and json.loads(trace["messages"][-2]["content"])["status"] == "not_applicable")
    trace, _, _ = loop("rejection_limit", [model_message([("c1", "inspect_case", '{}')]), model_message([("c2", "inspect_case", '{}')])])
    check("invalid_calls_are_bounded", trace["termination_reason"] == "rejected_call_limit" and trace["matlab_backend_calls"] == 0)
    trace, _, _ = loop("model_budget", [model_message([("c1", "inspect_case", args)])], override={**limits, "model_calls": 1})
    check("model_budget_stops_next_request", trace["termination_reason"] == "model_call_budget_exhausted" and trace["model_http_attempts"] == 1)
    trace, _, _ = loop("batch_budget", [model_message([("c1", "inspect_case", args), ("c2", "query_operating_context", args)])], override={**limits, "tool_calls": 1})
    check("oversized_batch_executes_nothing", trace["termination_reason"] == "tool_call_budget_exhausted" and trace["matlab_backend_calls"] == 0)
    trace, _, _ = loop("duplicate_call_id", [model_message([("c1", "inspect_case", args), ("c1", "query_operating_context", args)])])
    check("duplicate_ids_execute_nothing", trace["termination_reason"] == "malformed_model_response" and trace["matlab_backend_calls"] == 0)
    trace, _, _ = loop("truncated", [model_message([("c1", "inspect_case", args)], finish="length")])
    check("truncated_model_output_not_executed", trace["termination_reason"] == "model_output_truncated" and trace["matlab_backend_calls"] == 0)
    trace, _, _ = loop("backend_failure", [model_message([("c1", "inspect_case", args)])], FakeBackend(fail=True))
    check("backend_failure_stops_and_hides_exception", trace["termination_reason"] == "backend_unavailable"
          and "UNIT_ONLY_PRIVATE_PATH" not in json.dumps(trace))
    trace, _, _ = loop("model_failure", [ClientError("HTTP_403", {"http_status": 403})])
    check("model_failure_not_retried", trace["termination_reason"] == "model_request_failed" and trace["model_http_attempts"] == 1)
    slow_model = ScriptedModel([model_message([("c1", "inspect_case", args)])])
    def slow_call(*args, **kwargs):
        result = slow_model(*args, **kwargs)
        time.sleep(0.02)
        return result
    execution = ToolExecutor(CASE, FakeBackend())
    trace = run_loop("UNIT WALL TIME FIXTURE", execution, config, folder / "wall_budget",
        budget={**limits, "wall_time_s": 0.01}, model_call=slow_call,
        purpose="scripted_unit_test_not_live", response_source="scripted_unit_fixture")
    check("expired_wall_budget_prevents_tool_execution", trace["termination_reason"] == "wall_time_budget_exhausted"
          and trace["matlab_backend_calls"] == 0)
    late_final = ScriptedModel([model_message(content="UNIT LATE FINAL")])
    def late_final_call(*args, **kwargs):
        result = late_final(*args, **kwargs)
        time.sleep(0.02)
        return result
    trace = run_loop("UNIT LATE FINAL FIXTURE", ToolExecutor(CASE, FakeBackend()), config, folder / "late_final",
        budget={**limits, "wall_time_s": 0.01}, model_call=late_final_call,
        purpose="scripted_unit_test_not_live", response_source="scripted_unit_fixture")
    check("late_final_does_not_bypass_wall_budget", trace["termination_reason"] == "wall_time_budget_exhausted" and not trace["final_text"])
    for label, text, allowed in [
        ("bare_final_json", '{"x":1}', True),
        ("single_json_fence", '```json\n{"x":1}\n```', True),
        ("final_prose_rejected", 'answer: {"x":1}', False),
        ("multiple_final_fences_rejected", '```json\n{}\n```\n```json\n{}\n```', False),
        ("final_array_rejected", '[1]', False),
        ("final_duplicate_key_rejected", '{"x":1,"x":2}', False),
        ("final_nan_rejected", '{"x":NaN}', False),
    ]:
        try:
            parse_final_object(text)
            check(label, allowed)
        except GuardError:
            check(label, not allowed)
    return checks


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matlab", action="store_true", help="Also execute eight real MATLAB calls, no model or LLM requests")
    args = parser.parse_args()
    folder = ROOT / "results" / EXP / "validation" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    # Capture all existing data/tools/models/snapshots; outputs are in a separate tree.
    protected = {}
    for name in ["data", "tools", "matlab", "archive/source_snapshot"]:
        for path in (ROOT / name).rglob("*"):
            if path.is_file():
                protected[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    (folder / "protected_before.json").write_text(json.dumps(protected, indent=2), encoding="utf-8")
    checks = unit_checks(folder / "scripted_unit_fixtures")
    runtime = None
    real_records = []
    if args.matlab:
        bridge = MatlabBridge(folder / "matlab")
        execution = None
        try:
            runtime = bridge.start()
            execution = ToolExecutor(CASE, bridge)
            for name, arguments in [
                ("inspect_case", {"case_id": CASE}),
                ("query_operating_context", {"case_id": CASE}),
                ("lookup_method_conditions", {"method_id": "all", "case_id": CASE}),
                ("compute_residual_bundle", {"case_id": CASE}),
            ]:
                execution.execute(name, json.dumps(arguments))
            default = execution.records[-1]["response"]
            execution.execute("locate_anomalies", json.dumps({"residual_evidence_id": default["result"]["bundle_id"]}))
            uncompen = execution.records[-1]["response"]
            execution.execute("compute_residual_bundle", json.dumps({"case_id": CASE, "load_assumption": "prescribed_command"}))
            compen = execution.records[-1]["response"]
            execution.execute("locate_anomalies", json.dumps({"residual_evidence_id": compen["result"]["bundle_id"]}))
            alarms = execution.records[-1]["response"]
            execution.execute("plot_evidence", json.dumps({"residual_evidence_id": compen["result"]["bundle_id"]}))
            real_records = execution.records
            checks.append({"name": "eight_real_calls_six_tools", "passed": execution.backend_calls == 8
                and len({r["tool"] for r in real_records}) == 6 and all(r["response"]["status"] in {"ok", "insufficient_data"} for r in real_records)})
            checks.append({"name": "missing_compensation_not_no_alarm", "passed": any(c["status"] == "insufficient_data" for c in uncompen["result"]["channels"])})
            reference_chains = read_json(ROOT / "results/EXP-20261019-010/final/tool_call_traces.json")
            reference = next(c for c in reference_chains if c[0]["arguments"]["case_id"] == CASE)
            checks.append({"name": "real_residuals_equal_stage2", "passed": compen["result"]["channels"] == reference[5]["response"]["result"]["channels"]})
            checks.append({"name": "real_alarms_equal_stage2", "passed": alarms["result"] == reference[6]["response"]["result"]})
            conditions = {p["name"]: p["state"] for p in real_records[1]["response"]["preconditions"]}
            checks.append({"name": "unknown_independent_conditions_preserved", "passed": conditions["independent_normal_load"] == "unknown" and conditions["independent_initial_reference"] == "unknown"})
        except Exception as error:
            checks.append({"name": "matlab_runtime_validation", "passed": False, "error_type": type(error).__name__})
        finally:
            if execution is not None:
                real_records = execution.records
            bridge.close()
            checks.append({"name": "matlab_worker_stopped", "passed": (bridge.folder / "stopped.json").is_file()})
    unchanged = all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == value for name, value in protected.items())
    checks.append({"name": "all_existing_protected_files_unchanged", "passed": unchanged})
    report = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "scope": "step_2_control_and_matlab_executor_validation_not_diagnostic_performance",
        "checks": checks, "checks_passed": sum(c["passed"] for c in checks), "checks_total": len(checks),
        "all_passed": all(c["passed"] for c in checks), "protected_file_count": len(protected),
        "protected_files_unchanged": unchanged, "real_matlab_calls": len(real_records), "matlab_runtime": runtime,
        "llm_http_requests": 0, "new_physical_simulations": 0,
        "scripted_fixture_scope": "unit_control_tests_only_never_count_as_LLM_responses"}
    (folder / "acceptance.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    (folder / "real_matlab_calls.json").write_text(json.dumps(real_records, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ["all_passed", "checks_passed", "checks_total", "real_matlab_calls"]}))
    print(str(folder.relative_to(ROOT)))
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
