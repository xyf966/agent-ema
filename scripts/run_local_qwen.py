"""Probe the local model or run the existing controlled six-tool loop locally."""

import argparse
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import load_tools, sha256
from local_llm_client import CONFIG_PATH, chat_completion, load_config
from controlled_loop import parse_final_object, run_loop
from matlab_bridge import MatlabBridge
from tool_executor import ToolExecutor
from run_controlled_agent import public_tasks


def public_response(response):
    result = deepcopy(response)
    for choice in result.get("choices", []):
        message = choice.get("message", {})
        for key in ("reasoning_content", "reasoning"):
            message.pop(key, None)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("probe", "roundtrip", "diagnostic"), default="probe")
    parser.add_argument("--task-id", help="Required only for a full diagnostic development run")
    args = parser.parse_args()
    config = load_config()
    tasks = public_tasks()
    selected = next((task for task in tasks if task["task_id"] == args.task_id), None) if args.task_id else tasks[0]
    if selected is None or args.mode == "diagnostic" and not args.task_id:
        parser.error("Select an existing public task for diagnostic mode.")
    folder = ROOT / "results/local_qwen35_4b" / (args.mode + "_" + uuid.uuid4().hex)
    folder.mkdir(parents=True)
    (folder / "config_snapshot.json").write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
    report = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "mode": args.mode,
        "model": config["model"], "source_model": config["source_model"], "quantization": "Q4_K_M",
        "model_sha256": config["model_sha256"], "config_sha256": sha256(CONFIG_PATH),
        "new_physical_simulations": 0, "response_source": "local_llama_cpp_live", "passed": False}
    started = time.monotonic()
    try:
        if args.mode == "probe":
            config = deepcopy(config)
            config["generation_settings"]["enable_thinking"] = False
            payload, response = chat_completion(config, [{"role": "user", "content": "Reply with exactly EMA_LOCAL_READY."}], max_tokens=64, timeout_s=120)
            report["connection"] = {"request": payload, "response": public_response(response),
                "passed": (response["choices"][0]["message"].get("content") or "").strip() == "EMA_LOCAL_READY"}
            config["generation_settings"]["enable_thinking"] = True
            payload, response = chat_completion(config, [{"role": "user", "content":
                "This is a tool protocol check. Call inspect_case for " + selected["case_id"] + ". Do not invent a tool result."}],
                tools=load_tools(), tool_choice={"type": "function", "function": {"name": "inspect_case"}}, max_tokens=1024, timeout_s=180)
            calls = response["choices"][0]["message"].get("tool_calls") or []
            valid = (len(calls) == 1 and calls[0].get("type") == "function"
                and calls[0]["function"]["name"] == "inspect_case"
                and json.loads(calls[0]["function"]["arguments"]) == {"case_id": selected["case_id"]})
            report["tool_schema"] = {"request": payload, "response": public_response(response), "passed": valid}
            report["passed"] = report["connection"]["passed"] and valid
            report["scope"] = "connection_and_forced_tool_parameters_not_autonomous_diagnosis"
        else:
            bridge = MatlabBridge(folder)
            try:
                report["matlab_runtime"] = bridge.start()
                executor = ToolExecutor(selected["case_id"], bridge)
                kwargs = {"model_call": chat_completion, "response_source": "local_llama_cpp_live",
                          "provider_config_path": CONFIG_PATH}
                if args.mode == "diagnostic":
                    record = run_loop(selected["question"], executor, config, folder,
                        checked_report=True, shared_basic_rules=True, **kwargs)
                    report["passed"] = record["report_evidence_checked"]
                    report["semantic_task_accepted"] = None
                    (folder / "final_response.md").write_text(record["final_text"], encoding="utf-8")
                else:
                    question = ("这是接口验收。对 " + selected["case_id"] + " 调用一次inspect_case，然后只输出JSON对象，字段为"
                        "tool_status、sample_count、time_range_s、independent_load_state、initial_reference_state、evidence_id。"
                        "从真实工具返回提取，不计算残差，不做诊断。")
                    record = run_loop(question, executor, config, folder,
                        budget={"model_calls": 2, "tool_calls": 1, "wall_time_s": 300, "max_tokens": 4096, "max_rejected_calls": 2},
                        first_tool_choice={"type": "function", "function": {"name": "inspect_case"}},
                        later_tool_choice="none", purpose="local_deployment_inspection_roundtrip", **kwargs)
                    events = [event for event in record["events"] if event["type"] == "tool_result"]
                    actual = events[0]["response"]
                    preconditions = {item["name"]: item["state"] for item in actual["preconditions"]}
                    expected = {"tool_status": actual["status"], "sample_count": actual["result"]["channels"][0]["sample_count"],
                        "time_range_s": actual["result"]["time_range_s"], "independent_load_state": preconditions["independent_normal_load"],
                        "initial_reference_state": preconditions["independent_initial_reference"], "evidence_id": actual["evidence"]["id"]}
                    report["passed"] = (len(events) == 1 and events[0]["backend_executed"]
                        and actual["status"] == "ok" and parse_final_object(record["final_text"]) == expected)
                    report["expected_from_real_tool"] = expected
                    report["scope"] = "one_real_inspect_case_roundtrip_not_diagnosis_performance"
                report["termination_reason"] = record["termination_reason"]
                report["model_responses"] = record["model_responses"]
                report["matlab_backend_calls"] = executor.backend_calls
            finally:
                bridge.close()
    except Exception as error:
        report["error_type"] = type(error).__name__
        report["error_code"] = str(error)[:160]
    finally:
        report["elapsed_s"] = round(time.monotonic() - started, 3)
        path = folder / "acceptance.json"
        path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "mode": args.mode, "elapsed_s": report["elapsed_s"],
        "report": str(path), "error_code": report.get("error_code")}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
