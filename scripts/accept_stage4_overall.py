"""Stage4 overall evidence acceptance; reads saved evidence, never runs models/APIs."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "scripts"), str(ROOT / "evaluation")]
from bailian_client import read_json, sha256
from run_stage4_agent import load_frozen
from collect_stage4_results import audit

OUT = ROOT / "results/EXP-20261021-001"
DOCS = ["README.md", "研究计划_详细版.md", "experiments/下一步实验清单.md"]


def write(path, value, *, exclusive=False):
    with path.open("x" if exclusive else "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")


def prepare():
    if OUT.exists():
        raise SystemExit("EXISTING_ACCEPTANCE_RECORD_PRESERVE")
    OUT.mkdir(parents=True)
    before = {}
    for name in ["data", "results", "tools", "matlab", "archive/source_snapshot", "agent", "evaluation", "configs", "scripts", "provenance"]:
        for path in (ROOT / name).rglob("*"):
            if path.is_file() and OUT not in path.parents:
                with path.open("rb") as stream:
                    before[path.relative_to(ROOT).as_posix()] = hashlib.file_digest(stream, "sha256").hexdigest()
    write(OUT / "protected_hashes_before.json", before, exclusive=True)
    doc_before = {}
    for name in DOCS:
        target = OUT / "documentation_before" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
        doc_before[name] = sha256(target)
    write(OUT / "registration.json", {"experiment_id": "EXP-20261021-001", "user_stage": 4, "step": 5,
        "registered_at_utc": datetime.now(timezone.utc).isoformat(), "purpose": "Overall acceptance of existing development evidence and stage5 handoff.",
        "new_model_requests": 0, "new_matlab_tool_calls": 0, "new_simulations": 0,
        "documentation_before": doc_before, "protected_files_count": len(before)}, exclusive=True)
    print(json.dumps({"status": "registered", "protected_files": len(before)}))


def main():
    tasks, config, protocol, manifest = load_frozen()
    checks = []
    def check(name, value, detail=None):
        checks.append({"name": name, "passed": bool(value), "detail": detail})
    prior = {n: read_json(ROOT / f"results/EXP-20261020-{n:03d}/" / ("acceptance_final.json" if n >= 19 else "acceptance.json")) for n in [15,18,19,20]}
    for n, count in [(15,55),(18,19),(19,28),(20,28)]:
        record = prior[n]
        check(f"step_record_{n}_passed_and_all_checks_retained", record.get("passed", record.get("all_passed"))
              and record["checks_passed"] == record.get("check_count", record.get("checks_total")) == count
              and all(c["passed"] for c in record["checks"]))
    receipt = read_json(ROOT / "results/EXP-20261020-019/freeze_receipt.json")
    rubric_path = ROOT / "data/evaluation_private/EXP-20261020-019/rubric.json"
    rubric = read_json(rubric_path)
    check("102_frozen_dependencies_and_complete_prompt_match", len(manifest["frozen_files_sha256"]) == 102)
    check("task_manifest_private_rubric_and_protocol_still_frozen", sha256(rubric_path) == receipt["private_rubric_sha256"]
          and sha256(ROOT / "data/agent_visible/tasks_stage4_v1/manifest.json") == receipt["public_manifest_sha256"]
          and sha256(ROOT / "configs/stage4_protocol_v1.json") == receipt["protocol_sha256"])
    mapping = read_json(ROOT / "data/evaluation_private/EXP-20261019-004/case_mapping.json") + read_json(ROOT / "data/evaluation_private/EXP-20261020-018/case_mapping.json")
    check("nine_unique_physical_groups_not_duplicated_by_compensation", len(mapping) == len({m["group_id"] for m in mapping}) == 9)
    check("five_task_to_source_run_mapping_exact", len(tasks) == len({t["group_id"] for t in tasks}) == 5 and all(any(
        m["case_id"] == r["case_id"] and m["group_id"] == r["group_id"] and m["source_run_id"] == r["source_run_id"] for m in mapping) for r in rubric["tasks"]))
    release = read_json(ROOT / "results/EXP-20261020-015/release_integrity.json")["files"]
    check("legacy_observation_release_still_matches_19_recorded_hashes", len(release) == 19 and all(sha256(ROOT / e["path"]) == e["expected_sha256"] for e in release))
    index = read_json(ROOT / "tools/registry_stage4/boundary_release_index.json")
    boundary = ROOT / "data/agent_visible/observations_boundary_v1"
    check("boundary_catalog_and_per_case_manifest_unchanged", sha256(boundary / "catalog.json") == index["catalog_sha256"]
          and all(sha256(boundary / c["case_id"] / "manifest.json") == c["manifest_sha256"] for c in index["cases"]))
    check("all_boundary_observations_and_context_files_unchanged", all(sha256(boundary / c["case_id"] / f["path"]) == f["sha256"]
          for c in index["cases"] for f in read_json(boundary / c["case_id"] / "manifest.json")["files"]))
    changes = read_json(ROOT / "results/EXP-20261020-019/source_changes_final.json")["modified_files"]
    check("twelve_runtime_changes_and_original_bytes_traceable", len(changes) == 12 and all(sha256(ROOT / c["path"]) == c["after"]
          and sha256(ROOT / c["backup"]) == c["before"] for c in changes))
    artifacts = read_json(ROOT / "results/EXP-20261020-018/new_artifact_manifest.json")["files"]
    historical_drift = [e for e in artifacts if sha256(ROOT / e["path"]) != e["sha256"]]
    check("earlier_artifact_hash_drift_only_documented_step3_updates", all(any(e["path"] == c["path"] and e["sha256"] == c["before"]
          and sha256(ROOT / e["path"]) == c["after"] for c in changes) for e in historical_drift), [e["path"] for e in historical_drift])
    reports = [read_json(ROOT / f"results/EXP-20261020-{n:03d}/run_report.json") for n in [16,17]]
    posts = [read_json(ROOT / f"results/EXP-20261020-{n:03d}/postprocess_report.json") for n in [16,17]]
    check("two_completed_simulations_one_attempt_each_from_saved_records", all(r["simulation_completed"] and r["simulation_attempts"] == 1 for r in reports))
    check("model_bytes_match_after_real_simulation_compilation", all(r["compilation_passed_through_simulation"]
          and r["model_sha256_before"] == r["model_sha256_after"] == sha256(ROOT / "matlab/fixed/EMA_Paper_Fixed.slx") for r in reports))
    check("both_boundary_historical_replays_exact_from_saved_records", all(p["all_three_historical_residuals_exactly_equal"] for p in posts))
    check("initial_constant_offset_boundary_record", reports[0]["initial_bias_m"] == 2e-5 and reports[0]["max_bias_error_m"] < 1e-12
          and all(not c["alarmed"] and c["valid_points"] == 407 for c in posts[0]["diagnostic_assumption_alarms"]))
    check("load_comparison_preserves_original_alarm_and_correct_command_result", [c["alarmed"] for c in posts[1]["diagnostic_assumption_alarms"]] == [False,False,True]
          and posts[1]["diagnostic_assumption_alarms"][2]["first_alarm_s"] == 0.029 and not any(c["alarmed"] for c in posts[1]["correct_command_alarms"])
          and posts[1]["compensation_difference_formula_error_Nm"] < 1e-10)
    base = ROOT / "results/EXP-20261020-020"
    original_audit = read_json(base / "evaluation/deterministic_audit.json")
    registration = read_json(base / "preregistration.json")
    rerun_audits = []
    for task in tasks:
        old = next(t for t in original_audit["tasks"] if t["task_id"] == task["task_id"])
        fresh = audit(task, next(r for r in rubric["tasks"] if r["task_id"] == task["task_id"]), ROOT / old["run_directory"], registration, config, protocol)
        rerun_audits.append(fresh)
        check(task["task_id"] + "_offline_trace_audit_reproduces_exactly", fresh == old)
    write(OUT / "offline_trace_reaudit.json", {"scope": "Offline replay of saved requests, responses and report checks; no execution or new grading.", "tasks": rerun_audits})
    check("no_new_diagnostic_attempt_or_replacement", len(list(base.glob("runs/*/attempt_registered.json"))) == 5 and original_audit["totals"]["report_repairs"] == 0)
    semantic_path = ROOT / "data/evaluation_private/EXP-20261020-020/semantic_review.json"
    semantic = read_json(semantic_path)
    check("original_semantic_review_preserved_bound_to_original_reports", all(s["source_final_sha256"] == t["source_final_sha256"]
          and all(i["quote"] in (ROOT / t["run_directory"] / "final_response.md").read_text(encoding="utf-8") for i in s["issues"])
          for s,t in zip(semantic["tasks"], rerun_audits)))
    check("necessary_coverage_and_full_text_issues_remain_separate", semantic["mandatory_point_coverage_tasks"] == 5 and semantic["full_original_text_accepted_tasks"] == 2
          and semantic["original_text_requires_revision_tasks"] == 3 and semantic["formal_generalization_accuracy"] is None)
    check("no_claim_of_fixed_model_weights_or_independent_measurements", not protocol["model_weights_snapshot_frozen"]
          and not protocol["independent_load_measurement_available"] and not protocol["independent_initial_reference_available"] and not protocol["hidden_command_variant_included"])
    check("cost_totals_diagnostic_and_protocol_not_conflated", original_audit["totals"]["model_responses"] == 21
          and original_audit["usage_returned"]["total_tokens"] == 251605 and prior[19]["live_model_responses"] == 2
          and prior[19]["live_usage_returned_total_tokens"] == 2516)
    evidence_paths = [f"results/EXP-20261020-{n:03d}/" + ("acceptance_final.json" if n >= 19 else "acceptance.json") for n in [15,18,19,20]]
    evidence_paths += ["data/evaluation_private/EXP-20261020-019/rubric.json", "data/evaluation_private/EXP-20261020-020/semantic_review.json",
        "results/EXP-20261020-020/evaluation/deterministic_audit.json"]
    for n in [16,17]:
        evidence_paths += [f"results/EXP-20261020-{n:03d}/{name}" for name in ["run_report.json", "postprocess_report.json", "observations_aligned.mat", "residuals.mat"]]
    evidence_paths += [f"{t['run_directory']}/{name}" for t in rerun_audits for name in ["trace.json", "summary.json", "final_response.md", "report.json"]]
    write(OUT / "evidence_index.json", {"scope": "Research-only index includes private evidence; never an Agent input.",
        "files": [{"path": p, "sha256": sha256(ROOT / p)} for p in evidence_paths]})
    protected = read_json(OUT / "protected_hashes_before.json")
    drift = [name for name, expected in protected.items() if sha256(ROOT / name) != expected]
    check("all_existing_protected_files_unchanged", not drift, {"count": len(protected), "drift": drift})
    registration_now = read_json(OUT / "registration.json")
    doc_changes = []
    for name, before in registration_now["documentation_before"].items():
        check("documentation_backup_" + name, sha256(OUT / "documentation_before" / name) == before)
        doc_changes.append({"path": name, "before": before, "after": sha256(ROOT / name),
                            "backup": (OUT / "documentation_before" / name).relative_to(ROOT).as_posix()})
    write(OUT / "documentation_changes.json", {"files": doc_changes})
    check("current_project_entries_agree_on_stage4_completion_and_stage5_next", all("阶段4整体验收完成" in (ROOT / p).read_text(encoding="utf-8")[:1400]
          and "阶段5第1步" in (ROOT / p).read_text(encoding="utf-8")[:1400] for p in DOCS))
    delivery = ["docs/阶段4复杂案例整体验收与交接.md", "experiments/EXP-20261021-001.md"]
    unresolved = []
    for name in delivery:
        for ref in re.findall(r"\]\(([^)]+)\)", (ROOT / name).read_text(encoding="utf-8")):
            if ref.endswith("acceptance_final.json") and "20261021-001" in ref:
                continue
            if "://" not in ref and not ((ROOT / name).parent / ref).is_file():
                unresolved.append(ref)
    check("new_handoff_document_links_resolve", not unresolved, unresolved)
    passed = all(c["passed"] for c in checks)
    result = {"experiment_id": "EXP-20261021-001", "user_stage": 4, "step": 5,
        "scope": "Overall acceptance of complex-case DEVELOPMENT verification, with original explanation errors retained; not a performance certification.",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(), "checks": checks,
        "checks_passed": sum(c["passed"] for c in checks), "check_count": len(checks), "passed": passed,
        "stage4_complete": passed, "stage4_completion_scope": "data, frozen protocol, actual five-task execution, auditable evaluation and failure disclosure",
        "all_diagnostic_reports_correct": False, "numeric_evidence_tasks_passed": 5,
        "manual_full_text_accepted": 2, "manual_full_text_issues_retained": 3,
        "formal_accuracy": None, "method_superiority_established": False,
        "new_model_requests": 0, "new_matlab_tool_calls": 0, "new_simulations": 0,
        "stage4_new_physical_runs": 2, "project_representative_physical_runs": 9,
        "stage4_diagnostic_model_responses": 21, "stage4_protocol_model_responses": 2,
        "stage4_returned_tokens": 254121, "existing_files_unchanged": len(protected)-len(drift),
        "next_step": "Stage5 step1: define fair same-information baselines and evaluation protocol before new execution.",
        "limitations": ["five development tasks, one attempt each", "same-developer nonblind semantic review with postexecution wording issues",
            "ideal simulation thresholds, no noise/hardware/full-envelope validation", "provider model alias is not a weight snapshot",
            "no same-information baseline comparison yet", "report repair branch not triggered in diagnostic batch",
            "three original reports retain explanation issues", "tool summaries and plot references do not supply image pixels or exact waveform observations"]}
    write(OUT / "acceptance_final.json", result)
    print(json.dumps({"passed": passed, "checks": [result["checks_passed"], result["check_count"]],
        "protected_files": len(protected), "failed": [c["name"] for c in checks if not c["passed"]]}))
    return 0 if passed else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    args = parser.parse_args()
    if args.prepare:
        prepare()
    else:
        raise SystemExit(main())
