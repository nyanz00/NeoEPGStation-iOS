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
    if mode == 'tunnel':
        events = diagnostics['events']
        assert any(e['event'] == 'input.retiredAfterDeadline' for e in events), 'Opening deadline was not exercised'
        assert any(e['event'] == 'input.networkAvailable' for e in events), 'No upstream recovery gate'
        assert max(r['reload'] for r in rows) >= 2, 'Late input was reused instead of reopening'
        assert any(r['waitingNetwork'] for r in rows), 'No waiting interval after input retirement'
        assert tail[-1]['samples']-tail[0]['samples'] >= 12, 'No video delivery after tunnel recovery'
        assert tail[-1]['changes']-tail[0]['changes'] >= 2, 'Output is still the same frozen picture'
        assert tail[-1]['lost']-tail[0]['lost'] < (tail[-1]['video']-tail[0]['video'])/2, 'New video is still being dropped'
        for group in [[r for r in rows if r['waitingNetwork']], [r for r in rows if r['restoreVerifying'] and not r['reloading'] and not r['waitingNetwork']]]:
            if group:
                assert max(r['mediaMs'] for r in group)-min(r['mediaMs'] for r in group) <= 1500, 'Clock escaped a blocked restore'
        assert tail[-1]['commentTime'] > tail[0]['commentTime']+1, 'Comments did not resume'
        return {'success': True, 'lateInputRetired': True, 'freshVideoAndAudioConfirmed': True, 'reloads': max(r['reload'] for r in rows)}
    assert max(r['reload'] for r in rows) == 0, 'An ordinary network wait reopened the VLC input'
    start = None
    drift = 0
    for row in rows:
        key = (row['video'], row['playedAudio'])
        # libVLC publishes statistics from its input loop. While HTTP blocks,
        # queued output may still advance. A progressing native time point is
        # additional evidence; don't call that legitimate playback starvation.
        point_stale = row.get('pointAge', 10) >= 1.5
        if start is None or key != (start['video'], start['playedAudio']) or not point_stale or not (row['buffering'] or row['loading']):
            start = row
        else:
            drift = max(drift, row['mediaMs']-start['mediaMs'])
    assert drift <= 3000, f'Presentation advanced {drift}ms while A/V decoding/output was stalled'
    events = diagnostics['events']
    if mode == 'slow':
        assert any(r.get('confirmedMs', -1) >= 0 for r in rows), 'Native time-point observation is unavailable'
        assert any(e['event'] == 'network.presentationHeld' for e in events), 'The starved-read path was not exercised'
        assert all(r['flowMuted'] for r in rows if r.get('holding')), 'Audio escaped a held presentation'
        resyncs = [e for e in events if e['event'] == 'network.inputResynced']
        assert resyncs and all(not e.get('failed') and e.get('sameInput') for e in resyncs), 'Native input resynchronisation failed'
        assert all(abs(e['nativeMs']-e['targetMs']) < 1500 for e in resyncs), 'Native time did not reach the held position'
        assert any(e['event'] == 'network.videoResumed' for e in events), 'No decoded-video confirmation after byte recovery'
    return {'success': True, 'faults': len(applied), 'quiescentClockDriftMs': drift,
            'finalVideoFrames': tail[-1]['video']-tail[0]['video'],
            'sameInput': True, 'decodedVideoConfirmed': True}

if __name__ == '__main__':
    directory = Path(sys.argv[1])
    faults = json.loads((directory / 'network-faults.json').read_text())
    results = {}
    for mode in (sys.argv[2:] or ['slow', 'disconnect']):
        result = json.loads((directory / f'{mode}-network-recovery-smoke.json').read_text())
        diagnostics = json.loads((directory / f'{mode}-network-diagnostics.json').read_text())
        results[mode] = inspect(mode, result, diagnostics, faults)
    print(json.dumps({'success': True, 'profiles': results}, indent=2))
