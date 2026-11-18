#!/bin/bash
# Build TranslateLikeMe (EDITION=direct or EDITION=mas) or TranslateLikeMeBridge
# (EDITION=bridge) and assemble a signed macOS .app bundle (plus .pkg when PACKAGE_MAS=1).
set -euo pipefail

cd "$(dirname "$0")"

EDITION="${EDITION:-direct}"
case "$EDITION" in
    direct)
        APP="Translate Like Me.app"
        [[ "${RELEASE:-}" == 1 ]] || APP="Translate Like Me Dev.app"
        BIN="TranslateLikeMe"
        EMBED_SPARKLE=1
        NEEDS_MLX=1
        ;;
    mas)
        APP="Translate Like Me MAS.app"
        [[ "${RELEASE:-}" == 1 ]] && APP="${MAS_APP_NAME:-Translate Like Me.app}"
        [[ "${RELEASE:-}" == 1 ]] || APP="Translate Like Me MAS Dev.app"
        BIN="TranslateLikeMe"
        EMBED_SPARKLE=0
        NEEDS_MLX=1
        export TLM_EDITION="mas"
        ;;
    bridge)
        APP="Translate Like Me Bridge.app"
        [[ "${RELEASE:-}" == 1 ]] || APP="Translate Like Me Bridge Dev.app"
        BIN="TranslateLikeMeBridge"
        EMBED_SPARKLE=1
        NEEDS_MLX=0
        export TLM_EDITION="bridge"
        ;;
    *)
        echo "error: unknown EDITION '$EDITION' (expected direct, mas, or bridge)" >&2
        exit 1
        ;;
esac

# Apple silicon only: macOS 27 dropped Intel, and the app supports the three
# latest macOS releases (15+).
#
# The native build system is used on purpose: SwiftPM's default swiftbuild (Xcode
# 27, measured 2026-09-23) stamps the binary's LC_BUILD_VERSION sdk with the
# deployment target (15.0) instead of the SDK it compiled against (27.0), and
# AppKit reads that stamp to decide which SDK the app was linked on - an old stamp
# risks the pre-Liquid Glass compatibility look on macOS 26+.
BUILD=(swift build -c release --arch arm64 --build-system native)
if [[ "$EDITION" == "bridge" ]]; then
    BUILD+=(--product TranslateLikeMeBridge)
elif [[ "$EDITION" == "mas" ]]; then
    BUILD+=(--product TranslateLikeMe)
fi

echo "Building $EDITION (release, arm64)..."
"${BUILD[@]}" 2> >(grep -v "build-system native' has been deprecated" >&2)
BIN_DIR="$("${BUILD[@]}" --show-bin-path 2>/dev/null)"
if [[ "$NEEDS_MLX" == 1 ]]; then
    bash scripts/build-mlx-metallib.sh "$BIN_DIR"
fi
# Merges the strings the compiler listed (Package.swift) into the String
# Catalog, as Xcode does on each build, and fails, before anything is
# assembled, on a string missing a translation.
python3 -I scripts/sync-strings.py .build/localized-strings

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$BIN" "$APP/Contents/MacOS/$BIN"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$BIN"

if [[ "$EMBED_SPARKLE" == 1 ]]; then
    # Sparkle, found through @rpath: SwiftPM links it with @loader_path only, which
    # is the build directory, so the bundle's Frameworks folder is added. Its XPC
    # services exist for sandboxed apps; Direct and Bridge are not sandboxed.
    ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
        "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
    cp ".build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle LICENSE.txt"
fi

# SwiftPM does not embed backdeployment libraries when assembling an app by hand.
xcrun swift-stdlib-tool --copy --scan-executable "$APP/Contents/MacOS/$BIN" \
    --scan-folder "$APP/Contents/Frameworks" --platform macosx \
    --destination "$APP/Contents/Frameworks"

