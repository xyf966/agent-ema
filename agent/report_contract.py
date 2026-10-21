"""Generic report checks against this run's actual tools, never private answers.

Passing checks establishes structure/provenance/numeric consistency only.
Candidate explanations still require a separate research-side semantic review.
"""

import json
import math
import re

from tool_executor import GuardError, strict_json

VERSION = "EMA-REPORT-1.1"
CHECKER_REVISION = "EMA-REPORT-CHECK-1.1.1"
ID_PATTERN = r"\b(?:EV|CTX|METHOD|ANOM|BUNDLE|PLOT)-[0-9a-f]{64}(?:-(?:[0-9]+|scope))?(?![a-z0-9])"
REPORT_INSTRUCTION = """
最终交付约定EMA-REPORT-1.1（所有案例共用，无案例答案）：
工具仍由你自主选择。证据足够后直接交付一个JSON对象，不输出准备稿、思维过程或“接下来写报告”。
必须有以下字段（英文键名固定；说明文字用简洁中文；不要复制本说明作答）：
version="EMA-REPORT-1.1", case_id, bundle_id,
evidence_refs={inspection_id:实际inspect证据ID, context_ids:[实际CTX证据ID], method_ids:[实际METHOD证据ID]},
finding:范围受限的主要发现,
channels:[每个检测通道一个对象，包含quantity,status,unit,alarmed,first_exceed_s,first_alarm_s,
threshold,valid_max_abs,valid_rms,valid_points,valid_motion_intervals_s,applicability,
residual_evidence_id,alarm_evidence_id],
candidate_assessment:解释证据支持何种变化及不能确认何种原因,
candidates:[{hypothesis:具体相容机理而非重复报警事实,basis:观测与方法依据,caveat:不能唯一确诊的原因,evidence_ids:[实际证据ID]}],
load_assumption:与所选bundle.result.load_assumption完全相同的字符串值，不能加解释,
assumptions:一个非空字符串（不是数组或对象），在此说明补偿来源及采集前提,
unknowns:[{condition:实际工具preconditions中state=unknown的原始name,state:"unknown",impact:说明字符串,evidence_id:该条件对应的实际来源ID}],
needed_information:[能区分候选或补齐缺口的额外信息],
time_interpretation:{kind:"detector_confirmation_not_true_onset",explanation:首次连续报警的含义及无报警时刻不适用},
no_alarm_interpretation:未报警的适用范围而非整体健康保证,
scope:{threshold_version:实际检测器版本,ideal_simulation_only:true,noise_validated:false,
hardware_validated:false,full_envelope_validated:false,explanation:当前验证范围},
plot:{plot_id,residual_evidence_id,png_ref,editable_fig_ref}。
三通道以所选bundle对应locate_anomalies返回的channels为准，数值和status如实保留。
没有报警的时间用null；不适用/缺数据的alarmed用null，不能填false，缺失数值用null。
valid_motion_intervals_s来自该次检测的analysis_scope。unit必须用工具原单位。
标量可合理舍入，不能改数量级；time保留至少毫秒。残差和报警ID必须分别对应同bundle同quantity。
input/工况/方法和图的ID均须来自本次真实返回；unknown必须保留已查到的未知前提并说明影响。
unknowns必留inspect_case中的未知条件；可以增加其他工具明确给出的unknown条件，但name和证据须对应。
如果后续实际计算已将某条件确认为satisfied，不能再引用通用方法的unknown把它列为当前缺口。
工况条目independent_load/initial_reference可用对应CTX证据，condition仍用independent_normal_load/independent_initial_reference。
physical_sensor_validation=false表示已知尚未进行实物验证，写在assumptions或scope.explanation；不能新造一个unknown条件名称。
effective_interval_s是查询/分析时间窗；真正有效运动段是analysis_scope.valid_motion_intervals_s。
概述中称为“有效运动区间”时必须使用这些实际分段，不能把整个查询窗当作连续有效运动范围。
报警时至少给一项具体相容候选；无报警可以candidates=[]，但candidate_assessment仍须说明边界。
plot必须是所选bundle对应的实际图引用。给出相容原因，不推断未观测的真实注入时间、幅值或唯一机理。
"""


def decode_report(text):
    value = text.strip()
    match = re.fullmatch(r"```(?:json)?[ \t]*\r?\n(.*?)\r?\n```", value, re.DOTALL | re.IGNORECASE)
    if match:
        value = match[1]
    obj = strict_json(value)
    if not isinstance(obj, dict):
        raise GuardError("REPORT_NOT_OBJECT")
    try:
        json.dumps(obj, allow_nan=False)
    except ValueError:
        raise GuardError("NONFINITE_REPORT_NUMBER") from None
    return obj


