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
- A right swipe beginning within 32pt of the left edge opens the menu in the
  upper half and goes back in the lower half. Direction and distance thresholds
  avoid claiming vertical scrolling; the starting region fixes the operation.
  Menu/back buttons remain available. A left swipe or backdrop tap closes the drawer.
- Screen history, fetched recordings and list position remain available across
  route changes. The app does not refetch recordings merely for changing tabs.

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
details, menu/settings and the iPad sidebar. No React Native runtime is shipped.
Fixtures use invented text and code-drawn thumbnails; no private server or real
recordings are embedded. Actual device swipes and usability still need device testing.
