"""Bounded retry for transient failures in read-only GitHub CLI queries."""
import json
import re
import subprocess
import time


def read_json(arguments):
    for attempt, delay in enumerate((0, 3, 10)):
        if delay:
            time.sleep(delay)
        result = subprocess.run(['gh', *arguments], capture_output=True, text=True, timeout=45)
        if result.returncode == 0:
            return json.loads(result.stdout)
        temporary = re.search(r'HTTP (?:429|502|503|504)\b', result.stderr)
        if not temporary or attempt == 2:
            raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, result.stderr)
        print('Transient GitHub read failure; retrying query only:', temporary.group(), flush=True)
