"""Adversarial offline checks, archived tools and scripted model fixtures only."""

from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "evaluation"), str(ROOT / "scripts")]
from bailian_client import load_config, read_json
from controlled_loop import run_loop
from report_contract import VERSION, check_report, render_report
from tool_executor import ToolExecutor
from verify_controlled_loop import ScriptedModel, model_message, unit_checks
from complete_checked_report import complete_report, prepare_source

EXP = "EXP-20261020-004"
SOURCE = ROOT / "results/EXP-20261020-003/runs/90e3ba1f9708494787c008d65b35bd28/trace.json"


def fixture():
    """Synthetic report from archived numeric evidence; never a model diagnosis."""
    trace = read_json(SOURCE)
    records = [e for e in trace["events"] if e["type"] == "tool_result"]
    by_tool = {e["tool"]: e["response"] for e in records}
    bundle = by_tool["compute_residual_bundle"]["result"]
    alarm = by_tool["locate_anomalies"]
    numbers = {c["quantity"]: c for c in bundle["channels"]}
    alarm_ids = {e["quantity"]: e["id"] for e in alarm["evidence"]}
    channels = []
    for a in alarm["result"]["channels"]:
        v = numbers[a["quantity"]]
        channels.append({**{k: a[k] for k in ("quantity", "status", "unit", "alarmed", "threshold", "valid_points")},
            "first_exceed_s": a["first_exceed_s"] or None, "first_alarm_s": a["first_alarm_s"] or None,
            "valid_max_abs": v["valid_max_abs"], "valid_rms": v["valid_rms"],
            "valid_motion_intervals_s": alarm["result"]["analysis_scope"]["valid_motion_intervals_s"],
            "applicability": "SCRIPTED APPLICABILITY FIXTURE, NOT A DIAGNOSIS",
            "residual_evidence_id": v["evidence_id"], "alarm_evidence_id": alarm_ids[a["quantity"]]})
    inspect_id = by_tool["inspect_case"]["evidence"]["id"]
    report = {"version": VERSION, "case_id": trace["case_id"], "bundle_id": bundle["bundle_id"],
        "evidence_refs": {"inspection_id": inspect_id,
            "context_ids": [e["id"] for e in by_tool["query_operating_context"]["evidence"]],
            "method_ids": [e["id"] for e in by_tool["lookup_method_conditions"]["evidence"]]},
        "finding": "SCRIPTED STRUCTURE FIXTURE; NO SEMANTIC DIAGNOSIS", "channels": channels,
        "candidate_assessment": "This fixture intentionally does not perform a semantic diagnosis.",
        "candidates": [{"hypothesis": "SCRIPTED CANDIDATE", "basis": "SCRIPTED BASIS", "caveat": "NOT VERIFIED",
                        "evidence_ids": [channels[0]["alarm_evidence_id"]]}],
        "load_assumption": bundle["load_assumption"], "assumptions": "SCRIPTED ASSUMPTION",
        "unknowns": [{"condition": p["name"], "state": "unknown", "impact": "SCRIPTED IMPACT", "evidence_id": inspect_id}
                     for p in by_tool["inspect_case"]["preconditions"] if p["state"] == "unknown"],
        "needed_information": ["SCRIPTED REQUEST FOR INDEPENDENT OBSERVATIONS"],
        "time_interpretation": {"kind": "detector_confirmation_not_true_onset", "explanation": "SCRIPTED TIME SCOPE"},
        "no_alarm_interpretation": "SCRIPTED NOT-A-HEALTH-PROOF SCOPE",
        "scope": {"threshold_version": alarm["result"]["threshold_version"], "ideal_simulation_only": True,
                  "noise_validated": False, "hardware_validated": False, "full_envelope_validated": False,
                  "explanation": "SCRIPTED IDEAL SCOPE"},
        "plot": {k: by_tool["plot_evidence"]["result"][k] for k in ("plot_id", "residual_evidence_id", "png_ref", "editable_fig_ref")}}
    return trace["case_id"], records, report


