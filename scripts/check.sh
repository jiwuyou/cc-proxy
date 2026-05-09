#!/usr/bin/env sh
set -eu

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

have cc-proxy || die "cc-proxy is not on PATH. Try: ./scripts/install.sh"

cc_bin="$(command -v cc-proxy)"
printf 'cc-proxy: %s\n' "$cc_bin"

# Must not invoke interactive mode or print any stored secrets.
cc-proxy --help >/dev/null 2>&1 || die "cc-proxy --help failed"
cc-proxy --version >/dev/null 2>&1 || die "cc-proxy --version failed"
cc-proxy status --help >/dev/null 2>&1 || die "cc-proxy status --help failed"

printf 'OK\n'

