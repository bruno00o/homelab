#!/usr/bin/env bash
# One verdict over what the alerts and the other detectors do not cover on their own.
#
# Read-only. Reads the cluster and its logs, never the repo: what matters is what runs.
#
#   --full   also runs `task drift`, which takes minutes and needs outbound HTTPS.
#
# Exit 0 clean, 1 something to look at, 2 something could not be checked. A check that cannot
# read its source reports UNKNOWN, because silence here would read as healthy.
set -uo pipefail

cd "$(dirname "$0")/.."

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

WORK="$(mktemp -d)"
PIDS=()
cleanup() {
  [ "${#PIDS[@]}" -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

WARNINGS=0
UNKNOWNS=0
section() { printf '\n%s\n' "$1"; }
ok() { printf '  OK       %s\n' "$1"; }
info() { printf '  INFO     %s\n' "$1"; }
warn() { printf '  WARN     %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
unknown() { printf '  UNKNOWN  %s\n' "$1"; UNKNOWNS=$((UNKNOWNS + 1)); }
detail() { sed 's/^/           /' | cut -c1-150 | head -n "${1:-10}"; }

if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "No reachable cluster: this reads live state." >&2
  exit 2
fi

setting() { kubectl -n flux-system get cm cluster-settings -o jsonpath="{.data.$1}"; }

# Picks a free local port and prints it once the forward answers.
forward() { # namespace service port health-path
  local log="$WORK/pf-$2" port=""
  kubectl -n "$1" port-forward "svc/$2" ":$3" >"$log" 2>&1 &
  PIDS+=("$!")
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+).*/\1/p' "$log" | head -1)
    if [ -n "$port" ] && curl -fs -m 3 -o /dev/null "http://127.0.0.1:$port$4"; then
      echo "$port"
      return 0
    fi
    read -r -t 1 </dev/zero
  done
  return 1
}

# Prints one number, or nothing if the query failed or returned no series.
prom() {
  curl -fs -m 15 --get "http://127.0.0.1:$PROM_PORT/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[0].value[1] // empty' 2>/dev/null
}
loki() {
  curl -fs -m 30 --get "http://127.0.0.1:$LOKI_PORT/loki/api/v1/query" --data-urlencode "query=$1" |
    jq -r 'if .status == "success" then (.data.result[0].value[1] // "0") else empty end' 2>/dev/null
}

section "CLUSTER"

bad=$(kubectl get nodes -o json | jq -r '.items[]
  | select(any(.status.conditions[]; .type == "Ready" and .status == "True") | not) | .metadata.name')
if [ -z "$bad" ]; then ok "every node is Ready"; else warn "nodes not Ready: $(echo "$bad" | xargs)"; fi

kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A -o json >"$WORK/flux.json"
bad=$(jq -r '.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not)
  | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"' "$WORK/flux.json")
if [ -z "$bad" ]; then ok "Flux: every object is Ready"; else warn "Flux objects not Ready:"; echo "$bad" | detail; fi
bad=$(jq -r '.items[] | select(.spec.suspend == true) | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"' "$WORK/flux.json")
if [ -z "$bad" ]; then ok "Flux: nothing left suspended"; else warn "Flux objects suspended:"; echo "$bad" | detail; fi

bad=$(kubectl get pods -A -o json | jq -r '.items[]
  | select(.status.phase != "Succeeded")
  | select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not)
  | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"')
if [ -z "$bad" ]; then ok "every pod is ready"; else warn "pods not ready:"; echo "$bad" | detail; fi

if kubectl -n longhorn-system get volumes.longhorn.io -o json >"$WORK/volumes.json" 2>/dev/null; then
  bad=$(jq -r '.items[] | select(.status.state == "attached" and .status.robustness != "healthy")
    | "\(.metadata.name) \(.status.robustness)"' "$WORK/volumes.json")
  if [ -z "$bad" ]; then ok "Longhorn: $(jq '.items | length' "$WORK/volumes.json") volumes, none degraded"
  else warn "Longhorn volumes not healthy:"; echo "$bad" | detail; fi
else
  unknown "could not read the Longhorn volumes"
fi

if kubectl get clusters.postgresql.cnpg.io -A -o json >"$WORK/cnpg.json" 2>/dev/null; then
  bad=$(jq -r '.items[] | select(.status.readyInstances != .status.instances)
    | "\(.metadata.namespace)/\(.metadata.name) \(.status.readyInstances)/\(.status.instances)"' "$WORK/cnpg.json")
  if [ -z "$bad" ]; then ok "Postgres: $(jq '.items | length' "$WORK/cnpg.json") clusters, every instance ready"
  else warn "Postgres clusters short of instances:"; echo "$bad" | detail; fi
else
  unknown "could not read the Postgres clusters"
fi

if kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-1 -c alertmanager -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false' >"$WORK/alerts.json" 2>/dev/null; then
  bad=$(jq -r '.[].labels.alertname | select(. != "Watchdog" and . != "InfoInhibitor")' "$WORK/alerts.json" | sort -u)
  if [ -z "$bad" ]; then ok "no alert firing"; else warn "alerts firing: $(echo "$bad" | xargs)"; fi
else
  unknown "could not read Alertmanager"
fi

section "BACKUPS"

# Anything scheduled less often than daily would need its own rule here.
now=$(date +%s)
bad=$(kubectl get cronjobs -A -o json | jq -r --argjson now "$now" '.items[]
  | select(.spec.suspend != true)
  | ((.status.lastSuccessfulTime // "1970-01-01T00:00:00Z") | fromdate) as $last
  | select($now - $last > 26 * 3600)
  | "\(.metadata.namespace)/\(.metadata.name), last success \(.status.lastSuccessfulTime // "never")"')
if [ -z "$bad" ]; then ok "every CronJob succeeded within a day, etcd snapshot included"
else warn "CronJobs stale:"; echo "$bad" | detail; fi

if ./scripts/backup-orphans.sh >"$WORK/orphans" 2>&1; then
  if grep -q '^no orphaned backup' "$WORK/orphans"; then ok "no orphaned backup"
  else info "orphaned backups, a decision rather than a fault: $(tail -1 "$WORK/orphans" | sed 's/^=> //')"; fi
else
  unknown "could not list the orphaned backups"
fi

section "VERSIONS"

running=$(kubectl get nodes -o json | jq -r '.items[].status.nodeInfo.kubeletVersion' | sort -u)
if [ "$(echo "$running" | wc -l)" -ne 1 ]; then
  warn "nodes run different Kubernetes versions: $(echo "$running" | xargs)"
else
  minor=$(echo "$running" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/')
  latest=$(curl -fsL -m 15 "https://dl.k8s.io/release/stable-$minor.txt" 2>/dev/null)
  if [ -z "$latest" ]; then unknown "could not read the latest Kubernetes $minor patch"
  elif [ "$latest" = "$running" ]; then ok "Kubernetes $running, latest of its minor"
  else warn "Kubernetes $running, patch $latest is out"; fi
fi

running=$(kubectl get nodes -o json | jq -r '.items[].status.nodeInfo.osImage' | sed -E 's/.*\((v[^)]+)\).*/\1/' | sort -u)
if [ "$(echo "$running" | wc -l)" -ne 1 ]; then
  warn "nodes run different Talos versions: $(echo "$running" | xargs)"
else
  minor=$(echo "$running" | sed -E 's/^(v[0-9]+\.[0-9]+).*/\1/')
  latest=$(curl -fsL -m 15 'https://api.github.com/repos/siderolabs/talos/releases?per_page=40' 2>/dev/null |
    jq -r --arg m "$minor." '[.[] | select(.prerelease == false and .draft == false and (.tag_name | startswith($m))) | .tag_name]
      | sort_by(ltrimstr("v") | split(".") | map(tonumber)) | last // empty' 2>/dev/null)
  if [ -z "$latest" ]; then unknown "could not read the latest Talos $minor patch"
  elif [ "$latest" = "$running" ]; then ok "Talos $running, latest of its minor"
  else warn "Talos $running, patch $latest is out"; fi
fi

if [ "$FULL" -eq 1 ]; then
  ./scripts/drift.sh >"$WORK/drift" 2>&1
  case $? in
    0) ok "every comparable image is current" ;;
    1) warn "$(grep -E 'image\(s\) behind' "$WORK/drift" | cut -d. -f1), see task drift" ;;
    *) unknown "task drift could not run" ;;
  esac
fi

section "MACHINES OUTSIDE THE CLUSTER"

PROM_PORT=$(forward monitoring kube-prometheus-stack-prometheus 9090 /-/ready) || PROM_PORT=""
if [ -z "$PROM_PORT" ]; then
  unknown "could not reach Prometheus, so neither the Pi nor jinbe was checked"
else
  for job in franky jinbe; do
    up=$(prom "up{job=\"$job\"}")
    case "$up" in
      1) ok "$job is scraped" ;;
      0) warn "$job does not answer its scrape" ;;
      *) unknown "$job has no scrape target" ;;
    esac
  done
  free=$(prom 'min(node_filesystem_avail_bytes{job="franky",mountpoint="/"} / node_filesystem_size_bytes{job="franky",mountpoint="/"})')
  if [ -z "$free" ]; then unknown "could not read the disk of the Pi"
  elif awk -v f="$free" 'BEGIN { exit !(f < 0.15) }'; then warn "the Pi has $(awk -v f="$free" 'BEGIN { printf "%.0f", f * 100 }') % of its disk free"
  else ok "the Pi has $(awk -v f="$free" 'BEGIN { printf "%.0f", f * 100 }') % of its disk free"; fi
fi

# Only the service is checked: nothing here can log into that host.
domain=$(setting PUBLIC_DOMAIN)
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://livekit.$domain/" 2>/dev/null)
if [ "$code" = "200" ]; then ok "VPS: LiveKit answers, the host itself is not inspected"
else warn "VPS: LiveKit answered HTTP $code"; fi

robin=$(setting ROBIN_IP)
if ssh -o BatchMode=yes -o ConnectTimeout=6 "bruno@$robin" 'cat /proc/mdstat; df -P /volume1' >"$WORK/robin" 2>/dev/null; then
  if grep -qE '\[U*_+U*\]' "$WORK/robin"; then warn "NAS: an array is degraded"; else ok "NAS: every array has all its disks"; fi
  used=$(awk '$NF == "/volume1" { print $(NF - 1) + 0 }' "$WORK/robin")
  if [ "${used:-100}" -ge 85 ]; then warn "NAS: volume $used % full"; else ok "NAS: volume $used % full"; fi
else
  unknown "could not log into the NAS"
fi

section "FAILURES THAT RAISE NOTHING"

LOKI_PORT=$(forward loki-system loki 3100 /ready) || LOKI_PORT=""
if [ -z "$LOKI_PORT" ]; then
  unknown "could not reach Loki, so the logs were not read"
else
  # A zero means nothing unless the stream itself is there.
  log_check() { # label stream pattern window
    local seen hits
    seen=$(loki "sum(count_over_time($2 [$4]))")
    hits=$(loki "sum(count_over_time($2 |= \"$3\" [$4]))")
    if [ -z "$seen" ] || [ -z "$hits" ]; then unknown "$1: Loki did not answer"
    elif [ "$seen" = "0" ]; then unknown "$1: no log at all in $4"
    elif [ "$hits" = "0" ]; then ok "$1: nothing in $4"
    else warn "$1: $hits in $4"; fi
  }
  log_check "Frigate ffmpeg crashes" '{namespace="home-automation",pod=~"frigate.*"}' "Ffmpeg process crashed" 24h
  log_check "autokuma cut off from uptime-kuma" '{namespace="uptime-kuma",pod=~"autokuma.*"}' "EngineIO Error" 1h
fi

# Off can be deliberate, so this informs and does not count.
if kubectl -n home-automation exec deploy/frigate -c frigate -- python3 -c '
import json, time, urllib.request as u
now = int(time.time())
for name, cam in json.load(u.urlopen("http://localhost:5000/api/config", timeout=20))["cameras"].items():
    rows = json.load(u.urlopen(f"http://localhost:5000/api/{name}/recordings?after={now - 86400}&before={now}", timeout=30))
    last = max((r["end_time"] for r in rows), default=None)
    seen = f"last recording {int((now - last) / 60)} min ago" if last else "no recording in 24 h"
    state = "on" if cam.get("enabled") else "off"
    print(f"{name}: {state}, {seen}")
' >"$WORK/cameras" 2>/dev/null; then
  while IFS= read -r line; do info "$line"; done <"$WORK/cameras"
else
  unknown "could not read the camera state from Frigate"
fi

section "OTHER DETECTORS"

./scripts/inventory.sh >"$WORK/inventory" 2>&1
rc=$?
checks=$(sed -n '/^CHECKS/,$p' "$WORK/inventory" | tail -n +2 | sed '/^[[:space:]]*$/d')
if [ "$rc" -ne 0 ] || [ -z "$checks" ]; then unknown "task inventory could not run"
elif echo "$checks" | grep -q 'nothing to report'; then ok "inventory: nothing to report"
else warn "inventory:"; echo "$checks" | detail; fi

./kubernetes/infrastructure/configs/policy-drift/policy-drift.sh >"$WORK/policy" 2>&1
case $? in
  0) ok "policy drift: $(tail -1 "$WORK/policy")" ;;
  1) warn "policy drift, see task policy:drift" ;;
  *) unknown "task policy:drift could not run" ;;
esac

./kubernetes/infrastructure/configs/dns-leak/dns-leak.sh >"$WORK/dns" 2>&1
case $? in
  0) ok "DNS leaks: $(tail -1 "$WORK/dns")" ;;
  1) warn "DNS leaks, see task dns:leak-check" ;;
  *) unknown "task dns:leak-check could not run" ;;
esac

printf '\n'
if [ "$UNKNOWNS" -gt 0 ]; then
  echo "VERDICT: $WARNINGS to look at, $UNKNOWNS not checked."
  exit 2
fi
if [ "$WARNINGS" -gt 0 ]; then
  echo "VERDICT: $WARNINGS to look at."
  exit 1
fi
echo "VERDICT: clean."
