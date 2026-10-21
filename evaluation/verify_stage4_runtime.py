"""Validate stage4 schema/guard/gate/worker integration. No LLM or sim calls."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import load_tools, read_json
from matlab_bridge import MatlabBridge
from stage4_case_rules import evidence_ready_stage4, public_compensation_requirement
from tool_executor import ToolExecutor, validate_response, GuardError

REGISTRY = ROOT / "tools/registry_stage4"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matlab", action="store_true")
    args = parser.parse_args()
    folder = ROOT / "results/EXP-20261020-019/runtime_checks" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    checks, all_records = [], []

    def check(name, condition):
        checks.append({"name": name, "passed": bool(condition)})

    tools = load_tools(REGISTRY)
    check("six_stage4_schemas_load_with_matching_identities", len(tools) == 6)
    compute_schema = next(t["function"]["parameters"] for t in tools if t["function"]["name"] == "compute_residual_bundle")
    check("recorded_assumption_in_advertised_enum", "recorded_assumption" in compute_schema["properties"]["load_assumption"]["enum"])
    boundary_calls = read_json(ROOT / "results/EXP-20261020-018/tool_call_traces.json")
    boundary_id = next(r["arguments"]["case_id"] for r in boundary_calls if r["tool"] == "inspect_case")

    class RejectBackend:
        def call(self, *unused, **kwargs):
            raise AssertionError("SHOULD_NOT_REACH_BACKEND")

    executor = ToolExecutor(boundary_id, RejectBackend(), registry_dir=REGISTRY)
    check("boundary_residual_exact_expected_version", executor.versions["compute_residual_bundle"] == "EMA-BOUNDARY-RESIDUAL-1.0")
    actual = next(r["response"] for r in boundary_calls if r["tool"] == "compute_residual_bundle")
    bad = deepcopy(actual); bad["tool_version"] = "EMA-RESIDUAL-1.0"
    rejected = False
    try:
        validate_response(bad, "compute_residual_bundle", boundary_id, executor.versions["compute_residual_bundle"])
    except GuardError as error:
        rejected = str(error) == "TOOL_RESPONSE_VERSION_MISMATCH"
    check("wrong_release_response_version_rejected", rejected)
    check("cross_case_request_rejected_before_backend", executor.execute("inspect_case", json.dumps({"case_id": "CASE-" + "0"*32}))["error_code"] == "CROSS_CASE_ACCESS")
    check("new_enum_does_not_bypass_inspection", executor.execute("compute_residual_bundle", json.dumps({"case_id": boundary_id, "load_assumption": "recorded_assumption"}))["error_code"] == "INSPECTION_REQUIRED")
    check("extra_path_rejected_before_backend", executor.execute("inspect_case", json.dumps({"case_id": boundary_id, "path": "C:/unapproved.mat"}))["error_code"] == "EXTRA_ARGUMENT")
    check("unowned_boundary_bundle_rejected", executor.execute("plot_evidence", json.dumps({"residual_evidence_id": actual["result"]["bundle_id"]}))["error_code"] == "BUNDLE_NOT_OBTAINED_IN_THIS_RUN")
    try:
        MatlabBridge(folder / "invalid_profile", profile="arbitrary_code")
        invalid_profile = False
    except Exception:
        invalid_profile = True
    check("unknown_worker_profile_rejected", invalid_profile)
    mapping = read_json(ROOT / "data/evaluation_private/EXP-20261019-004/case_mapping.json")
    gradual = [x for x in mapping if x["profile"] == "linear_ramp"]
    new = read_json(ROOT / "data/evaluation_private/EXP-20261020-018/case_mapping.json")
    selected = sorted(gradual + new, key=lambda x: x["case_id"])
    runtime = None
    bridge = None
    try:
        if args.matlab:
            bridge = MatlabBridge(folder / "matlab", profile="stage4")
            runtime = bridge.start()
            check("real_worker_stage4_entrypoint", runtime["dispatcher"] == "ema_tool_stage4" and runtime["tool_profile"] == "stage4")
            check("worker_does_not_simulate_or_load_model", runtime["simulation_executed"] is False and runtime["model_loaded"] is False)
            for item in selected:
                case_id = item["case_id"]
                execution = ToolExecutor(case_id, bridge, registry_dir=REGISTRY)

                def call(tool, arguments):
                    response = execution.execute(tool, json.dumps(arguments))
                    if response["status"] != "ok":
                        raise RuntimeError("STAGE4_REAL_CALL_FAILED:" + tool + ":" + response["error_code"])
                    return response

                call("inspect_case", {"case_id": case_id})
                call("query_operating_context", {"case_id": case_id})
                call("lookup_method_conditions", {"case_id": case_id, "method_id": "all"})
                mode, mismatch = public_compensation_requirement(execution.records)
                r = call("compute_residual_bundle", {"case_id": case_id, "load_assumption": mode})
                call("locate_anomalies", {"residual_evidence_id": r["result"]["bundle_id"]})
                call("plot_evidence", {"residual_evidence_id": r["result"]["bundle_id"]})
                check(case_id + "_gate_before_comparison", evidence_ready_stage4(execution.records) is (not mismatch))
                if mismatch:
                    correct = call("compute_residual_bundle", {"case_id": case_id, "load_assumption": "prescribed_command"})
                    check(case_id + "_comparison_calculation_alone_not_enough", not evidence_ready_stage4(execution.records))
                    call("locate_anomalies", {"residual_evidence_id": correct["result"]["bundle_id"]})
                check(case_id + "_ready_after_required_real_evidence", evidence_ready_stage4(execution.records))
                check(case_id + "_six_tools_pass_python_guard", len({r["tool"] for r in execution.records}) == 6
                      and all("EXECUTOR_REJECTED_CALL" not in r["response"]["warnings"] for r in execution.records))
                check(case_id + "_all_responses_same_case", all(r["response"]["case_id"] == case_id for r in execution.records))
                all_records.append({"case_id": case_id, "group_id": item["group_id"], "baseline_mode": mode,
                                    "comparison_required": mismatch, "records": execution.records})
            check("five_cases_32_real_guarded_calls", len(all_records) == 5 and sum(len(c["records"]) for c in all_records) == 32)
    except Exception as error:
        checks.append({"name": "real_worker_integration", "passed": False, "error": str(error)[:200]})
    finally:
        if bridge is not None:
            bridge.close()
            check("real_worker_stopped_cleanly", (bridge.folder / "stopped.json").is_file())
    result = {"passed": all(c["passed"] for c in checks), "checks": checks,
              "check_count": len(checks), "checks_passed": sum(c["passed"] for c in checks),
              "real_guarded_matlab_calls": sum(len(c["records"]) for c in all_records),
              "llm_calls": 0, "new_simulations": 0, "runtime": runtime,
              "scope": "research_protocol_and_control_checks_not_Agent_diagnosis"}
    (folder / "tool_records.json").write_text(json.dumps(all_records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (folder / "acceptance.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ["passed", "checks_passed", "check_count", "real_guarded_matlab_calls"]}))
    print(folder.relative_to(ROOT).as_posix())
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
