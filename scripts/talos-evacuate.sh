#!/usr/bin/env bash
# Moves what the house relies on off a cordoned worker before its reboot, one pod at a time.
# Not a drain: the workers cannot hold everything with one of them gone, and draining Longhorn's
# instance managers and strict-local replicas blocks. Everything else falls with the node.
# Trouble with one pod is reported, not fatal: the pod then falls with the node, as it would have.
set -uo pipefail

NODE="${1:?usage: talos-evacuate.sh NODE [TIMEOUT_SECONDS]}"
TIMEOUT="${2:-300}"
problems=0

note() { printf '%s %s\n' "$(date +%T)" "$*"; }
warn() { note "WARN $*"; problems=$((problems + 1)); }

node_json=$(kubectl get node "$NODE" -o json) || exit 1
if [ "$(jq -r '.metadata.labels | has("node-role.kubernetes.io/control-plane")' <<<"$node_json")" = true ]; then
  note "$NODE is a control plane, nothing to move"
  exit 0
fi
if [ "$(jq -r '.spec.unschedulable // false' <<<"$node_json")" != true ]; then
  echo "$NODE is not cordoned: the pods could come back to it" >&2
  exit 1
fi

# The operator switches a primary over by itself once its node is cordoned. Reboot before that
# and it is a failover instead, which depends on the operator noticing the node is gone.
deadline=$(($(date +%s) + TIMEOUT))
while :; do
  primaries=$(kubectl get pods -A -l cnpg.io/instanceRole=primary --field-selector "spec.nodeName=$NODE" -o name 2>/dev/null)
  if [ -z "$primaries" ]; then
    note "no Postgres primary on $NODE"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    warn "primaries still on $NODE: $(tr '\n' ' ' <<<"$primaries")"
    break
  fi
  note "waiting for $(wc -l <<<"$primaries") Postgres primaries to leave $NODE"
  read -r -t 10 </dev/zero
done

pods=$(kubectl get pods -A --field-selector "spec.nodeName=$NODE,status.phase=Running" -o json | jq -r '
  .items[]
  | select(.metadata.deletionTimestamp | not)
  | select(.spec.priorityClassName == "homelab-essential" or .spec.priorityClassName == "system-cluster-critical")
  | select(.metadata.labels["cnpg.io/cluster"] | not)
  | select(.metadata.namespace != "longhorn-system")
  | (.metadata.ownerReferences // [])[0] as $owner
  | select($owner.kind == "ReplicaSet" or $owner.kind == "StatefulSet")
  | [.metadata.namespace, .metadata.name, .metadata.uid, $owner.kind, $owner.name] | @tsv')

moved_uptime_kuma=false
while IFS=$'\t' read -r ns pod uid kind owner; do
  [ -n "$ns" ] || continue
  start=$(date +%s)

  # The eviction API, so that a PodDisruptionBudget is honoured.
  evicted=false
  body=$(jq -nc --arg ns "$ns" --arg pod "$pod" \
    '{apiVersion: "policy/v1", kind: "Eviction", metadata: {name: $pod, namespace: $ns}}')
  deadline=$((start + 120))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if kubectl create --raw "/api/v1/namespaces/$ns/pods/$pod/eviction" -f - <<<"$body" >/dev/null 2>&1; then
      evicted=true
      break
    fi
    read -r -t 10 </dev/zero
  done
  if [ "$evicted" != true ]; then
    warn "$ns/$pod could not be evicted, it falls with the node"
    continue
  fi

  # A StatefulSet pod comes back under the same name, hence the uid.
  deadline=$((start + TIMEOUT))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$uid" ] || break
    read -r -t 2 </dev/zero
  done

  if [ "$kind" = ReplicaSet ]; then
    workload="deployment/$(kubectl -n "$ns" get rs "$owner" -o jsonpath='{.metadata.ownerReferences[0].name}')"
  else
    workload="statefulset/$owner"
  fi
  if kubectl -n "$ns" rollout status "$workload" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    note "$ns/$workload ready after $(($(date +%s) - start)) s"
  else
    warn "$ns/$workload not ready after $(($(date +%s) - start)) s"
  fi
  [ "$ns/$workload" = uptime-kuma/deployment/uptime-kuma ] && moved_uptime_kuma=true
done <<<"$pods"

# autokuma never reconnects by itself once uptime-kuma has restarted.
if [ "$moved_uptime_kuma" = true ]; then
  kubectl -n uptime-kuma delete pod -l app.kubernetes.io/name=autokuma >/dev/null || warn "autokuma not restarted"
fi

note "done, $problems problem(s)"
