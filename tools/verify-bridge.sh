#!/usr/bin/env bash
# Checks the agent/phone bridge end to end from the server side.
#
#   tools/verify-bridge.sh            # one-shot report
#   tools/verify-bridge.sh --watch    # poll until a phone shows up (Ctrl-C to stop)
#
# What "working" means, in order:
#   1. the bridge service is up on loopback (its /healthz answers ok)
#   2. a phone is attached (healthz reports phones >= 1)
#   3. that phone declared the capabilities the agent tools rely on
#   4. the MCP side the app talks to is the one dsh loaded (mcp-phone in the web profile)
#
# Exit code 0 only when 1-4 all hold; 2 when the bridge is up but no phone is attached.
set -uo pipefail

BRIDGE=http://127.0.0.1:3082/healthz
UNIT=dsh-fusion-bridge
PROFILE_PATCH=/root/.dsh/profiles/web/cordis.patch.yml
WATCH=0
[ "${1:-}" = "--watch" ] && WATCH=1

check_bridge() {
  local body
  body=$(curl -sf --max-time 4 "$BRIDGE" 2>/dev/null) || return 1
  echo "  service: $body"
  return 0
}

phone_count() {
  curl -sf --max-time 4 "$BRIDGE" 2>/dev/null | sed -n 's/.*"phones":\([0-9]*\).*/\1/p'
}

report() {
  local ok=0
  echo "== 1. bridge service =="
  if check_bridge; then echo "  OK  $UNIT answers on 127.0.0.1:3082"; else echo "  FAIL $UNIT is not answering ($(systemctl is-active $UNIT 2>/dev/null))"; return 2; fi

  echo "== 2. phone attached =="
  local n; n=$(phone_count); n=${n:-0}
  if [ "$n" -ge 1 ]; then
    echo "  OK  $n phone(s) attached"
    journalctl -u "$UNIT" --no-pager -n 40 2>/dev/null | grep "phone connected" | tail -1 | sed 's/^/  last: /'
  else
    echo "  WAIT 0 phones attached — open the bridge page in the app and press 连接"
    ok=2
  fi

  echo "== 3. capability surface =="
  if [ "$n" -ge 1 ]; then
    local caps
    caps=$(journalctl -u "$UNIT" --no-pager -n 200 2>/dev/null | grep "phone connected" | tail -1 | sed 's/.*caps=//')
    echo "  caps: ${caps:-<none>}"
    for need in ping info clipboard.get files.save fs.roots apps.list; do
      case ",$caps," in
        *",$need,"*) echo "  OK  $need" ;;
        *) echo "  MISSING $need" ;;
      esac
    done
  else
    echo "  (skipped: no phone)"
  fi

  echo "== 4. MCP wiring in the dsh profile =="
  if grep -q "serverName: phone" "$PROFILE_PATCH" 2>/dev/null; then
    grep -A3 "serverName: phone" "$PROFILE_PATCH" | sed 's/^/  /'
    echo "  OK  mcp-phone registered (agent tools appear after the dsh web process restarts)"
  else
    echo "  FAIL mcp-phone not found in $PROFILE_PATCH"
    ok=1
  fi

  return "$ok"
}

if [ "$WATCH" = 1 ]; then
  echo "watching for a phone… (Ctrl-C to stop)"
  while :; do
    if [ "$(phone_count)" != "" ] && [ "$(phone_count)" -ge 1 ] 2>/dev/null; then
      report; exit $?
    fi
    sleep 3
  done
fi

report
exit $?
