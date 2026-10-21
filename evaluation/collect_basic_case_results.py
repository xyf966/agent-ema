"""Post-run research checks for four frozen development tasks; no LLM access.

Numbers, provenance and completeness are automatic. Physical explanations are
reviewed separately; this program never marks semantic diagnosis accepted.
"""

from datetime import datetime, timezone
import argparse
import json
import math
import re
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import read_json, sha256


def numeric_equal(actual, expected, relative, absolute):
    return (type(actual) in (int, float) and math.isfinite(actual)
            and math.isclose(actual, expected, rel_tol=relative, abs_tol=absolute))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-id", default="EXP-20261020-005")
    args = parser.parse_args()
    if not re.fullmatch(r"EXP-[0-9]{8}-[0-9]{3}", args.experiment_id):
        raise SystemExit("INVALID_EXPERIMENT_ID")
    base = ROOT / "results" / args.experiment_id
    plan = read_json(base / "preregistration.json")
    private = ROOT / "data/evaluation_private" / args.experiment_id / "pre_registered_rubric.json"
    if sha256(private) != plan["private_rubric_sha256"]:
        raise ValueError("PRIVATE_RUBRIC_DRIFT")
    if any(sha256(ROOT / name) != value for name, value in plan["implementation_sha256"].items()):
        raise ValueError("FROZEN_IMPLEMENTATION_DRIFT")
    rubrics = {t["task_id"]: t for t in read_json(private)["tasks"]}
    rows = []
    for task in plan["tasks"]:
        matches = [(p, read_json(p)) for p in (base / "runs").glob("*/summary.json")
                   if read_json(p)["task_id"] == task["task_id"]]
        if len(matches) != 1:
            raise ValueError("ONE_FINISHED_ATTEMPT_PER_TASK_REQUIRED")
        path, summary = matches[0]
        folder = path.parent
        trace = read_json(folder / "trace.json")
        rubric = rubrics[task["task_id"]]
        audit = subprocess.run([sys.executable, "evaluation/audit_diagnostic_trace.py", "--experiment-id", args.experiment_id,
            "--run-id", folder.name], cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
        lines = audit.stdout.strip().splitlines()
        if not lines:
            raise ValueError("AUDIT_DID_NOT_RETURN_REPORT")
        audit_path = ROOT / lines[-1] / "audit.json"
        checked = read_json(audit_path)
        report = read_json(folder / "report.json") if (folder / "report.json").is_file() else {}
        values = {c["quantity"]: c for c in report.get("channels", []) if isinstance(c, dict) and isinstance(c.get("quantity"), str)}
        tolerance = rubric["numeric_tolerances"]
        number_checks = []

        def check(quantity, field, passed):
            number_checks.append({"quantity": quantity, "field": field, "passed": bool(passed)})

        for quantity, expected in rubric["expected_channels"].items():
            actual = values.get(quantity, {})
            for field in ("threshold", "valid_max_abs", "valid_rms"):
                check(quantity, field, numeric_equal(actual.get(field), expected[field], tolerance["reported_scalar_relative"],
                                                     tolerance["reported_scalar_absolute_floor"]))
            for field in ("unit", "status", "valid_points"):
                check(quantity, field, actual.get(field) == expected[field])
            check(quantity, "alarmed", actual.get("alarmed") is expected["alarmed"])
            for field in ("first_exceed_s", "first_alarm_s"):
                wanted = expected[field]
                check(quantity, field, field in actual and (actual[field] is None if wanted == [] else
                    numeric_equal(actual[field], wanted, 0, tolerance["report_rounded_time_abs_s"])))
            intervals = actual.get("valid_motion_intervals_s", [])
            target = rubric["valid_motion_intervals_s"]
            check(quantity, "valid_motion_intervals_s", isinstance(intervals, list) and len(intervals) == len(target)
                  and all(isinstance(x, list) and len(x) == 2 and all(numeric_equal(a, z, 0, tolerance["report_rounded_time_abs_s"])
                      for a, z in zip(x, y)) for x, y in zip(intervals, target)))
        runtime = read_json(folder / "runtime_manifest.json")
        frozen = (runtime["system_message"] == plan["system_message"]
                  and all(plan["implementation_sha256"].get(n) == h for n, h in runtime["implementation_sha256"].items())
                  and trace["provider_config_sha256"] == plan["implementation_sha256"]["configs/llm_provider.json"]
                  and trace["messages"][:2] == [{"role": "system", "content": plan["system_message"]},
                                               {"role": "user", "content": task["question"]}])
        model_events = [e for e in trace["events"] if e["type"] == "model_response"]
        usage = {k: sum((e.get("usage") or {}).get(k, 0) for e in model_events)
                 for k in ("prompt_tokens", "completion_tokens", "total_tokens")}
        rows.append({"task_id": task["task_id"], "case_id": task["case_id"], "group_id": task["group_id"],
            "reference_class": rubric["reference_class"], "run_id": folder.name, "execution_status": trace["termination_reason"],
            "frozen_runtime_and_fresh_context": frozen, "trace_audit_passed": checked["all_passed"],
            "trace_audit_checks_passed": checked["checks_passed"], "trace_audit_checks_total": checked["checks_total"],
            "trace_audit": str(audit_path.relative_to(ROOT).as_posix()),
            "report_numbers_passed": all(c["passed"] for c in number_checks), "report_numeric_checks": number_checks,
            "program_report_check_passed": trace["report_evidence_checked"],
            "semantic_review_status": "pending_separate_development_assistant_review_not_blinded",
            "requests": trace["model_http_attempts"], "responses": trace["model_responses"],
            "real_matlab_calls": trace["matlab_backend_calls"], "tool_attempts": trace["tool_call_attempts"],
            "rejected_calls": trace["rejected_calls"], "program_report_repairs": trace["report_repairs"],
            "report_phase_started": trace["report_phase_started"], "loop_elapsed_s": trace["elapsed_s"],
            "end_to_end_s": summary["end_to_end_s"], "usage_returned": usage,
            "requests_without_returned_usage": trace["model_http_attempts"] - len(model_events),
            "worker_stopped_cleanly": summary["worker_stopped_cleanly"], "new_simulations": trace["new_physical_simulations"],
            "raw_trace_sha256": sha256(folder / "trace.json"),
            "report_sha256": sha256(folder / "report.json") if report else None})
    result = {"created_utc": datetime.now(timezone.utc).isoformat(), "experiment": args.experiment_id,
        "scope": "four_development_cases_post_run_provenance_and_numbers_not_semantic_grading",
        "cases": rows, "tasks_executed": len(rows), "physical_groups": len({v["group_id"] for v in rows}),
        "fresh_contexts_and_frozen_settings": all(v["frozen_runtime_and_fresh_context"] for v in rows),
        "new_model_requests": sum(v["requests"] for v in rows), "new_model_responses": sum(v["responses"] for v in rows),
        "new_real_matlab_calls": sum(v["real_matlab_calls"] for v in rows), "new_simulations": sum(v["new_simulations"] for v in rows),
        "usage_returned": {k: sum(v["usage_returned"][k] for v in rows) for k in ("prompt_tokens", "completion_tokens", "total_tokens")},
        "requests_without_returned_usage": sum(v["requests_without_returned_usage"] for v in rows),
        "semantic_review_required": True, "not_general_accuracy_estimate": True}
    dest = base / "postrun_checks" / uuid.uuid4().hex
    dest.mkdir(parents=True)
    (dest / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("tasks_executed", "fresh_contexts_and_frozen_settings", "new_model_requests", "new_model_responses", "new_real_matlab_calls", "usage_returned")}))
    print(str(dest.relative_to(ROOT)))


if __name__ == "__main__":
    main()
