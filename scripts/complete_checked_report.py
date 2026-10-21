"""Bounded report continuation on an intact real tool trace; no new tools.

Source evidence is revalidated against archived MATLAB envelopes, then sent
unchanged. No labels, rubric or private evaluator can be read by this program.
"""

import argparse
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "scripts")]
from bailian_client import ClientError, chat_completion, load_config, load_tools, read_json, sha256
from controlled_loop import SYSTEM_MESSAGE, system_message
from report_contract import check_report, decode_report, render_report, repair_message
from run_controlled_agent import experiment_id, public_tasks
from tool_executor import canonical, validate_response

COMPLETION_PROMPT = """以上是同一匿名开发任务的真实工具结果及尚未交付完整的模型整理稿。
请现在根据这些已取得的结果，直接交付EMA-REPORT-1.0完整JSON报告，不再调用工具。
说明保持简短，method_ids只列实际用到的规则，不要大段重复工具返回；候选机理与检出事实要分开。
不能添加未观测信息，不得把补偿假设当测量或把检测时刻当真实起点。"""

INTERPRETATION_REVIEW = """请按以下所有案例共用的物理一致性规则复核并重交完整JSON，不输出准备稿，不调用工具：
1. 摘要和正文须一致。初值相减前已存在且之后恒定的偏置会完全抵消，不能作为后续新增残差的单独来源；未知初始参考只保留该偏置与其他异常共存的可能。
2. 未报警不能用于排除未测量的共同源干扰，也不能证明采集独立。采集前提由元数据得到；未报警仅说明当前适用判据未检出对应不一致。
3. 位置差分和速度积分比较的是运动学关系。外载或摩擦改变本身不破坏该关系；不能凭另一个残差未报警但接近阈值，就把机械或负载原因列成有观测支持的候选。无实际证据的传动变化等只可列为待补充信息，不要用“任何原因都有可能”取代有依据的候选。
4. applicability须用简短文字说明计算/解释前提及未核实部分，而不只复制interpretation_basis。保留已有准确数字、未知信息、补偿假设、图引用和理想阈值边界。
本次只依据已有观测和通用关系修正解释，不添加标签、真实起点、幅值或其他未观测信息。"""


def prepare_source(folder):
    trace = read_json(folder / "trace.json")
    task = next(t for t in public_tasks() if t["case_id"] == trace["case_id"])
    if trace["response_source"] != "bailian_live" or trace["termination_reason"] != "model_finished":
        raise ValueError("SOURCE_MUST_BE_REAL_COMPLETED_DEVELOPMENT_TRACE")
    if trace["messages"][:2] != [{"role": "system", "content": SYSTEM_MESSAGE}, {"role": "user", "content": task["question"]}]:
        raise ValueError("SOURCE_INITIAL_CONTEXT_MISMATCH")
    messages = deepcopy(trace["messages"][:2])
    records = []
    versions = {t["name"]: t["version"] for t in read_json(ROOT / "tools/registry/tool_registry_v1.json")["tools"]}
    for event in trace["events"]:
        if event["type"] == "model_response":
            if event["request"]["messages"] != messages or event["request"]["tools"] != load_tools():
                raise ValueError("SOURCE_REQUEST_NOT_RECONSTRUCTIBLE")
            messages.append(event["message"])
        elif event["type"] == "tool_result":
            if not event["backend_executed"]:
                raise ValueError("SOURCE_CONTAINS_REJECTED_CALL")
            archived = read_json(folder / "worker_records" / f"response_{len(records)+1:04d}.json")
            if archived["bridge_status"] != "ok" or archived["response"] != event["response"]:
                raise ValueError("SOURCE_MATLAB_RECORD_MISMATCH")
            validate_response(event["response"], event["tool"], task["case_id"], versions[event["tool"]])
            records.append(event)
            messages.append({"role": "tool", "tool_call_id": event["tool_call_id"], "content": canonical(event["response"])})
        else:
            raise ValueError("UNSUPPORTED_SOURCE_EVENT")
    if messages != trace["messages"]:
        raise ValueError("SOURCE_MESSAGES_MISMATCH")
    messages[0] = {"role": "system", "content": system_message(True)}
    messages.append({"role": "user", "content": COMPLETION_PROMPT})
    return task, messages, records