def main():
    folder = ROOT / "results" / EXP / "validation" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    case, records, report = fixture()
    checks = unit_checks(folder / "prior_control_fixtures")

    def check(name, passed):
        checks.append({"name": name, "passed": bool(passed)})

    check("synthetic_structural_fixture_passes_not_semantic_proof", check_report(json.dumps(report), records, case)["passed"])
    mutations = [
        ("missing_plot", lambda r: r.pop("plot")),
        ("wrong_maximum_order", lambda r: r["channels"][0].update(valid_max_abs=0.02)),
        ("wrong_threshold", lambda r: r["channels"][0].update(threshold=1)),
        ("wrong_unit", lambda r: r["channels"][0].update(unit="mm")),
        ("wrong_alarm_state", lambda r: r["channels"][0].update(alarmed=False)),
        ("boolean_as_alarm_number", lambda r: r["channels"][0].update(threshold=True)),
        ("false_alarm_time_for_clear_channel", lambda r: r["channels"][1].update(first_alarm_s=0)),
        ("wrong_onset_time", lambda r: r["channels"][0].update(first_alarm_s=0.030)),
        ("wrong_scope", lambda r: r["channels"][0].update(valid_motion_intervals_s=[[0, 0.8]])),
        ("wrong_point_count", lambda r: r["channels"][0].update(valid_points=410)),
        ("wrong_channel_evidence", lambda r: r["channels"][0].update(alarm_evidence_id=r["channels"][1]["alarm_evidence_id"])),
        ("malformed_id_array", lambda r: r["channels"][0].update(alarm_evidence_id=[])),
        ("missing_unknown", lambda r: r.update(unknowns=[])),
        ("unknown_changed_to_known", lambda r: r["unknowns"][0].update(state="satisfied")),
        ("wrong_evidence_category", lambda r: r["evidence_refs"].update(method_ids=[r["evidence_refs"]["inspection_id"]])),
        ("missing_candidate_for_alarm", lambda r: r.update(candidates=[])),
        ("candidate_without_basis", lambda r: r["candidates"][0].pop("basis")),
        ("wrong_plot_parent", lambda r: r["plot"].update(residual_evidence_id="BUNDLE-" + "f" * 64)),
        ("wrong_png_uri", lambda r: r["plot"].update(png_ref="figure://wrong/overview.png")),
        ("hardware_claim", lambda r: r["scope"].update(hardware_validated=True)),
        ("wrong_time_meaning", lambda r: r["time_interpretation"].update(kind="true_injection_onset")),
        ("unobtained_citation_in_text", lambda r: r.update(finding="EV-" + "f" * 64)),
        ("other_case_in_text", lambda r: r.update(finding="CASE-" + "f" * 32)),
        ("wrong_compensation", lambda r: r.update(load_assumption="none")),
        ("duplicate_channel", lambda r: r["channels"].append(deepcopy(r["channels"][0]))),
        ("malformed_channel", lambda r: r["channels"].append([])),
        ("malformed_unknown", lambda r: r["unknowns"].append("unknown")),
        ("no_alarm_used_as_exclusion", lambda r: r["candidates"][0].update(basis="相电流正常排除了部分共同源干扰")),
    ]
    for name, mutate in mutations:
        changed = deepcopy(report)
        mutate(changed)
        check(name + "_rejected", not check_report(json.dumps(changed), records, case)["passed"])
    bounded_claim = deepcopy(report)
    bounded_claim["candidates"][0]["basis"] = "未报警不能排除共同源干扰"
    check("negative_exclusion_warning_is_allowed", check_report(json.dumps(bounded_claim), records, case)["passed"])
    partial_records, partial_report = deepcopy(records), deepcopy(report)
    for r in partial_records:
        if r["tool"] == "compute_residual_bundle" and r["response"]["result"]["bundle_id"] == report["bundle_id"]:
            c = next(c for c in r["response"]["result"]["channels"] if c["quantity"] == "torque_known_load_Nm")
            c.update(status="insufficient_data", valid_max_abs=None, valid_rms=None)
        if r["tool"] == "locate_anomalies" and r["response"]["result"]["residual_evidence_id"] == report["bundle_id"]:
            c = next(c for c in r["response"]["result"]["channels"] if c["quantity"] == "torque_known_load_Nm")
            c.update(status="insufficient_data", alarmed=[], first_alarm_s=[], first_exceed_s=[], valid_points=0)
    c = partial_report["channels"][-1]
    c.update(status="insufficient_data", alarmed=None, first_alarm_s=None, first_exceed_s=None,
             valid_max_abs=None, valid_rms=None, valid_points=0)
    check("synthetic_insufficient_data_preserved_as_unknown", check_report(json.dumps(partial_report), partial_records, case)["passed"])
    c["alarmed"] = False
    check("synthetic_insufficient_data_not_healthy", not check_report(json.dumps(partial_report), partial_records, case)["passed"])
    clipped_records = deepcopy(records)
    clipped_records[-2]["response"]["result"]["analysis_scope"]["effective_interval_s"] = [0.02, 0.7]
    check("clipped_alarm_and_full_statistics_not_mixed", not check_report(json.dumps(report), clipped_records, case)["passed"])
    for text in ['{"version":"a","version":"b"}', '{"x":NaN}', '{"x":1e999}', '[1]', 'preparing final report']:
        check("non_report_or_invalid_json_rejected_" + str(len(checks)), not check_report(text, records, case)["passed"])
    old_reports = []
    for rid in ("b0cea6f535cb454a818f838f572cb57e", "90e3ba1f9708494787c008d65b35bd28"):
        text = (SOURCE.parents[1] / rid / "final_response.md").read_text(encoding="utf-8")
        checked = check_report(text, records, case)
        old_reports.append({"run_id": rid, "check": checked,
                            "scope": "retrospective_new_structure_check_not_regrading_old_task"})
        check("prior_prose_not_silently_accepted_" + rid[:6], not checked["passed"])
    check("render_preserves_all_critical_fields", all(str(c["first_alarm_s"]) in render_report(report) for c in report["channels"])
          and report["plot"]["png_ref"] in render_report(report) and report["candidate_assessment"] in render_report(report))

    class ArchivedBackend:
        def __init__(self):
            self.index = 0

        def call(self, name, arguments, timeout_s=45):
            r = records[self.index]
            assert r["tool"] == name and r["arguments"] == arguments
            self.index += 1
            return deepcopy(r["response"])

    config = load_config()
    config["call_budget"]["report_repair_limit"] = 1
    calls = [("replay" + str(i), r["tool"], json.dumps(r["arguments"])) for i, r in enumerate(records)]
    for label, outputs, max_calls, expected in [
        ("one_report_repair", ["unfinished prose", json.dumps(report)], 3, "report_evidence_checked"),
        ("repair_remains_bad", ["unfinished prose", "still unfinished"], 3, "report_validation_failed"),
        ("model_budget_blocks_repair", ["unfinished prose"], 2, "report_validation_failed"),
    ]:
        model = ScriptedModel([model_message(calls)] + [model_message(content=o) for o in outputs])
        executor = ToolExecutor(case, ArchivedBackend())
        trace = run_loop("SCRIPTED OFFLINE ARCHIVED TOOL REPLAY; NOT LIVE DIAGNOSIS", executor, config, folder / label,
            budget={"model_calls": max_calls, "tool_calls": 20, "wall_time_s": 10, "max_tokens": 4096, "max_rejected_calls": 2},
            model_call=model, checked_report=True, purpose="scripted_control_test_only", response_source="archived_tools_scripted_model_fixture")
        check(label, trace["termination_reason"] == expected and trace["report_repairs"] <= 1
              and trace["model_http_attempts"] <= max_calls and trace["diagnostic_task_scored"] is False)
        check(label + "_raw_attempts_preserved", (folder / label / "report_attempt_01.txt").read_text(encoding="utf-8") == outputs[0])
    task, messages, source_records = prepare_source(SOURCE.parent)
    check("continuation_source_rebuilt_from_archived_matlab_records", task["case_id"] == case and len(source_records) == 9)
    continuation = complete_report(messages, records, case, config, folder / "continuation_repair",
        model_call=ScriptedModel([model_message(content="incomplete"), model_message(content=json.dumps(report))]),
        response_source="scripted_fixture_no_live_calls")
    check("report_only_continuation_one_repair_and_no_new_tools", continuation["status"] == "report_evidence_checked"
          and continuation["model_http_attempts"] == 2 and continuation["report_repairs"] == 1
          and continuation["new_matlab_tool_calls"] == 0)
    class TimeoutRecordingModel(ScriptedModel):
        def __call__(self, config, messages, **kwargs):
            check("continuation_passes_explicit_120s_request_timeout", kwargs["timeout_s"] == 120)
            return super().__call__(config, messages, **kwargs)
    complete_report(messages, records, case, config, folder / "continuation_timeout_option",
        model_call=TimeoutRecordingModel([model_message(content=json.dumps(report))]), response_source="scripted_fixture_no_live_calls")
    from bailian_client import ClientError
    failed = complete_report(messages, records, case, config, folder / "continuation_network_failure",
        model_call=ScriptedModel([ClientError("NETWORK_OR_TIMEOUT")]), response_source="scripted_fixture_no_live_calls")
    check("continuation_network_failure_not_automatically_retried", failed["status"] == "model_request_failed"
          and failed["model_http_attempts"] == 1)
    bounded = complete_report(messages, records, case, config, folder / "one_review_request_only",
        model_call=ScriptedModel([model_message(content="incomplete")]), response_source="scripted_fixture_no_live_calls",
        max_requests=1, wall_limit_s=120)
    check("review_episode_does_not_add_another_automatic_repair", bounded["model_http_attempts"] == 1
          and bounded["report_repairs"] == 0 and bounded["status"] == "report_validation_failed")
    result = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "scope": "offline_adversarial_controls_not_LLM_or_new_MATLAB_execution",
        "checks": checks, "checks_passed": sum(c["passed"] for c in checks), "checks_total": len(checks),
        "all_passed": all(c["passed"] for c in checks), "prior_report_demonstrations": old_reports,
        "live_llm_calls": 0, "new_matlab_calls": 0, "new_simulations": 0}
    (folder / "acceptance.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("all_passed", "checks_passed", "checks_total")}))
    print(str(folder.relative_to(ROOT)))
    return 0 if result["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
