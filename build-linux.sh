#!/usr/bin/env bash
# ============================================================================
# build-linux.sh — Cross-compile Flarial.dll (the client "addon") on Linux.
#
# The official CI (.github/workflows/build-latest.yml) already builds this
# repository on Linux runners. This script mirrors it locally and supports
# two toolchains:
#
#   msvc-wine  (default)   Real MSVC cl.exe/link.exe/rc.exe running under Wine,
#                          installed with the msvc-wine project. This is exactly
#                          what the official CI uses, so it is the most proven
#                          path (C++/WinRT, D2D, FetchContent deps, .rc, PDBs).
#
#   clang-cl               Wine-free alternative: the native Linux clang-cl
#                          binary in MSVC mode + lld-link, with the Windows SDK
#                          & CRT fetched by `xwin`. No Wine involved.
#                          Experimental: expect possible source-level quirks.
#
# Nothing is installed automatically. To download a toolchain (opt-in):
#   ./build-linux.sh --setup                        # auto-detected toolchain
#   ./build-linux.sh --toolchain msvc-wine --setup  # MSVC under Wine (~5 GB)
#   ./build-linux.sh --toolchain clang-cl  --setup  # Windows SDK via xwin (~2 GB)
#
# Then build:
#   ./build-linux.sh                                # Release (default)
#   ./build-linux.sh --type debug --clean           # Debug, wipe build dir first
#   ./build-linux.sh --toolchain msvc-wine -j 16    # pick toolchain explicitly
#   ./build-linux.sh --out dist                     # copy Flarial.dll/.pdb to dist/
#   ./build-linux.sh -- -DFETCHCONTENT_FULLY_DISCONNECTED=OFF  # extra cmake args after --
#
# Output artifacts:
#   build-linux-<toolchain>/Flarial.dll  (+ Flarial.pdb)
#
# Environment overrides:
#   MSVC_DIR      existing msvc-wine install  (probes /opt/msvc, ~/opt/flarial-msvc)
#   XWIN_DIR      xwin cache + splat root     (default ~/.cache/flarial-xwin)
#   WINEPREFIX    wine prefix for msvc-wine   (default ~/.wine-flarial-msvc)
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSVC_DIR="${MSVC_DIR:-}"
XWIN_DIR="${XWIN_DIR:-$HOME/.cache/flarial-xwin}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-flarial-msvc}"

TOOLCHAIN="auto"
BTYPE="Release"
JOBS="$(nproc 2>/dev/null || echo 4)"
DO_SETUP=0
CLEAN=0
NO_PCH=0
OUT_DIR=""
EXTRA_CMAKE_ARGS=()

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolchain) TOOLCHAIN="${2:?}"; shift 2 ;;
    --type)      BTYPE="$(printf '%s' "${2:?}" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
    --setup)     DO_SETUP=1; shift ;;
    --clean)     CLEAN=1; shift ;;
    --no-pch)    NO_PCH=1; shift ;;
    -j|--jobs)   JOBS="${2:?}"; shift 2 ;;
    --out)       OUT_DIR="${2:?}"; shift 2 ;;
    -h|--help)   usage ;;
    --)          shift; EXTRA_CMAKE_ARGS=("$@"); break ;;
    *)           die "Unknown option: $1 (see --help)" ;;
  esac
done

case "$BTYPE" in Release|Debug|Test) ;; *) die "--type must be release|debug|test" ;; esac

find_msvc_dir() {
  local d
  for d in "$MSVC_DIR" /opt/msvc "$HOME/opt/flarial-msvc"; do
    [[ -n "$d" && -f "$d/bin/x64/msvcenv.sh" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

detect_toolchain() {
  case "$TOOLCHAIN" in
    msvc-wine|clang-cl) ;;
    auto)
      if find_msvc_dir >/dev/null 2>&1; then
        TOOLCHAIN="msvc-wine"
      elif have clang-cl; then
        TOOLCHAIN="clang-cl"
      else
        TOOLCHAIN="msvc-wine"
      fi
      ;;
    *) die "Unknown --toolchain '$TOOLCHAIN' (auto|msvc-wine|clang-cl)" ;;
  esac
}

