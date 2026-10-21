"""Create separate boundary adapters from frozen, unchanged numerical tools.

This source preparation script is research-only. It never reads private cases.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / "tools/private"


def replace_once(text, old, new):
    assert text.count(old) == 1, (old, text.count(old))
    return text.replace(old, new)


def write_new(path, text):
    with path.open("x", encoding="utf-8") as stream:
        stream.write(text)


def main():
    code = (PRIVATE / "compute_residual_core.m").read_text(encoding="utf-8-sig")
    code = code.replace("compute_residual_core", "compute_boundary_core")
    code = code.replace("EMA-RESIDUAL-1.0", "EMA-BOUNDARY-RESIDUAL-1.0")
    code = replace_once(code, "ismember(mode,{'none','prescribed_command'})", "ismember(mode,{'none','prescribed_command','recorded_assumption'})")
    code = replace_once(code, "if strcmp(mode,'prescribed_command')", "if ismember(mode,{'prescribed_command','recorded_assumption'})")
    code = replace_once(code, "[command,commandHash] = read_residual_input(release,manifest,'command');", """[command,commandHash] = read_residual_input(release,manifest,'command');
            if strcmp(mode,'recorded_assumption')
                [assumedLoad,assumptionInfo,assumptionHash] = read_boundary_assumption(release,manifest);
                command.compensation_time_s = assumedLoad.time_s;
                command.compensation_force_N = assumedLoad.external_force_N;
                command.compensation_direct_torque_Nm = assumedLoad.direct_torque_Nm;
                commandHash = tool_sha256([commandHash '|' assumptionHash '|' assumptionInfo.assumption_id],'text');
            end""")
    code = replace_once(code, "if k==4, basis = 'command_derived_compensation_assumption'; end", """if k==4
            basis = 'command_derived_compensation_assumption';
            if strcmp(mode,'recorded_assumption'), basis = 'recorded_diagnostic_assumption_not_measurement'; end
        end""")
    code = replace_once(code, "if d.loadKnown\n        response.warnings{end+1} = 'COMPENSATION_IS_COMMAND_ASSUMPTION';", """if d.loadKnown
        response.warnings{end+1} = 'COMPENSATION_IS_COMMAND_ASSUMPTION';
        if strcmp(mode,'recorded_assumption')
            response.warnings{end} = 'COMPENSATION_IS_RECORDED_DIAGNOSTIC_ASSUMPTION';
        end""")
    write_new(PRIVATE / "compute_boundary_core.m", code)
    code = (PRIVATE / "read_validated_bundle.m").read_text(encoding="utf-8-sig")
    code = code.replace("read_validated_bundle", "read_boundary_bundle").replace("compute_residual_core", "compute_boundary_core")
    code = code.replace("{'none','prescribed_command'}", "{'none','prescribed_command','recorded_assumption'}")
    write_new(PRIVATE / "read_boundary_bundle.m", code)
    code = (PRIVATE / "locate_anomalies_core.m").read_text(encoding="utf-8-sig")
    code = code.replace("locate_anomalies_core", "locate_boundary_core").replace("read_validated_bundle", "read_boundary_bundle")
    code = code.replace("EMA-LOCATE-1.0", "EMA-BOUNDARY-LOCATE-1.0")
    write_new(PRIVATE / "locate_boundary_core.m", code)
    code = (PRIVATE / "plot_evidence_core.m").read_text(encoding="utf-8-sig")
    code = code.replace("plot_evidence_core", "plot_boundary_core").replace("read_validated_bundle", "read_boundary_bundle")
    code = code.replace("locate_anomalies_core", "locate_boundary_core").replace("render_evidence_v1", "render_boundary_evidence")
    code = code.replace("EMA-PLOT-1.0", "EMA-BOUNDARY-PLOT-1.0")
    code = replace_once(code, "mode = 'none';\n    if isfield(r,'torque_known_load_Nm'), mode = 'prescribed_command'; end", "mode = parent.result.load_assumption;")
    write_new(PRIVATE / "plot_boundary_core.m", code)
    code = (PRIVATE / "render_evidence_v1.m").read_text(encoding="utf-8-sig")
    code = code.replace("render_evidence_v1", "render_boundary_evidence").replace("EMA-PLOT-1.0", "EMA-BOUNDARY-PLOT-1.0")
    old_title = "\u8f6c\u77e9\u5e73\u8861\uff08\u89c4\u5b9a\u8d1f\u8f7d\u6307\u4ee4\u8865\u507f\u5047\u8bbe\uff09"
    code = code.replace(old_title, "\u8f6c\u77e9\u5e73\u8861\uff08\u663e\u5f0f\u8d1f\u8f7d\u8865\u507f\u5047\u8bbe\uff09")
    code = replace_once(code, "if strcmp(mode,'prescribed_command')\n    note", "if ismember(mode,{'prescribed_command','recorded_assumption'})\n    note")
    code = replace_once(code, "xlabel(layout,note,", """if strcmp(mode,'recorded_assumption')
    note = 'Compensation: separately recorded diagnostic assumption, not actual load measurement. Ideal-simulation thresholds only.';
end
xlabel(layout,note,""")
    write_new(PRIVATE / "render_boundary_evidence.m", code)
    registry = ROOT / "tools/registry_stage4"
    registry.mkdir()
    original = json.loads((ROOT / "tools/registry/tool_registry_v1.json").read_text(encoding="utf-8-sig"))
    original["registry_version"] = "EMA-TOOLS-STAGE4-1.0"
    original["entrypoint"] = "ema_tool_stage4"
    original["scope"] = "development_boundary_and_legacy_tool_layer"
    original["current_agent_worker_switched"] = False
    for tool in original["tools"]:
        path = ROOT / "tools/registry" / tool["schema_file"]
        spec = json.loads(path.read_text(encoding="utf-8-sig"))
        if tool["name"] == "compute_residual_bundle":
            spec["parameters"]["properties"]["load_assumption"]["enum"].append("recorded_assumption")
            spec["description"] += " For approved boundary cases recorded_assumption selects a separate diagnostic setting; prescribed_command uses the actual prescribed-command record."
        target = registry / tool["schema_file"]
        write_new(target, json.dumps(spec, ensure_ascii=False, indent=2) + "\n")
        tool["schema_sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
        tool["version"] = "EMA-STAGE4-ADAPTER-1.0"
    write_new(registry / "tool_registry_v1.json", json.dumps(original, ensure_ascii=False, indent=2) + "\n")
    print("Created five independent boundary adapters and a separate six-tool registry; legacy files unchanged.")


if __name__ == "__main__":
    main()
