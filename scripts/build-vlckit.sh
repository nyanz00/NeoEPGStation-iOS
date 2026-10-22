#!/bin/bash
# Rebuild the pinned dependency, including its upstream patches, for one SDK.
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
task_sdk=${1:?iphoneos or iphonesimulator required}
case "$task_sdk" in iphoneos|iphonesimulator) ;; *) exit 2 ;; esac
task_work="$task_root/build/vlckit-$task_sdk"
task_wrapper="$task_work/VLCKit"
task_vlc="$task_wrapper/libvlc/vlc"
mkdir -p "$task_work" "$task_root/dist"
if ! command -v gmake >/dev/null; then
    brew install make
fi
# Modern GNU make's FIFO jobserver survives CMake/Meson subprocesses. The
# macOS make 3.81 pipe descriptors are closed by them, which breaks Ninja.
export MAKE="$(command -v gmake)"
"$MAKE" --version
task_brew_prefix=$(brew --prefix)
test -f "$task_brew_prefix/share/aclocal/pkg.m4"
# VLC builds its own automake. Its aclocal cannot discover Homebrew's pkg.m4
# through its own installation prefix even though pkg-config is on PATH.
export ACLOCAL_PATH="$task_brew_prefix/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
read -r task_wrapper_rev task_vlc_rev < <(python3 -c 'import json; s=json.load(open("vendor/vlckit/source.json")); print(s["vlckit"], s["vlc"])')

task_checkout() {
    local path=$1 url=$2 revision=$3
    if [ ! -d "$path/.git" ]; then
        git init "$path"
        git -C "$path" remote add origin "$url"
    fi
    if ! git -C "$path" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$path" fetch --depth=1 origin "$revision"
    fi
    # Only the generated dependency checkout inside build/ is reset. Keep its
    # untracked contrib/tool outputs so a source repair doesn't rebuild them.
    git -C "$path" checkout --detach --force "$revision"
    git -C "$path" reset --hard "$revision"
    test "$(git -C "$path" rev-parse HEAD)" = "$revision"
}
task_checkout "$task_wrapper" https://github.com/videolan/vlckit.git "$task_wrapper_rev"
python3 "$task_root/scripts/prepare-vlckit-source.py" capture-times "$task_vlc" "$task_work/source-times.json"
task_checkout "$task_vlc" https://github.com/videolan/vlc.git "$task_vlc_rev"
python3 "$task_root/scripts/prepare-vlckit-source.py" "$task_vlc" "$task_wrapper/libvlc/patches"
git -C "$task_vlc" apply --index "$task_root/vendor/vlckit/patches/0001-videotoolbox-av1.patch"
cp "$task_root/vendor/vlckit/av1.c.inc" "$task_vlc/modules/codec/videotoolbox/av1.c.inc"
# The app supports iOS 18+, and the AV1 APIs are available throughout that range.
python3 - "$task_vlc/extras/package/apple/build.conf" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
s=s.replace('VLC_DEPLOYMENT_TARGET_IOS="9.0"', 'VLC_DEPLOYMENT_TARGET_IOS="18.0"')
s=s.replace('VLC_DEPLOYMENT_TARGET_IOS_SIMULATOR="12.0"', 'VLC_DEPLOYMENT_TARGET_IOS_SIMULATOR="18.0"')
p.write_text(s)
for relative in ('extras/tools/packages.mak', 'contrib/src/main.mak'):
    source = p.parents[3] / relative
    # The redirect service selected a mirror with an expired TLS certificate.
    # Use a fixed HTTPS mirror; keep every upstream SHA-512 check intact.
    source.write_text(source.read_text().replace('https://ftpmirror.gnu.org/gnu', 'https://mirrors.kernel.org/gnu'))
PY
python3 "$task_root/scripts/prepare-vlckit-source.py" restore-times "$task_vlc" "$task_work/source-times.json"
python3 "$task_root/scripts/fetch-vlckit-tools.py" "$task_vlc/extras/tools"
mkdir -p "$task_vlc/build-$task_sdk-arm64"
(
    cd "$task_vlc/build-$task_sdk-arm64"
    bash ../extras/package/apple/build.sh --arch=aarch64 --sdk="$task_sdk" --disable-debug
) 2>&1 | tee "$task_root/dist/vlckit-$task_sdk.log"

# Reuse the official wrapper's static module list and archive/link functions.
# Build only arm64 and this SDK; do not spend time compiling unused x86 slices.
python3 - "$task_wrapper" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); s=(p/'compileAndBuildVLCKit.sh').read_text()
s=s.split('while getopts ',1)[0]
assert s.count('SKIP_INSTALL=no') == 1
s=s.replace('SKIP_INSTALL=no', 'SKIP_INSTALL=no CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO')
(p/'neo-build-functions.sh').write_text(s)
PY
(
    cd "$task_wrapper"
    # The upstream shell helpers use optional unset Xcode environment values.
    set +u
    source ./neo-build-functions.sh
    VLCROOT="$task_vlc"
    PROJECT_DIR="$task_wrapper"
    CONFIGURATION=Release
    SDK_MIN=18.0
    SDK=""
    out="/dev/stdout"
    FARCH=aarch64
    if [ "$task_sdk" = iphoneos ]; then
        build_device_static_lib iphone
        buildxcodeproj VLCKit iphoneos iOS
    else
        build_simulator_static_lib iphone
        buildxcodeproj VLCKit iphonesimulator 'iOS Simulator'
    fi
) 2>&1 | tee -a "$task_root/dist/vlckit-$task_sdk.log"

task_output="$task_root/build/vlckit-output-$task_sdk"
mkdir -p "$task_output"
ditto "$task_wrapper/build/VLCKit-$task_sdk.xcarchive/Products/Library/Frameworks/VLCKit.framework" "$task_output/VLCKit.framework"
# Both sides must contain the actual extension, not just an app capability log.
strings "$task_output/VLCKit.framework/VLCKit" > "$task_work/strings.txt"
grep -q 'neo-av1-selection hardware=1' "$task_work/strings.txt"
grep -q 'videotoolbox-av1-hardware' "$task_work/strings.txt"
python3 "$task_root/scripts/vlckit-provenance.py" "$task_sdk"
