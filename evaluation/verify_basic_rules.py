"""Offline checks of the shared evidence gate, never new LLM or MATLAB calls."""

from copy import deepcopy
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "agent"), str(ROOT / "evaluation")]
from basic_case_rules import FINAL_PHASE_MESSAGE, evidence_ready
from bailian_client import load_config
from controlled_loop import run_loop
from tool_executor import ToolExecutor
from verify_controlled_loop import ScriptedModel, model_message
from verify_report_contract import fixture


def main():
    folder = ROOT / "results/EXP-20261020-005/validation" / uuid.uuid4().hex
    folder.mkdir(parents=True)
    case, records, report = fixture()
    checks = []

    def check(name, ok):
        checks.append({"name": name, "passed": bool(ok)})

    check("all_actual_categories_and_three_applicable_channels_ready", evidence_ready(records))
    check("default_uncompensated_chain_not_three_applicable_channels", not evidence_ready(records[:6]))
    check("no_plot_not_ready", not evidence_ready([r for r in records if r["tool"] != "plot_evidence"]))
    check("no_methods_not_ready", not evidence_ready([r for r in records if r["tool"] != "lookup_method_conditions"]))
    check("rejected_results_not_counted", not evidence_ready([{**r, "backend_executed": False} for r in records]))
    wrong_plot = deepcopy(records)
    wrong_plot[-1]["response"]["result"]["residual_evidence_id"] = "wrong"
    check("plot_for_other_bundle_does_not_complete_chain", not evidence_ready(wrong_plot))
    clipped = deepcopy(records)
    clipped[-2]["response"]["result"]["analysis_scope"]["effective_interval_s"] = [0.02, 0.7]
    check("clipped_alarm_not_full_summary", not evidence_ready(clipped))
    incomplete = deepcopy(records)
    incomplete[-2]["response"]["result"]["channels"][-1]["status"] = "insufficient_data"
    check("insufficient_channel_does_not_complete_three_channels", not evidence_ready(incomplete))
    clear = deepcopy(records)
    for c in clear[-2]["response"]["result"]["channels"]:
        c["alarmed"] = False
    check("gate_does_not_depend_on_fault_or_alarm_result", evidence_ready(clear))

    class ArchivedBackend:
        def __init__(self):
            self.index = 0

        def call(self, name, args, timeout_s=45):
            row = records[self.index]
            assert row["tool"] == name and row["arguments"] == args
            self.index += 1
            return deepcopy(row["response"])

    calls = [("archived" + str(i), r["tool"], json.dumps(r["arguments"])) for i, r in enumerate(records)]
    class RecordingModel(ScriptedModel):
        def __init__(self):
            super().__init__([model_message(calls), model_message(content=json.dumps(report))])
            self.choices = []

        def __call__(self, config, messages, **kwargs):
            self.choices.append(kwargs["tool_choice"])
            return super().__call__(config, messages, **kwargs)

    model = RecordingModel()
    execution = ToolExecutor(case, ArchivedBackend())
    trace = run_loop("OFFLINE UNIT FIXTURE NOT A REAL DIAGNOSTIC TASK", execution, load_config(), folder / "phase",
        budget={"model_calls": 3, "tool_calls": 20, "wall_time_s": 10, "max_tokens": 4096, "max_rejected_calls": 2},
        model_call=model, checked_report=True, shared_basic_rules=True, response_source="archived_tools_scripted_model_fixture")
    check("tool_selection_auto_then_report_only", model.choices == [None, "none"])
    check("phase_message_logged_and_sent_exactly_once", sum(e["type"] == "report_phase" for e in trace["events"]) == 1
          and model.messages[-1][-1] == {"role": "user", "content": FINAL_PHASE_MESSAGE})
    check("valid_answer_kept_without_manual_repair", trace["termination_reason"] == "report_evidence_checked"
          and trace["report_repairs"] == 0 and trace["diagnostic_task_scored"] is False)
    result = {"scope": "offline_archived_tool_replay_only_no_live_calls", "checks": checks,
        "checks_passed": sum(c["passed"] for c in checks), "checks_total": len(checks),
        "all_passed": all(c["passed"] for c in checks), "new_model_calls": 0, "new_matlab_calls": 0}
    (folder / "acceptance.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("all_passed", "checks_passed", "checks_total")}))
    print(str(folder.relative_to(ROOT)))
    return 0 if result["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
