#!/usr/bin/env bash
# Backups on the NAS whose source volume no longer exists.
#
# Longhorn's retention is carried by a volume's own recurring job, so once the volume is
# gone nothing evaluates its retention and its backups stay forever. The store can only
# grow — every deleted PVC leaves a trace behind, and replica churn deletes a lot of them.
#
# Reads the cluster, not the repo: a backup outlives whatever manifest created it.
#
# Reports by default. `--cutoff <YYYY-MM-DD>` narrows the report to orphans whose last
# backup is on or before that date, and `--purge` then deletes exactly what was reported —
# which erases the data on the backup target and cannot be undone. Purging without a cutoff
# is refused: there is no date at which deleting every orphan is the obvious thing to do.
set -euo pipefail

NS=longhorn-system
CUTOFF=""
PURGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cutoff)
      CUTOFF="${2:-}"
      [[ "$CUTOFF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
        echo "--cutoff needs a YYYY-MM-DD date" >&2; exit 1; }
      shift 2
      ;;
    --purge) PURGE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ "$PURGE" -eq 1 && -z "$CUTOFF" ]]; then
  echo "--purge needs --cutoff" >&2
  exit 1
fi

# An unreachable target makes Longhorn report an empty backup list, which would read as
# "everything is orphaned". Refuse rather than act on that.
avail=$(kubectl get backuptargets.longhorn.io -n "$NS" default -o jsonpath='{.status.available}')
[[ "$avail" == "true" ]] || { echo "backup target unavailable (available=$avail)" >&2; exit 1; }

live=$(kubectl get volumes.longhorn.io -n "$NS" -o json | jq -c '[.items[].metadata.name]')

plan=$(kubectl get backupvolumes.longhorn.io -n "$NS" -o json | jq -r \
  --argjson live "$live" --arg cutoff "$CUTOFF" '
  .items[]
  | .metadata as $m
  | ($m.labels["backup-volume"] // "") as $vol
  # No label means the backup has no identity we can check. Never touch it.
  | select($vol != "")
  # Source volume still exists, so this is a live backup, not an orphan.
  | select(($live | index($vol)) == null)
  # Longhorn sets this when it has already detached the resource from its data: deleting
  # it frees nothing and it reappears on the next sync.
  | select([$m.labels // {} | keys[] | select(test("delete-custom-resource-only"))] | length == 0)
  | ((.status.lastBackupAt // "") | .[0:10]) as $last
  # An unreadable date cannot be compared to the cutoff, so it is never in scope.
  | select($last != "")
  | select($cutoff == "" or $last <= $cutoff)
  | ((.status.labels.KubernetesStatus // "{}") | fromjson) as $k
  | [$m.name, (.status.dataStored // 0 | tonumber), "\($k.namespace // "?")/\($k.pvcName // "?")", $last]
  | @tsv')

[[ -n "$plan" ]] || { echo "no orphaned backup"; exit 0; }

printf '%9s  %-12s %s\n' 'size' 'last backup' 'volume'
sort -t$'\t' -k2 -rn <<<"$plan" |
  awk -F'\t' '{printf "%6.2f Gi  %-12s %s\n", $2/1073741824, $4, $3}'

n=$(wc -l <<<"$plan")
awk -F'\t' -v n="$n" '{s+=$2} END {printf "\n=> %d orphaned backups, %.1f Gi\n", n, s/1073741824}' <<<"$plan"

[[ "$PURGE" -eq 1 ]] || exit 0

echo
echo "deleting (last backup on or before $CUTOFF)..."
i=0
while IFS=$'\t' read -r name _ id _; do
  i=$((i + 1))
  printf '[%3d/%3d] %-52s %s\n' "$i" "$n" "$name" "$id"
  kubectl delete backupvolumes.longhorn.io -n "$NS" "$name" --wait=false
done <<<"$plan"

echo
# The resource keeps a deletionTimestamp until the data is gone from the target, and a
# large volume takes far longer than the rest put together, so the delete returning says
# nothing about the space being back.
echo "erasing on the target runs in the background; watch it drain with:"
echo "  kubectl get backupvolumes.longhorn.io -n $NS"
