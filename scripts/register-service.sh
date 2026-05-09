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

service_name="cc-proxy"
port="${CC_PROXY_PORT:-8082}"

base="${SERVICE_MANAGER_URL:-http://127.0.0.1:8787}"
token="${SERVICE_MANAGER_TOKEN:-}"

spec_json() {
  cat <<EOF
{
  "name": "$service_name",
  "description": "OpenHouse component: cc-proxy (Claude Code proxy)",
  "provider": "process",
  "command": ["cc-proxy", "start"],
  "working_dir": "",
  "env": {
    "PORT": "$port"
  },
  "runtime": {},
  "restart": { "mode": "always", "max_retries": 0 },
  "health": [
    {
      "type": "http",
      "url": "http://127.0.0.1:$port/health",
      "interval": "30s",
      "timeout": "5s"
    }
  ],
  "enabled": true,
  "tags": ["group:local-stack", "openhouse-component:cc-proxy"]
}
EOF
}

extract_id_from_obj() {
  if have jq; then
    jq -r '.id // ""'
    return 0
  fi
  if have python3; then
    python3 -c '
import sys, json
try:
    obj = json.load(sys.stdin)
except Exception:
    obj = {}
print(obj.get("id", "") if isinstance(obj, dict) else "")
'
    return 0
  fi
  if have python; then
    python -c '
import sys, json
try:
    obj = json.load(sys.stdin)
except Exception:
    obj = {}
print(obj.get("id", "") if isinstance(obj, dict) else "")
'
    return 0
  fi

  # Last resort: string match a single top-level "id":"...".
  tr -d ' \n\t\r' | sed -n 's/.*"id":"\([0-9a-f]\{32\}\)".*/\1/p' | head -n 1
}

find_service_id_by_name() {
  name="$1"
  if have jq; then
    jq -r --arg name "$name" '.[] | select(.spec.name == $name) | .id' | head -n 1
    return 0
  fi
  if have python3; then
    python3 -c '
import sys, json
name = sys.argv[1]
try:
    svcs = json.load(sys.stdin)
except Exception:
    svcs = []
for svc in svcs if isinstance(svcs, list) else []:
    spec = svc.get("spec") if isinstance(svc, dict) else None
    if isinstance(spec, dict) and spec.get("name") == name:
        print(svc.get("id",""))
        break
' "$name"
    return 0
  fi
  if have python; then
    python -c '
import sys, json
name = sys.argv[1]
try:
    svcs = json.load(sys.stdin)
except Exception:
    svcs = []
for svc in svcs if isinstance(svcs, list) else []:
    spec = svc.get("spec") if isinstance(svc, dict) else None
    if isinstance(spec, dict) and spec.get("name") == name:
        print(svc.get("id",""))
        break
' "$name"
    return 0
  fi

  # Last resort: string match on the compact JSON list.
  tr -d ' \n\t\r' \
    | sed -n 's/.*{"id":"\([0-9a-f]\{32\}\)","spec":{"name":"cc-proxy".*/\1/p' \
    | head -n 1
}

if [ -z "$token" ] && have service-manager; then
  token="$(service-manager token show 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$token" ]; then
  log "SERVICE_MANAGER_TOKEN is not set; skipping automatic registration."
  log ""
  log "Intended service-manager record:"
  log "  id/name: $service_name"
  log "  port:    $port"
  log "  tags:    group:local-stack openhouse-component:cc-proxy"
  log ""
  log "Manual API create (token omitted):"
  log ""
  log "  curl -fsS \\"
  log "    -H \"Authorization: Bearer \$SERVICE_MANAGER_TOKEN\" \\"
  log "    -H \"Content-Type: application/json\" \\"
  log "    --data-binary @- \\"
  log "    \"$base/api/v1/services\" <<'JSON'"
  spec_json
  log "JSON"
  exit 0
fi

have curl || die "curl is required for service-manager API registration."

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cc-proxy-sm.XXXXXX")"
curl_cfg="$tmp_dir/curl.cfg"
cleanup() {
  rm -rf "$tmp_dir" >/dev/null 2>&1 || true
}
trap cleanup 0 INT HUP TERM
printf 'header = "Authorization: Bearer %s"\n' "$token" >"$curl_cfg"
printf 'header = "Content-Type: application/json"\n' >>"$curl_cfg"

# Upsert by service spec.name. service-manager service IDs are server-generated.
services="$(curl -q -fsS -K "$curl_cfg" "$base/api/v1/services")"
existing_id="$(printf '%s' "$services" | find_service_id_by_name "$service_name")"

if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
  log "Updating service-manager record: $service_name ($existing_id)"
  spec_json | curl -q -fsS -X PUT \
    -K "$curl_cfg" \
    --data-binary @- \
    "$base/api/v1/services/$existing_id" >/dev/null
  log "OK"
  exit 0
fi

log "Creating service-manager record: $service_name"
create_out="$(spec_json | curl -q -fsS \
  -K "$curl_cfg" \
  --data-binary @- \
  "$base/api/v1/services")"
new_id="$(printf '%s' "$create_out" | extract_id_from_obj)"

if [ -z "$new_id" ] || [ "$new_id" = "null" ]; then
  die "service created but could not parse returned id"
fi

# Best-effort provider registration; start/restart will also register.
curl -q -fsS -X POST -K "$curl_cfg" "$base/api/v1/services/$new_id/register" >/dev/null || true
log "OK (created id: $new_id)"
exit 0