# ---------------------------------------------------------------------------
# --setup: download toolchains (explicit opt-in only, never automatic)
# ---------------------------------------------------------------------------
setup_msvc_wine() {
  local dest="${MSVC_DIR:-$HOME/opt/flarial-msvc}"
  if [[ -f "$dest/bin/x64/msvcenv.sh" ]]; then
    info "msvc-wine already installed at $dest"
    return 0
  fi
  info "Installing MSVC + Windows SDK via msvc-wine into: $dest"
  info "This downloads several GB from Microsoft and takes a while."
  for t in python3 curl git msiextract wine; do
    have "$t" || die "Missing prerequisite '$t'.
  Debian/Ubuntu: sudo apt install python3 curl git msitools wine64 winbind
  Arch:          sudo pacman -S python curl git msitools wine winbind"
  done
  local tmp; tmp="$(mktemp -d)"
  git clone --depth=1 https://github.com/mstorsjo/msvc-wine "$tmp/msvc-wine"
  python3 "$tmp/msvc-wine/vsdownload.py" --accept-license --dest "$dest"
  "$tmp/msvc-wine/install.sh" "$dest"
  info "Done. Build with:  MSVC_DIR=$dest ./build-linux.sh"
  warn "If a build fails with 'fatal error C1902' or mspdbsrv.exe hangs, install winbind."
}

setup_clang_cl() {
  for t in clang-cl lld-link llvm-rc llvm-mt curl tar python3; do
    have "$t" || die "Missing '$t'. Install the LLVM toolchain (clang, lld, llvm)."
  done
  mkdir -p "$XWIN_DIR/toolchain"
  local xwinbin="$XWIN_DIR/toolchain/bin/xwin"
  if [[ ! -x "$xwinbin" ]]; then
    info "Fetching prebuilt xwin binary..."
    local url tmp
    url="$(curl -fsSL https://api.github.com/repos/Jake-Shadle/xwin/releases/latest \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(a["browser_download_url"] for a in d["assets"] if "x86_64-unknown-linux-musl" in a["name"]))')"
    tmp="$(mktemp -d)"
    curl -fsSL "$url" -o "$tmp/xwin.tar.gz"
    tar -xzf "$tmp/xwin.tar.gz" -C "$tmp"
    local found; found="$(find "$tmp" -type f -name xwin | head -n1)"
    [[ -n "$found" ]] || die "xwin binary not found in the release tarball"
    install -Dm755 "$found" "$xwinbin"
    rm -rf "$tmp"
  fi
  if [[ ! -d "$XWIN_DIR/splat/crt" ]]; then
    info "Downloading Windows SDK + CRT via xwin (~2 GB)..."
    "$xwinbin" --accept-license --cache-dir "$XWIN_DIR/cache" --arch x86_64 \
               splat --output "$XWIN_DIR/splat"
  fi
  info "clang-cl toolchain ready in $XWIN_DIR"
  info "Build with:  XWIN_DIR=$XWIN_DIR ./build-linux.sh --toolchain clang-cl"
}

# ---------------------------------------------------------------------------
# Toolchain 1: msvc-wine (mirrors the official CI invocation)
# ---------------------------------------------------------------------------
build_msvc_wine() {
  local msvc_dir; msvc_dir="$(find_msvc_dir)" || \
    die "msvc-wine toolchain not found. Run: ./build-linux.sh --toolchain msvc-wine --setup
(or point MSVC_DIR at an existing install)"
  local bin="$msvc_dir/bin/x64"
  info "Toolchain: msvc-wine ($msvc_dir), wine prefix: $WINEPREFIX"
  export WINEPREFIX
  # shellcheck source=/dev/null
  source "$bin/msvcenv.sh"

  local cppwinrt
  cppwinrt="$(find "$msvc_dir/Windows Kits/10/Include" -maxdepth 2 -type d -name cppwinrt \
              | sort -V | tail -n1)"
  [[ -n "$cppwinrt" ]] || \
    die "cppwinrt headers not found under '$msvc_dir/Windows Kits/10/Include'"

  local bdir="$ROOT/build-linux-msvc"
  cmake -G Ninja -S "$ROOT" -B "$bdir" \
    -DCMAKE_BUILD_TYPE="$BTYPE" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER="$bin/cl" \
    -DCMAKE_CXX_COMPILER="$bin/cl" \
    -DCMAKE_LINKER="$bin/link" \
    -DCMAKE_RC_COMPILER="$bin/rc" \
    -DCMAKE_CXX_FLAGS="/I\"$cppwinrt\"" \
    ${EXTRA_CMAKE_ARGS[@]+"${EXTRA_CMAKE_ARGS[@]}"}
  cmake --build "$bdir" -j "$JOBS"
  printf '%s' "$bdir"
}