def evidence_items(response):
    evidence = response.get("evidence", [])
    return evidence if isinstance(evidence, list) else [evidence]


def close_number(actual, expected, *, time=False):
    if expected is None or expected == []:
        return actual is None
    return (type(actual) in (int, float) and math.isfinite(actual)
            and math.isclose(actual, expected, rel_tol=0 if time else 0.005,
                             abs_tol=0.0005 if time else 0))


def unknown_sources(actual):
    """Condition-to-source links from actual public tools; no inferred unknowns.

    Method prerequisites are generic. A satisfied case-specific prerequisite
    takes priority over a method's still-unchecked generic prerequisite.
    """
    resolved = {p.get('name') for r in actual if r.get('tool') != 'lookup_method_conditions'
                for p in r.get('preconditions', []) if p.get('state') == 'satisfied'}
    sources = {}
    mandatory = set()
    for r in actual:
        for p in r.get('preconditions', []):
            if p.get('state') != 'unknown' or p.get('name') in resolved:
                continue
            name, source = p.get('name'), p.get('evidence_id')
            if isinstance(name, str) and isinstance(source, str):
                sources.setdefault(name, set()).add(source)
                if r.get('tool') == 'inspect_case':
                    mandatory.add(name)
        if r.get('tool') == 'query_operating_context':
            mapping = {'independent_load':'independent_normal_load',
                       'initial_reference':'independent_initial_reference'}
            for entry in r.get('result', {}).get('records', []):
                name = mapping.get(entry.get('name'))
                if name and entry.get('value', {}).get('available') is False and isinstance(entry.get('evidence_id'), str):
                    sources.setdefault(name, set()).add(entry['evidence_id'])
    return {name:sorted(ids) for name,ids in sorted(sources.items())}, sorted(mandatory)


