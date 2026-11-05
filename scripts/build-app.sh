#!/bin/zsh
# Builds build/RimControl.app with an ad-hoc signature, for local use.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

swift build -c release --product RimControl
bin="$(swift build -c release --show-bin-path)/RimControl"

app="$root/build/RimControl.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/RimControl"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

# macOS ties Accessibility access to this requirement. By default an ad-hoc build's requirement is its
# exact hash, which changes on every rebuild and silently invalidates the grant. Matching the identifier
# keeps the grant, but any app claiming this identifier could inherit it. For local builds only:
# anything distributed needs a real signing certificate instead.
identifier="local.rimcontrol.app"
codesign --force --sign - --identifier "$identifier" -r="designated => identifier \"$identifier\"" "$app"

echo "Built $app"
