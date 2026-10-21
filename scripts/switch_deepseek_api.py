"""Bounded model-switch preparation/probe; no diagnosis, MATLAB or private inputs."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'agent'), str(ROOT / 'scripts')]
from bailian_client import load_config, load_tools, read_json, sha256
from check_bailian_setup import run

EXP = ROOT / 'results/EXP-20261020-007'
MODEL = 'deepseek-v4-flash-0731'


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    if not args.live:
        if EXP.exists():
            raise SystemExit('MODEL_SWITCH_ALREADY_PREPARED')
        protected = {p.relative_to(ROOT).as_posix(): sha256(p)
                     for directory in ('data', 'results', 'archive', 'matlab', 'tools')
                     for p in (ROOT / directory).rglob('*') if p.is_file()}
        provider = load_config()
        protocol = read_json(ROOT / 'configs/research_protocol.json')
        save(EXP / 'protected_before.json', protected)
        save(EXP / 'provider_before.json', provider)
        save(EXP / 'research_protocol_before.json', protocol)
        provider.update(model=MODEL, model_selection='user_selected_return_to_api',
            model_version_frozen=False, model_identifier_is_dated_snapshot=True,
            status='deepseek_api_selected_protocol_verification_pending',
            connectivity_verified=False, tool_call_schema_verified=False, function_calling_verified=False,
            current_model_connectivity_verified=False, current_model_function_calling_verified=False,
            model_returned=None, function_calling_verification_scope='current_model_pending; historical_results_preserved',
            latest_model_switch_experiment='EXP-20261020-007',
            note='User returned to cloud API and selected exact model deepseek-v4-flash-0731. Existing Beijing workspace and user environment credential source retained. Historical diagnosis counters are cumulative, not current-model acceptance. No local model diagnosis is being launched.')
        save(ROOT / 'configs/llm_provider.json', provider)
        protocol.update(llm_model=MODEL, llm_provider='aliyun_bailian',
            llm_model_switch_reason='user_returned_to_api_and_selected_deepseek_v4_flash_0731',
            llm_api_connectivity_verified=False, llm_tool_call_schema_verified=False,
            llm_tool_execution_roundtrip_verified=False,
            llm_agent_connection_scope='new_model_protocol_pending; previous_model_results_retained',
            llm_agent_connected=False, latest_model_switch_experiment='EXP-20261020-007')
        save(ROOT / 'configs/research_protocol.json', protocol)
        save(EXP / 'preregistration.json', {
            'created_utc':datetime.now(timezone.utc).isoformat(), 'model':MODEL,
            'purpose':'API model switch; two protocol probes only; not stage3 step6 acceptance',
            'max_requests':2, 'max_output_tokens_per_request':256, 'automatic_retries':0,
            'generation_settings':provider['generation_settings'],
            'provider_config_sha256':sha256(ROOT / 'configs/llm_provider.json'),
            'task_sha256':sha256(ROOT / 'data/agent_visible/tasks_stage3_v1/tasks.json'),
            'registry_sha256':sha256(ROOT / 'tools/registry/tool_registry_v1.json'),
            'sources':{p:sha256(ROOT / p) for p in ('agent/bailian_client.py','scripts/check_bailian_setup.py','scripts/switch_deepseek_api.py')},
            'official_references':['https://help.aliyun.com/en/model-studio/deepseek-v4-flash','https://help.aliyun.com/zh/model-studio/deepseek-api'],
            'private_inputs_sent':False,'new_simulations':0,'matlab_calls':0})
        offline = run(False)
        save(EXP / 'offline_precheck.json', offline)
        assert load_config()['model'] == MODEL and len(load_tools()) == 6
        print(json.dumps({'model':MODEL,'status':offline['status'],'key_present':offline['api_key_present'],'requests':0}))
        return
    plan = read_json(EXP / 'preregistration.json')
    assert sha256(ROOT / 'configs/llm_provider.json') == plan['provider_config_sha256']
    report = run(True)
    folder = EXP / 'setup_checks' / uuid.uuid4().hex
    save(folder / 'report.json', report)
    print(json.dumps({'status':report['status'],'requests':report['http_requests_attempted'],
        'responses':report['llm_responses_received'],'probes':[{'name':p['name'],'passed':p['passed'],
        'model_returned':p.get('model_returned'),'error_code':p.get('error_code'),'error_details':p.get('error_details')}
        for p in report['probes']], 'report':str((folder/'report.json').relative_to(ROOT))}))


if __name__ == '__main__':
    main()
