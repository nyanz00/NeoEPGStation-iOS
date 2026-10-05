# UI foundation

## Appearance

The initial palette matches NeoEPGStation Web's neon-teal dark theme:
background `#101418`, paper/header `#191e23`, primary `#20a89a`.
The header is 56pt tall; the menu is 240pt wide with the Web labels, order and
icons. Mobile recorded cards use a 108pt row, a 32% thumbnail and compact
14pt title/12pt metadata. System fonts are used in this first version.
Custom colors and light/dark appearance selection remain future work.

## Navigation

- iPhone: configurable bottom shortcuts, one to five items, saved in UserDefaults.
  The menu always includes all destinations and shares the same route state.
- iPad: persistent sidebar with a button to collapse it; no bottom bar.
  Detailed split-view/adaptive layout behavior remains to be designed.
- A right swipe can start anywhere in the content area. The upper 40% of screen
  height opens the menu; the lower 60% goes back within the current tab if possible,
  otherwise opens the menu. The starting region fixes the action for the entire drag. Diagonals up to 45
  degrees are accepted; predominantly vertical motion stays with scrolling.
  Sliders, text input and horizontal scrolling take priority over navigation.
  Detail/search back transitions follow the finger and can be cancelled.
  Search results are pushed on the native navigation stack, so returning restores
  the original list and its scroll position instead of clearing it and refetching.
  Menu/back buttons remain available. A left swipe or backdrop tap closes the drawer.
- Each tab retains its own navigation stack, fetched recordings and list position
  across tab changes. Back buttons and swipes stop at the current tab's root;
  switching tabs never adds a back target. The app does not refetch recordings
  merely for changing tabs.
- Recorded page changes fade in over 500ms, or 320ms for a page cached within
  30 seconds (up to 12 page/filter combinations). Manual refresh bypasses this
  cache. Thumbnails are warmed up for at most 400ms; late images fade in over
  180ms. Image downloads are shared and reused cells cannot show a stale image.
- The status bar shares the header background. The brand image follows the
  measured title width with a 7pt gap. Anime uses the Web's scaled MDI alpha-a.

## Implemented screens

Swift / UIKit implements server URL saving/automatic connection, keyword search,
recorded cards, scrolling page-number controls, recording details, file selection
and native PLAY. Settings includes bottom shortcut customization.
Other destinations show an explicit preparation screen; their functionality has
not been ported. OAuth, advanced filters, viewer profiles and recording management
actions are separate follow-up work. Unsupported actions are not shown as working buttons.

## Verification

Swift tests cover page ranges, compact Web timestamps, URL recovery and recording
data decoding. Actions exercises real preference methods, builds the device IPA
and launches the Release UIKit app with simulator-only synthetic fixtures.
UI checks retain the list across tab changes and capture recorded cards, page 7,
details, menu/settings, interactive back completion/cancellation, isolation of
tab roots and retained detail stacks across tabs, returning from search, page fade
durations and delayed/shared thumbnail loading. iPad simulator checks are
optional (`check_ipad` or `reuse_run` on workflow_dispatch). No React Native runtime is shipped.
Fixtures use invented text and code-drawn thumbnails; no private server or real
recordings are embedded. Actual device swipes and usability still need device testing.
Build 39 results are recorded in `navigation-polish-verification.md`.
Build 40 tab isolation and the 40/60 swipe split are recorded in `tab-navigation-verification.md`.
