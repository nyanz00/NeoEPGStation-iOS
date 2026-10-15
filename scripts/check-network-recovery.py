"""Assert recovery from recorded native samples, not just successful HTTP."""
import json
from pathlib import Path
import sys

def inspect(mode, result, diagnostics, faults):
    rows = result['rows']
    assert result['success'] and result.get('zoomedDrawableOnly'), 'Native probe/zoom did not complete'
    assert all(result['zoomChecks'].values()), result['zoomChecks']
    applied = [e for e in faults if e['mode'] == mode]
    assert len(applied) >= (3 if mode == 'slow' else 1), 'The requested fault was not fully applied'
    # A stale frame callback can still have a fresh arrival timestamp. Require
    # actual native decoded-video and audio progress in the final interval.
    tail = rows[-5:]
    assert tail[-1]['video']-tail[0]['video'] >= 12, 'Video did not resume decoding'
    assert tail[-1]['playedAudio']-tail[0]['playedAudio'] >= 12, 'Audio did not resume'
    assert all(r['state'] == 2 and not r['loading'] for r in tail[-3:]), 'Recovery never left the loading state'
    assert max(r['reload'] for r in rows) == 0, 'An ordinary network wait reopened the VLC input'
    start = None
    drift = 0
    for row in rows:
        key = (row['video'], row['playedAudio'])
        if start is None or key != (start['video'], start['playedAudio']) or not (row['buffering'] or row['loading']):
            start = row
        else:
            drift = max(drift, row['mediaMs']-start['mediaMs'])
    assert drift <= 3000, f'Playback clock advanced {drift}ms while A/V decoding/output was stalled'
    events = diagnostics['events']
    if mode == 'slow':
        assert any(e['event'] == 'network.clockHeld' for e in events), 'The starved-read clock path was not exercised'
        assert any(e['event'] == 'network.videoResumed' for e in events), 'No decoded-video confirmation after byte recovery'
    return {'success': True, 'faults': len(applied), 'quiescentClockDriftMs': drift,
            'finalVideoFrames': tail[-1]['video']-tail[0]['video'],
            'sameInput': True, 'decodedVideoConfirmed': True}

if __name__ == '__main__':
    directory = Path(sys.argv[1])
    faults = json.loads((directory / 'network-faults.json').read_text())
    results = {}
    for mode in ['slow', 'disconnect']:
        result = json.loads((directory / f'{mode}-network-recovery-smoke.json').read_text())
        diagnostics = json.loads((directory / f'{mode}-network-diagnostics.json').read_text())
        results[mode] = inspect(mode, result, diagnostics, faults)
    print(json.dumps({'success': True, 'profiles': results}, indent=2))
