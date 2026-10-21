"""Offline adversarial repair checks; no live model, MATLAB or private rubric."""
from copy import deepcopy
import json
from pathlib import Path
import sys
import uuid

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'agent'),str(ROOT/'evaluation')]
from report_contract import check_report, repair_message, unknown_sources
from verify_report_contract import fixture


def main():
    case,records,base=fixture()
    response={r['tool']:r['response'] for r in records}
    checks=[]

    def check(name,ok):
        checks.append({'name':name,'passed':bool(ok)})

    def evaluate(report,source=records):
        return check_report(json.dumps(report,ensure_ascii=False),source,case)

    check('baseline_still_valid',evaluate(base)['passed'])
    changed=deepcopy(base); changed['assumptions']=['source explanation']
    result=evaluate(changed)
    check('list_assumptions_rejected_with_type_guidance',not result['passed']
          and any(i['code']=='TEXT_REQUIRED' for i in result['issues']) and '非空字符串' in repair_message(result))
    changed=deepcopy(base); changed['load_assumption']='descriptive prescribed_command explanation'
    result=evaluate(changed)
    check('compensation_requires_original_enum_and_public_expected_value',not result['passed']
          and result['repair_context']['expected_load_assumption']==base['load_assumption'])
    methods=response['lookup_method_conditions']
    noise=next(p for p in methods['preconditions'] if p['name']=='noise_calibration_available' and p['state']=='unknown')
    changed=deepcopy(base); changed['unknowns'].append({'condition':noise['name'],'state':'unknown',
        'impact':'Noise applicability is not validated.','evidence_id':noise['evidence_id']})
    check('observed_method_unknown_with_matching_source_allowed',evaluate(changed)['passed'])
    wrong=deepcopy(changed); wrong['unknowns'][-1]['evidence_id']=base['evidence_refs']['inspection_id']
    check('unrelated_but_real_evidence_does_not_prove_condition',not evaluate(wrong)['passed'])
    context=response['query_operating_context']['result']['records']
    independent=next(r for r in context if r['name']=='independent_load')
    changed=deepcopy(base)
    next(u for u in changed['unknowns'] if u['condition']=='independent_normal_load')['evidence_id']=independent['evidence_id']
    check('context_missing_load_source_allowed_with_canonical_condition',evaluate(changed)['passed'])
    wrong=deepcopy(changed)
    next(u for u in wrong['unknowns'] if u['condition']=='independent_normal_load')['evidence_id']=next(r for r in context if r['name']=='load_command')['evidence_id']
    check('command_source_not_a_missing_load_source',not evaluate(wrong)['passed'])
    changed=deepcopy(base); changed['unknowns'].append({'condition':'physical_sensor_validation','state':'unknown',
        'impact':'Hardware not validated.','evidence_id':next(r for r in context if r['name']=='signal_acquisition')['evidence_id']})
    result=evaluate(changed)
    check('known_false_hardware_validation_not_inferred_as_unknown_name',not result['passed']
          and 'physical_sensor_validation' not in result['repair_context']['unknown_condition_sources'])
    changed=deepcopy(base); changed['scope']['explanation']+=' Hardware validation has not been performed.'
    check('known_hardware_limit_allowed_in_scope',evaluate(changed)['passed'])
    changed=deepcopy(base); changed['unknowns']=[]
    check('mandatory_inspection_unknowns_cannot_be_dropped',not evaluate(changed)['passed'])
    sources,_=unknown_sources([r['response'] for r in records])
    check('case_resolved_motion_condition_overrides_generic_method_unknown','valid_motion_window' not in sources)
    changed=deepcopy(base); stale=next(p for p in methods['preconditions'] if p['name']=='valid_motion_window')
    changed['unknowns'].append({'condition':'valid_motion_window','state':'unknown','impact':'stale method precondition','evidence_id':stale['evidence_id']})
    check('stale_method_unknown_is_rejected_after_actual_computation',not evaluate(changed)['passed'])
    alarm=response['locate_anomalies']['result']; interval=alarm['analysis_scope']['effective_interval_s']
    valid=alarm['analysis_scope']['valid_motion_intervals_s'][0]
    changed=deepcopy(base); changed['finding']=f'在{interval[0]}–{interval[1]} s有效运动区间内进行分析。'
    result=evaluate(changed)
    check('query_window_mislabelled_as_motion_rejected',any(i['code']=='QUERY_WINDOW_IS_NOT_VALID_MOTION' for i in result['issues']))
    check('scope_feedback_uses_actual_intervals',result['repair_context']['valid_motion_intervals_s']==alarm['analysis_scope']['valid_motion_intervals_s'])
    changed['finding']=f'查询窗为{interval[0]}–{interval[1]} s；其中的有效段见channels。'
    check('query_window_correctly_named_allowed',evaluate(changed)['passed'])
    changed['finding']=f'在{valid[0]}–{valid[1]} s有效运动区间内检验。'
    check('actual_motion_interval_allowed',evaluate(changed)['passed'])
    changed=deepcopy(base); changed['unknowns'].append({'condition':'invented_sensor','state':'unknown','impact':'invented','evidence_id':noise['evidence_id']})
    check('fabricated_name_still_rejected',not evaluate(changed)['passed'])
    before_report,before_records=deepcopy(base),deepcopy(records)
    evaluate(base)
    check('checker_never_rewrites_report_or_actual_results',base==before_report and records==before_records)
    text=repair_message(evaluate(base))
    check('feedback_does_not_include_private_answer_fields',all(s not in text for s in ('reference_class','expected_channels','required_claims','injected_','appliedFault')))
    changed=deepcopy(base); changed['channels'][0]['alarm_evidence_id']=changed['channels'][1]['alarm_evidence_id']
    result=evaluate(changed); channel=base['channels'][0]
    check('wrong_alarm_reference_still_rejected_with_actual_channel_link',not result['passed']
          and channel['alarm_evidence_id'] in result['repair_context']['channel_evidence_links'][channel['quantity']]['alarm_evidence_ids'])
    links=result['repair_context']['channel_evidence_links']
    check('feedback_links_bind_each_real_parent_not_guessed_suffixes',all(
          links[c['quantity']]['residual_evidence_id']==c['residual_evidence_id']
          and c['alarm_evidence_id'] in links[c['quantity']]['alarm_evidence_ids'] for c in base['channels']))
    result={'scope':'offline_controls_archived_tools_and_synthetic_reports_not_model_diagnosis',
        'checks':checks,'checks_passed':sum(c['passed'] for c in checks),'checks_total':len(checks),
        'all_passed':all(c['passed'] for c in checks),'new_model_calls':0,'new_matlab_calls':0,'new_simulations':0}
    folder=ROOT/'results/EXP-20261020-010/validation'/uuid.uuid4().hex; folder.mkdir(parents=True)
    (folder/'acceptance.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('all_passed','checks_passed','checks_total')}))
    print(folder.relative_to(ROOT))
    return 0 if result['all_passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
