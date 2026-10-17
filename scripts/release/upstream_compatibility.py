#!/usr/bin/env python3
"""Read-only structural compatibility gate; never certifies production data or behavior."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

UPSTREAM_URL = 'https://github.com/open-noodle/gallery'
UPSTREAM_BASE = 'da5480ae42b77db9cae729f2447ec9b3079ba4a7'
ROOT = Path(__file__).resolve().parents[2]
METHODS = {'get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace'}
ANNOTATIONS = {'description', 'summary', 'example', 'examples', 'title', 'deprecated'}


def retained_schema(before, after, location, failures):
    """Permit additive object fields/enum values; retain every existing wire shape."""
    if not isinstance(before, dict) or not isinstance(after, dict):
        if before != after:
            failures.append(location + ': shape changed')
        return
    if set(after.get('required', [])) - set(before.get('required', [])):
        failures.append(location + ': new required members; explicit compatibility review required')
    constraints = {'minimum', 'maximum', 'minLength', 'maxLength', 'pattern', 'format', 'nullable',
                   'minItems', 'maxItems', 'exclusiveMinimum', 'exclusiveMaximum', 'oneOf', 'allOf',
                   'anyOf', 'not', 'additionalProperties'}
    for constraint in (after.keys() - before.keys()) & constraints:
        failures.append(location + ': new ' + constraint + ' constraint; explicit compatibility review required')
    for key, value in before.items():
        if key in ANNOTATIONS:
            continue
        current = after.get(key)
        if key == 'properties':
            if not isinstance(current, dict):
                failures.append(location + ': properties missing')
                continue
            for name, schema in value.items():
                if name not in current:
                    failures.append(location + '.' + name + ': property removed')
                else:
                    retained_schema(schema, current[name], location + '.' + name, failures)
        elif key in {'enum', 'required'}:
            if not isinstance(current, list) or not set(value).issubset(current):
                failures.append(location + ': existing ' + key + ' member removed')
            if key == 'required' and isinstance(current, list) and set(current) != set(value):
                failures.append(location + ': required members changed; explicit compatibility review required')
        elif key in {'items', 'additionalProperties'} and isinstance(value, dict):
            retained_schema(value, current, location + '.' + key, failures)
        elif key not in after or current != value:
            failures.append(location + ': ' + key + ' changed')


def api_report(before, after):
    failures = []
    operations = 0
    changed = []
    for path, entry in before['paths'].items():
        for method, operation in entry.items():
            if method not in METHODS:
                continue
            operations += 1
            candidate = after.get('paths', {}).get(path, {}).get(method)
            location = method.upper() + ' ' + path
            if not candidate:
                failures.append(location + ': operation removed')
                continue
            if operation != candidate:
                changed.append(location)
            for key in ('operationId', 'security'):
                if operation.get(key) != candidate.get(key):
                    failures.append(location + ': ' + key + ' changed')
            parameters = {(p['in'], p['name']): p for p in operation.get('parameters', [])}
            candidate_parameters = {(p['in'], p['name']): p for p in candidate.get('parameters', [])}
            for identity, parameter in parameters.items():
                current = candidate_parameters.get(identity)
                if current is None:
                    failures.append(location + ': existing parameter removed')
                elif parameter.get('required', False) != current.get('required', False):
                    failures.append(location + ': parameter requirement changed')
                else:
                    retained_schema(parameter['schema'], current['schema'], location + ': parameter ' + identity[1], failures)
            for identity, parameter in candidate_parameters.items():
                if identity not in parameters and parameter.get('required', False):
                    failures.append(location + ': new required parameter')
            if 'requestBody' in operation:
                old_body = operation['requestBody']
                new_body = candidate.get('requestBody', {})
                if old_body.get('required', False) != new_body.get('required', False):
                    failures.append(location + ': body requirement changed')
                retained_content(old_body, new_body, location + ': request', failures)
            elif candidate.get('requestBody', {}).get('required', False):
                failures.append(location + ': new required body')
            for code, response in operation.get('responses', {}).items():
                if code not in candidate.get('responses', {}):
                    failures.append(location + ': response removed ' + code)
                else:
                    retained_content(response, candidate['responses'][code], location + ': response ' + code, failures)
    old_schemas = before.get('components', {}).get('schemas', {})
    new_schemas = after.get('components', {}).get('schemas', {})
    changed_schemas = []
    for name, schema in old_schemas.items():
        if name not in new_schemas:
            failures.append('schema ' + name + ': removed')
        else:
            retained_schema(schema, new_schemas[name], 'schema ' + name, failures)
            if schema != new_schemas[name]:
                changed_schemas.append(name)
    for name, security in before.get('components', {}).get('securitySchemes', {}).items():
        if after.get('components', {}).get('securitySchemes', {}).get(name) != security:
            failures.append('security scheme ' + name + ': changed')
    return {'status': 'PASS' if not failures else 'FAIL', 'upstreamOperations': operations,
            'changedOperations': changed, 'changedSchemas': changed_schemas, 'failures': failures,
            'limitation': 'Structural wire-contract retention only; authentication and runtime behavior require integration tests.'}


def retained_content(before, after, location, failures):
    for content_type, content in before.get('content', {}).items():
        current = after.get('content', {}).get(content_type)
        if current is None:
            failures.append(location + ': content type removed')
        else:
            retained_schema(content.get('schema', {}), current.get('schema', {}), location, failures)


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], stderr=subprocess.DEVNULL)


def migration_report(base):
    prefix = 'server/src/schema/migrations/'
    files = git('ls-tree', '-r', '--name-only', base, '--', prefix).decode().splitlines()
    if not files:
        raise RuntimeError('VERIFIED_UPSTREAM_MIGRATIONS_REQUIRED')
    failures = []
    for name in files:
        path = ROOT / name
        if not path.is_file() or path.is_symlink() or path.read_bytes() != git('show', base + ':' + name):
            failures.append(name)
    current = {path.relative_to(ROOT).as_posix() for path in (ROOT / prefix).glob('*.ts')}
    return {'status': 'PASS' if not failures else 'FAIL', 'upstreamFiles': len(files),
            'changedOrMissing': failures, 'additionalFiles': sorted(current - set(files)),
            'limitation': 'Byte retention does not replace migration execution on an isolated restored production database.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream-base', default=UPSTREAM_BASE)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.upstream_base):
        parser.error('a full immutable upstream SHA is required')
    base_api = json.loads(git('show', args.upstream_base + ':open-api/immich-openapi-specs.json'))
    current_api = json.loads((ROOT / 'open-api/immich-openapi-specs.json').read_text())
    migrations = migration_report(args.upstream_base)
    api = api_report(base_api, current_api)
    report = {'upstreamURL': UPSTREAM_URL, 'upstreamBase': args.upstream_base,
              'candidateHead': git('rev-parse', 'HEAD').decode().strip(),
              'workingTreeDirty': bool(git('status', '--porcelain')), 'migrations': migrations, 'api': api,
              'productionRestoredDatabase': 'NOT TESTED', 'physicalAndroid': 'NOT TESTED',
              'physicalIOS': 'NOT TESTED', 'productionNFS': 'NOT TESTED',
              'status': 'PASS' if api['status'] == migrations['status'] == 'PASS' else 'FAIL'}
    if args.report:
        with args.report.open('x') as file:
            json.dump(report, file, indent=2)
            file.write('\n')
    print(json.dumps(report, indent=2))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
