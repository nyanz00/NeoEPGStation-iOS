import type { Recordings } from '../api';

// Only enabled by a simulator-only native constant. No server access or real data.
export const uiFixture: Recordings = {
  total: 4,
  records: [
    {
      id: 1,
      name: 'サンプル番組 第12話「新しい朝」',
      channelName: 'サンプル放送 BS',
      description: '録画カードのレイアウト確認用データです。',
      startAt: 1791021600000,
      endAt: 1791023400000,
      isRecording: false,
    },
    {
      id: 2,
      name: '週末の映画劇場「旅のはじまり」',
      channelName: 'サンプルテレビ',
      description: '長い番組名や説明は一行で省略表示します。',
      startAt: 1791018000000,
      endAt: 1791025200000,
      isRecording: false,
    },
    {
      id: 3,
      name: 'ニュースと天気',
      channelName: 'サンプル総合',
      description: '最新の情報をお伝えします。',
      startAt: 1791014400000,
      endAt: 1791016200000,
      isRecording: false,
    },
    {
      id: 4,
      name: '音楽の時間',
      channelName: 'サンプル音楽',
      description: '今週の特集をお届けします。',
      startAt: 1791010800000,
      endAt: 1791012600000,
      isRecording: false,
    },
  ],
};
