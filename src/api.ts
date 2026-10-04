import type { Connection } from './native';
import { URL } from 'react-native-url-polyfill';

export interface VideoFile {
  id: number;
  name: string;
  filename?: string;
  type: 'ts' | 'encoded';
  size: number;
}

export interface Recording {
  id: number;
  name: string;
  startAt: number;
  endAt: number;
  isRecording: boolean;
  thumbnails?: number[];
  videoFiles?: VideoFile[];
}

export interface Recordings {
  records: Recording[];
  total: number;
}

export function normalizeServerURL(input: string): string {
  let url: InstanceType<typeof URL>;
  try {
    url = new URL(input.trim());
  } catch {
    throw new Error('サーバーURLの形式を確認してください。');
  }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname) {
    throw new Error(
      'http:// または https:// から始まるURLを入力してください。',
    );
  }
  if (
    url.username ||
    url.password ||
    url.search ||
    (url.hash && !url.hash.startsWith('#/'))
  ) {
    throw new Error(
      'URLに認証情報・クエリ・フラグメントを含めないでください。',
    );
  }
  return (
    url
      .toString()
      // Web bookmarks include the SPA route; it is not part of the server base.
      .split('#')[0]
      .replace(/\/+$/, '')
      .replace(/\/api$/, '')
  );
}

export function apiURL(connection: Connection, path: string): string {
  return `${connection.url}/api${path}`;
}

export function requestHeaders(_connection: Connection): Record<string, string> {
  return {
    Accept: 'application/json',
    'X-EPGStation-User-Id': 'master',
  };
}

async function request<T>(
  connection: Connection,
  path: string,
  signal?: AbortSignal,
): Promise<T> {
  const controller = new AbortController();
  let timedOut = false;
  const cancel = () => controller.abort();
  signal?.addEventListener('abort', cancel);
  if (signal?.aborted) {
    controller.abort();
  }
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, 20000);
  try {
    const response = await fetch(apiURL(connection, path), {
      headers: requestHeaders(connection),
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(
        response.status === 401 || response.status === 403
          ? 'アクセスできません。認証設定を確認してください。'
          : `サーバーがエラーを返しました（HTTP ${response.status}）。`,
      );
    }
    try {
      return (await response.json()) as T;
    } catch {
      throw new Error(
        'APIの応答がJSONではありません。NeoEPGStationのURLを確認してください。',
      );
    }
  } catch (error) {
    if (timedOut) {
      throw new Error('接続がタイムアウトしました。');
    }
    if (controller.signal.aborted) {
      throw error;
    }
    if (error instanceof TypeError) {
      throw new Error(
        'サーバーに接続できません。URLとネットワークを確認してください。',
      );
    }
    throw error;
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener('abort', cancel);
  }
}

export async function getRecordings(
  connection: Connection,
  offset: number,
  signal?: AbortSignal,
): Promise<Recordings> {
  const result = await request<Recordings>(
    connection,
    `/recorded?isHalfWidth=true&isReverse=false&limit=30&offset=${offset}`,
    signal,
  );
  if (
    !Array.isArray(result.records) ||
    !Number.isSafeInteger(result.total) ||
    result.total < 0 ||
    result.records.some(
      item =>
        !Number.isSafeInteger(item.id) ||
        item.id <= 0 ||
        typeof item.name !== 'string',
    )
  ) {
    throw new Error(
      '録画一覧の応答形式が一致しません。サーバーを確認してください。',
    );
  }
  return result;
}

export async function getRecording(
  connection: Connection,
  id: number,
  signal?: AbortSignal,
): Promise<Recording> {
  const item = await request<Recording>(
    connection,
    `/recorded/${id}?isHalfWidth=true`,
    signal,
  );
  if (item.id !== id || typeof item.name !== 'string') {
    throw new Error('録画情報の応答形式が一致しません。');
  }
  return item;
}
