import {
  getRecordings,
  normalizeServerURL,
  apiURL,
  requestHeaders,
} from '../src/api';

const connection = {
  url: 'https://example.com/neo',
};

test('does not send Basic credentials left over from an old prototype', () => {
  const legacy = { ...connection, authorization: 'Basic fixture' };
  expect(requestHeaders(legacy)).not.toHaveProperty('Authorization');
});

test('preserves reverse-proxy subpaths and removes the optional API suffix', () => {
  expect(normalizeServerURL(' https://example.com/neo/api/ ')).toBe(
    'https://example.com/neo',
  );
  expect(apiURL(connection, '/videos/2')).toBe(
    'https://example.com/neo/api/videos/2',
  );
});

test.each([
  ['https://recorder.example.ts.net/#/', 'https://recorder.example.ts.net'],
  [
    'https://recorder.example.ts.net/neo/#/recorded?page=2',
    'https://recorder.example.ts.net/neo',
  ],
  ['http://192.168.1.2:8888/#/recorded', 'http://192.168.1.2:8888'],
])('accepts Web UI bookmarks: %s', (input, expected) => {
  expect(normalizeServerURL(input)).toBe(expected);
});

test('normalizes bookmarks with the actual React Native URL implementation', () => {
  const original = globalThis.URL;
  const { URL: NativeURL } = jest.requireActual<{ URL: typeof URL }>(
    'react-native/Libraries/Blob/URL',
  );
  try {
    globalThis.URL = NativeURL;
    expect(normalizeServerURL('https://recorder.example.ts.net/neo/#/')).toBe(
      'https://recorder.example.ts.net/neo',
    );
    expect(() =>
      normalizeServerURL('https://user:secret@example.com/#/'),
    ).toThrow();
  } finally {
    globalThis.URL = original;
  }
});

test('requests newest recordings first on every page', async () => {
  globalThis.fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ records: [], total: 0 }),
  });
  await getRecordings(connection, 30);
  const requested = new URL((globalThis.fetch as jest.Mock).mock.calls[0][0]);
  expect(requested.searchParams.get('isReverse')).toBe('false');
  expect(requested.searchParams.get('offset')).toBe('30');
});

test.each([
  'file:///tmp/video',
  'https://user:secret@example.com',
  'https://example.com?token=test',
  'https://example.com/#x',
])('rejects unsafe or ambiguous server URL %s', input => {
  expect(() => normalizeServerURL(input)).toThrow();
});

test('does not mistake an incompatible response for an empty library', async () => {
  globalThis.fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ items: [], total: 0 }),
  });
  await expect(getRecordings(connection, 0)).rejects.toThrow('応答形式');
});

test('reports denied access without including the server or credentials', async () => {
  globalThis.fetch = jest.fn().mockResolvedValue({ ok: false, status: 401 });
  await expect(getRecordings(connection, 0)).rejects.toThrow('認証設定');
});

test('aborts a stalled request after the timeout', async () => {
  jest.useFakeTimers();
  globalThis.fetch = jest.fn().mockImplementation(
    (_url, init) =>
      new Promise((_resolve, reject) => {
        init.signal.addEventListener('abort', () =>
          reject(new Error('aborted')),
        );
      }),
  );
  await Promise.all([
    expect(getRecordings(connection, 0)).rejects.toThrow('タイムアウト'),
    jest.advanceTimersByTimeAsync(20000),
  ]);
  jest.useRealTimers();
});
