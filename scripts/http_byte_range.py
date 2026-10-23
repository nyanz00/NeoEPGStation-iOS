"""Single byte ranges used by the synthetic playback origin."""


def byte_range(header, length):
    if not header:
        return 0, length - 1
    if not header.startswith('bytes=') or ',' in header:
        raise ValueError('Unsupported byte range')
    first, last = header[6:].split('-', 1)
    if first:
        begin = int(first)
        end = min(int(last), length - 1) if last else length - 1
    else:
        suffix = int(last)
        if suffix <= 0:
            raise ValueError('Invalid suffix length')
        begin, end = max(0, length - suffix), length - 1
    if begin < 0 or begin > end or begin >= length:
        raise ValueError('Unsatisfiable byte range')
    return begin, end
