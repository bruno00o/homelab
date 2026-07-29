#!/usr/bin/env bash
# What is exposed, on which hostname, through which path — with the variables resolved.
#
# Every HTTPRoute hostname in the repo is templated (`<app>.${CLUSTER_DOMAIN}`), so no grep
# answers "what is actually reachable". That gap produced a real incident: three invented
# hostnames during a post-upgrade check (authentik./matrix./element.merry.home.arpa, when
# the real ones are auth.merry.home.arpa, matrix.seilliebert.app, element.seilliebert.app).
#
# Reads the cluster, not the repo. The repo would be incomplete by construction — Helm
# charts generate Services and routes that exist in no file, and `qdrant` and `valkey`
# LoadBalancers are exactly that. Flux has also already substituted the variables there.
# The cost is that this needs a working kubeconfig, unlike `task validate`.
#
# Three exposure paths exist and are listed separately, because reading only the first is
# how you conclude an app is internal when the tunnel publishes it:
#   1. HTTPRoute -> gateway         (LAN, split-horizon DNS)
#   2. Cloudflare tunnel -> Service (public internet, bypasses the gateway entirely)
#   3. LoadBalancer Service         (LAN, raw ports, no hostname)
set -euo pipefail

cd "$(dirname "$0")/.."

if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "No reachable cluster: this reads live state, not the repo." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

kubectl get httproute -A -o json > "$WORK/routes.json"
kubectl get svc -A -o json > "$WORK/svc.json"
kubectl -n cloudflare-tunnel get cm cloudflare-tunnel-config -o jsonpath='{.data.config\.yaml}' \
  2>/dev/null \
  | yq -N -o=json '[.ingress[] | select(has("hostname")) | {"hostname": .hostname, "service": .service}]' \
  > "$WORK/tunnel.json"

# An empty tunnel list is not a valid reading: it would silently turn every public route
# into a "no tunnel entry" warning below. Fail instead of reporting something false.
[ "$(jq 'length' "$WORK/tunnel.json")" -gt 0 ] || {
  echo "Could not read the Cloudflare tunnel ingress list — refusing to report a partial inventory." >&2
  exit 1
}

CLUSTER_DOMAIN=$(kubectl -n flux-system get cm cluster-settings -o jsonpath='{.data.CLUSTER_DOMAIN}')
PUBLIC_DOMAIN=$(kubectl -n flux-system get cm cluster-settings -o jsonpath='{.data.PUBLIC_DOMAIN}')
PROJECTS_DOMAIN=$(kubectl -n flux-system get cm cluster-settings -o jsonpath='{.data.PROJECTS_DOMAIN}')

# An empty domain would turn its suffix pattern below into `*"."`, matching every hostname
# and disabling the check without saying so.
for v in CLUSTER_DOMAIN PUBLIC_DOMAIN PROJECTS_DOMAIN; do
  [ -n "${!v}" ] || { echo "$v is empty in the cluster-settings ConfigMap." >&2; exit 1; }
done