if [[ "$NEEDS_MLX" == 1 ]]; then
    # Local speech runtime and models retain their upstream MIT/Apache notices.
    cp .build/checkouts/argmax-oss-swift/LICENSE "$APP/Contents/Resources/WhisperKit LICENSE.txt"
    cp .build/checkouts/argmax-oss-swift/NOTICES "$APP/Contents/Resources/WhisperKit NOTICES.txt"
    cp Resources/Whisper-LICENSE.txt "$APP/Contents/Resources/Whisper LICENSE.txt"
    cp Resources/Silero-LICENSE.txt "$APP/Contents/Resources/Silero LICENSE.txt"
    # MLX uses native Metal kernels; SwiftPM does not compile them itself.
    cp "$BIN_DIR/mlx.metallib" "$APP/Contents/Resources/mlx.metallib"
    cp .build/checkouts/mlx-audio-swift/LICENSE "$APP/Contents/Resources/MLX Audio LICENSE.txt"
    cp .build/checkouts/mlx-swift/LICENSE "$APP/Contents/Resources/MLX Swift LICENSE.txt"
    cp Resources/Qwen-NOTICES.txt "$APP/Contents/Resources/Qwen NOTICES.txt"
    cp Resources/Qwen-LICENSE.txt "$APP/Contents/Resources/Qwen LICENSE.txt"
    cp Resources/FluidSpeech-NOTICES.txt "$APP/Contents/Resources/FluidSpeech NOTICES.txt"
    cp Resources/FluidSpeech-LICENSE.txt "$APP/Contents/Resources/FluidSpeech LICENSE.txt"
    # Read the current build graph: globbing *.bundle would revive stale resources
    # from removed dependencies such as FluidAudio.
    python3 - "$BIN_DIR" "$APP/Contents/Resources" <<'PYTHON'
import json
from pathlib import Path
import subprocess
import sys
import shutil
import os
build = Path(sys.argv[1])
destination = Path(sys.argv[2])
graph = json.loads((build / "description.json").read_text())
bundles = set()
for command in graph["copyCommands"].values():
    for item in command["outputs"]:
        file = Path(item["name"])
        for candidate in (file, *file.parents):
            if candidate.suffix == ".bundle" and candidate.parent == build:
                bundles.add(candidate)
for bundle in sorted(bundle for bundle in bundles if bundle.is_dir()):
    subprocess.run(["ditto", str(bundle), str(destination / bundle.name)], check=True)
pins = {pin["identity"] for pin in json.loads(Path("Package.resolved").read_text())["pins"]}
workspace = json.loads(Path(".build/workspace-state.json").read_text())["object"]
for dependency in workspace["dependencies"]:
    identity = dependency["packageRef"]["identity"]
    if identity not in pins:
        continue
    if os.environ.get("TLM_EDITION") == "mas" and identity.lower() == "sparkle":
        continue
    checkout = Path(".build/checkouts") / dependency["subpath"]
    for directory, folders, filenames in os.walk(checkout):
        folders[:] = [name for name in folders if name != ".git"]
        for name in filenames:
            if not name.upper().startswith(("LICENSE", "LICENCE", "NOTICE", "ACKNOWLEDG")):
                continue
            file = Path(directory) / name
            if file.suffix.lower() not in ("", ".txt", ".md", ".mit") or not file.is_file():
                continue
            target = destination / "Third-party notices" / identity / file.relative_to(checkout)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(file, target)
PYTHON
fi

# Fail loudly, before anything is signed, if the linked-on SDK ever drops back
# to the deployment target.
SDK_STAMP="$(vtool -show-build "$APP/Contents/MacOS/$BIN" | awk '/ sdk /{print $2}')"
if [[ "$SDK_STAMP" != "$(xcrun --show-sdk-version)" ]]; then
    echo "error: binary is stamped sdk $SDK_STAMP, expected $(xcrun --show-sdk-version)" >&2
    exit 1
fi

