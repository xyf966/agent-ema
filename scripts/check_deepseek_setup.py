"""Official DeepSeek preflight; --live permits two tiny protocol probes only."""
from datetime import datetime, timezone
import argparse
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'agent'), str(ROOT/'scripts')]
from bailian_client import load_config
from check_bailian_setup import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    if load_config()['provider'] != 'deepseek_official':
        raise SystemExit('DEEPSEEK_PROVIDER_NOT_SELECTED')
    report = run(args.live)
    report['purpose'] = 'official_deepseek_connection_and_six_schema_probe_not_diagnosis'
    report['prepared_utc'] = datetime.now(timezone.utc).isoformat()
    folder = ROOT/'results/EXP-20261020-008/setup_checks'/uuid.uuid4().hex
    folder.mkdir(parents=True)
    path = folder/'report.json'
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':report['status'],'provider':report['provider'],
        'model':report['model_requested'],'key_present':report['api_key_present'],
        'requests':report['http_requests_attempted'],'responses':report['llm_responses_received'],
        'report':str(path.relative_to(ROOT))}))


if __name__ == '__main__':
    main()
