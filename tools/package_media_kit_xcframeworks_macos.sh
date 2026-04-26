#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd ruby otool install_name_tool lipo codesign plutil tar shasum

find_tool() {
  local env_name="$1"
  local xcrun_name="$2"
  local fallback_name="$3"
  local value="${!env_name:-}"

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if command -v xcrun >/dev/null 2>&1; then
    value="$(xcrun --find "$xcrun_name" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi

  command -v "$fallback_name"
}

if ! XCODEBUILD_BIN="$(find_tool XCODEBUILD_BIN xcodebuild xcodebuild)"; then
  echo "Missing required command: xcodebuild" >&2
  exit 1
fi
if ! VTOOL_BIN="$(find_tool VTOOL_BIN vtool vtool)"; then
  echo "Missing required command: vtool" >&2
  exit 1
fi

MEDIA_KIT_XCFRAMEWORKS_VERSION="${MEDIA_KIT_XCFRAMEWORKS_VERSION:-0.0.0}"
MEDIA_KIT_XCFRAMEWORKS_TARGET_LABELS="${MEDIA_KIT_XCFRAMEWORKS_TARGET_LABELS:-macos-arm64 macos-universal}"
MEDIA_KIT_XCFRAMEWORKS_VARIANT="${MEDIA_KIT_XCFRAMEWORKS_VARIANT:-video}"
MEDIA_KIT_XCFRAMEWORKS_FLAVOR="${MEDIA_KIT_XCFRAMEWORKS_FLAVOR:-full}"
MEDIA_KIT_DYLIB_ROOT="$WORK_ROOT/media-kit-dylibs"
MEDIA_KIT_FRAMEWORK_ROOT="$WORK_ROOT/media-kit-frameworks"
MEDIA_KIT_XCFRAMEWORK_ROOT="$WORK_ROOT/media-kit-xcframeworks"
MEDIA_KIT_MANIFEST_PATH="$ARTIFACT_ROOT/media-kit-xcframeworks-manifest.txt"

LIBMPV_PATH=""
if [[ -f "$MPV_PREFIX/lib/libmpv.2.dylib" ]]; then
  LIBMPV_PATH="$MPV_PREFIX/lib/libmpv.2.dylib"
elif [[ -f "$MPV_PREFIX/lib/libmpv.dylib" ]]; then
  LIBMPV_PATH="$MPV_PREFIX/lib/libmpv.dylib"
else
  echo "Could not locate libmpv dylib under $MPV_PREFIX/lib" >&2
  exit 1
fi

framework_name_for_dylib() {
  local dylib="$1"
  local name

  name="$(basename "$dylib" .dylib | sed 's/\.[0-9][0-9]*$//' | sed 's/^lib//')"
  printf '%s%s' "$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')" "${name:1}"
}

detect_min_macos_version() {
  local binary="$1"
  local min_version=""
  local arch
  local candidate

  for arch in $(lipo -archs "$binary"); do
    candidate="$(
      "$VTOOL_BIN" -arch "$arch" -show-build "$binary" 2>/dev/null |
        awk '/^[[:space:]]*minos[[:space:]]+/ { print $2; exit } /^[[:space:]]*version[[:space:]]+[0-9]+\./ { print $2; exit }'
    )" || true

    if [[ -z "$candidate" ]]; then
      continue
    fi

    if [[ -z "$min_version" ]] || awk -v a="$candidate" -v b="$min_version" 'BEGIN { split(a, av, "."); split(b, bv, "."); for (i = 1; i <= 3; i++) { ai = av[i] + 0; bi = bv[i] + 0; if (ai < bi) exit 0; if (ai > bi) exit 1 } exit 1 }'; then
      min_version="$candidate"
    fi
  done

  printf '%s' "${min_version:-${MACOSX_DEPLOYMENT_TARGET:-10.13}}"
}

write_framework_info_plist() {
  local plist_path="$1"
  local framework_name="$2"
  local min_os_version="$3"

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleExecutable</key>
    <string>$framework_name</string>
    <key>CFBundleIdentifier</key>
    <string>com.github.media-kit.$framework_name</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>$min_os_version</string>
  </dict>
</plist>
PLIST
  plutil -convert binary1 "$plist_path"
}

rewrite_framework_deps() {
  local binary="$1"
  local dep
  local dep_name
  local dep_framework_name
  local new_dep

  while IFS= read -r dep; do
    dep_name="$(basename "$dep" .dylib | sed 's/\.[0-9][0-9]*$//' | sed 's/^lib//')"
    dep_framework_name="$(printf '%s%s' "$(printf '%s' "${dep_name:0:1}" | tr '[:lower:]' '[:upper:]')" "${dep_name:1}")"
    new_dep="@rpath/${dep_framework_name}.framework/Versions/A/${dep_framework_name}"
    install_name_tool -change "$dep" "$new_dep" "$binary" 2>/dev/null || true
  done < <(
    otool -L "$binary" |
      tail -n +3 |
      awk '$1 ~ /^@rpath\/.*\.dylib$/ { print $1 }'
  )
}

