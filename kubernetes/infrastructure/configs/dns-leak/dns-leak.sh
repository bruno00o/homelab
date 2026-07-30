#!/usr/bin/env sh
# Does anything resolve publicly that should not?
#
# Lives under kubernetes/ rather than scripts/ because the CronJob next to it embeds this
# exact file through a configMapGenerator. One file, two callers (`task dns:leak-check` and
# the CronJob), so the check cannot drift between the on-demand and the scheduled run.
#
# Asks a public resolver, so the answer is the public view of DNS regardless of where this
# runs. Two things are leaks:
#
#   1. A hostname the cluster serves with no Cloudflare tunnel entry, yet resolving
#      publicly. Nothing routes to it from outside, so a record is either a mistake or a
#      published piece of internal topology.
#   2. A public answer that is a private address. external-dns runs with
#      --cloudflare-proxied, so every record it owns must answer as a Cloudflare address;
#      a 10.x or 192.168.x answer means the proxy is off and the home IP is exposed.
#
# Exit 0 clean, 1 leak found, 2 could not check — never silently pass.
set -eu

RESOLVER="${RESOLVER:-1.1.1.1}"

resolve() {
  # busybox nslookup in the CronJob image, dig when run from a workstation. Both are asked
  # for A records only; the answers are filtered to dotted quads either way.
  if command -v dig >/dev/null 2>&1; then
    dig +short +time=3 +tries=1 "@$RESOLVER" "$1" A 2>/dev/null | grep -E '^[0-9]+\.' || true
  else
    nslookup -type=a "$1" "$RESOLVER" 2>/dev/null \
      | sed -n '/^Name:/,$p' | sed -n 's/^Address: *//p' | grep -E '^[0-9]+\.' || true
  fi
}

is_private() {
  case "$1" in
    10.*|127.*|169.254.*|192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    *) return 1 ;;
  esac
}

HOSTS=$(kubectl get httproute -A -o json \
  | jq -r '[.items[].spec.hostnames // [] | .[]] | unique | .[]')

TUNNEL=$(kubectl -n cloudflare-tunnel get cm cloudflare-tunnel-config \
  -o jsonpath='{.data.config\.yaml}' \
  | sed -n 's/^ *- *hostname: *//p')

# An empty read is not "nothing is exposed": it would clear every expectation below and
# report a clean run. Refuse instead.
[ -n "$HOSTS" ] || { echo "Could not list HTTPRoute hostnames." >&2; exit 2; }
[ -n "$TUNNEL" ] || { echo "Could not read the tunnel ingress list." >&2; exit 2; }

LEAKS=0
CHECKED=0

for H in $HOSTS; do
  CHECKED=$((CHECKED + 1))
  ADDRS=$(resolve "$H")
  [ -n "$ADDRS" ] || continue

  if ! echo "$TUNNEL" | grep -qxF "$H"; then
    echo "LEAK  $H resolves publicly ($(echo "$ADDRS" | paste -sd, -)) but has no tunnel entry"
    LEAKS=$((LEAKS + 1))
    continue
  fi

  for A in $ADDRS; do
    if is_private "$A"; then
      echo "LEAK  $H answers $A publicly — a private address, so the Cloudflare proxy is off"
      LEAKS=$((LEAKS + 1))
    fi
  done
done

echo "Checked $CHECKED hostnames against $RESOLVER: $LEAKS leak(s)."
[ "$LEAKS" -eq 0 ] || exit 1
