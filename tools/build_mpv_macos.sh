#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd git meson ninja pkg-config install_name_tool otool

MPV_GIT_URL="${MPV_GIT_URL:-https://github.com/Yuch3nE/mpv.git}"
MPV_SOURCE_DIR="$SOURCE_ROOT/mpv"
MPV_BUILD_DIR="$WORK_ROOT/mpv-build"
MESON_BIN="${MESON_BIN:-meson}"
NINJA_BIN="${NINJA_BIN:-ninja}"
MPV_PATCH_ROOT="$SCRIPT_DIR/patches/mpv"

[[ -d "$FFMPEG_PREFIX/lib/pkgconfig" ]] || {
  echo "FFmpeg prefix not found at $FFMPEG_PREFIX. Run build_ffmpeg_prefix_macos.sh first." >&2
  exit 1
}

pkg_paths=("$FFMPEG_PREFIX/lib/pkgconfig")
export PKG_CONFIG_PATH="$(join_by : "${pkg_paths[@]}")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="-I$FFMPEG_PREFIX/include${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="-L$FFMPEG_PREFIX/lib${LDFLAGS:+ $LDFLAGS}"

# Locate MoltenVK + Vulkan headers so mpv's Vulkan render backend (used by the
# libmpv gpu-next Vulkan API) can be enabled. Allow overrides via env vars,
# fall back to Homebrew. If neither is available, leave Vulkan disabled.
MOLTENVK_PREFIX="${MOLTENVK_PREFIX:-}"
VULKAN_HEADERS_PREFIX="${VULKAN_HEADERS_PREFIX:-}"
if [[ -z "$MOLTENVK_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
  MOLTENVK_PREFIX="$(brew --prefix molten-vk 2>/dev/null || true)"
fi
if [[ -z "$VULKAN_HEADERS_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
  VULKAN_HEADERS_PREFIX="$(brew --prefix vulkan-headers 2>/dev/null || true)"
fi

vulkan_meson_option="disabled"
if [[ -n "$MOLTENVK_PREFIX" && -d "$MOLTENVK_PREFIX/lib" ]]; then
  if [[ -n "$VULKAN_HEADERS_PREFIX" && -d "$VULKAN_HEADERS_PREFIX/include" ]]; then
    export CPPFLAGS="-I$VULKAN_HEADERS_PREFIX/include $CPPFLAGS"
  fi
  if [[ -d "$MOLTENVK_PREFIX/include" ]]; then
    export CPPFLAGS="-I$MOLTENVK_PREFIX/include $CPPFLAGS"
  fi
  export LDFLAGS="-L$MOLTENVK_PREFIX/lib $LDFLAGS"
  # MoltenVK ships as libMoltenVK.dylib and acts as the Vulkan ICD on macOS.
  # libplacebo / mpv link against the Vulkan loader API regardless; on macOS
  # the dylib name is libvulkan.dylib provided by the Vulkan-Loader package
  # (also available via brew). Detect optional vulkan-loader prefix.
  VULKAN_LOADER_PREFIX="${VULKAN_LOADER_PREFIX:-}"
  if [[ -z "$VULKAN_LOADER_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
    VULKAN_LOADER_PREFIX="$(brew --prefix vulkan-loader 2>/dev/null || true)"
  fi
  if [[ -n "$VULKAN_LOADER_PREFIX" && -d "$VULKAN_LOADER_PREFIX/lib" ]]; then
    export LDFLAGS="-L$VULKAN_LOADER_PREFIX/lib $LDFLAGS"
    if [[ -d "$VULKAN_LOADER_PREFIX/lib/pkgconfig" ]]; then
      export PKG_CONFIG_PATH="$VULKAN_LOADER_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
    fi
  fi
  if "$PKG_CONFIG_BIN" --exists vulkan; then
    vulkan_meson_option="enabled"
    log "Vulkan render backend will be enabled (MoltenVK at $MOLTENVK_PREFIX)"
  else
    log "Vulkan loader pkg-config not found; Vulkan render backend disabled"
  fi
else
  log "MoltenVK not found (set MOLTENVK_PREFIX or 'brew install molten-vk'); Vulkan render backend disabled"
fi

log "Fetching mpv source"
rm -rf "$MPV_SOURCE_DIR" "$MPV_BUILD_DIR" "$MPV_PREFIX"
git init "$MPV_SOURCE_DIR" >/dev/null
git -C "$MPV_SOURCE_DIR" remote add origin "$MPV_GIT_URL"
git -C "$MPV_SOURCE_DIR" fetch --depth 1 origin
git -C "$MPV_SOURCE_DIR" checkout --detach FETCH_HEAD

# if [[ -d "$MPV_PATCH_ROOT" ]]; then
#   while IFS= read -r patch_path; do
#     log "Applying mpv $(basename "$patch_path")"
#     if ! git -C "$MPV_SOURCE_DIR" apply --check --recount --ignore-space-change --ignore-whitespace "$patch_path" >/dev/null 2>&1; then
#       echo "Failed to apply mpv patch: $patch_path" >&2
#       exit 1
#     fi
#     git -C "$MPV_SOURCE_DIR" apply --recount --ignore-space-change --ignore-whitespace "$patch_path"
#   done < <(find "$MPV_PATCH_ROOT" -maxdepth 1 -type f -name '*.patch' | sort)
# fi

log "Configuring mpv"
meson_flags=(
  setup "$MPV_BUILD_DIR" "$MPV_SOURCE_DIR"
  --prefix "$MPV_PREFIX"
  --buildtype release
  -Dlibmpv=true
  -Dcplayer=false
  -Dtests=false
  -Dmanpage-build=disabled
  -Dlua=enabled
  -Djavascript=enabled
  "-Dvulkan=$vulkan_meson_option"
)
append_flags_from_env MPV_EXTRA_MESON_FLAGS meson_flags
"$MESON_BIN" "${meson_flags[@]}"

log "Building mpv"
"$MESON_BIN" compile -C "$MPV_BUILD_DIR"
"$MESON_BIN" install -C "$MPV_BUILD_DIR"

[[ -f "$MPV_PREFIX/lib/libmpv.dylib" || -f "$MPV_PREFIX/lib/libmpv.2.dylib" ]] || {
  echo "libmpv dylib was not produced under $MPV_PREFIX/lib" >&2
  exit 1
}

cat > "$ARTIFACT_ROOT/mpv-build-manifest.txt" <<MANIFEST
mpv ref: $MPV_REF
mpv prefix: $MPV_PREFIX
FFmpeg prefix: $FFMPEG_PREFIX
Meson args:
$(printf '  %s\n' "${meson_flags[@]}")
MANIFEST
