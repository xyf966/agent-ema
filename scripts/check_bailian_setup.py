"""Offline by default. --live sends at most two protocol probes, no diagnosis."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import ClientError, chat_completion, load_config, load_tools, read_api_key, read_json, sha256


def run(live=False):
    config = load_config()
    tools = load_tools()
    tasks = read_json(ROOT / "data/agent_visible/tasks_stage3_v1/tasks.json")
    case_id = tasks["tasks"][0]["case_id"]
    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "purpose": "stage_3_step_1_connection_and_tool_schema_probe",
        "provider": config["provider"], "base_url": config["base_url"],
        "model_requested": config["model"],
        "provider_config_sha256": sha256(ROOT / "configs/llm_provider.json"),
        "generation_settings": config["generation_settings"],
        "model_version_frozen": config["model_version_frozen"],
        "api_key_present": bool(read_api_key()), "registered_tool_count": len(tools),
        "live_requested": live, "http_requests_attempted": 0,
        "llm_responses_received": 0, "diagnostic_agent_runs": 0,
        "matlab_tools_executed": 0, "new_physical_simulations": 0,
        "connectivity_verified": False, "tool_call_schema_verified": False,
        "tool_execution_roundtrip_verified": False, "probes": [],
    }
    if not live:
        report["status"] = "offline_ready" if report["api_key_present"] else "offline_ready_missing_api_key"
        return report
    if not report["api_key_present"]:
        report["status"] = "missing_api_key_no_network_request"
        return report
    probes = [
        {"name": "connection", "messages": [{"role": "user", "content": "Reply with exactly EMA_API_READY."}]},
        {"name": "tool_schema", "messages": [{"role": "user", "content":
            "Call inspect_case for " + case_id + ". This is a protocol check; do not invent tool results."}],
         "tools": tools, "tool_choice": {"type": "function", "function": {"name": "inspect_case"}}},
    ]
    for probe in probes:
        started = time.perf_counter()
        entry = {"name": probe["name"]}
        report["http_requests_attempted"] += 1
        try:
            payload, response = chat_completion(config, probe["messages"],
                tools=probe.get("tools"), tool_choice=probe.get("tool_choice"), max_tokens=256)
            report["llm_responses_received"] += 1
            # Headers and reasoning_content are deliberately excluded from saved records.
            message = response["choices"][0]["message"]
            entry.update({"request": payload, "response_id": response.get("id"),
                "model_returned": response.get("model"), "usage": response.get("usage"),
                "message": {k: message.get(k) for k in ("role", "content", "tool_calls")},
                "finish_reason": response["choices"][0].get("finish_reason")})
            if probe["name"] == "connection":
                passed = not message.get("tool_calls") and (message.get("content") or "").strip() == "EMA_API_READY"
                report["connectivity_verified"] = True
            else:
                calls = message.get("tool_calls") or []
                passed = len(calls) == 1 and calls[0].get("type") == "function"
                if passed:
                    function = calls[0]["function"]
                    passed = function["name"] == "inspect_case" and json.loads(function["arguments"]) == {"case_id": case_id}
                report["tool_call_schema_verified"] = passed
            entry["passed"] = passed
        except ClientError as error:
            entry.update({"passed": False, "error_code": str(error), "error_details": error.details})
        except (KeyError, TypeError, ValueError, IndexError):
            entry.update({"passed": False, "error_code": "MALFORMED_PROBE_RESPONSE"})
        entry["duration_ms"] = round((time.perf_counter() - started) * 1000, 3)
        report["probes"].append(entry)
        if not entry["passed"]:
            break
    report["status"] = "protocol_probes_passed" if len(report["probes"]) == 2 and all(p["passed"] for p in report["probes"]) else "protocol_probe_failed"
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="At most 2 real API requests; no retries or MATLAB calls")
    args = parser.parse_args()
    try:
        report = run(args.live)
    except (ClientError, OSError, KeyError, ValueError, TypeError):
        print(json.dumps({"status": "local_setup_invalid", "http_requests_attempted": 0}))
        return 1
    folder = ROOT / "results/EXP-20261020-001/setup_checks" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "api_key_present": report["api_key_present"],
        "http_requests_attempted": report["http_requests_attempted"], "llm_responses_received": report["llm_responses_received"],
        "report": str((folder / "report.json").relative_to(ROOT))}, ensure_ascii=True))
    return 0 if report["status"] in ("offline_ready", "offline_ready_missing_api_key", "protocol_probes_passed") else 2


if __name__ == "__main__":
    raise SystemExit(main())
