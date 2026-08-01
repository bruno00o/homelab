#!/usr/bin/env bash
# How far behind upstream is each image actually running, and can Renovate even see it?
#
# Renovate only updates what a manifest names. Roughly half the images in this cluster are
# named by a chart instead, and for those there is no PR, no diff and no signal — the
# release stays green on whatever the chart pinned. promtail is the standing example: its
# chart is the newest published *and* deprecated, so the image it pins can never move, and
# nothing anywhere says so.
#
# Reads the cluster, not the repo, for the same reason `inventory` does: a chart-internal
# image exists in no file. Each running image is then looked up in its own registry and
# compared with the newest tag of the same shape.
#
# "Same shape" is what makes the output usable. A tag is only comparable to one with the
# same suffix and the same number of numeric components, so `v1.19.6` is not measured
# against `v1.19.0-20260514`, and a bare build number (`9799770991`) never becomes
# "the latest version". Anything that does not parse is reported as such rather than
# silently dropped — this refuses to guess.
#
# The `tracked` column is the point of the report, not the version gap: it says whether a
# manifest in this repo names the image, i.e. whether Renovate has any chance of proposing
# the update. `chart` means nobody is watching but this script.
#
# Exit 0 clean, 1 something is behind, 2 could not check — never silently pass.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "jq not found. Run 'task deps:install'." >&2; exit 2; }

if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "No reachable cluster: this reads live state, not the repo." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -L because registry.k8s.io answers /v2/ with a 307 to a regional Artifact Registry; without
# it every registry.k8s.io image reads as unreadable.
CURL=(curl -sSL --max-time 25 --retry 2 --retry-delay 1)

# Every image actually running, containers and init containers alike, deduplicated.
kubectl get pods -A -o json \
  | jq -r '[.items[].spec | (.containers // []) + (.initContainers // []) | .[].image]
           | unique | .[]' > "$WORK/images.txt"

[ -s "$WORK/images.txt" ] || { echo "No images read from the cluster." >&2; exit 2; }

# The LAN-only registry has no upstream to be behind of, and is unreachable from a runner.
sed -i '/^zot\.merry\.home\.arpa/d' "$WORK/images.txt"

# registry_of <image> -> "<registry>\t<repository>"
registry_of() {
  local image="$1" first rest
  first="${image%%/*}"
  case "$first" in
    *.*|*:*)
      rest="${image#*/}"
      # An official image is `library/<name>` even when the registry is spelled out:
      # docker.io/eclipse-mosquitto is a 401, docker.io/library/eclipse-mosquitto is a 200.
      if [ "$first" = "docker.io" ] && [ "$rest" = "${rest%%/*}" ]; then
        printf 'docker.io\tlibrary/%s\n' "$rest"
      else
        printf '%s\t%s\n' "$first" "$rest"
      fi ;;
    *)
      case "$image" in
        */*) printf 'docker.io\t%s\n' "$image" ;;
        *)   printf 'docker.io\tlibrary/%s\n' "$image" ;;
      esac ;;
  esac
}

api_host() { [ "$1" = "docker.io" ] && echo "registry-1.docker.io" || echo "$1"; }

# Bearer token via the standard Www-Authenticate challenge, so this works the same on
# ghcr.io, docker.io, quay.io, registry.k8s.io and anything else that speaks the v2 API.
token_for() {
  local reg="$1" repo="$2" host chal realm service
  host="$(api_host "$reg")"
  chal="$("${CURL[@]}" -o /dev/null -D - "https://$host/v2/" 2>/dev/null \
          | tr -d '\r' | grep -i '^www-authenticate:' | head -1 || true)"
  [ -n "$chal" ] || return 0
  realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$chal")"
  service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$chal")"
  [ -n "$realm" ] || return 0
  "${CURL[@]}" "$realm?service=${service}&scope=repository:${repo}:pull" 2>/dev/null \
    | jq -r '.token // .access_token // empty' 2>/dev/null || true
}

# All tags for a repository, following the Link header, bounded so a huge repository
# cannot hang the run.
tags_for() {
  local reg="$1" repo="$2" host tok url page link i
  host="$(api_host "$reg")"
  tok="$(token_for "$reg" "$repo")"
  url="https://$host/v2/$repo/tags/list?n=1000"
  for i in $(seq 1 8); do
    page="$WORK/page.json"
    if [ -n "$tok" ]; then
      link="$("${CURL[@]}" -H "Authorization: Bearer $tok" -D "$WORK/h" -o "$page" "$url" 2>/dev/null && \
              tr -d '\r' < "$WORK/h" | sed -n 's/^[Ll]ink: *//p' | head -1)"
    else
      link="$("${CURL[@]}" -D "$WORK/h" -o "$page" "$url" 2>/dev/null && \
              tr -d '\r' < "$WORK/h" | sed -n 's/^[Ll]ink: *//p' | head -1)"
    fi
    jq -r '.tags // [] | .[]' "$page" 2>/dev/null || return 1
    [ -n "$link" ] || break
    url="https://$host$(sed -n 's/^<\([^>]*\)>.*/\1/p' <<<"$link")"
  done
}