if [[ "$EDITION" == "bridge" ]]; then
    cp "Resources/Info-Bridge.plist" "$APP/Contents/Info.plist"
    if [[ "${RELEASE:-}" != 1 ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wiltodelta.translatelikeme.bridge.dev" \
            -c "Set :CFBundleName Translate Like Me Bridge Dev" \
            -c "Set :CFBundleDisplayName Translate Like Me Bridge Dev" \
            -c "Delete :SUFeedURL" -c "Set :SUEnableAutomaticChecks false" "$APP/Contents/Info.plist"
    fi
elif [[ "$EDITION" == "mas" ]]; then
    cp "Resources/Info.plist" "$APP/Contents/Info.plist"
    # Strip Sparkle keys (Guideline 2.4.5(iv)) and stamp MAS bundle id + NSServices.
    python3 - "$APP/Contents/Info.plist" "${RELEASE:-0}" <<'PYTHON'
import plistlib, sys
plist_path, release = sys.argv[1], sys.argv[2] == "1"
with open(plist_path, "rb") as f:
    data = plistlib.load(f)
for key in list(data.keys()):
    if key.startswith("SU"):
        del data[key]
if release:
    data["CFBundleIdentifier"] = "com.wiltodelta.translatelikeme.mas"
else:
    data["CFBundleIdentifier"] = "com.wiltodelta.translatelikeme.mas.dev"
    data["CFBundleName"] = "Translate Like Me MAS Dev"
    data["CFBundleDisplayName"] = "Translate Like Me MAS Dev"
port_name = data["CFBundleName"]
data["NSServices"] = [
    {
        "NSMenuItem": {"default": "Translate with Translate Like Me"},
        "NSMessage": "translateSelectionService",
        "NSPortName": port_name,
        "NSSendTypes": ["public.utf8-plain-text", "NSStringPboardType"],
        "NSReturnTypes": ["public.utf8-plain-text", "NSStringPboardType"],
    },
    {
        "NSMenuItem": {"default": "Rewrite with Translate Like Me"},
        "NSMessage": "rewriteSelectionService",
        "NSPortName": port_name,
        "NSSendTypes": ["public.utf8-plain-text", "NSStringPboardType"],
        "NSReturnTypes": ["public.utf8-plain-text", "NSStringPboardType"],
    },
]
with open(plist_path, "wb") as f:
    plistlib.dump(data, f, sort_keys=True)
PYTHON
else
    cp "Resources/Info.plist" "$APP/Contents/Info.plist"
    if [[ "${RELEASE:-}" != 1 ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wiltodelta.translatelikeme.dev" \
            -c "Set :CFBundleName Translate Like Me Dev" -c "Set :CFBundleDisplayName Translate Like Me Dev" \
            -c "Set :SUEnableAutomaticChecks false" "$APP/Contents/Info.plist"
    fi
fi

VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if [[ -n "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "error: no git tag to take the version from" >&2
    exit 1
fi

MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
grep -q ".macOS(\"$MIN_MACOS\")" Package.swift ||
    { echo "error: Package.swift platform differs from LSMinimumSystemVersion $MIN_MACOS" >&2; exit 1; }

ICON_INFO="$(mktemp -t tlm-icon)"
ENTITLEMENTS_TMP="$(mktemp -t tlm-ent)"
trap 'rm -f "$ICON_INFO" "$ENTITLEMENTS_TMP"' EXIT

xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
    --output-partial-info-plist "$ICON_INFO" >/dev/null

for CATALOG in Localizable InfoPlist; do
    xcrun xcstringstool compile "Resources/$CATALOG.xcstrings" --output-directory "$APP/Contents/Resources" >/dev/null
done
cp "Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [[ "$EDITION" != "bridge" ]]; then
    cp "Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
    cp "Resources/MenuBarBusy.png" "$APP/Contents/Resources/MenuBarBusy.png"
fi

if [[ "$EDITION" == "mas" && -n "${MAS_PROVISIONING_PROFILE:-}" ]]; then
    cp "$MAS_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

# productbuild installs /Applications owned by root:wheel; any 0600 file (such as
# a copied .provisionprofile) fails App Store Connect validation with ITMS-90255.
chmod -R a+rX "$APP"

if [[ "$EDITION" == "mas" ]]; then
    cp "Resources/Entitlements-MAS.plist" "$ENTITLEMENTS_TMP"
    if [[ "${RELEASE:-}" == 1 ]]; then
        /usr/libexec/PlistBuddy \
            -c "Add :com.apple.application-identifier string K2GT9Q4S6U.com.wiltodelta.translatelikeme.mas" \
            -c "Add :com.apple.developer.team-identifier string K2GT9Q4S6U" \
            "$ENTITLEMENTS_TMP"
    else
        /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 K2GT9Q4S6U.tlm.dev" "$ENTITLEMENTS_TMP"
    fi
elif [[ "$EDITION" == "bridge" ]]; then
    cp "Resources/Entitlements-Bridge.plist" "$ENTITLEMENTS_TMP"
    if [[ "${RELEASE:-}" != 1 ]]; then
        /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 K2GT9Q4S6U.tlm.dev" "$ENTITLEMENTS_TMP"
    fi
else
    cp "Resources/Entitlements.plist" "$ENTITLEMENTS_TMP"
fi

TEAM_ID="K2GT9Q4S6U"
if [[ "$EDITION" == "mas" && "${RELEASE:-}" == 1 && -n "${MAS_APP_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$MAS_APP_IDENTITY"
elif [[ "$EDITION" == "mas" && "${RELEASE:-}" == 1 ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' -v team="($TEAM_ID)" '/(3rd Party Mac Developer Application|Apple Distribution):/ && index($2, team) {print $2; exit}')"
else
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' -v team="($TEAM_ID)" '/Developer ID Application:/ && index($2, team) {print $2; exit}')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    TIMESTAMP="--timestamp=none"
    [[ "${RELEASE:-}" == 1 ]] && TIMESTAMP="--timestamp"
    SIGN=(codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY")
elif [[ "${RELEASE:-}" == 1 ]]; then
    echo "error: RELEASE=1 ($EDITION) but no matching signing identity for team $TEAM_ID" >&2
    exit 1
else
    echo "warning: no signing identity found, signing ad hoc"
    SIGN=(codesign --force --sign -)
fi

for LIBRARY in "$APP/Contents/Frameworks/"*.dylib; do
    [[ -f "$LIBRARY" ]] || continue
    "${SIGN[@]}" "$LIBRARY"
done
if [[ "$EMBED_SPARKLE" == 1 ]]; then
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    "${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
    "${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
    "${SIGN[@]}" "$SPARKLE"
fi
"${SIGN[@]}" --entitlements "$ENTITLEMENTS_TMP" "$APP"
bash scripts/check-swift-runtime.sh "$APP"

if [[ "$EDITION" == "mas" ]]; then
    if otool -L "$APP/Contents/MacOS/$BIN" | grep -qi Sparkle; then
        echo "error: MAS binary still links Sparkle" >&2
        exit 1
    fi
fi

if [[ "$EDITION" == "mas" && "${PACKAGE_MAS:-0}" == 1 ]]; then
    PKG_OUT="${MAS_PKG_PATH:-Translate-Like-Me-MAS.pkg}"
    INSTALLER_ID="${MAS_INSTALLER_IDENTITY:-$(security find-identity -v 2>/dev/null \
        | awk -F'"' -v team="($TEAM_ID)" '/3rd Party Mac Developer Installer:/ && index($2, team) {print $2; exit}')}"
    if [[ -n "$INSTALLER_ID" ]]; then
        productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG_OUT"
    else
        productbuild --component "$APP" /Applications "$PKG_OUT"
    fi
    echo "Packaged MAS installer: $PWD/$PKG_OUT"
fi

echo "Done: $PWD/$APP"
echo "Launch with: open \"$PWD/$APP\""
