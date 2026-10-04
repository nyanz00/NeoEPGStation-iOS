# Third-party software

The initial application skeleton comes from the MIT-licensed
[React Native Community Template](https://github.com/react-native-community/template).
Its notice is preserved in `licenses/ReactNativeTemplate-MIT.txt`.
The current application uses Swift / UIKit and does not ship the React Native
runtime or JavaScript dependencies. The template notice remains for retained
project scaffolding.

The retired prototype used [react-native-url-polyfill](https://github.com/charpeni/react-native-url-polyfill)
4.0.0 under the MIT license. Its notice is preserved in
`licenses/ReactNativeURLPolyfill-MIT.txt` and included in the IPA.

The retired SVG wrapper used react-native-svg 15.15.5 (MIT), copyright (c)
[2015-2016] [Horcrux]. Its notice is retained in `licenses/ReactNativeSVG-MIT.txt`.
The current icon paths are drawn with UIKit and do not use that runtime.
Material icon paths match those used by NeoEPGStation Web: the MUI distribution
is MIT (copyright (c) 2014 Call-Em-All), and the underlying Google Material Design
icons are Apache-2.0. FilmstripBoxMultiple and TelevisionGuide are by the
Pictogrammers contributors under Apache-2.0. License texts are preserved in
`licenses/MUI-icons-MIT.txt` and `licenses/Apache-2.0.txt`.

VLCKit and libVLC are VideoLAN projects distributed under LGPL-2.1-or-later;
the bundled framework and its components have their own notices and licenses.
The initial unmodified framework is downloaded from:

https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip

Wrapper source and packaging recipe:

https://github.com/videolan/vlckit/tree/2e0868f5ed40fe59cd92f377645fdcc260c6e759

VLC source:

https://code.videolan.org/videolan/vlc

Keep the archive's COPYING notices with distributed artifacts. Any modified
VideoLAN components must be accompanied by the corresponding source and patches.
The dependency and distribution requirements must be checked before a public
App Store release.
