/**
 * @format
 */

import React from 'react';
import { Animated, Modal, Text, TextInput } from 'react-native';
import ReactTestRenderer, { act } from 'react-test-renderer';
import App from '../App';
import { native } from '../src/native';

jest.mock('react-native-safe-area-context', () => {
  const { View } = require('react-native');
  return {
    SafeAreaProvider: View,
    SafeAreaView: View,
    useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  };
});
jest.mock('../src/native', () => ({
  native: {
    loadNavigation: jest.fn().mockResolvedValue(null),
    saveNavigation: jest.fn().mockResolvedValue(undefined),
    loadConnection: jest.fn().mockResolvedValue(null),
    saveConnection: jest
      .fn()
      .mockImplementation(value => Promise.resolve(value)),
    play: jest.fn().mockResolvedValue(undefined),
  },
}));

beforeEach(() => {
  jest.clearAllMocks();
  (native.loadConnection as jest.Mock).mockResolvedValue(null);
  (native.loadNavigation as jest.Mock).mockResolvedValue(null);
});

test('bottom shortcuts and the full menu share a route, preserve recordings, and return with back', async () => {
  (native.loadConnection as jest.Mock).mockResolvedValue({
    url: 'https://example.com',
  });
  (native.loadNavigation as jest.Mock).mockResolvedValue(['recorded', 'guide']);
  globalThis.fetch = jest
    .fn()
    .mockResolvedValue({
      ok: true,
      json: async () => ({
        records: [{ id: 1, name: '保存した番組', startAt: 1000, endAt: 2000 }],
        total: 1,
      }),
    });
  const animation = jest
    .spyOn(Animated, 'timing')
    .mockImplementation(() => ({
      start: callback => callback?.({ finished: true }),
      stop: jest.fn(),
      reset: jest.fn(),
    }));
  let tree: ReactTestRenderer.ReactTestRenderer;
  await act(async () => {
    tree = ReactTestRenderer.create(<App />);
  });
  const press = async (label: string) => {
    await act(async () => {
      tree!.root
        .findAll(
          node =>
            node.props.accessibilityLabel === label &&
            typeof node.props.onPress === 'function',
        )[0]
        .props.onPress();
    });
  };
  await press('ナビゲーション：番組表');
  await press('メニューを開く');
  const selected = tree!.root.findAll(
    node =>
      node.props.accessibilityLabel === 'メニュー：番組表' &&
      node.props.accessibilityState?.selected,
  );
  expect(selected.length).toBeGreaterThan(0);
  await press('メニュー：録画済み');
  expect(
    tree!.root.findAll(
      node =>
        node.props.accessibilityLabel === '保存した番組の再生ファイルを選択',
    ).length,
  ).toBeGreaterThan(0);
  expect(globalThis.fetch).toHaveBeenCalledTimes(1);
  await press('戻る');
  expect(
    tree!.root.findAll(
      node =>
        node.props.accessibilityLabel === 'ナビゲーション：番組表' &&
        node.props.accessibilityState?.selected,
    ).length,
  ).toBeGreaterThan(0);
  await act(async () => {
    tree!.unmount();
  });
  animation.mockRestore();
});

test('customizing shortcuts persists the chosen order and updates the bottom bar', async () => {
  let tree: ReactTestRenderer.ReactTestRenderer;
  await act(async () => {
    tree = ReactTestRenderer.create(<App />);
  });
  const press = async (label: string) => {
    await act(async () => {
      tree!.root
        .findAll(
          node =>
            node.props.accessibilityLabel === label &&
            typeof node.props.onPress === 'function',
        )[0]
        .props.onPress();
    });
  };
  await press('表示項目：アニメ');
  await press('表示項目：検索');
  await press('searchを上へ');
  await press('ナビゲーションを保存');
  expect(native.saveNavigation).toHaveBeenCalledWith([
    'recorded',
    'onair',
    'guide',
    'search',
    'settings',
  ]);
  expect(
    tree!.root.findAll(
      node => node.props.accessibilityLabel === 'ナビゲーション：検索',
    ).length,
  ).toBeGreaterThan(0);
  expect(
    tree!.root.findAll(
      node => node.props.accessibilityLabel === 'ナビゲーション：アニメ',
    ),
  ).toHaveLength(0);
  await act(async () => {
    tree!.unmount();
  });
});