def complete_report(messages, records, case_id, config, folder, *, model_call=chat_completion,
                    response_source="bailian_live", max_requests=2, wall_limit_s=180):
    if type(max_requests) is not int or max_requests not in (1, 2) or not 0 < wall_limit_s <= 180:
        raise ValueError("INVALID_COMPLETION_BUDGET")
    folder.mkdir(parents=True, exist_ok=True)
    trace = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "response_source": response_source,
        "purpose": "report_continuation_on_verified_prior_evidence_not_new_autonomous_run",
        "case_id": case_id, "budget": {"model_requests": max_requests, "wall_time_s": wall_limit_s, "request_timeout_s": 120,
                                      "max_tokens": 4096, "report_repairs": max_requests - 1},
        "model_http_attempts": 0, "model_responses": 0, "report_repairs": 0, "new_matlab_tool_calls": 0,
        "new_physical_simulations": 0, "events": [], "messages": deepcopy(messages), "final_text": "",
        "report_evidence_checked": False, "semantic_task_accepted": None, "status": "running"}
    started = time.monotonic()

    def save():
        trace["elapsed_s"] = round(time.monotonic() - started, 6)
        (folder / "continuation.json").write_text(json.dumps(trace, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    save()
    while trace["model_http_attempts"] < max_requests:
        remaining = wall_limit_s - (time.monotonic() - started)
        if remaining <= 0:
            trace["status"] = "wall_time_budget_exhausted"
            break
        trace["model_http_attempts"] += 1
        save()
        try:
            payload, response = model_call(config, deepcopy(trace["messages"]), tools=load_tools(), tool_choice="none",
                max_tokens=4096, timeout_s=min(120, remaining))
        except ClientError as error:
            trace["events"].append({"type": "model_error", "error_code": str(error), "details": error.details})
            trace["status"] = "model_request_failed"
            break
        trace["model_responses"] += 1
        choice = response["choices"][0]
        message = choice["message"]
        trace["events"].append({"type": "model_response", "request": payload, "response": response})
        content = message.get("content") or ""
        trace["final_text"] = content
        (folder / f"report_attempt_{trace['model_responses']:02d}.txt").write_text(content, encoding="utf-8")
        trace["messages"].append({"role": "assistant", "content": content})
        if time.monotonic() - started >= wall_limit_s:
            trace["status"] = "wall_time_budget_exhausted"
            break
        if choice.get("finish_reason") == "length" or message.get("tool_calls"):
            trace["status"] = "truncated_or_tool_call_in_report_only_mode"
            break
        checked = check_report(content, records, case_id)
        trace["events"].append({"type": "report_check", "result": checked})
        if checked["passed"]:
            trace["status"] = "report_evidence_checked"
            trace["report_evidence_checked"] = True
            report = decode_report(content)
            (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            (folder / "report_readable.md").write_text(render_report(report), encoding="utf-8")
            break
        if trace["model_responses"] == 1 and max_requests > 1:
            feedback = {"role": "user", "content": repair_message(checked)}
            trace["events"].append({"type": "report_feedback", "message": feedback})
            trace["messages"].append(feedback)
            trace["report_repairs"] += 1
        trace["status"] = "report_validation_failed"
        save()
    (folder / "final_response.md").write_text(trace["final_text"], encoding="utf-8")
    save()
    return trace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-experiment-id", required=True, type=experiment_id)
    parser.add_argument("--source-run-id", required=True)
    parser.add_argument("--experiment-id", required=True, type=experiment_id)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--review-continuation-id", help="One explicitly logged generic physical-review revision; no automatic retries")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{32}", args.source_run_id):
        raise SystemExit("INVALID_SOURCE_RUN_ID")
    source = ROOT / "results" / args.source_experiment_id / "runs" / args.source_run_id
    task, messages, records = prepare_source(source)
    parent = None
    if args.review_continuation_id:
        if not re.fullmatch(r"[0-9a-f]{32}", args.review_continuation_id):
            raise SystemExit("INVALID_REVIEW_PARENT_ID")
        parent = ROOT / "results" / args.experiment_id / "continuations" / args.review_continuation_id / "continuation.json"
        previous = read_json(parent)
        parent_check = check_report(previous["final_text"], records, task["case_id"])
        permitted_lint = all(i["code"] == "NO_ALARM_DOES_NOT_EXCLUDE_UNMEASURED_ALTERNATIVES" for i in parent_check["issues"])
        if (not previous["report_evidence_checked"] or previous["model_responses"] != 1
                or previous["messages"][:len(messages)] != messages
                or not permitted_lint):
            raise SystemExit("INVALID_REVIEW_PARENT_TRACE")
        review_feedback = INTERPRETATION_REVIEW if parent_check["passed"] else repair_message(parent_check)
        messages = deepcopy(previous["messages"]) + [{"role": "user", "content": review_feedback}]
    config = load_config()
    if not args.live:
        print(json.dumps({"status": "offline_ready", "source_verified": True, "source_real_tool_calls": len(records),
                          "new_tools": 0, "new_model_calls": 0}))
        return 0
    folder = ROOT / "results" / args.experiment_id / "continuations" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    link = {"created_utc": datetime.now(timezone.utc).isoformat(), "source_trace": str((source / "trace.json").relative_to(ROOT)),
        "source_trace_sha256": sha256(source / "trace.json"), "task_id": task["task_id"], "group_id": task["group_id"],
        "model_requested": config["model"], "provider_config_sha256": sha256(ROOT / "configs/llm_provider.json"),
        "source_real_tool_calls": len(records), "new_matlab_tool_calls": 0, "new_physical_simulations": 0,
        "initial_messages": messages}
    if parent:
        link.update({"review_parent_trace": str(parent.relative_to(ROOT)), "review_parent_sha256": sha256(parent),
                     "review_feedback": review_feedback, "review_is_generic_physics_not_private_answer": True})
    (folder / "source_link.json").write_text(json.dumps(link, ensure_ascii=False, indent=2), encoding="utf-8")
    (folder / "config_snapshot.json").write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
    trace = complete_report(messages, records, task["case_id"], config, folder,
                            max_requests=1 if parent else 2, wall_limit_s=120 if parent else 180)
    print(json.dumps({"directory": str(folder.relative_to(ROOT)), "status": trace["status"],
        "model_requests": trace["model_http_attempts"], "model_responses": trace["model_responses"],
        "report_repairs": trace["report_repairs"], "new_matlab_tool_calls": 0, "elapsed_s": trace["elapsed_s"]}))
    return 0 if trace["report_evidence_checked"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
