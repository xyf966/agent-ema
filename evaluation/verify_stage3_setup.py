"""Research-side checks, including negative boundaries. Not an Agent tool/grader."""

from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import sys
from unittest.mock import patch
import uuid
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "scripts")]
import bailian_client as client
import check_bailian_setup as setup


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    checks = []

    def check(name, condition):
        checks.append({"name": name, "passed": bool(condition)})

    public_dir = ROOT / "data/agent_visible/tasks_stage3_v1"
    public = read(public_dir / "tasks.json")
    manifest = read(public_dir / "manifest.json")
    rubric = read(ROOT / "data/evaluation_private/EXP-20261020-001/rubric.json")
    mapping = {m["case_id"]: m for m in read(ROOT / "data/evaluation_private/EXP-20261019-004/case_mapping.json")}
    catalog = {m["case_id"]: m["group_id"] for m in read(ROOT / "data/agent_visible/observations_v1/catalog.json")["cases"]}
    before = read(ROOT / "results/EXP-20261020-001/protected_hashes_before.json")
    after = read(ROOT / "results/EXP-20261020-001/protected_hashes_after.json")
    check("four_tasks_four_physical_groups", len(public["tasks"]) == 4
          and len({t["case_id"] for t in public["tasks"]}) == 4
          and len({t["group_id"] for t in public["tasks"]}) == 4)
    check("public_release_has_exact_fields", set(public) == {"task_set_version", "partition", "tool_registry_version", "tasks"}
          and all(set(t) == {"task_id", "case_id", "group_id", "question", "allowed_tools"} for t in public["tasks"]))
    check("opaque_unique_task_ids", len({t["task_id"] for t in public["tasks"]}) == 4
          and all(re.fullmatch(r"TASK-[0-9a-f]{32}", t["task_id"]) for t in public["tasks"]))
    check("same_question_template", len({t["question"].replace(t["case_id"], "CASE") for t in public["tasks"]}) == 1)
    check("development_partition_only", public["partition"] == "development"
          and all(t["partition"] == "development" for t in rubric["tasks"]))
    check("public_manifest_contains_no_private_reference", set(manifest) == {
        "task_set_version", "task_file_sha256", "catalog_sha256", "tool_registry_sha256", "schema_sha256"})
    text = (public_dir / "tasks.json").read_text(encoding="utf-8")
    check("no_truth_labels_or_expected_values_in_public_tasks", not re.search(
        r"F[123]|healthy|reference_class|source_run_id|evaluation_private|injected_|appliedFault|"
        r"required_claims|expected_channels|EXP-20261016|0\.039|0\.210|300\s*N", text))
    check("six_tool_schemas_load_and_have_parameter_contract", len(client.load_tools()) == 6
          and all(set(t) == {"type", "function"} and set(t["function"]) == {"name", "description", "parameters"}
                  for t in client.load_tools()))
    check("public_tasks_only_allow_six_tools", all(set(t["allowed_tools"]) == client.REGISTERED_NAMES for t in public["tasks"]))
    check("task_manifest_hash", digest(public_dir / "tasks.json") == manifest["task_file_sha256"])
    check("registry_and_catalog_hashes", digest(ROOT / "tools/registry/tool_registry_v1.json") == manifest["tool_registry_sha256"]
          and digest(ROOT / "data/agent_visible/observations_v1/catalog.json") == manifest["catalog_sha256"])
    check("existing_702_inputs_unchanged", len(before) == 702 and before == after
          and all(digest(ROOT / name) == value for name, value in before.items()))
    by_task = {r["task_id"]: r for r in rubric["tasks"]}
    check("private_rubrics_cover_exact_public_tasks", set(by_task) == {t["task_id"] for t in public["tasks"]})
    check("four_basic_sources_and_classes", {r["reference_class"] for r in rubric["tasks"]} == {"healthy", "F1", "F2", "F3"}
          and {r["source_run_id"] for r in rubric["tasks"]} == {"EXP-20261016-001", "EXP-20261016-002", "EXP-20261016-003", "EXP-20261016-004"})
    chains = {c[0]["arguments"]["case_id"]: c for c in read(ROOT / "results/EXP-20261019-010/final/tool_call_traces.json")}
    for task in public["tasks"]:
        ref = by_task[task["task_id"]]
        case = task["case_id"]
        check("mapping_and_group_" + task["task_id"], task["group_id"] == catalog[case] == ref["group_id"]
              and ref["reference_class"] == mapping[case]["reference_class"])
        metadata = ROOT / "data/agent_visible/observations_v1" / case / "metadata.json"
        check("observation_binding_" + task["task_id"], digest(metadata) == ref["metadata_sha256"]
              and digest(metadata.parent / "observations.mat") == ref["observations_sha256"])
        locate = next(c["response"]["result"] for c in chains[case]
                      if c["tool"] == "locate_anomalies" and c["arguments"]["residual_evidence_id"] == ref["reference_bundle_id"])
        check("reference_alarm_numbers_" + task["task_id"], all(
            ref["expected_channels"][c["quantity"]][k] == c[k]
            for c in locate["channels"] for k in ("alarmed", "first_alarm_s", "valid_points", "threshold")))
        check("rubric_requirements_and_tolerances_" + task["task_id"], len(ref["required_evidence"]) == 6
              and len(ref["required_claims"]) >= 5 and len(ref["forbidden_claims"]) >= 7
              and ref["numeric_tolerances"]["report_rounded_time_abs_s"] == 0.0005)
    f3 = next(r for r in rubric["tasks"] if r["reference_class"] == "F3")
    check("f3_requires_retained_cause_uncertainty", f3["allowed_success_termination"] == ["evidence_insufficient_for_unique_cause"])
    check("configured_model_is_explicit_and_not_formally_frozen", isinstance(client.load_config()["model"], str)
          and bool(client.load_config()["model"])
          and not client.load_config()["model_version_frozen"])
    with patch.object(setup, "read_api_key", return_value=""), patch.object(setup, "chat_completion", side_effect=AssertionError("NETWORK_FORBIDDEN")):
        offline = setup.run(False)
        missing = setup.run(True)
        check("offline_mode_never_calls_model", offline["http_requests_attempted"] == 0 and offline["llm_responses_received"] == 0)
        check("missing_key_live_mode_never_calls_model", missing["status"] == "missing_api_key_no_network_request" and missing["http_requests_attempted"] == 0)
    try:
        client.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.com")
        check("redirect_is_refused", False)
    except client.ClientError as error:
        check("redirect_is_refused", str(error) == "REDIRECT_REFUSED")
    config = client.load_config()
    fake_secret = "test-secret-not-a-real-credential"
    body = json.dumps({"error": {"code": "insufficient_quota", "message": fake_secret}}).encode()
    denied = urllib.error.HTTPError(config["base_url"], 403, "Forbidden", {}, io.BytesIO(body))
    with patch.object(client, "read_api_key", return_value=fake_secret), patch.object(client.urllib.request, "build_opener") as factory:
        factory.return_value.open.side_effect = denied
        try:
            client.chat_completion(config, [{"role": "user", "content": "probe"}])
            check("provider_error_is_sanitized", False)
        except client.ClientError as error:
            check("provider_error_is_sanitized", str(error) == "HTTP_403"
                  and error.details == {"http_status": 403, "provider_error_code": "insufficient_quota"}
                  and fake_secret not in str(error.details))
        check("http_error_not_automatically_retried", factory.return_value.open.call_count == 1)
    with patch.object(client, "read_api_key", return_value=fake_secret), patch.object(client.urllib.request, "build_opener", side_effect=AssertionError("NETWORK_FORBIDDEN")):
        try:
            client.chat_completion(config, [], tools=[{"type": "function", "function": {"name": "eval_matlab"}}])
            check("unregistered_request_tools_rejected_before_network", False)
        except client.ClientError as error:
            check("unregistered_request_tools_rejected_before_network", str(error) == "UNREGISTERED_TOOL_SET")
    temp_parent = ROOT / "results/EXP-20261020-001/boundary_fixtures"
    temp_parent.mkdir(parents=True, exist_ok=True)
    folder = temp_parent / uuid.uuid4().hex
    folder.mkdir()

    def check_registry_boundaries(folder):
        original = ROOT / "tools/registry"
        shutil.copyfile(original / "tool_registry_v1.json", folder / "tool_registry_v1.json")
        registry = read(folder / "tool_registry_v1.json")
        for item in registry["tools"]:
            shutil.copyfile(original / item["schema_file"], folder / item["schema_file"])
        target = folder / registry["tools"][0]["schema_file"]
        target.write_bytes(target.read_bytes() + b" ")
        try:
            client.load_tools(folder)
            check("tampered_schema_rejected", False)
        except client.ClientError as error:
            check("tampered_schema_rejected", str(error) == "SCHEMA_HASH_MISMATCH")
        shutil.copyfile(original / registry["tools"][0]["schema_file"], target)
        registry["tools"][0]["schema_file"] = "../outside.json"
        (folder / "tool_registry_v1.json").write_text(json.dumps(registry), encoding="utf-8")
        try:
            client.load_tools(folder)
            check("schema_path_escape_rejected", False)
        except client.ClientError as error:
            check("schema_path_escape_rejected", str(error) == "SCHEMA_PATH_OUTSIDE_REGISTRY")
        registry["tools"][0]["name"] = "eval_matlab"
        (folder / "tool_registry_v1.json").write_text(json.dumps(registry), encoding="utf-8")
        try:
            client.load_tools(folder)
            check("unregistered_tool_rejected", False)
        except client.ClientError as error:
            check("unregistered_tool_rejected", str(error) == "REGISTRY_SCOPE_MISMATCH")
    check_registry_boundaries(folder)
    report = {"experiment": "EXP-20261020-001", "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "offline_setup_and_task_rubric_integrity_not_agent_performance",
        "checks_passed": sum(c["passed"] for c in checks), "checks_total": len(checks),
        "all_passed": all(c["passed"] for c in checks), "checks": checks,
        "llm_calls": 0, "new_physical_simulations": 0,
        "software_sha256": {p.relative_to(ROOT).as_posix(): digest(p) for p in (
            ROOT / "agent/bailian_client.py", ROOT / "scripts/check_bailian_setup.py",
            ROOT / "scripts/prepare_stage3_tasks.py", Path(__file__).resolve())}}
    dest = ROOT / "results/EXP-20261020-001/offline_acceptance" / uuid.uuid4().hex
    dest.mkdir(parents=True)
    (dest / "acceptance.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("all_passed", "checks_passed", "checks_total", "llm_calls")}))
    print(str((dest / "acceptance.json").relative_to(ROOT)))
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
