import { getRecordings, normalizeServerURL, apiURL } from '../src/api';

const connection = {
  url: 'https://example.com/neo',
  username: '',
  password: '',
};

test('preserves reverse-proxy subpaths and removes the optional API suffix', () => {
  expect(normalizeServerURL(' https://example.com/neo/api/ ')).toBe(
    'https://example.com/neo',
  );
  expect(apiURL(connection, '/videos/2')).toBe(
    'https://example.com/neo/api/videos/2',
  );
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
