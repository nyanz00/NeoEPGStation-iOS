import type { IconName } from './Icon';

export const destinations = [
  { id: 'dashboard', title: 'ダッシュボード', icon: 'DashboardOutlined' },
  { id: 'onair', title: '放映中', icon: 'LiveTvOutlined' },
  { id: 'guide', title: '番組表', icon: 'TelevisionGuide' },
  { id: 'anime', title: 'アニメ', icon: 'AlphaA' },
  { id: 'recording', title: '録画中', icon: 'RadioButtonUncheckedOutlined' },
  { id: 'recorded', title: '録画済み', icon: 'FilmstripBoxMultiple' },
  { id: 'encode', title: 'エンコード', icon: 'SyncOutlined' },
  { id: 'reserves', title: '予約', icon: 'ScheduleOutlined' },
  { id: 'search', title: '検索', icon: 'SearchOutlined' },
  { id: 'rule', title: 'ルール', icon: 'CalendarMonthOutlined' },
  { id: 'history', title: '視聴履歴', icon: 'HistoryOutlined' },
  { id: 'system', title: 'システム', icon: 'DnsOutlined' },
  { id: 'settings', title: '設定', icon: 'SettingsOutlined' },
] as const satisfies readonly { id: string; title: string; icon: IconName }[];
export type Destination = (typeof destinations)[number]['id'];
export const defaultShortcuts: Destination[] = [
  'recorded',
  'onair',
  'guide',
  'anime',
  'settings',
];
export function sanitizeShortcuts(value: unknown): Destination[] {
  if (!Array.isArray(value)) {
    return [...defaultShortcuts];
  }
  const result = [...new Set(value)]
    .filter((id): id is Destination =>
      destinations.some(item => item.id === id),
    )
    .slice(0, 5);
  return result.length ? result : [...defaultShortcuts];
}

// Only a deliberate horizontal drag from the left edge claims a gesture.
// The region is fixed from the initial touch, never its current location.
export function swipeIntent(
  startX: number,
  startY: number,
  width: number,
  height: number,
  dx: number,
  dy: number,
  canGoBack: boolean,
): 'menu' | 'back' | null {
  if (
    startX > Math.min(32, width * 0.1) ||
    dx < 12 ||
    dx < Math.abs(dy) * 1.6
  ) {
    return null;
  }
  return startY < height / 2 ? 'menu' : canGoBack ? 'back' : null;
}
