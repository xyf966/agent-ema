"""Check the source-only checkout without reading data or calling services."""
import ast
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'agent'))


def main():
    errors = []
    count = size = 0
    for path in ROOT.rglob('*'):
        if not path.is_file() or '.git' in path.relative_to(ROOT).parts:
            continue
        relative = path.relative_to(ROOT)
        if '__pycache__' in relative.parts:
            continue
        count += 1
        raw = path.read_bytes()
        size += len(raw)
        if relative.as_posix() not in {'README.md', '.gitignore', '.gitattributes'}:
            if relative.parts[0] not in {'agent', 'tools', 'scripts', 'evaluation', 'configs'}:
                errors.append('unexpected_path:' + relative.as_posix())
            if path.suffix not in {'.py', '.m', '.ps1', '.json'}:
                errors.append('non_source_file:' + relative.as_posix())
        if path.name in {'observations_v1_manifest.json', 'boundary_release_index.json'}:
            errors.append('case_index:' + relative.as_posix())
        try:
            value = raw.decode('utf-8-sig')
            if path.suffix == '.py':
                ast.parse(value)
            elif path.suffix == '.json':
                json.loads(value)
            patterns = (r'\bsk-[A-Za-z0-9_-]{20,}', r'\bgh[pousr]_[A-Za-z0-9]{30,}',
                        r'\bgithub_pat_[A-Za-z0-9_]{30,}',
                        r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
            if any(re.search(pattern, value) for pattern in patterns):
                errors.append('credential_pattern:' + relative.as_posix())
        except (UnicodeError, SyntaxError, ValueError):
            errors.append('invalid_source:' + relative.as_posix())
    from bailian_client import load_config, load_tools
    from deepseek_client import validate_config
    validate_config(load_config())
    schemas = sum(len(load_tools(ROOT / folder)) for folder in ('tools/registry', 'tools/registry_stage4'))
    report = {'passed': not errors and schemas == 12, 'files': count, 'bytes': size,
              'validated_tool_schemas': schemas, 'errors': errors,
              'llm_requests': 0, 'matlab_calls': 0, 'new_simulations': 0}
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
