import React from 'react';
import { Animated, PanResponder, Text, View } from 'react-native';
import type {
  GestureResponderEvent,
  PanResponderGestureState,
} from 'react-native';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { AppShell } from '../src/ui/AppShell';
import * as safeArea from 'react-native-safe-area-context';

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
}));

test('the left-edge swipe uses the safe-area origin in landscape', async () => {
  const insets = jest
    .spyOn(safeArea, 'useSafeAreaInsets')
    .mockReturnValue({ left: 59, right: 59, top: 0, bottom: 21 });
  const create = jest.spyOn(PanResponder, 'create');
  let tree: ReactTestRenderer.ReactTestRenderer;
  await act(async () => {
    tree = ReactTestRenderer.create(
      <AppShell
        current="recorded"
        navigate={jest.fn()}
        back={jest.fn()}
        canGoBack={false}
        shortcuts={['recorded']}
      >
        <Text>content</Text>
      </AppShell>,
    );
  });
  tree!.root
    .findAllByType(View)
    .find(node => typeof node.props.onLayout === 'function')!
    .props.onLayout({ nativeEvent: { layout: { height: 390 } } });
  expect(
    create.mock.calls[0][0].onMoveShouldSetPanResponderCapture!(
      {} as GestureResponderEvent,
      {
        x0: 65,
        y0: 100,
        dx: 20,
        dy: 0,
        vx: 0,
        numberActiveTouches: 1,
      } as PanResponderGestureState,
    ),
  ).toBe(true);
  await act(async () => {
    tree!.unmount();
  });
  create.mockRestore();
  insets.mockRestore();
});

test('an opening gesture survives the drawer rerender and keeps its initial operation', async () => {
  const create = jest.spyOn(PanResponder, 'create');
  const animation = jest.spyOn(Animated, 'timing').mockImplementation(() => ({
    start: callback => callback?.({ finished: true }),
    stop: jest.fn(),
    reset: jest.fn(),
  }));
  const back = jest.fn();
  let tree: ReactTestRenderer.ReactTestRenderer;
  await act(async () => {
    tree = ReactTestRenderer.create(
      <AppShell
        current="guide"
        navigate={jest.fn()}
        back={back}
        canGoBack
        shortcuts={['recorded', 'guide']}
      >
        <Text>content</Text>
      </AppShell>,
    );
  });
  tree!.root
    .findAllByType(View)
    .find(node => typeof node.props.onLayout === 'function')!
    .props.onLayout({ nativeEvent: { layout: { height: 800 } } });
  const callbacks = create.mock.calls[0][0];
  const event = {} as GestureResponderEvent;
  const beginning = {
    x0: 10,
    y0: 200,
    dx: 20,
    dy: 0,
    vx: 0,
    numberActiveTouches: 1,
  } as PanResponderGestureState;
  expect(callbacks.onMoveShouldSetPanResponderCapture!(event, beginning)).toBe(
    true,
  );
  await act(async () => {
    callbacks.onPanResponderGrant!(event, beginning);
  });
  expect(create).toHaveBeenCalledTimes(1);
  const ending = { ...beginning, moveY: 600, dx: 200 };
  await act(async () => {
    callbacks.onPanResponderMove!(event, ending);
    callbacks.onPanResponderRelease!(event, ending);
  });
  expect(back).not.toHaveBeenCalled();
  expect(
    tree!.root.findAll(
      node => node.props.accessibilityLabel === 'メニュー：番組表',
    ).length,
  ).toBeGreaterThan(0);
  expect(
    callbacks.onMoveShouldSetPanResponderCapture!(event, {
      ...beginning,
      dx: -200,
    }),
  ).toBe(true);
  await act(async () => {
    callbacks.onPanResponderGrant!(event, { ...beginning, dx: -200 });
    callbacks.onPanResponderRelease!(event, { ...beginning, dx: -200 });
  });
  expect(
    tree!.root.findAll(
      node => node.props.accessibilityLabel === 'メニュー：番組表',
    ),
  ).toHaveLength(0);
  expect(
    callbacks.onMoveShouldSetPanResponderCapture!(event, {
      ...beginning,
      y0: 600,
      dx: 80,
    }),
  ).toBe(true);
  await act(async () => {
    callbacks.onPanResponderRelease!(event, { ...beginning, y0: 600, dx: 80 });
  });
  expect(back).toHaveBeenCalledTimes(1);
  await act(async () => {
    tree!.unmount();
  });
  create.mockRestore();
  animation.mockRestore();
});