# One row per (hostname, route). A route carrying two hostnames is two rows: the hostname is
# what you look up, so it is the key.
jq -r '
  [ .items[] | . as $r
    | ($r.spec.hostnames // [])[] as $h
    | { host: $h,
        ns: $r.metadata.namespace,
        gw: ([$r.spec.parentRefs[] | .name] | unique | join(",")),
        backend: ([$r.spec.rules[]?.backendRefs[]?
                   | ((.namespace // $r.metadata.namespace) + "/" + .name + ":" + (.port|tostring))]
                  | unique | join(",")) }
  ] | sort_by(.host)[] | [.host, .ns, .backend, .gw] | @tsv
' "$WORK/routes.json" > "$WORK/gateway.tsv"

jq -r '
  sort_by(.hostname)[]
  | [ .hostname, (.service | sub("^https?://"; "") | sub("\\.svc\\.cluster\\.local"; "")) ] | @tsv
' "$WORK/tunnel.json" > "$WORK/tunnel.tsv"

jq -r '
  [ .items[] | select(.spec.type=="LoadBalancer")
    | { name: (.metadata.namespace + "/" + .metadata.name),
        ip: (.status.loadBalancer.ingress[0].ip // "<none>"),
        ports: ([.spec.ports[] | ((.port|tostring) + "/" + (.protocol // "TCP"))] | join(",")) }
  ] | sort_by(.name)[] | [.name, .ip, .ports] | @tsv
' "$WORK/svc.json" > "$WORK/lb.tsv"

# One column -t per table: a shared one would pad every hostname out to the width of the
# longest section title, since a title is a single field in the first column.
section() { echo "$1"; column -ts$'\t'; echo; }

{
  printf 'HOSTNAME\tNAMESPACE\tBACKEND\tGATEWAY\tSSO\n'
  while IFS=$'\t' read -r host ns backend gw; do
    sso=$([[ "$backend" == *authentik-server* ]] && echo "proxy" || echo "-")
    printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$ns" "$backend" "$gw" "$sso"
  done < "$WORK/gateway.tsv"
} | section "GATEWAY  (LAN, split-horizon DNS)"

{
  printf 'HOSTNAME\tTARGET\tALSO ON GATEWAY\n'
  while IFS=$'\t' read -r host target; do
    onmesh=$(cut -f1 "$WORK/gateway.tsv" | grep -qxF "$host" && echo "yes" || echo "no")
    printf '%s\t%s\t%s\n' "$host" "$target" "$onmesh"
  done < "$WORK/tunnel.tsv"
} | section "TUNNEL  (public internet, does not traverse the gateway)"

{
  printf 'SERVICE\tIP\tPORTS\n'
  cat "$WORK/lb.tsv"
} | section "LOADBALANCER  (LAN, raw ports)"

# The cross-checks are the point of joining the three sources: each one below is invisible
# when you look at a single exposure path.
echo
echo "CHECKS"
found=0

# A hostname on none of the three declared domains has no owner: nothing manages its DNS
# and no future domain change would find it. The three are all legitimate — an earlier
# version of this check knew only two and flagged the seven PROJECTS_DOMAIN hostnames as
# anomalies, which is how a check teaches you to ignore checks.
while IFS=$'\t' read -r host _; do
  case "$host" in
    *".$CLUSTER_DOMAIN"|*".$PUBLIC_DOMAIN"|*".$PROJECTS_DOMAIN") ;;
    *) echo "  tunnel hostname on an undeclared domain: $host"; found=1 ;;
  esac
done < "$WORK/tunnel.tsv"

# A route on a published domain with no tunnel entry answers on the LAN only, which is
# rarely what a hostname meant for the internet is for.
while IFS=$'\t' read -r host _ _ _; do
  case "$host" in
    *".$PUBLIC_DOMAIN"|*".$PROJECTS_DOMAIN")
      cut -f1 "$WORK/tunnel.tsv" | grep -qxF "$host" ||
        { echo "  published-domain route with no tunnel entry, LAN-only: $host"; found=1; } ;;
  esac
done < "$WORK/gateway.tsv"

# A Gateway asking for an address it did not get: Cilium does not propagate
# io.cilium/lb-ipam-ips from a Gateway to the Service it generates, so the request is
# dropped in silence and LB-IPAM serves whatever the pool has (AUDIT R19).
while IFS=$'\t' read -r name ip _; do
  case "$name" in
    kube-system/cilium-gateway-*)
      gw=${name#kube-system/cilium-gateway-}
      want=$(kubectl -n kube-system get gateway "$gw" \
        -o jsonpath='{.metadata.annotations.io\.cilium/lb-ipam-ips}' 2>/dev/null || true)
      [ -n "$want" ] && [ "$want" != "$ip" ] &&
        { echo "  gateway $gw requests $want but serves $ip"; found=1; } ;;
  esac
done < "$WORK/lb.tsv"

[ "$found" = 0 ] && echo "  nothing to report"
exit 0
