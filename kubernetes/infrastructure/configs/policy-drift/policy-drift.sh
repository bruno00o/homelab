#!/usr/bin/env sh
# What are the Kyverno exclusions hiding?
#
# The four enforced policies each carry an `exclude:` list of namespaces. Those exclusions
# are deliberate — upstream charts that cannot comply — but nothing says what else they let
# through. `reloader` ran for months in kube-system with an empty container securityContext
# and no resource limits, because its values were written where the chart never read them;
# every dashboard was green (AUDIT R20).
#
# The audit/ mirrors run the same four rules without exclusions and report instead of
# blocking. This reads their findings and compares them to accepted.txt, the list of
# violations we have looked at and accepted. Anything not on that list is new.
#
# Lives under kubernetes/ rather than scripts/ because the CronJob next to it embeds this
# exact file, so `task policy:drift` and the scheduled run cannot diverge.
#
# Exit 0 clean, 1 something unaccepted, 2 could not check — never silently pass.
set -eu

HERE=$(dirname "$0")
ACCEPTED="${ACCEPTED_FILE:-$HERE/accepted.txt}"

[ -r "$ACCEPTED" ] || { echo "Cannot read the accepted list at $ACCEPTED." >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

kubectl get policyreport -A -o json > "$WORK/polr.json" || exit 2
kubectl get pods -A -o json > "$WORK/pods.json" || exit 2
kubectl get replicasets -A -o json > "$WORK/rs.json" || exit 2
kubectl get jobs -A -o json > "$WORK/jobs.json" || exit 2

# No audit-* result at all means the mirrors are gone, renamed, or never scanned — not that
# the cluster is clean. Refuse rather than report a clean run, which is the failure mode
# this whole check exists to remove.
TOTAL=$(jq '[.items[].results[]? | select(.policy | startswith("audit-"))] | length' "$WORK/polr.json")
[ "$TOTAL" -gt 0 ] || {
  echo "No audit-* results in any PolicyReport. The mirrors are not reporting." >&2
  exit 2
}

owners() {
  jq -r '.items[]
    | "\(.metadata.namespace)/\(.metadata.name)\t\(.metadata.ownerReferences[0].kind // "-")\t\(.metadata.ownerReferences[0].name // "-")"' "$1"
}
owners "$WORK/pods.json" > "$WORK/pod-owner.tsv"
owners "$WORK/rs.json"   > "$WORK/rs-owner.tsv"
owners "$WORK/jobs.json" > "$WORK/job-owner.tsv"

TAB=$(printf '\t')

lookup() {  # file, ns/name -> "kind<TAB>name", empty if unknown
  grep -F "$2$TAB" "$1" 2>/dev/null | head -1 | cut -f2,3
}

# A pod name changes at every rollout, so keying on it would make the accepted list rot on
# its own and stop meaning anything. Resolved up to the controller instead: Deployment,
# DaemonSet, StatefulSet or CronJob names are stable.
workload() {  # ns/pod -> Kind/Name
  NS=${1%%/*}
  POD=${1#*/}
  O=$(lookup "$WORK/pod-owner.tsv" "$1")
  [ -n "$O" ] || { echo "Pod/$POD"; return; }
  K=$(echo "$O" | cut -f1)
  N=$(echo "$O" | cut -f2)
  case "$K" in
    ReplicaSet)
      O2=$(lookup "$WORK/rs-owner.tsv" "$NS/$N")
      [ "$(echo "$O2" | cut -f1)" = "Deployment" ] &&
        { echo "Deployment/$(echo "$O2" | cut -f2)"; return; }
      echo "ReplicaSet/$N" ;;
    Job)
      O2=$(lookup "$WORK/job-owner.tsv" "$NS/$N")
      [ "$(echo "$O2" | cut -f1)" = "CronJob" ] &&
        { echo "CronJob/$(echo "$O2" | cut -f2)"; return; }
      echo "Job/$N" ;;
    -) echo "Pod/$POD" ;;
    *) echo "$K/$N" ;;
  esac
}

# Only Pod-scoped reports. Kyverno also reports on the controllers through its autogen
# rules, so counting both would list every workload twice, and a bare Pod with no
# controller — a static control-plane pod, for one — only ever appears here.
jq -r '.items[]
  | select(.scope.kind == "Pod")
  | .scope.namespace as $ns | .scope.name as $n
  | .results[]?
  | select(.result == "fail")
  | select(.policy | startswith("audit-"))
  | "\($ns)/\($n)\t\(.policy)"' "$WORK/polr.json" | sort -u > "$WORK/fails.tsv"

while read -r LINE; do
  [ -n "$LINE" ] || continue
  POD=$(echo "$LINE" | cut -f1)
  POLICY=$(echo "$LINE" | cut -f2)
  echo "${POD%%/*} $(workload "$POD") $POLICY"
done < "$WORK/fails.tsv" | sort -u > "$WORK/current.txt"

grep -vE '^[[:space:]]*(#|$)' "$ACCEPTED" \
  | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | sort -u > "$WORK/accepted.txt"

# Glob rather than exact match, because some names carry a hash that rotates on its own:
# Longhorn renames its engine-image DaemonSets and InstanceManagers at every upgrade. Exact
# entries would go stale on their own and the list would cry wolf once a quarter.
: > "$WORK/new.txt"
: > "$WORK/matched.txt"
while read -r LINE; do
  [ -n "$LINE" ] || continue
  HIT=""
  while read -r PAT; do
    [ -n "$PAT" ] || continue
    # shellcheck disable=SC2254
    case "$LINE" in
      $PAT) HIT=$PAT; break ;;
    esac
  done < "$WORK/accepted.txt"
  if [ -n "$HIT" ]; then
    echo "$HIT" >> "$WORK/matched.txt"
  else
    echo "$LINE" >> "$WORK/new.txt"
  fi
done < "$WORK/current.txt"

NEW=$(cat "$WORK/new.txt")
GONE=$(sort -u "$WORK/matched.txt" | comm -13 - "$WORK/accepted.txt")

echo "$(wc -l < "$WORK/current.txt" | tr -d ' ') violation(s) found, \
$(wc -l < "$WORK/accepted.txt" | tr -d ' ') entries accepted."

if [ -n "$GONE" ]; then
  # A warning and not a failure: a workload scaled to zero has no pod and would look like a
  # cleared violation. Left visible so the list does not silently fill with dead entries.
  echo
  echo "Accepted entries that match nothing any more (remove them from accepted.txt):"
  echo "$GONE" | sed 's/^/  /'
fi

[ -z "$NEW" ] || {
  echo
  echo "NOT ACCEPTED — these violate a policy their namespace is excluded from:"
  echo "$NEW" | sed 's/^/  /'
  exit 1
}

exit 0
