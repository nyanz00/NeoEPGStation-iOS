import {
  defaultShortcuts,
  sanitizeShortcuts,
  swipeIntent,
} from '../src/ui/navigation';

test('restores known shortcuts in order and recovers from obsolete or corrupt preferences', () => {
  expect(sanitizeShortcuts(['guide', 'obsolete', 'recorded', 'guide'])).toEqual(
    ['guide', 'recorded'],
  );
  expect(sanitizeShortcuts(['obsolete'])).toEqual(defaultShortcuts);
  expect(sanitizeShortcuts(null)).toEqual(defaultShortcuts);
  expect(
    sanitizeShortcuts([
      'recorded',
      'guide',
      'anime',
      'settings',
      'search',
      'onair',
    ]),
  ).toHaveLength(5);
});

test('uses the starting half and ignores vertical scrolls, inner horizontal controls, and root back swipes', () => {
  expect(swipeIntent(10, 200, 390, 800, 80, 20, true)).toBe('menu');
  expect(swipeIntent(10, 600, 390, 800, 80, -300, true)).toBeNull();
  expect(swipeIntent(10, 600, 390, 800, 80, 20, true)).toBe('back');
  expect(swipeIntent(100, 200, 390, 800, 80, 0, true)).toBeNull();
  expect(swipeIntent(10, 600, 390, 800, 80, 0, false)).toBeNull();
  expect(swipeIntent(10, 200, 390, 800, -80, 0, true)).toBeNull();
});
