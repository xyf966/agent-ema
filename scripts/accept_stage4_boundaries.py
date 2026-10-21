"""Research-side acceptance of stage 4 step 2, not Agent performance scoring."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "results/EXP-20261020-018"


def read(path):
    return json.loads((ROOT / path).read_text(encoding="utf-8-sig"))


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")


def main():
    before = read("results/EXP-20261020-018/protected_hashes_before.json")
    after = {name: sha(ROOT / name) for name in before}
    write(OUT / "protected_hashes_after.json", after)
    checks = []

    def check(name, value):
        checks.append({"name": name, "passed": bool(value)})

    reports = [read(f"results/EXP-20261020-{n:03d}/run_report.json") for n in [16, 17]]
    posts = [read(f"results/EXP-20261020-{n:03d}/postprocess_report.json") for n in [16, 17]]
    check("exactly_two_completed_simulations_one_attempt_each", all(
        x["simulation_completed"] and x["simulation_attempts"] == 1 for x in reports))
    check("models_compiled_and_model_bytes_unchanged", all(
        x["compilation_passed_through_simulation"] and x["model_sha256_before"] == x["model_sha256_after"] for x in reports))
    check("initial_bias_present_at_t0_and_constant", abs(reports[0]["initial_bias_m"] - 2e-5) < 1e-12
          and reports[0]["max_bias_error_m"] < 1e-12)
    check("healthy_second_run_no_position_bias", reports[1]["initial_bias_m"] == 0 and reports[1]["max_bias_error_m"] == 0)
    check("both_three_channel_historical_replays_exact", all(x["all_three_historical_residuals_exactly_equal"] for x in posts))
    check("initial_constant_offset_three_channels_no_alarm", not any(x["alarmed"] for x in posts[0]["diagnostic_assumption_alarms"]))
    check("healthy_correct_compensation_no_alarm", not any(x["alarmed"] for x in posts[1]["correct_command_alarms"]))
    check("load_mismatch_only_torque_alarm_at_0p029", [x["alarmed"] for x in posts[1]["diagnostic_assumption_alarms"]] == [False, False, True]
          and posts[1]["diagnostic_assumption_alarms"][2]["first_alarm_s"] == 0.029)
    check("compensation_difference_formula_verified", all(x["compensation_difference_formula_error_Nm"] < 1e-10 for x in posts))
    tool = read("results/EXP-20261020-018/tool_acceptance.json")
    export = read("results/EXP-20261020-018/export_integrity.json")
    check("113_tool_checks_pass", tool["passed"] and tool["check_count"] == tool["checks_passed"] == 113)
    check("42_export_checks_pass_and_14_arrays_roundtrip", export["passed"] and export["check_count"] == export["checks_passed"] == 42
          and export["source_observation_fields_roundtrip"] == 14)
    analyzer = read("results/EXP-20261020-018/code_analyzer_final.json")
    check("13_MATLAB_files_no_analyzer_messages", len(analyzer) == 13 and all(not x["messages"] for x in analyzer))
    mapping = read("data/evaluation_private/EXP-20261020-018/case_mapping.json")
    old = read("data/evaluation_private/EXP-20261019-004/case_mapping.json")
    check("nine_distinct_physical_groups_total", len(mapping) == 2 and len({x["group_id"] for x in old + mapping}) == 9)
    index = read("tools/registry_stage4/boundary_release_index.json")
    base = ROOT / "data/agent_visible/observations_boundary_v1"
    check("public_catalog_trusted_hash", sha(base / "catalog.json") == index["catalog_sha256"])
    check("per_case_manifest_trusted_hashes", all(sha(base / x["case_id"] / "manifest.json") == x["manifest_sha256"] for x in index["cases"]))
    manifest_matches = True
    for case in index["cases"]:
        manifest = read(f"data/agent_visible/observations_boundary_v1/{case['case_id']}/manifest.json")
        manifest_matches &= all(sha(base / case["case_id"] / f["path"]) == f["sha256"] for f in manifest["files"])
    check("all_exported_manifest_files_match", manifest_matches)
    registry = read("tools/registry_stage4/tool_registry_v1.json")
    check("six_separate_schema_hashes_match", len(registry["tools"]) == 6 and all(
        sha(ROOT / "tools/registry_stage4" / t["schema_file"]) == t["schema_sha256"] for t in registry["tools"]))
    check("2604_existing_files_unchanged", len(before) == 2604 and before == after)
    figures = read("results/EXP-20261020-018/research_figures_manifest.json")["figures"]
    check("research_PNG_and_editable_FIG_hashes_match", len(figures) == 2 and all(
        sha(ROOT / x["png"]) == x["png_sha256"] and sha(ROOT / x["fig"]) == x["fig_sha256"] for x in figures))
    failures = [x["name"] for x in checks if not x["passed"]]
    write(OUT / "implementation_failures.json", {"failures_retained": [
        {"step": "initial_postprocess", "error": "Dissimilar-structure indexed assignment in process_stage4_boundary at the alarm-array assignment.",
         "fix": "Preallocate all named fields; postprocess saved observations again. No new simulation."},
        {"step": "initial_tool_connection", "error": "Two initial probes returned invalid_registry: outer package version used for the unchanged inner strict reader.",
         "fix": "Preserve rejected manifests/probes, identify the inner data schema as EMA-OBS-1.0, retain outer EMA-BOUNDARY-OBS-1.0 release and distinct source provenance, update actual manifest hashes.",
         "evidence": "rejected_tool_probes.json and rejected_manifest_attempt/"}],
         "new_simulations_due_to_repairs": 0})
    write(OUT / "acceptance.json", {"experiment_id": "EXP-20261020-018", "user_stage": 4, "step": 2,
          "passed": not failures, "checks": checks, "check_count": len(checks),
          "checks_passed": len(checks)-len(failures), "new_physical_simulations": 2,
          "representative_physical_runs_total": 9, "llm_calls": 0, "new_agent_diagnoses": 0,
          "formal_top_level_tool_dispatch_calls": tool["actual_dispatch_calls"],
          "additional_connection_probe_dispatch_calls": 4,
          "tool_checks": 113, "export_checks": 42, "protected_files_unchanged": len(before),
          "stage4_complete": False, "agent_runtime_switched": False,
          "next_step": "Stage 4 step 3: bind and freeze tasks/information conditions; configure the validated stage4 entrypoint before freezing model/schema/knowledge/budgets and private rubrics.",
          "scope": "simulation_observations_numerical_replay_export_and_tool_preparation_not_Agent_performance"})
    entries = []
    for folder in ["data", "results", "tools", "scripts"]:
        for p in (ROOT / folder).rglob("*"):
            if p.is_file() and p.relative_to(ROOT).as_posix() not in before:
                entries.append({"path": p.relative_to(ROOT).as_posix(), "sha256": sha(p)})
    write(OUT / "new_artifact_manifest.json", {"scope": "research_only_includes_private_evaluation_fixtures", "files": entries})
    print(json.dumps({"passed": not failures, "acceptance_checks": len(checks), "failures": failures,
                      "new_simulations": 2, "physical_runs_total": 9, "protected_files": len(before)}))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
