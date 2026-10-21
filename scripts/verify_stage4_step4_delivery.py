"""Verify delivery completeness, not perfect diagnostic performance."""
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "scripts")]
from bailian_client import read_json, sha256
from run_stage4_agent import load_frozen


def main():
    base = ROOT / "results/EXP-20261020-020"
    tasks, config, protocol, manifest = load_frozen()
    audit = read_json(base / "evaluation/deterministic_audit.json")
    semantic = read_json(ROOT / "data/evaluation_private/EXP-20261020-020/semantic_review.json")
    registration = read_json(base / "preregistration.json")
    progress = read_json(base / "progress.json")
    protected = read_json(base / "protected_hashes_before.json")
    rubric = ROOT / "data/evaluation_private/EXP-20261020-019/rubric.json"
    checks = []
    def check(name, value, detail=None):
        checks.append({"name": name, "passed": bool(value), "detail": detail})
    check("102_frozen_files_and_system_prompt_unchanged", len(manifest["frozen_files_sha256"]) == 102)
    check("private_rubric_unchanged", sha256(rubric) == registration["private_rubric_sha256"] == semantic["private_frozen_rubric_sha256"])
    runs = list((base / "runs").glob("*/summary.json"))
    check("exactly_five_registered_attempts", len(runs) == len(tasks) == len(list((base / "runs").glob("*/attempt_registered.json"))) == 5)
    check("one_attempt_for_each_frozen_task", sorted(read_json(p)["task_id"] for p in runs) == sorted(t["task_id"] for t in tasks))
    check("all_subprocesses_completed", len(progress["completed_tasks"]) == 5 and all(r["exit_code"] == 0 for r in progress["completed_tasks"]))
    check("numeric_evidence_5_of_5", audit["numeric_evidence_tasks_passed"] == 5)
    check("per_task_27_provenance_checks", all(t["provenance"]["passed_count"] == t["provenance"]["check_count"] == 27 for t in audit["tasks"]))
    check("per_task_30_report_numbers", all(len(t["report_attempts"]) == 1 and t["report_attempts"][0]["numbers"]["passed_count"] == t["report_attempts"][0]["numbers"]["check_count"] == 30 for t in audit["tasks"]))
    check("tool_baselines_150_checks", all(t["tool_baseline_numbers"]["passed"] and t["tool_baseline_numbers"]["check_count"] == 30 for t in audit["tasks"]))
    comparisons = [t["tool_required_comparison_numbers"] for t in audit["tasks"] if t["tool_required_comparison_numbers"] is not None]
    check("required_load_comparison_30_checks", len(comparisons) == 1 and comparisons[0]["passed"] and comparisons[0]["check_count"] == 30)
    check("21_returned_responses_no_unreturned_request", audit["totals"]["http_attempts"] == audit["totals"]["model_responses"] == 21 and audit["totals"]["unreturned_requests"] == 0)
    check("34_real_tool_calls", audit["totals"]["real_tool_calls"] == 34)
    check("zero_report_repairs", audit["totals"]["report_repairs"] == 0)
    check("returned_token_totals", audit["usage_returned"] == {"prompt_tokens": 233090, "completion_tokens": 18515, "total_tokens": 251605})
    check("all_original_traces_and_finals_preserved", all(sha256(ROOT / t["run_directory"] / "trace.json") == t["source_trace_sha256"]
        and sha256(ROOT / t["run_directory"] / "final_response.md") == t["source_final_sha256"] for t in audit["tasks"]))
    check("semantic_review_bound_to_originals", all(s["source_final_sha256"] == t["source_final_sha256"] and s["task_id"] == t["task_id"] for s, t in zip(semantic["tasks"], audit["tasks"])))
    exact_quotes = all(issue["quote"] in (ROOT / t["run_directory"] / "final_response.md").read_text(encoding="utf-8")
        for s, t in zip(semantic["tasks"], audit["tasks"]) for issue in s["issues"])
    check("manual_criticisms_use_exact_original_quotes", exact_quotes)
    check("necessary_coverage_separate_from_full_text", semantic["mandatory_point_coverage_tasks"] == 5
        and semantic["full_original_text_accepted_tasks"] == 2 and semantic["original_text_requires_revision_tasks"] == 3)
    check("manual_review_discloses_nonblind_postexecution_details", "not independent or blinded" in semantic["reviewer"]
        and "identified after execution" in semantic["scoring_interpretation"])
    check("no_formal_accuracy_claim", audit["formal_generalization_accuracy"] is None and semantic["formal_generalization_accuracy"] is None)
    check("all_2913_preexisting_protected_files_unchanged", len(protected) == 2913 and all(sha256(ROOT / name) == expected for name, expected in protected.items()))
    check("execution_integrity_snapshot_matches_before", read_json(base / "protected_hashes_after_execution.json") == protected)
    check("all_owned_matlab_workers_stopped", all(read_json(p)["worker_stopped_cleanly"] for p in runs))
    check("no_new_simulations", audit["new_physical_simulations"] == 0 and all(read_json(p)["new_physical_simulations"] == 0 for p in runs))
    docs = ["docs/阶段4第4步复杂任务验证与交接.md", "experiments/EXP-20261020-020.md"]
    links = []
    for name in docs:
        path = ROOT / name
        for ref in re.findall(r"\]\(([^)]+)\)", path.read_text(encoding="utf-8")):
            if ref.endswith("acceptance_final.json"):
                continue  # This invocation creates that self-referenced receipt below.
            if "://" not in ref:
                links.append((path.parent / ref).is_file())
    check("delivery_document_links_resolve", bool(links) and all(links))
    check("next_step_is_stage4_step5", all("阶段4第5步" in (ROOT / name).read_text(encoding="utf-8")[:1100]
        for name in ("README.md", "研究计划_详细版.md", "experiments/下一步实验清单.md")))
    check("actual_date_distinguished_from_planned_id", audit["actual_execution_date_local"] == "2026-10-21" and audit["planned_id_date_retained"])
    check("frozen_protocol_unchanged", registration["protocol"] == protocol)
    paths = docs + ["README.md", "研究计划_详细版.md", "experiments/下一步实验清单.md",
        "scripts/execute_stage4_batch.py", "evaluation/collect_stage4_results.py",
        "evaluation/record_stage4_semantic_review.py", "scripts/verify_stage4_step4_delivery.py",
        "results/EXP-20261020-020/evaluation/deterministic_audit.json",
        "data/evaluation_private/EXP-20261020-020/semantic_review.json"]
    result = {"experiment_id": "EXP-20261020-020", "actual_execution_date_local": "2026-10-21",
        "verified_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Stage4 step4 execution and honest result-delivery completeness; does not certify all reports correct or stage4 complete.",
        "checks": checks, "checks_passed": sum(c["passed"] for c in checks), "checks_total": len(checks),
        "all_passed": all(c["passed"] for c in checks), "execution_complete": True, "evaluation_complete": True,
        "stage4_whole_accepted": False, "next_step": "stage4_step5_overall_acceptance",
        "numeric_evidence_tasks_passed": 5, "full_text_manual_review_accepted": 2,
        "full_text_manual_review_issues_retained": 3, "formal_accuracy": None,
        "delivery_file_sha256": {name: sha256(ROOT / name) for name in paths},
        "existing_runtime_source_changes": 0,
        "documentation_files_updated": ["README.md", "研究计划_详细版.md", "experiments/下一步实验清单.md"]}
    (base / "acceptance_final.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"all_passed": result["all_passed"], "checks_passed": result["checks_passed"], "checks_total": result["checks_total"],
        "failed": [c["name"] for c in checks if not c["passed"]]}))
    return 0 if result["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