# newest_comparable <current-tag> < tags-on-stdin
# Prints "<newest> <how-many-newer>", or nothing when no tag shares the current shape.
newest_comparable() {
  jq -Rrn --arg cur "$1" '
    # "v1.2.3-distroless" -> {nums: [1,2,3], flav: "distroless"}; null when not a version.
    def parse:
      . as $t
      | ($t | ltrimstr("v")) as $b
      | ($b | capture("^(?<n>[0-9]+(\\.[0-9]+)*)([-.](?<r>.*))?$") // null) as $m
      | if $m == null then null
        else ($m.r // "") as $rest
          | if ($rest | test("^[0-9]+$"))
            # a trailing all-numeric segment is a build date, not a flavour: keep comparing
            then {nums: (($m.n | split(".")) + [$rest] | map(tonumber)), flav: ""}
            elif ($rest == "" or ($rest | test("^[a-z][a-z0-9.-]*$")))
            then {nums: ($m.n | split(".") | map(tonumber)), flav: $rest}
            # rc / alpha / a commit hash: deliberately out of the comparison
            else null end
        end;
    ($cur | parse) as $c
    | if $c == null then empty
      else
        [inputs | select(length > 0)] as $tags
        | [ $tags[] | . as $t | ($t | parse) as $p
            | select($p != null and $p.flav == $c.flav
                     and ($p.nums | length) == ($c.nums | length))
            | {tag: $t, nums: $p.nums} ]                            as $cand
        | if ($cand | length) == 0 then empty
          else
            ($cand | sort_by(.nums) | last)                          as $best
            | ([ $cand[] | select(.nums > $c.nums) ] | length)       as $ahead
            | "\($best.tag) \($ahead)"
          end
      end'
}

BEHIND=0
printf '%-58s %-22s %-22s %-8s %s\n' IMAGE CURRENT LATEST TRACKED GAP
printf '%.0s-' {1..122}; echo

while read -r full; do
  [ -n "$full" ] || continue
  ref="${full%%@*}"                       # a digest pin still carries the tag we compare
  case "${ref##*/}" in
    *:*) image="${ref%:*}"; cur="${ref##*:}" ;;
    *)   image="$ref";      cur="" ;;
  esac

  # Does any manifest here name this image? That is what decides whether Renovate can see
  # it at all — the version gap below is only interesting once the answer is "no".
  if grep -rqF "$image" kubernetes/ 2>/dev/null; then tracked="repo"; else tracked="chart"; fi

  if [ -z "$cur" ]; then
    printf '%-58s %-22s %-22s %-8s %s\n' "$image" "(none)" "-" "$tracked" "untagged"
    continue
  fi

  IFS=$'\t' read -r reg repo <<<"$(registry_of "$image")"
  if ! tags_for "$reg" "$repo" > "$WORK/tags.txt" 2>/dev/null || [ ! -s "$WORK/tags.txt" ]; then
    printf '%-58s %-22s %-22s %-8s %s\n' "$image" "$cur" "-" "$tracked" "unreadable"
    continue
  fi

  result="$(newest_comparable "$cur" < "$WORK/tags.txt" || true)"
  if [ -z "$result" ]; then
    printf '%-58s %-22s %-22s %-8s %s\n' "$image" "$cur" "-" "$tracked" "not comparable"
    continue
  fi

  latest="${result%% *}"; ahead="${result##* }"
  if [ "$ahead" -gt 0 ]; then
    BEHIND=$((BEHIND + 1))
    printf '%-58s %-22s %-22s %-8s %s\n' "$image" "$cur" "$latest" "$tracked" "$ahead behind"
  fi
done < "$WORK/images.txt"

echo
if [ "$BEHIND" -eq 0 ]; then
  echo "Every comparable image is on the newest tag of its shape."
  exit 0
fi
echo "$BEHIND image(s) behind. A 'chart' one has no Renovate PR coming — it moves only if"
echo "the chart is bumped, or never, if the chart itself is frozen."
exit 1
