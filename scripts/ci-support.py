"""Small Actions helpers: avoid equivalent successful runs and summarize evidence."""
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def api(path):
    request = Request(os.environ['GITHUB_API_URL'] + path, headers={
        'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    })
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def find_equivalent(current, runs):
    # A skipped duplicate must not become the evidence for another skip.
    # The caller verifies that the earlier run's real build/recheck succeeded.
    return [run for run in runs
            if run['id'] < current['id']
            and run['head_sha'] == current['head_sha']
            and run['head_branch'] == current['head_branch']
            and run['display_title'] == current['display_title']
            and run['status'] == 'completed' and run['conclusion'] == 'success']


def append_summary(content):
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a', encoding='utf-8') as output:
        output.write(content + '\n')


def guard():
    repository = os.environ['GITHUB_REPOSITORY']
    base = f'/repos/{repository}/actions'
    current = api(f'{base}/runs/{os.environ["GITHUB_RUN_ID"]}')
    previous = None
    # GitHub's explicit "Re-run jobs" remains available for an intentional rerun.
    # PR validation may check a different merge tree even for the same head SHA.
    if (int(os.environ.get('GITHUB_RUN_ATTEMPT', '1')) == 1
            and current['event'] in ('push', 'workflow_dispatch')):
        for page in range(1, 11):
            query = urlencode({'head_sha': current['head_sha'], 'per_page': 100, 'page': page})
            runs = api(f'{base}/workflows/{current["workflow_id"]}/runs?{query}')['workflow_runs']
            last_page = len(runs) < 100
            runs = [run for run in runs if run['event'] in ('push', 'workflow_dispatch')]
            for candidate in find_equivalent(current, runs):
                jobs = api(f'{base}/runs/{candidate["id"]}/jobs?per_page=100')['jobs']
                if any(job['name'] in ('build', 'Reused simulator UI checks')
                       and job['conclusion'] == 'success' for job in jobs):
                    artifacts = api(f'{base}/runs/{candidate["id"]}/artifacts?per_page=100')['artifacts']
                    if any(not artifact['expired'] and artifact['size_in_bytes'] > 0
                           and artifact['name'].startswith(('NeoEPGStation-iOS-', 'NeoEPGStation-Reused-UI-'))
                           for artifact in artifacts):
                        previous = candidate
                        break
            if previous or last_page:
                break
    with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as output:
        output.write(f'proceed={str(previous is None).lower()}\n')
    if previous:
        append_summary('## Duplicate verification skipped\n\n'
                       'The same commit and requested checks already succeeded. '
                       f'Use the [original run and artifacts]({previous["html_url"]}).\n\n'
                       'No new IPA was built. Use **Re-run all jobs** to deliberately repeat this run.')
    else:
        append_summary('## Verification scheduled\n\n'
                       f'Commit: `{current["head_sha"]}`\n\n'
                       'No equivalent successful verification was reused. '
                       'Failed runs do not suppress another attempt.')


def cell(value):
    return str(value).replace('|', '\\|').replace('\n', ' ').replace('\r', '')


def render_summary(directory, steps, scope, sha, reuse_run=''):
    lines = ['## Build and verification', '', f'- Requested checks: {cell(scope)}',
             f'- Workflow commit: `{sha}`']
    if reuse_run:
        lines += [f'- Source build run: `{reuse_run}`',
                  '- This run rechecks a saved application; **no new IPA** is generated.']
    else:
        ipa = steps.get('upload-ipa', {})
        ipa_name = 'NeoEPGStation.ipa'  # Existing builds remain readable.
        try:
            info = json.loads((directory / 'build-info.json').read_text(encoding='utf-8'))
            ipa_name = info.get('ipaFile', ipa_name)
        except (ValueError, OSError):
            pass
        url = ipa.get('outputs', {}).get('artifact-url', '')
        if ipa.get('outcome') == 'success' and url:
            lines += [f'- [Download {cell(ipa_name)}]({url}) (single file; no ZIP extraction).']
        else:
            lines += [f'- Installable IPA: `{cell(ipa_name)}` artifact, available only after successful packaging and upload.']
        lines += ['- Logs, screenshots, hashes and simulator application: `NeoEPGStation-iOS-*` diagnostic artifact.']
    for name in ('build-info.json', 'reused-build-info.json'):
        path = directory / name
        if path.exists():
            try:
                info = json.loads(path.read_text(encoding='utf-8'))
                lines += [f'- Application build: `{cell(info.get("build", "unknown"))}`; '
                          f'source commit: `{cell(info.get("commit", "unknown"))}`']
            except (ValueError, OSError):
                lines += [f'- Could not read `{name}`.']
    lines += ['', '### Steps', '', '| Step | Outcome |', '| --- | --- |']
    for name, value in steps.items():
        lines.append(f'| {cell(name)} | {cell(value.get("outcome", "unknown"))} |')
    lines += ['', '### Recorded test results', '', '| Result file | Result |', '| --- | --- |']
    count = 0
    for path in sorted(directory.glob('*.json')):
        try:
            value = json.loads(path.read_text(encoding='utf-8'))
        except (ValueError, OSError):
            lines.append(f'| `{cell(path.name)}` | unreadable JSON |')
            continue
        if isinstance(value, dict) and isinstance(value.get('success'), bool):
            lines.append(f'| `{cell(path.name)}` | {"PASS" if value["success"] else "FAIL"} |')
            count += 1
    if not count:
        lines.append('| — | No test result with an explicit success flag was produced. |')
    lines += ['', 'Unlisted or missing results are not treated as passes. '
              'Failure details and screenshots remain in the diagnostic artifact.']
    return '\n'.join(lines)


def main():
    if sys.argv[1:] == ['guard']:
        guard()
    elif sys.argv[1:] == ['summary']:
        append_summary(render_summary(Path('dist'), json.loads(os.environ['CI_STEPS']),
                                      os.environ['CI_SCOPE'], os.environ['GITHUB_SHA'],
                                      os.environ.get('REUSE_RUN', '')))
    else:
        raise SystemExit('Usage: ci-support.py guard|summary')


if __name__ == '__main__':
    main()