log "Collecting libmpv dylib closure for media_kit"
rm -rf "$MEDIA_KIT_DYLIB_ROOT" "$MEDIA_KIT_FRAMEWORK_ROOT" "$MEDIA_KIT_XCFRAMEWORK_ROOT"
mkdir -p "$MEDIA_KIT_DYLIB_ROOT" "$MEDIA_KIT_FRAMEWORK_ROOT" "$MEDIA_KIT_XCFRAMEWORK_ROOT"
ruby "$REPO_ROOT/tools/collect_dylibs.rb" "$MEDIA_KIT_DYLIB_ROOT" "$FFMPEG_PREFIX" "$MPV_PREFIX" "$LIBMPV_PATH"

log "Wrapping dylibs as macOS frameworks"
find "$MEDIA_KIT_DYLIB_ROOT" -maxdepth 1 -type f -name '*.dylib' -print | sort | while IFS= read -r dylib; do
  framework_name="$(framework_name_for_dylib "$dylib")"
  framework_dir="$MEDIA_KIT_FRAMEWORK_ROOT/${framework_name}.framework"

  if [[ -d "$framework_dir" ]]; then
    continue
  fi

  min_os_version="$(detect_min_macos_version "$dylib")"
  mkdir -p "$framework_dir/Versions/A/Resources"
  cp "$dylib" "$framework_dir/Versions/A/$framework_name"

  framework_binary="$framework_dir/Versions/A/$framework_name"
  install_name_tool -id "@rpath/${framework_name}.framework/Versions/A/${framework_name}" "$framework_binary" 2>/dev/null || true
  rewrite_framework_deps "$framework_binary"
  write_framework_info_plist "$framework_dir/Versions/A/Resources/Info.plist" "$framework_name" "$min_os_version"

  ln -s A "$framework_dir/Versions/Current"
  ln -s "Versions/Current/$framework_name" "$framework_dir/$framework_name"
  ln -s Versions/Current/Resources "$framework_dir/Resources"
  codesign --force --sign - "$framework_dir"
done

log "Creating xcframeworks"
find "$MEDIA_KIT_FRAMEWORK_ROOT" -maxdepth 1 -type d -name '*.framework' -print | sort | while IFS= read -r framework_dir; do
  framework_name="$(basename "$framework_dir" .framework)"
  output_path="$MEDIA_KIT_XCFRAMEWORK_ROOT/${framework_name}.xcframework"
  rm -rf "$output_path"
  "$XCODEBUILD_BIN" -create-xcframework -framework "$framework_dir" -output "$output_path"
done

{
  echo "media_kit xcframeworks version: $MEDIA_KIT_XCFRAMEWORKS_VERSION"
  echo "target labels: $MEDIA_KIT_XCFRAMEWORKS_TARGET_LABELS"
  echo "variant: $MEDIA_KIT_XCFRAMEWORKS_VARIANT"
  echo "flavor: $MEDIA_KIT_XCFRAMEWORKS_FLAVOR"
  echo "libmpv path: $LIBMPV_PATH"
  echo "dylib root: $MEDIA_KIT_DYLIB_ROOT"
  echo "framework root: $MEDIA_KIT_FRAMEWORK_ROOT"
  echo "xcframework root: $MEDIA_KIT_XCFRAMEWORK_ROOT"
  echo
  echo "XCFrameworks:"
  find "$MEDIA_KIT_XCFRAMEWORK_ROOT" -maxdepth 1 -type d -name '*.xcframework' -print | sort
  echo
  echo "Archives:"
} > "$MEDIA_KIT_MANIFEST_PATH"

for target_label in $MEDIA_KIT_XCFRAMEWORKS_TARGET_LABELS; do
  package_name="libmpv-xcframeworks_${MEDIA_KIT_XCFRAMEWORKS_VERSION}_${target_label}-${MEDIA_KIT_XCFRAMEWORKS_VARIANT}-${MEDIA_KIT_XCFRAMEWORKS_FLAVOR}"
  package_root="$WORK_ROOT/$package_name"
  archive_path="$ARTIFACT_ROOT/$package_name.tar.gz"

  rm -rf "$package_root" "$archive_path"
  mkdir -p "$package_root"
  cp -R "$MEDIA_KIT_XCFRAMEWORK_ROOT"/*.xcframework "$package_root/"

  (
    cd "$WORK_ROOT"
    tar -czf "$archive_path" "$package_name"
  )

  shasum -a 256 "$archive_path" >> "$MEDIA_KIT_MANIFEST_PATH"
  log "Created media_kit xcframework archive: $archive_path"
done