test('automatically opens recordings from the saved server without a connect tap', async () => {
  (native.loadConnection as jest.Mock).mockResolvedValueOnce({
    url: 'https://example.com/neo',
  });
  globalThis.fetch = jest.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ records: [], total: 0 }),
  });
  let tree: ReactTestRenderer.ReactTestRenderer;
  await act(async () => {
    tree = ReactTestRenderer.create(<App />);
  });
  expect(globalThis.fetch).toHaveBeenCalledWith(
    expect.stringContaining('https://example.com/neo/api/recorded?'),
    expect.anything(),
  );
  expect(tree!.root.findAllByType(TextInput)).toHaveLength(0);
  expect(native.saveConnection).not.toHaveBeenCalled();
  await act(async () => {
    tree!.unmount();
  });
});

test('keeps the saved URL editable when automatic connection fails', async () => {
  (native.loadConnection as jest.Mock).mockResolvedValueOnce({
    url: 'https://example.com/neo',
  });
  globalThis.fetch = jest.fn().mockRejectedValue(new TypeError('offline'));
  let tree: ReactTestRenderer.ReactTestRenderer;
  await act(async () => {
    tree = ReactTestRenderer.create(<App />);
  });
  const inputs = tree!.root.findAllByType(TextInput);
  expect(inputs).toHaveLength(1);
  expect(inputs[0].props.value).toBe('https://example.com/neo');
  expect(
    tree!.root
      .findAllByType(Text)
      .some(node =>
        String(node.props.children).includes('サーバーに接続できません'),
      ),
  ).toBe(true);
  await act(async () => {
    tree!.unmount();
  });
});

test('connects, selects an actual file, and hands the raw PLAY URL to native code', async () => {
  globalThis.fetch = jest
    .fn()
    .mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        records: [{ id: 1, name: '番組', startAt: 1000 }],
        total: 1,
      }),
    })
    .mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        id: 1,
        name: '番組',
        videoFiles: [{ id: 7, name: 'AV1', type: 'encoded', size: 100 }],
      }),
    });
  let tree: ReactTestRenderer.ReactTestRenderer;
  await act(async () => {
    tree = ReactTestRenderer.create(<App />);
  });
  const root = tree!.root;
  await act(async () => {
    root
      .findAll(
        node =>
          node.props.accessibilityLabel === 'サーバーURL' &&
          typeof node.props.onChangeText === 'function',
      )[0]
      .props.onChangeText('https://example.com/neo/');
  });
  await act(async () => {
    root
      .findAll(
        node =>
          node.props.accessibilityLabel === '保存して接続' &&
          typeof node.props.onPress === 'function',
      )[0]
      .props.onPress();
  });
  await act(async () => {
    root
      .findAll(
        node =>
          node.props.accessibilityLabel === '番組の再生ファイルを選択' &&
          typeof node.props.onPress === 'function',
      )[0]
      .props.onPress();
  });
  await act(async () => {
    root
      .findAll(
        node =>
          node.props.accessibilityRole === 'button' &&
          typeof node.props.onPress === 'function' &&
          node.findAllByType(Text).some(text => text.props.children === 'AV1'),
      )[0]
      .props.onPress();
  });
  expect(native.play).not.toHaveBeenCalled();
  await act(async () => {
    root.findByType(Modal).props.onDismiss();
  });
  expect(native.play).toHaveBeenCalledWith(
    expect.objectContaining({
      url: 'https://example.com/neo/api/videos/7',
      title: '番組',
    }),
  );
  await act(async () => {
    tree!.unmount();
  });
});
