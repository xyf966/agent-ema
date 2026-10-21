"""Execute the frozen five-task development batch once each. No simulation."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import read_json, sha256
from run_stage4_agent import load_frozen

OUT = ROOT / "results/EXP-20261020-020"


def write(path, value, *, exclusive=False):
    with path.open("x" if exclusive else "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")


def main():
    if OUT.exists():
        raise SystemExit("BATCH_DIRECTORY_EXISTS_PRESERVE_ATTEMPTS_NO_AUTOMATIC_RERUN")
    tasks, config, protocol, manifest = load_frozen()
    receipt = read_json(ROOT / "results/EXP-20261020-019/freeze_receipt.json")
    rubric = ROOT / "data/evaluation_private/EXP-20261020-019/rubric.json"
    assert sha256(rubric) == receipt["private_rubric_sha256"]
    OUT.mkdir(parents=True)
    protected = {}
    for folder in ["data", "results", "tools", "matlab", "archive/source_snapshot",
                   "agent", "evaluation", "configs", "scripts", "provenance"]:
        for path in (ROOT / folder).rglob("*"):
            if path.is_file() and OUT not in path.parents:
                with path.open("rb") as stream:
                    protected[path.relative_to(ROOT).as_posix()] = hashlib.file_digest(stream, "sha256").hexdigest()
    write(OUT / "protected_hashes_before.json", protected, exclusive=True)
    registration = {"experiment_id": "EXP-20261020-020", "user_stage": 4, "step": 4,
        "registered_at_utc": datetime.now(timezone.utc).isoformat(), "tasks": tasks,
        "public_manifest_sha256": sha256(ROOT / "data/agent_visible/tasks_stage4_v1/manifest.json"),
        "private_rubric_sha256": receipt["private_rubric_sha256"], "protocol": protocol,
        "frozen_runtime_files": manifest["frozen_files_sha256"],
        "new_simulations": 0, "attempts_per_task": 1,
        "failure_policy": "Keep the first attempt, including failures; no automatic task rerun or case-specific feedback."}
    write(OUT / "preregistration.json", registration, exclusive=True)
    progress = {"status": "running", "completed_tasks": [], "current_task": None}
    write(OUT / "progress.json", progress)
    started = time.monotonic()
    for task in tasks:
        progress["current_task"] = task["task_id"]
        write(OUT / "progress.json", progress)
        log = OUT / (task["task_id"] + "_runner.log")
        with log.open("xb") as stream:
            process = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/run_stage4_agent.py"),
                "--live", "--task-id", task["task_id"], "--experiment-id", "EXP-20261020-020"],
                cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        matches = [p for p in (OUT / "runs").glob("*/summary.json") if read_json(p).get("task_id") == task["task_id"]]
        if len(matches) != 1:
            progress["status"] = "batch_control_failure"
            progress["error"] = "ONE_SUMMARY_REQUIRED_NO_TASK_RERUN"
            write(OUT / "progress.json", progress)
            return 1
        summary = read_json(matches[0])
        row = {"task_id": task["task_id"], "case_id": task["case_id"], "exit_code": process.returncode,
               "summary_path": matches[0].relative_to(ROOT).as_posix(), "status": summary["status"],
               "model_responses": summary["llm_calls"], "real_tool_calls": summary.get("real_tool_calls", 0)}
        progress["completed_tasks"].append(row)
        write(OUT / "progress.json", progress)
        print(json.dumps(row), flush=True)
    progress["status"] = "five_attempts_finished_pending_evaluation"
    progress["current_task"] = None
    progress["elapsed_s"] = round(time.monotonic() - started, 6)
    write(OUT / "progress.json", progress)
    after = {name: sha256(ROOT / name) for name in protected}
    write(OUT / "protected_hashes_after_execution.json", after, exclusive=True)
    assert after == protected, "EXISTING_PROTECTED_FILE_DRIFT"
    load_frozen()
    print(json.dumps({"status": progress["status"], "tasks": 5, "protected_files_unchanged": len(protected)}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
