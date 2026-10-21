"""Offline scripted loop checks with archived real tool data; zero live calls."""
from copy import deepcopy
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import read_json, sha256
from controlled_loop import run_loop
from tool_executor import ToolExecutor


def main():
    candidates = [p for p in (ROOT / "results/EXP-20261020-019/runtime_checks").glob("*/acceptance.json") if read_json(p)["passed"]]
    assert len(candidates) == 1
    cases = read_json(candidates[0].parent / "tool_records.json")
    folder = ROOT / "results/EXP-20261020-019/loop_checks" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    checks = []

    def check(name, value):
        checks.append({"name": name, "passed": bool(value)})

    for case in cases:
        expected = case["records"]

        class ArchivedBackend:
            def __init__(self):
                self.index = 0

            def call(self, name, arguments, timeout_s=45):
                wanted = expected[self.index]
                assert name == wanted["tool"] and arguments == wanted["arguments"]
                self.index += 1
                return deepcopy(wanted["response"])

        class ScriptedModel:
            def __init__(self):
                self.index = 0
                self.choices = []
                self.schemas = []

            def __call__(self, config, messages, **kwargs):
                self.choices.append(kwargs["tool_choice"])
                self.schemas.append(kwargs["tools"])
                self.index += 1
                chosen = []
                if self.index == 1:
                    chosen = expected[:6]
                elif self.index == 2 and case["comparison_required"]:
                    chosen = expected[6:]
                if chosen:
                    content = {"role": "assistant", "content": "", "tool_calls": [
                        {"id": "offline_" + str(self.index) + "_" + str(k), "type": "function",
                         "function": {"name": r["tool"], "arguments": json.dumps(r["arguments"])}}
                        for k, r in enumerate(chosen)]}
                else:
                    # Deliberately invalid report: test the phase and failure
                    # handling without manufacturing a successful diagnosis.
                    content = {"role": "assistant", "content": "OFFLINE DELIVERY MARKER"}
                return {}, {"choices": [{"message": content, "finish_reason": "stop"}]}

        config = read_json(ROOT / "configs/llm_stage4_frozen_v1.json")
        config["call_budget"]["report_repair_limit"] = 0
        backend = ArchivedBackend(); model = ScriptedModel()
        execution = ToolExecutor(case["case_id"], backend, registry_dir=ROOT / "tools/registry_stage4")
        trace = run_loop("OFFLINE CONTROL FIXTURE; NOT A LIVE DIAGNOSIS", execution, config,
            folder / case["case_id"], budget={"model_calls": 3, "tool_calls": 20, "wall_time_s": 10,
                                             "max_tokens": 4096, "max_rejected_calls": 2},
            model_call=model, checked_report=True, shared_basic_rules=True, stage4_rules=True,
            response_source="scripted_model_archived_tools_no_live_calls",
            provider_config_path=ROOT / "configs/llm_stage4_frozen_v1.json")
        prefix = case["case_id"] + "_"
        phases = [i for i, e in enumerate(trace["events"]) if e["type"] == "report_phase"]
        preceding = sum(e["type"] == "tool_result" for e in trace["events"][:phases[0]]) if phases else -1
        check(prefix + "gate_after_all_required_tool_results", len(phases) == 1 and preceding == len(expected))
        check(prefix + "new_registry_hash_recorded", trace["tool_registry_sha256"] == sha256(ROOT / "tools/registry_stage4/tool_registry_v1.json"))
        check(prefix + "schema_sent_matches_executor", all(s == execution.tools for s in model.schemas))
        check(prefix + "stage4_rules_in_system_message", "EMA-STAGE4-RULES-1.0" in trace["messages"][0]["content"])
        check(prefix + "report_only_after_required_evidence", model.choices == ([None, None, "none"] if case["comparison_required"] else [None, "none"]))
        check(prefix + "invalid_delivery_not_accepted_as_diagnosis", trace["termination_reason"] == "report_validation_failed"
              and not trace["report_evidence_checked"] and not trace["diagnostic_task_scored"])
    result = {"passed": all(c["passed"] for c in checks), "check_count": len(checks),
              "checks_passed": sum(c["passed"] for c in checks), "checks": checks,
              "live_model_calls": 0, "real_matlab_calls": 0, "new_simulations": 0,
              "scope": "scripted_control_fixtures_not_Agent_performance"}
    (folder / "acceptance.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ["passed", "checks_passed", "check_count"]}))
    print(folder.relative_to(ROOT).as_posix())
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
