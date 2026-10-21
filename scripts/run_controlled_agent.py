"""Run step-2 protocol roundtrip, or an explicitly selected development task."""

import argparse
import hashlib
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import load_config, read_api_key, read_json, sha256
from controlled_loop import parse_final_object, run_loop, system_message
from report_contract import decode_report, render_report
from tool_executor import GuardError
from matlab_bridge import MatlabBridge
from tool_executor import ToolExecutor


def public_tasks():
    folder = ROOT / "data/agent_visible/tasks_stage3_v1"
    manifest = read_json(folder / "manifest.json")
    if (sha256(folder / "tasks.json") != manifest["task_file_sha256"]
            or sha256(ROOT / "tools/registry/tool_registry_v1.json") != manifest["tool_registry_sha256"]):
        raise ValueError("PUBLIC_TASK_OR_REGISTRY_HASH_MISMATCH")
    return read_json(folder / "tasks.json")["tasks"]


def experiment_id(value):
    if not re.fullmatch(r"EXP-[0-9]{8}-[0-9]{3}", value):
        raise argparse.ArgumentTypeError("INVALID_EXPERIMENT_ID")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--task-id", help="Omit for the limited step-2 inspect_case roundtrip")
    parser.add_argument("--checked-report", action="store_true", help="Check generic final-report fields against actual tools; at most one bounded repair")
    parser.add_argument("--shared-basic-rules", action="store_true", help="Frozen common physics rules and evidence-based report phase; no case-specific feedback")
    parser.add_argument("--experiment-id", type=experiment_id, default="EXP-20261020-002",
                        help="Project-local experiment identifier; never a path")
    args = parser.parse_args()
    if args.checked_report and not args.task_id:
        parser.error("CHECKED_REPORT_REQUIRES_DIAGNOSTIC_TASK")
    if args.shared_basic_rules and not args.checked_report:
        parser.error("SHARED_RULES_REQUIRE_CHECKED_REPORT")
    config = load_config()
    response_source = ('deepseek_official_live' if config['provider'] == 'deepseek_official'
                       else 'bailian_live')
    tasks = public_tasks()
    selected = next((t for t in tasks if t["task_id"] == args.task_id), None) if args.task_id else tasks[0]
    if selected is None:
        raise SystemExit("UNKNOWN_PUBLIC_TASK_ID")
    if not args.live:
        print(json.dumps({"status": "offline_ready", "mode": "diagnostic" if args.task_id else "protocol_roundtrip",
            "model": config["model"], "key_present": bool(read_api_key()), "http_requests": 0,
            "matlab_started": False}))
        return 0
    if not read_api_key():
        raise SystemExit("MISSING_API_KEY")
    folder = ROOT / "results" / args.experiment_id / "runs" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    (folder / "config_snapshot.json").write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    runtime_manifest = {
        "created_utc": datetime.now(timezone.utc).isoformat(), "system_message": system_message(args.checked_report, args.shared_basic_rules),
        "system_message_sha256": hashlib.sha256(system_message(args.checked_report, args.shared_basic_rules).encode("utf-8")).hexdigest(),
        "implementation_sha256": {name: sha256(ROOT / name) for name in (
            "agent/bailian_client.py", "agent/controlled_loop.py", "agent/tool_executor.py",
            "agent/matlab_bridge.py", "agent/matlab/ema_agent_worker.m", "scripts/run_controlled_agent.py", "agent/report_contract.py", "agent/basic_case_rules.py")},
    }
    if config['provider'] == 'deepseek_official':
        runtime_manifest['implementation_sha256']['agent/deepseek_client.py'] = sha256(ROOT / 'agent/deepseek_client.py')
    (folder / "runtime_manifest.json").write_text(json.dumps(runtime_manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    bridge = MatlabBridge(folder)
    started = time.monotonic()
    summary = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "status": "starting",
        "experiment_id": args.experiment_id, "task_id": selected["task_id"] if args.task_id else None,
        "group_id": selected["group_id"],
        "public_task_file_sha256": sha256(ROOT / "data/agent_visible/tasks_stage3_v1/tasks.json"),
        "purpose": "diagnostic_development" if args.task_id else "controlled_inspection_roundtrip",
        "model_requested": config["model"], "case_id": selected["case_id"],
        "new_physical_simulations": 0, "diagnostic_run": bool(args.task_id)}
    try:
        summary["matlab_runtime"] = bridge.start()
        summary["startup_duration_s"] = round(time.monotonic() - started, 6)
        executor = ToolExecutor(selected["case_id"], bridge)
        if args.task_id:
            record = run_loop(selected["question"], executor, config, folder, purpose="diagnostic_development",
                              checked_report=args.checked_report, shared_basic_rules=args.shared_basic_rules,
                              response_source=response_source)
        else:
            question = ("这是接口验收，不是故障诊断。对 " + selected["case_id"] +
                " 调用一次inspect_case；根据实际返回，最后只输出JSON对象，字段为tool_status、sample_count、"
                "time_range_s、independent_load_state、initial_reference_state、evidence_id。不计算残差、不做诊断。")
            record = run_loop(question, executor, config, folder,
                budget={"model_calls": 2, "tool_calls": 1, "wall_time_s": 120, "max_tokens": 512, "max_rejected_calls": 2},
                first_tool_choice={"type": "function", "function": {"name": "inspect_case"}},
                later_tool_choice="none", purpose="controlled_inspection_roundtrip",
                response_source=response_source)
        summary.update({"status": record["termination_reason"], "model_http_attempts": record["model_http_attempts"],
            "model_responses": record["model_responses"], "tool_attempts": record["tool_call_attempts"],
            "matlab_backend_calls": executor.backend_calls,
            "report_evidence_checked": record["report_evidence_checked"], "report_repairs": record["report_repairs"],
            "semantic_task_accepted": None})
        if args.task_id:
            (folder / "final_response.md").write_text(record["final_text"], encoding="utf-8")
            if record["report_evidence_checked"]:
                report = decode_report(record["final_text"])
                (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                (folder / "report_readable.md").write_text(render_report(report), encoding="utf-8")
        if not args.task_id:
            tools = [e for e in record["events"] if e["type"] == "tool_result"]
            try:
                final = parse_final_object(record["final_text"])
                actual = tools[0]["response"]
                conditions = {p["name"]: p["state"] for p in actual["preconditions"]}
                passed = (record["termination_reason"] == "model_finished" and len(tools) == 1
                    and tools[0]["backend_executed"] and actual["status"] == "ok"
                    and final["tool_status"] == actual["status"]
                    and final["sample_count"] == actual["result"]["channels"][0]["sample_count"]
                    and final["time_range_s"] == actual["result"]["time_range_s"]
                    and final["independent_load_state"] == conditions["independent_normal_load"]
                    and final["initial_reference_state"] == conditions["independent_initial_reference"]
                    and final["evidence_id"] == actual["evidence"]["id"])
            except (GuardError, KeyError, TypeError, ValueError, IndexError):
                passed = False
            summary["roundtrip_passed"] = passed
    except Exception:
        summary["status"] = "runtime_setup_or_bridge_failed"
    finally:
        bridge.close()
        summary["end_to_end_s"] = round(time.monotonic() - started, 6)
        summary["worker_stopped_cleanly"] = (bridge.folder / "stopped.json").is_file()
        (folder / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({**summary, "run_directory": str(folder.relative_to(ROOT))}, ensure_ascii=True))
    return 0 if summary.get("roundtrip_passed") or args.task_id and summary["status"] in ("model_finished", "report_evidence_checked") else 1


if __name__ == "__main__":
    raise SystemExit(main())