def text_fields(value, field='report'):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from text_fields(child, field+'.'+key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from text_fields(child, field+f'[{index}]')
    elif isinstance(value, str):
        yield field, value


def check_report(text, records, case_id):
    issues = []
    actual = [r['response'] for r in records if r.get('backend_executed')
              and isinstance(r.get('response'), dict) and r['response'].get('case_id') in (case_id, '')]
    sources, mandatory = unknown_sources(actual)
    repair_context = {'text_fields':['finding','candidate_assessment','assumptions','no_alarm_interpretation'],
                      'unknown_condition_sources':sources, 'required_unknown_conditions':mandatory,
                      'load_assumption_values_observed':sorted({r['result']['load_assumption'] for r in actual
                          if r.get('tool') == 'compute_residual_bundle' and r.get('result', {}).get('load_assumption') is not None})}

    def require(ok, code, field):
        if not ok:
            issues.append({"code": code, "field": field})

    def result():
        return {"version": VERSION, "passed": not issues, "issues": issues,
                "scope": "structure_actual_evidence_numbers_and_narrow_scope_wording_not_semantic_diagnosis",
                "repair_context":repair_context, "checker_revision":CHECKER_REVISION}

    try:
        report = decode_report(text)
    except (GuardError, ValueError, TypeError, RecursionError):
        require(False, "FINAL_JSON_REQUIRED", "report")
        return result()
    required = {"version", "case_id", "bundle_id", "evidence_refs", "finding", "channels",
                "candidate_assessment", "candidates", "load_assumption", "assumptions", "unknowns",
                "needed_information", "time_interpretation", "no_alarm_interpretation", "scope", "plot"}
    for key in sorted(required - report.keys()):
        require(False, "MISSING_FIELD", key)
    if issues:
        return result()
    def exclusion_lint(value, field):
        if isinstance(value, dict):
            for k, v in value.items():
                exclusion_lint(v, field + "." + k)
        elif isinstance(value, list):
            for i, v in enumerate(value):
                exclusion_lint(v, f"{field}[{i}]")
        elif isinstance(value, str):
            for phrase in re.findall(r"(?:未报警|无报警|正常)[^。；\n]{0,40}(?:排除了|排除部分)", value):
                if not re.search(r"不能|无法|不可|不应|不意味着", phrase):
                    require(False, "NO_ALARM_DOES_NOT_EXCLUDE_UNMEASURED_ALTERNATIVES", field)
    require(report["version"] == VERSION, "VERSION_MISMATCH", "version")
    require(report["case_id"] == case_id, "CASE_MISMATCH", "case_id")
    require(all(c == case_id for c in re.findall(r"CASE-[0-9a-f]{32}", text)), "OTHER_CASE_CITED", "report")
    for key in ("finding", "candidate_assessment", "assumptions", "no_alarm_interpretation"):
        require(isinstance(report[key], str) and bool(report[key].strip()), "TEXT_REQUIRED", key)
    for key in ("channels", "unknowns", "candidates", "needed_information"):
        require(isinstance(report[key], list), "LIST_REQUIRED", key)
    for key in ("evidence_refs", "time_interpretation", "scope", "plot"):
        require(isinstance(report[key], dict), "OBJECT_REQUIRED", key)
    if issues:
        return result()
    actual = [r["response"] for r in records if r.get("backend_executed") and isinstance(r.get("response"), dict)]
    actual = [r for r in actual if r.get("case_id") in (case_id, "")]
    known_ids = {e["id"] for r in actual for e in evidence_items(r) if isinstance(e, dict) and "id" in e}
    known_ids.update(r["result"]["bundle_id"] for r in actual if r.get("tool") == "compute_residual_bundle"
                     and isinstance(r.get("result", {}).get("bundle_id"), str))
    require(set(re.findall(ID_PATTERN, text)).issubset(known_ids), "UNOBTAINED_ID", "report")
    refs = report["evidence_refs"]
    for key, tool, many in [("inspection_id", "inspect_case", False),
                            ("context_ids", "query_operating_context", True),
                            ("method_ids", "lookup_method_conditions", True)]:
        values = refs.get(key, []) if many else [refs.get(key)]
        allowed = {e["id"] for r in actual if r.get("tool") == tool for e in evidence_items(r)}
        require(isinstance(values, list) and bool(values) and all(isinstance(v, str) and v in allowed for v in values),
                "EVIDENCE_CATEGORY_MISSING_OR_WRONG", "evidence_refs." + key)
    bundles = [r for r in actual if r.get("tool") == "compute_residual_bundle" and r.get("status") in ("ok", "insufficient_data")
               and r["result"].get("bundle_id") == report["bundle_id"]]
    alarms = [r for r in actual if r.get("tool") == "locate_anomalies" and r.get("status") in ("ok", "insufficient_data")
              and r["result"].get("residual_evidence_id") == report["bundle_id"]]
    plots = [r for r in actual if r.get("tool") == "plot_evidence" and r.get("status") == "ok"
             and r["result"].get("residual_evidence_id") == report["bundle_id"]]
    require(bool(bundles and alarms and plots), "BUNDLE_ALARM_PLOT_CHAIN_REQUIRED", "bundle_id")
    if not bundles or not alarms or not plots:
        return result()
    bundle, alarm = bundles[-1]["result"], alarms[-1]["result"]
    repair_context['expected_load_assumption'] = bundle['load_assumption']
    repair_context['analysis_interval_s'] = alarm['analysis_scope']['effective_interval_s']
    repair_context['valid_motion_intervals_s'] = alarm['analysis_scope']['valid_motion_intervals_s']
    number = r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?'
    range_label = re.compile(r'('+number+r')\s*[–—~至-]\s*('+number+r')\s*(?:s|秒)\s*(?:的)?有效运动(?:区间|范围)')
    valid_intervals = alarm['analysis_scope']['valid_motion_intervals_s']
    for field, content in text_fields(report):
        for match in range_label.finditer(content):
            interval = [float(match[1]), float(match[2])]
            require(any(all(close_number(a,b,time=True) for a,b in zip(interval,valid)) for valid in valid_intervals),
                    'QUERY_WINDOW_IS_NOT_VALID_MOTION', field)
    # Only approve full-scope summaries: clipped alarm queries need clipped statistics,
    # which the current six tools do not return. Do not compare unlike intervals.
    require(alarm["analysis_scope"]["effective_interval_s"] == bundle["time_range_s"],
            "MATCHING_FULL_ANALYSIS_SCOPE_REQUIRED", "channels")
    require(report["load_assumption"] == bundle["load_assumption"], "COMPENSATION_MISMATCH", "load_assumption")
    channel_map = {c["quantity"]: c for c in bundle["channels"]}
    alarm_map = {c["quantity"]: c for c in alarm["channels"]}
    repair_context['channel_evidence_links'] = {
        q:{'residual_evidence_id':channel_map[q]['evidence_id'],
           'alarm_evidence_ids':sorted(e['id'] for e in evidence_items(alarms[-1])
               if e.get('quantity') == q and e.get('parent_evidence_id') == channel_map[q]['evidence_id'])}
        for q in alarm_map if q in channel_map}
    require(all(isinstance(c, dict) for c in report["channels"]), "CHANNEL_OBJECT_REQUIRED", "channels")
    if any(not isinstance(c, dict) for c in report["channels"]):
        return result()
    quantities = [c.get("quantity") for c in report["channels"]]
    require(all(isinstance(q, str) for q in quantities) and len(quantities) == len(alarm_map)
            and set(quantities) == set(alarm_map), "ALL_CHANNELS_ONCE_REQUIRED", "channels")
    for c in report["channels"]:
        q = c.get("quantity")
        if not isinstance(q, str) or q not in alarm_map:
            continue
        v, a = channel_map[q], alarm_map[q]
        for key in ("status", "unit"):
            require(c.get(key) == a[key], "CHANNEL_METADATA_MISMATCH", q + "." + key)
        expected_alarm = a["alarmed"] if isinstance(a["alarmed"], bool) else None
        require(c.get("alarmed") is expected_alarm, "ALARM_STATE_MISMATCH", q + ".alarmed")
        for key in ("first_exceed_s", "first_alarm_s"):
            require(key in c and close_number(c.get(key), a[key], time=True), "TIME_MISMATCH", q + "." + key)
        for key, expected in [("threshold", a.get("threshold")), ("valid_max_abs", v.get("valid_max_abs")),
                               ("valid_rms", v.get("valid_rms"))]:
            require(key in c and close_number(c.get(key), expected), "NUMERIC_MISMATCH", q + "." + key)
        require(type(c.get("valid_points")) is int and c["valid_points"] == a.get("valid_points"),
                "POINT_COUNT_MISMATCH", q + ".valid_points")
        intervals = c.get("valid_motion_intervals_s")
        expected_intervals = alarm["analysis_scope"]["valid_motion_intervals_s"]
        require(isinstance(intervals, list) and len(intervals) == len(expected_intervals)
                and all(isinstance(x, list) and len(x) == 2 and all(close_number(y, z, time=True)
                    for y, z in zip(x, e)) for x, e in zip(intervals, expected_intervals)),
                "VALID_INTERVAL_MISMATCH", q + ".valid_motion_intervals_s")
        require(c.get("residual_evidence_id") == v["evidence_id"], "RESIDUAL_ID_MISMATCH", q)
        ids = {e["id"] for e in evidence_items(alarms[-1]) if e.get("quantity") == q
               and e.get("parent_evidence_id") == v["evidence_id"]}
        require(isinstance(c.get("alarm_evidence_id"), str) and c["alarm_evidence_id"] in ids, "ALARM_ID_MISMATCH", q)
        require(isinstance(c.get("applicability"), str) and bool(c["applicability"].strip()), "APPLICABILITY_REQUIRED", q)
    candidates = report["candidates"]
    require(bool(candidates) or not alarm["any_alarm"], "CANDIDATE_REQUIRED_FOR_ALARM", "candidates")
    for i, candidate in enumerate(candidates):
        require(isinstance(candidate, dict) and all(isinstance(candidate.get(k), str) and candidate[k].strip()
                for k in ("hypothesis", "basis", "caveat")) and isinstance(candidate.get("evidence_ids"), list)
                and bool(candidate["evidence_ids"]) and all(isinstance(v, str) and v in known_ids for v in candidate["evidence_ids"]),
                "CANDIDATE_WITH_ACTUAL_BASIS_REQUIRED", f"candidates[{i}]")
    unknowns = report["unknowns"]
    require(all(isinstance(v, dict) and isinstance(v.get("condition"), str) and v["condition"] in sources
                and v.get("state") == "unknown" and isinstance(v.get("impact"), str) and v["impact"].strip()
                and isinstance(v.get("evidence_id"), str) and v["evidence_id"] in sources[v['condition']]
                and v['evidence_id'] in known_ids for v in unknowns),
            "UNKNOWN_RECORD_INVALID_OR_UNOBSERVED", "unknowns")
    for name in mandatory:
        require(any(isinstance(v, dict) and v.get("condition") == name and v.get("state") == "unknown"
                and isinstance(v.get("impact"), str) and bool(v["impact"].strip())
                and isinstance(v.get("evidence_id"), str) and v["evidence_id"] in sources[name] for v in unknowns),
                "OBSERVED_UNKNOWN_MUST_REMAIN", "unknowns." + name)
    require(bool(report["needed_information"]) and all(isinstance(v, str) and v.strip() for v in report["needed_information"]),
            "ADDITIONAL_INFORMATION_REQUIRED", "needed_information")
    timing = report["time_interpretation"]
    require(timing.get("kind") == "detector_confirmation_not_true_onset" and isinstance(timing.get("explanation"), str)
            and bool(timing["explanation"].strip()), "DETECTOR_TIME_SCOPE_REQUIRED", "time_interpretation")
    scope = report["scope"]
    require(scope.get("threshold_version") == alarm["threshold_version"] and scope.get("ideal_simulation_only") is True
            and all(scope.get(k) is False for k in ("noise_validated", "hardware_validated", "full_envelope_validated"))
            and isinstance(scope.get("explanation"), str) and bool(scope["explanation"].strip()), "IDEAL_BASELINE_SCOPE_REQUIRED", "scope")
    plot = report["plot"]
    require(any(all(plot.get(k) == p["result"].get(k) for k in ("plot_id", "residual_evidence_id", "png_ref", "editable_fig_ref"))
                for p in plots), "PLOT_REFERENCE_MISMATCH", "plot")
    # A narrow, conservative wording check, not a general semantic evaluator.
    exclusion_lint(report, "report")
    return result()


def repair_message(check):
    # Field requirements and source links are reconstructed only from actual
    # public returns. Never supply private rubrics, case labels or diagnoses.
    return ("报告尚未通过通用结构与实际证据核对。请直接返回补齐后的完整JSON，不输出准备说明。"
            "仍只依据本轮工具实际返回，不允许读取文件或私有答案；若证据不足，保留缺失。"
            "NO_ALARM_DOES_NOT_EXCLUDE_UNMEASURED_ALTERNATIVES表示不得用正常/未报警排除没有独立检验的原因；"
            "请修正该字段中的排除主张，保留当前判据未检出的范围。问题清单："
            + json.dumps(check["issues"][:30], ensure_ascii=False)
            + "。TEXT_REQUIRED需非空字符串，不是数组；COMPENSATION_MISMATCH需使用原始补偿枚举值。"
            "UNKNOWN_RECORD_INVALID_OR_UNOBSERVED需逐项核对原始条件名及其证据；已知未验证的硬件限制写入scope/assumptions。"
            "QUERY_WINDOW_IS_NOT_VALID_MOTION需区分分析窗和实际有效分段。以下字段/来源要求仅来自本轮真实工具，不是私有答案："
            "ALARM_ID_MISMATCH或RESIDUAL_ID_MISMATCH须按quantity从channel_evidence_links逐项复制对应ID，不要按后缀编号猜测，也不要把另一通道或另一轮检测的ID换进来。"
            + json.dumps(check.get('repair_context', {}), ensure_ascii=False))


def render_report(report):
    """Display supplied model fields verbatim; never invent explanatory claims."""
    lines = ["# 模型诊断报告", "", report["finding"], "", "## 通道结果", "",
             "| 通道 | 状态 | 报警 | 首次连续报警/s | 最大绝对残差 | RMS | 阈值 | 单位 |",
             "|---|---|---|---|---|---|---|---|"]
    for c in report["channels"]:
        lines.append("| " + " | ".join(str(c[k]) for k in ("quantity", "status", "alarmed", "first_alarm_s", "valid_max_abs", "valid_rms", "threshold", "unit")) + " |")
    for c in report["channels"]:
        lines.extend(["", f"{c['quantity']}：{c['applicability']}",
                      "有效区间/s：" + json.dumps(c["valid_motion_intervals_s"]),
                      "残差/报警证据：" + c["residual_evidence_id"] + "；" + c["alarm_evidence_id"]])
    lines.extend(["", "## 候选与限制", "", report["candidate_assessment"]])
    for c in report["candidates"]:
        lines.extend(["", c["hypothesis"], c["basis"], c["caveat"], "证据：" + "；".join(c["evidence_ids"])])
    lines.extend(["", "## 假设、未知信息与范围", "", "load_assumption=" + report["load_assumption"], report["assumptions"]])
    for u in report["unknowns"]:
        lines.append(f"\n{u['condition']}（{u['state']}）：{u['impact']}；{u['evidence_id']}")
    lines.extend(["", "需要补充：" + "；".join(report["needed_information"]), report["time_interpretation"]["explanation"],
                  report["no_alarm_interpretation"], report["scope"]["explanation"], json.dumps(report["scope"], ensure_ascii=False),
                  "", "## 证据引用", "", json.dumps(report["evidence_refs"], ensure_ascii=False, indent=2),
                  "", json.dumps(report["plot"], ensure_ascii=False, indent=2)])
    return "\n".join(lines) + "\n"
