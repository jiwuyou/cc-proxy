#!/usr/bin/env sh
set -eu

log() {
  printf '%s\n' "$*"
}

warn() {
  printf '%s\n' "$*" >&2
}

die() {
  warn "ERROR: $*"
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

is_termux=0
if [ -n "${PREFIX:-}" ] && printf '%s' "$PREFIX" | grep -q "com.termux"; then
  is_termux=1
fi

default_install_dir() {
  if [ "$is_termux" = "1" ]; then
    printf '%s/bin\n' "$PREFIX"
    return 0
  fi

  if [ -z "${HOME:-}" ]; then
    die "HOME is not set; set INSTALL_DIR to a writable bin directory."
  fi
  printf '%s/.local/bin\n' "$HOME"
}

install_dir="${INSTALL_DIR:-}"
if [ -z "$install_dir" ]; then
  install_dir="$(default_install_dir)"
fi

install_binary() {
  src="$1"
  [ -x "$src" ] || die "binary is not executable: $src"

  mkdir -p "$install_dir"
  dst="$install_dir/cc-proxy"

  if have install; then
    install -m 0755 "$src" "$dst"
  else
    cp "$src" "$dst"
    chmod 0755 "$dst"
  fi

  log "installed: $dst"

  case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *)
      warn "note: $install_dir is not on PATH"
      warn "  export PATH=\"$install_dir:\$PATH\""
      ;;
  esac
}

mode="${CC_PROXY_INSTALL_MODE:-auto}"
package="${CC_PROXY_NPM_PACKAGE:-ccproxy-cli}"

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
repo_root="$(CDPATH= cd "$script_dir/.." && pwd)"
local_bin="$repo_root/target/release/cc-proxy"

if have cc-proxy; then
  log "cc-proxy already available: $(command -v cc-proxy)"
  exit 0
fi

if [ "$mode" = "auto" ] && [ -x "$local_bin" ]; then
  log "Found existing local build: $local_bin"
  install_binary "$local_bin"
  exit 0
fi

install_via_npm() {
  log "Installing cc-proxy via npm (global): $package"
  npm install -g "$package"

  if have cc-proxy; then
    log "cc-proxy installed: $(command -v cc-proxy)"
    return 0
  fi

  # The package may have installed successfully, but the global npm bin dir
  # isn't on PATH for the current shell/user. Provide a safe hint.
  npm_prefix="$(npm prefix -g 2>/dev/null || true)"
  if [ -n "$npm_prefix" ] && [ -d "$npm_prefix/bin" ]; then
    warn "cc-proxy is not on PATH yet. Add this directory to PATH:"
    warn "  $npm_prefix/bin"
  else
    warn "cc-proxy is not on PATH yet. Check your npm global prefix/bin directory."
  fi
  return 0
}

case "$mode" in
  auto)
    if have npm; then
      install_via_npm
      exit 0
    fi

    warn "npm is not available; refusing to source-build by default."
    if have cargo; then
      warn "cargo is available. To build from source, re-run with:"
      warn "  CC_PROXY_INSTALL_MODE=source $0"
      exit 1
    fi

    die "Neither npm nor cargo is available. Install Node.js/npm (recommended), or Rust for source builds."
    ;;
  npm)
    have npm || die "npm is not available. Install Node.js/npm, or use CC_PROXY_INSTALL_MODE=source."
    install_via_npm
    exit 0
    ;;
  source)
    ;;
  *)
    die "Unknown CC_PROXY_INSTALL_MODE: $mode (expected: auto, npm, source)"
    ;;
esac

# Source build is an explicit developer mode.
have cargo || die "cargo is not available. Install Rust, or install via npm (recommended)."

log "Building cc-proxy from source (release)..."
(
  cd "$repo_root"
  cargo build --release
)

bin_path="$repo_root/target/release/cc-proxy"

if [ ! -x "$bin_path" ]; then
  die "Expected built binary not found: $bin_path"
fi

install_binary "$bin_path"
exit 0
