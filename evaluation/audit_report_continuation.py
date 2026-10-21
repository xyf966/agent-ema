"""Research-side reconstruction of a report-only continuation; no semantic grading."""

import argparse
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "scripts")]
from bailian_client import load_tools, read_json, sha256, read_api_key
from complete_checked_report import prepare_source
from report_contract import check_report, decode_report, render_report, repair_message


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--continuation-id", required=True)
    parser.add_argument("--plan", default="continuation_plan_v2.json")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{32}", args.continuation_id):
        raise SystemExit("INVALID_CONTINUATION_ID")
    base = ROOT / "results/EXP-20261020-004"
    folder = base / "continuations" / args.continuation_id
    if not re.fullmatch(r"continuation_plan_v[0-9]+\.json", args.plan):
        raise SystemExit("INVALID_PLAN_NAME")
    plan = read_json(base / args.plan)
    link = read_json(folder / "source_link.json")
    trace = read_json(folder / "continuation.json")
    source = (ROOT / link["source_trace"]).resolve()
    source.relative_to(ROOT / "results")
    task, messages, records = prepare_source(source.parent)
    if "review_parent_trace" in link:
        parent_path = (ROOT / link["review_parent_trace"]).resolve()
        parent_path.relative_to(base / "continuations")
        parent = read_json(parent_path)
        if sha256(parent_path) != plan["review_parent_sha256"] or sha256(parent_path) != link["review_parent_sha256"]:
            raise ValueError("REVIEW_PARENT_CHANGED")
        messages = deepcopy(parent["messages"]) + [{"role": "user", "content": plan["review_feedback"]}]
    checks = []

    def check(name, value):
        checks.append({"name": name, "passed": bool(value)})

    check("continuation_registered_before_execution", plan["created_utc"] < link["created_utc"] < trace["timestamp_utc"])
    check("source_real_trace_intact_and_matlab_results_revalidated", sha256(source) == plan["source_trace_sha256"] == link["source_trace_sha256"])
    check("only_known_source_plus_generic_reporting_instruction_in_initial_context", messages == link["initial_messages"]
          and messages[0]["content"] == plan["system_message"] and messages[-1]["content"] == plan.get("review_feedback", plan["completion_prompt"]))
    check("case_task_group_bound", trace["case_id"] == task["case_id"] and link["task_id"] == task["task_id"] and link["group_id"] == task["group_id"])
    check("live_response_not_fixture", trace["response_source"] == "bailian_live")
    check("successful_final_structure_and_evidence_check", trace["status"] == "report_evidence_checked")
    replay = deepcopy(messages)
    models = []
    consistent = True
    all_report_only = True
    last_check = None
    for event in trace["events"]:
        if event["type"] == "model_response":
            request, response = event["request"], event["response"]
            consistent &= request["messages"] == replay and request["tools"] == load_tools() and request["model"] == plan["model"]
            all_report_only &= request["tool_choice"] == "none" and request["max_tokens"] == 4096
            choice = response["choices"][0]
            consistent &= choice["finish_reason"] == "stop" and not choice["message"].get("tool_calls")
            models.append(response)
            replay.append({"role": "assistant", "content": choice["message"].get("content") or ""})
        elif event["type"] == "report_check":
            last_check = check_report(replay[-1]["content"], records, task["case_id"])
            consistent &= event["result"] == last_check
        elif event["type"] == "report_feedback":
            consistent &= last_check is not None and event["message"] == {"role": "user", "content": repair_message(last_check)}
            replay.append(event["message"])
        else:
            consistent = False
    check("every_request_result_and_feedback_reconstructs_without_private_answers", consistent and replay == trace["messages"])
    check("report_only_mode_and_fixed_output_limit", all_report_only)
    check("model_and_repair_budget_respected", trace["model_http_attempts"] == len(models) <= plan["max_model_requests"]
          and trace["report_repairs"] <= 1 and trace["elapsed_s"] <= plan["wall_limit_s"])
    check("no_new_tools_or_simulations", trace["new_matlab_tool_calls"] == trace["new_physical_simulations"] == 0)
    check("final_report_rechecked_against_actual_prior_tools", check_report(trace["final_text"], records, task["case_id"])["passed"])
    report = decode_report(trace["final_text"])
    check("parsed_and_rendered_files_preserve_model_fields", read_json(folder / "report.json") == report
          and (folder / "report_readable.md").read_text(encoding="utf-8") == render_report(report)
          and (folder / "final_response.md").read_text(encoding="utf-8") == trace["final_text"])
    check("semantic_acceptance_not_inferred_from_program_checks", trace["semantic_task_accepted"] is None)
    before = read_json(base / "protected_before.json")
    check("all_existing_data_models_tools_and_prior_results_intact", all(sha256(ROOT / p) == h for p, h in before.items()))
    key = read_api_key()
    check("key_not_present_in_saved_continuation", bool(key) and key not in (folder / "continuation.json").read_text(encoding="utf-8"))
    result = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "scope": "source_provenance_structure_and_numeric_consistency_not_semantic_scoring",
        "continuation_id": args.continuation_id, "checks": checks, "checks_passed": sum(c["passed"] for c in checks),
        "checks_total": len(checks), "all_passed": all(c["passed"] for c in checks),
        "usage": {k: sum(r["usage"][k] for r in models) for k in ("prompt_tokens", "completion_tokens", "total_tokens")}}
    dest = base / "continuation_audits" / uuid.uuid4().hex
    dest.mkdir(parents=True)
    (dest / "audit.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("all_passed", "checks_passed", "checks_total", "usage")}))
    print(str(dest.relative_to(ROOT)))
    return 0 if result["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
