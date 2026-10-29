"""Anchor checks for the synthetic AV1/AAC player fixtures, including cold cache boundaries."""


def validate_cache_seek_anchors(anchors):
    assert len(anchors) >= 2, 'No repeated cached seeks'
    keys = {e['videoKeyMs'] for e in anchors}
    assert len(keys) >= 2 and max(keys) > 1000, 'No interior cached key observed'
    boundary = min(keys)
    warmed = 0
    for event in anchors:
        assert event['independent'] == 1 and event['videoKeyMs'] <= event['targetMs'], event
        gap = event['videoKeyMs'] - event['audioStartMs']
        if gap == 0:
            # A cold seek creates a fresh FIFO beginning at its video key. No
            # earlier audio bookmark exists there. Audio warms up on the way to
            # the target; this is distinct from an interior key losing preroll.
            assert event['videoKeyMs'] == boundary and event['targetMs']-boundary >= 100, event
        else:
            assert 99 <= gap <= 600, event
            warmed += 1
    assert warmed > 0, 'No independent AAC warm-up bookmark observed'