# ---------------------------------------------------------------------------
# Toolchain 2: clang-cl + lld-link (no Wine), SDK/CRT via xwin
# ---------------------------------------------------------------------------
build_clang_cl() {
  have clang-cl || die "clang-cl not found (install LLVM)"
  have lld-link || die "lld-link not found (install LLVM)"
  if ! cmake --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 \
       | grep -qE '^([2-9]|[1-9][0-9]|[0-9]+)\.' ; then
    warn "Could not determine CMake version"
  fi
  local splat="$XWIN_DIR/splat"
  [[ -d "$splat" ]] || \
    die "xwin splat not found at '$splat'. Run: ./build-linux.sh --toolchain clang-cl --setup"

  local crt_inc="$splat/crt/include"
  local sdk_inc="$splat/sdk/include"
  local crt_lib="$splat/crt/lib/x86_64"
  local sdk_lib="$splat/sdk/lib"
  local d
  for d in "$crt_inc" "$sdk_inc/um" "$sdk_inc/ucrt" "$sdk_inc/shared" \
           "$sdk_inc/winrt" "$sdk_inc/cppwinrt" "$crt_lib" \
           "$sdk_lib/um/x86_64" "$sdk_lib/ucrt/x86_64"; do
    [[ -d "$d" ]] || die "Unexpected xwin layout: missing '$d'
(inspect '$XWIN_DIR' — was it produced by 'xwin splat --output ...'?)"
  done

  # clang-cl consumes INCLUDE like cl.exe; lld-link consumes LIB like link.exe
  export INCLUDE="$crt_inc;$sdk_inc/um;$sdk_inc/ucrt;$sdk_inc/shared;$sdk_inc/winrt;$sdk_inc/cppwinrt"
  export LIB="$crt_lib;$sdk_lib/um/x86_64;$sdk_lib/ucrt/x86_64"
  info "Toolchain: clang-cl ($(clang-cl --version | head -n1))"
  info "INCLUDE/LIB point at $splat"

  local bdir="$ROOT/build-linux-clang"
  cmake -G Ninja -S "$ROOT" -B "$bdir" \
    -DCMAKE_BUILD_TYPE="$BTYPE" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER=clang-cl \
    -DCMAKE_CXX_COMPILER=clang-cl \
    -DCMAKE_LINKER=lld-link \
    -DCMAKE_RC_COMPILER=llvm-rc \
    -DCMAKE_MT=llvm-mt \
    -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="$ROOT/cmake/linux-rc-enable.cmake" \
    ${NO_PCH:+-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON} \
    ${EXTRA_CMAKE_ARGS[@]+"${EXTRA_CMAKE_ARGS[@]}"}
  cmake --build "$bdir" -j "$JOBS"
  printf '%s' "$bdir"
}

main() {
  [[ -f "$ROOT/CMakeLists.txt" ]] || die "Run this script from the Flarial dll-oss repository."
  detect_toolchain

  if [[ "$DO_SETUP" == 1 ]]; then
    case "$TOOLCHAIN" in
      msvc-wine) setup_msvc_wine ;;
      clang-cl)  setup_clang_cl ;;
    esac
    return 0
  fi

  local bdir
  case "$TOOLCHAIN" in
    msvc-wine)
      [[ "$CLEAN" == 1 ]] && rm -rf "$ROOT/build-linux-msvc"
      info "Building Flarial.dll ($BTYPE) — toolchain: msvc-wine"
      bdir="$(build_msvc_wine)"
      ;;
    clang-cl)
      [[ "$CLEAN" == 1 ]] && rm -rf "$ROOT/build-linux-clang"
      info "Building Flarial.dll ($BTYPE) — toolchain: clang-cl (experimental)"
      bdir="$(build_clang_cl)"
      ;;
  esac

  echo
  info "Artifacts:"
  ls -la "$bdir/Flarial.dll" 2>/dev/null || die "Flarial.dll was not produced"
  [[ -f "$bdir/Flarial.pdb" ]] && ls -la "$bdir/Flarial.pdb"
  if [[ -n "$OUT_DIR" ]]; then
    mkdir -p "$OUT_DIR"
    cp -f "$bdir/Flarial.dll" "$OUT_DIR/"
    [[ -f "$bdir/Flarial.pdb" ]] && cp -f "$bdir/Flarial.pdb" "$OUT_DIR/"
    info "Copied to $OUT_DIR/"
  fi
}

main "$@"
