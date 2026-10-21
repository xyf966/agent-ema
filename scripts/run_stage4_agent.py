"""Explicit stage4 protocol probe or one frozen development task; no simulation."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import read_json, sha256
from controlled_loop import parse_final_object, run_loop, system_message
from deepseek_client import validate_config
from matlab_bridge import MatlabBridge
from report_contract import decode_report, render_report
from tool_executor import ToolExecutor

PUBLIC = ROOT / "data/agent_visible/tasks_stage4_v1"
PROVIDER = ROOT / "configs/llm_stage4_frozen_v1.json"
REGISTRY = ROOT / "tools/registry_stage4"


def load_frozen():
    manifest = read_json(PUBLIC / "manifest.json")
    for name, expected in manifest["frozen_files_sha256"].items():
        path = (ROOT / name).resolve()
        path.relative_to(ROOT)
        if sha256(path) != expected:
            raise ValueError("FROZEN_STAGE4_INPUT_OR_IMPLEMENTATION_DRIFT:" + name)
    tasks = read_json(PUBLIC / "tasks.json")["tasks"]
    config = validate_config(read_json(PROVIDER))
    protocol = read_json(ROOT / "configs/stage4_protocol_v1.json")
    prompt = system_message(True, True, True)
    if hashlib.sha256(prompt.encode("utf-8")).hexdigest() != manifest["system_message_sha256"]:
        raise ValueError("FROZEN_STAGE4_SYSTEM_MESSAGE_DRIFT")
    return tasks, config, protocol, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol-live", action="store_true", help="At most two real API requests; inspect roundtrip only")
    parser.add_argument("--live", action="store_true", help="Execute one explicitly selected frozen task")
    parser.add_argument("--task-id")
    parser.add_argument("--experiment-id", default="EXP-20261020-020")
    args = parser.parse_args()
    if args.protocol_live and (args.live or args.task_id):
        parser.error("PROTOCOL_PROBE_AND_DIAGNOSIS_ARE_SEPARATE")
    if not re.fullmatch(r"EXP-[0-9]{8}-[0-9]{3}", args.experiment_id):
        parser.error("INVALID_EXPERIMENT_ID")
    if args.protocol_live:
        config = validate_config(read_json(PROVIDER))
        case = read_json(ROOT / "data/agent_visible/observations_boundary_v1/catalog.json")["cases"][0]
        selected = {"case_id": case["case_id"], "group_id": case["group_id"], "task_id": None}
        folder = ROOT / "results/EXP-20261020-019/live_protocol" / uuid.uuid4().hex
        protocol = None
    else:
        tasks, config, protocol, _ = load_frozen()
        if not args.live:
            print(json.dumps({"status": "frozen_offline_ready", "tasks": len(tasks), "model": config["model"],
                              "api_requests": 0, "matlab_started": False}))
            return 0
        if not args.task_id:
            parser.error("LIVE_DIAGNOSIS_REQUIRES_EXPLICIT_TASK_ID")
        selected = next((t for t in tasks if t["task_id"] == args.task_id), None)
        if selected is None:
            parser.error("UNKNOWN_FROZEN_TASK_ID")
        base = ROOT / "results" / args.experiment_id
        existing = [read_json(p).get("task_id") for p in base.glob("runs/*/attempt_registered.json")]
        if selected["task_id"] in existing:
            raise SystemExit("TASK_ALREADY_ATTEMPTED_PRESERVE_FAILURE_NO_AUTOMATIC_RERUN")
        folder = base / "runs" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    registration = {"task_id": selected["task_id"], "case_id": selected["case_id"],
                    "group_id": selected["group_id"], "registered_at_utc": datetime.now(timezone.utc).isoformat(),
                    "purpose": "stage4_protocol_inspect_only" if args.protocol_live else "stage4_complex_development",
                    "new_physical_simulations": 0}
    (folder / "attempt_registered.json").write_text(json.dumps(registration, indent=2) + "\n", encoding="utf-8")
    (folder / "config_snapshot.json").write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if not args.protocol_live:
        runtime = {"system_message": system_message(True, True, True),
                   "manifest": read_json(PUBLIC / "manifest.json"), "protocol": protocol}
        (folder / "runtime_manifest.json").write_text(json.dumps(runtime, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    bridge = MatlabBridge(folder, profile="stage4")
    summary = {**registration, "status": "starting", "llm_calls": 0,
               "model_requested": config["model"], "semantic_task_accepted": None}
    start = time.monotonic()
    executor = None
    try:
        summary["matlab_runtime"] = bridge.start()
        executor = ToolExecutor(selected["case_id"], bridge, registry_dir=REGISTRY)
        if args.protocol_live:
            question = ("这是接口验收，不是故障诊断。对 " + selected["case_id"] +
                        " 调用一次inspect_case。根据真实返回，最后只输出JSON对象：tool_status、sample_count、"
                        "time_range_s、independent_load_state、initial_reference_state、evidence_id。不计算残差，不做诊断。")
            record = run_loop(question, executor, config, folder,
                budget={"model_calls": 2, "tool_calls": 1, "wall_time_s": 120, "max_tokens": 512, "max_rejected_calls": 2},
                first_tool_choice={"type": "function", "function": {"name": "inspect_case"}}, later_tool_choice="none",
                purpose="stage4_protocol_inspect_only", response_source="deepseek_official_live",
                provider_config_path=PROVIDER)
        else:
            record = run_loop(selected["question"], executor, config, folder,
                purpose="stage4_complex_development", response_source="deepseek_official_live",
                checked_report=True, shared_basic_rules=True, stage4_rules=True, provider_config_path=PROVIDER)
        summary.update({"status": record["termination_reason"], "model_http_attempts": record["model_http_attempts"],
                        "llm_calls": record["model_responses"], "real_tool_calls": executor.backend_calls,
                        "report_repairs": record["report_repairs"], "report_evidence_checked": record["report_evidence_checked"]})
        if args.protocol_live:
            calls = [e for e in record["events"] if e["type"] == "tool_result"]
            passed = False
            try:
                final = parse_final_object(record["final_text"])
                actual = calls[0]["response"]
                conditions = {p["name"]: p["state"] for p in actual["preconditions"]}
                passed = (record["termination_reason"] == "model_finished" and len(calls) == 1
                          and calls[0]["backend_executed"] and actual["status"] == final["tool_status"] == "ok"
                          and final["sample_count"] == actual["result"]["channels"][0]["sample_count"]
                          and final["time_range_s"] == actual["result"]["time_range_s"]
                          and final["independent_load_state"] == conditions["independent_normal_load"]
                          and final["initial_reference_state"] == conditions["independent_initial_reference"]
                          and final["evidence_id"] == actual["evidence"]["id"])
            except (ValueError, KeyError, TypeError, IndexError):
                passed = False
            summary["roundtrip_passed"] = passed
            summary["usage_returned"] = [e["usage"] for e in record["events"] if e["type"] == "model_response"]
        else:
            (folder / "final_response.md").write_text(record["final_text"], encoding="utf-8")
            if record["report_evidence_checked"]:
                report = decode_report(record["final_text"])
                (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                (folder / "report_readable.md").write_text(render_report(report), encoding="utf-8")
    except Exception as error:
        summary["status"] = "runtime_or_protocol_failure"
        summary["error_type"] = type(error).__name__
        # No raw provider messages, credentials, or request headers are saved.
    finally:
        bridge.close()
        summary["end_to_end_s"] = round(time.monotonic() - start, 6)
        summary["worker_stopped_cleanly"] = (bridge.folder / "stopped.json").is_file()
        if executor is not None:
            summary["real_tool_calls"] = executor.backend_calls
        (folder / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": summary["status"], "roundtrip_passed": summary.get("roundtrip_passed"),
                      "llm_calls": summary["llm_calls"], "real_tool_calls": summary.get("real_tool_calls", 0),
                      "run_directory": folder.relative_to(ROOT).as_posix()}))
    return 0 if summary.get("roundtrip_passed") or not args.protocol_live and summary.get("report_evidence_checked") else 1


if __name__ == "__main__":
    raise SystemExit(main())
