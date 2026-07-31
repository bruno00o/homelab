#!/usr/bin/env bash
# Do the values we write in a HelmRelease actually exist in the chart?
#
# Helm accepts unknown value keys in silence. Nothing warns, nothing fails, the release
# reports Ready — the setting simply never happens. Measured twice in this repo:
# `reloader` ran for months with an empty securityContext and no limits because its values
# sat one level above where the chart reads them (AUDIT R20), and `hubble.ui.resources`
# was written where the cilium chart only defines `hubble.ui.frontend` and
# `hubble.ui.backend`, so both containers ran with `resources: {}` (item 20).
#
# A values.schema.json is not the protection it looks like. Every chart here that ships one
# still accepts an unknown key at the root — app-template rejects `bogus` under
# `/controllers/main/containers/main` but takes it at the top level, and cilium's schema
# refuses nothing at all. Skipping schema-bearing charts is what hid `cilium.externalIPs`
# from this script until `flate` reported it, so no chart is exempt.
#
# `flate test` warns on the same class of defect and is worth keeping: it reads the chart
# through Helm's own loader rather than by grepping templates. It stops at the top level
# though — measured on the tree before these were fixed, it found 2 of the 20, both
# top-level keys. The nested ones (`hubble.ui.resources`, `admissionController.resources`,
# `defaultSettings.backupTarget`) are what this walk is for.
#
# Fails the build when it finds anything, because the repo is at zero: the twenty dead
# values this found on its first run are fixed. The case that will trip it in practice is a
# Renovate bump moving or renaming a key, which is exactly when someone should look — the
# alternative, a baseline file, would let a real regression be filed away as accepted.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v helm >/dev/null || { echo "helm not found. Run 'task deps:install'." >&2; exit 2; }
command -v yq >/dev/null || { echo "yq not found. Run 'task deps:install'." >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found. Run 'task deps:install'." >&2; exit 2; }

REPOS="kubernetes/flux/repositories.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Chart sources, resolved once. A HelmRelease names either an OCIRepository through
# `chartRef` (version pinned on the source) or a HelmRepository through `chart.spec`
# (version pinned on the release), and both live in this one file.
yq -o=json 'select(.kind == "OCIRepository" or .kind == "HelmRepository")' "$REPOS" |
  jq -s 'map({key: (.kind + "/" + .metadata.name),
             value: {url: .spec.url, tag: (.spec.ref.tag // ""), type: (.spec.type // "")}})
         | from_entries' > "$WORK/sources.json"

# ---------------------------------------------------------------------------
# Pull a chart once and print its directory. Repeated calls for the same chart and version
# are free, which matters because several releases share app-template.
fetch() {  # ref version [repo] -> dir on stdout
  ref=$1 version=$2 repo=${3:-}
  key=$(printf '%s@%s@%s' "$repo" "$ref" "$version" | tr -c 'A-Za-z0-9' '_')
  dir="$WORK/charts/$key"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    if ! helm pull "$ref" ${repo:+--repo "$repo"} ${version:+--version "$version"} \
         --untar --untardir "$dir" >"$dir/.pull.log" 2>&1; then
      rm -rf "$dir"
      return 1
    fi
  fi
  find "$dir" -maxdepth 2 -name Chart.yaml -print0 | head -z -n1 | xargs -0 dirname
}

# Defaults tree for a chart, with every subchart merged under the name the parent uses for
# it. Without this, `grafana.*` inside kube-prometheus-stack looks unknown: a packaged
# chart's values.yaml declares only its own keys, its dependencies' defaults live in
# charts/<name>/values.yaml.
defaults() {  # chartdir -> json on stdout
  root=$1
  base=$(yq -o=json '.' "$root/values.yaml" 2>/dev/null || echo '{}')
  [ "$base" = "null" ] && base='{}'
  for sub in "$root"/charts/*/; do
    [ -d "$sub" ] || continue
    name=$(yq -r '.name' "$sub/Chart.yaml" 2>/dev/null || true)
    [ -n "$name" ] && [ "$name" != "null" ] || continue
    # An aliased dependency is addressed by its alias, not by the subchart's own name.
    alias=$(yq -r --arg n "$name" \
      '.dependencies[]? | select(.name == $n) | .alias // ""' "$root/Chart.yaml" 2>/dev/null || true)
    [ -n "$alias" ] && [ "$alias" != "null" ] && name=$alias
    subvals=$(defaults "${sub%/}")
    base=$(jq --arg k "$name" --argjson v "$subvals" '.[$k] = ((.[$k] // {}) * $v)' <<<"$base")
  done
  printf '%s' "$base"
}

# Does a template actually consume this path? values.yaml is only a declaration; templates
# are what reads. Two ways a path can be legitimate without appearing in values.yaml:
#
#   - the template names it outright, which charts do all the time for undocumented keys;
#   - an ancestor is handed over whole — `with`, `range`, `toYaml` — so the chart takes
#     whatever sits below it. `podSecurityContext` on qdrant is exactly this.
#
# The pass-through test is deliberately narrow. Cilium writes `hasKey .Values.hubble "x"`,
# which mentions the ancestor without passing it through: treating any mention as a
# pass-through would suppress `hubble.ui.resources`, one of the two defects this exists for.
# The cost of the narrowness is the reverse case — a `with` whose body reads keys one by
# one hides them from us — and that is the right way round for a warning.
consumed() {  # chartdir path
  d=$1 p=$2
  esc=$(printf '%s' "$p" | sed 's/\./\\./g')
  grep -rEq "\.Values\.$esc([^.A-Za-z0-9_]|$)" "$d" --include="*.tpl" --include="*.yaml" 2>/dev/null && return 0
  # Subchart templates address their own values without the parent's prefix — but only when
  # the first segment really names a subchart. Dropping it unconditionally absolves far too
  # much: `server.annotations` on authentik was cleared by an unrelated top-level
  # `.Values.annotations`, and that value is dead.
  sub=${p#*.}
  if [ "$sub" != "$p" ] && [ -d "$d/charts/${p%%.*}" ]; then
    esc=$(printf '%s' "$sub" | sed 's/\./\\./g')
    grep -rEq "\.Values\.$esc([^.A-Za-z0-9_]|$)" "$d" --include="*.tpl" --include="*.yaml" 2>/dev/null && return 0
  fi
  anc=$p
  while [ "${anc%.*}" != "$anc" ]; do
    anc=${anc%.*}
    cands=$anc
    [ -d "$d/charts/${p%%.*}" ] && [ "${anc#*.}" != "$anc" ] && cands="$anc ${anc#*.}"
    for cand in $cands; do
      esc=$(printf '%s' "$cand" | sed 's/\./\\./g')
      # `$.Values` as well as `.Values`: inside a range or a with, charts reach back to the
      # root context that way, and home-assistant's `with $.Values.livenessProbe` is exactly
      # a pass-through we must not report.
      grep -rEq "(toYaml|with|range)[[:space:]]+\(?\\\$?\.Values\.$esc([^.A-Za-z0-9_]|$)|\\\$?\.Values\.$esc[[:space:]]*\|[[:space:]]*toYaml" \
        "$d" --include="*.tpl" --include="*.yaml" 2>/dev/null && return 0
    done
  done
  return 1
}

# Top-level keys a chart's own values.schema.json does not declare.
#
# For a chart routed through a library loader the walk below is impossible, but the schema is
# still an authority on the first level. Helm will not use it there: app-template and cilium
# both declare root `properties` and leave `additionalProperties` unset, which JSON Schema
# reads as "anything goes", so a bogus key at the root of a HelmRelease is accepted by Helm,
# ignored by flate, and skipped by the walk. This closes that.
schema_root_unknown() {  # chartdir ours-json
  file="$1/values.schema.json"
  [ -f "$file" ] || return 0
  # The key is bound before the test: inside `$p | has(.)` the dot would refer to $p, not to
  # the key, and every lookup would succeed silently.
  jq -r --argjson ours "$2" '
    (.properties // {}) as $p
    | if ($p | length) == 0 then empty
      else ($ours | keys_unsorted[]) as $k | select($p | has($k) | not) | $k
      end' "$file" 2>/dev/null || true
}

# Keys we write that the chart's defaults do not define.
#
# The walk stops descending as soon as the defaults stop describing a structure: an empty
# map, a list or a scalar means the chart takes whatever is put there (podAnnotations,
# nodeSelector, extraEnv, a config blob), so nothing below it can be called unknown.
UNKNOWN_JQ='
def walk($ours; $defs; $path):
  if ($ours | type) != "object" then empty
  elif ($defs | type) != "object" then empty
  elif ($defs | length) == 0 then empty
  else
    $ours | keys_unsorted[] as $k
    | if ($defs | has($k) | not) then ($path + [$k] | join("."))
      # A key whose own name contains a dot (grafana.ini) cannot be told apart from nesting
      # once the path is joined, and no template addresses it as `.Values.a.b` either. Its
      # presence is still checked; what sits below it is not ours to judge.
      elif ($k | test("\\.")) then empty
      else walk($ours[$k]; $defs[$k]; $path + [$k]) end
  end;
walk($ours; $defs; [])'

# ---------------------------------------------------------------------------
found=0
checked=0
skipped=""
library=""
unchecked=""

for f in $(grep -rl "kind: HelmRelease" kubernetes --include="*.yaml" | sort); do
  # One file can hold several documents; gotk-components.yaml matches the grep on a CRD.
  count=$(yq -o=json 'select(.kind == "HelmRelease") | .metadata.name' "$f" 2>/dev/null | wc -l)
  [ "$count" -gt 0 ] || continue

  for i in $(seq 0 $((count - 1))); do
    doc=$(yq -o=json "[select(.kind == \"HelmRelease\")] | .[$i]" "$f" 2>/dev/null)
    [ -n "$doc" ] && [ "$doc" != "null" ] || continue
    name=$(jq -r '.metadata.name' <<<"$doc")
    ours=$(jq '.spec.values // {}' <<<"$doc")
    [ "$(jq 'length' <<<"$ours")" -gt 0 ] || continue

    url="" repo=""
    refkind=$(jq -r '.spec.chartRef.kind // ""' <<<"$doc")
    if [ "$refkind" = "OCIRepository" ]; then
      src=$(jq -r --arg n "$(jq -r '.spec.chartRef.name' <<<"$doc")" \
        '.["OCIRepository/" + $n] // empty' "$WORK/sources.json")
      url=$(jq -r '.url' <<<"$src")
      version=$(jq -r '.tag' <<<"$src")
    else
      chart=$(jq -r '.spec.chart.spec.chart // ""' <<<"$doc")
      version=$(jq -r '.spec.chart.spec.version // ""' <<<"$doc")
      src=$(jq -r --arg n "$(jq -r '.spec.chart.spec.sourceRef.name // ""' <<<"$doc")" \
        '.["HelmRepository/" + $n] // empty' "$WORK/sources.json")
      [ -n "$chart" ] && [ -n "$src" ] || { skipped="$skipped $name"; continue; }
      base=$(jq -r '.url' <<<"$src")
      if [ "$(jq -r '.type' <<<"$src")" = "oci" ]; then
        url="${base%/}/$chart"
      else
        # A plain HTTP repository is not something helm pulls from by URL: the chart is
        # named on its own and the repository passed beside it.
        url=$chart repo=${base%/}
      fi
    fi
    [ -n "$url" ] && [ "$url" != "null" ] || { skipped="$skipped $name"; continue; }

    dir=$(fetch "$url" "$version" "${repo:-}") || { skipped="$skipped $name"; continue; }

    checked=$((checked + 1))

    # A chart built on a library chart is out of reach for this technique. immich is the
    # case here: it depends on bjw-s `common`, and every component is rendered by handing
    # a rewritten context to the library's loader, so `.Values.server.controllers...`
    # appears in no template of either chart. Grepping would call the whole tree unknown —
    # 21 lines of noise on a release that is in fact correct. Named in the output rather
    # than dropped quietly, so the gap stays visible.
    if find "$dir/charts" -maxdepth 2 -name Chart.yaml 2>/dev/null |
       xargs -r grep -lq '^type: library' 2>/dev/null; then
      checked=$((checked - 1))
      # Split by what can still be said about it: with a schema the first level is checked,
      # without one nothing is. Lumping the two together would claim a coverage that does
      # not exist for immich, the only chart here in the second group.
      if [ -f "$dir/values.schema.json" ]; then
        library="$library $name"
        for path in $(schema_root_unknown "$dir" "$ours"); do
          echo "  $name: values.$path is not read by the chart"
          found=1
        done
      else
        unchecked="$unchecked $name"
      fi
      continue
    fi

    defs=$(defaults "$dir")
    unknown=$(jq -r --argjson ours "$ours" --argjson defs "$defs" "$UNKNOWN_JQ" <<<'null')
    [ -n "$unknown" ] || continue

    for path in $unknown; do
      consumed "$dir" "$path" && continue
      echo "  $name: values.$path is not read by the chart"
      found=1
    done
  done
done

echo
echo "$checked chart(s) checked."
[ -n "$library" ] && echo "Root level only, values routed through a library chart:$library"
[ -n "$unchecked" ] && echo "Not checked at all, library-routed and no values.schema.json:$unchecked"
[ -n "$skipped" ] && echo "Could not resolve a chart for:$skipped" >&2

if [ "$found" -eq 1 ]; then
  echo "Each line above is a setting that has no effect. Check it against the chart:"
  echo "  helm show values <chart> --version <version>"
  echo "  for a library-routed chart, its values.schema.json lists the valid top-level keys"
  exit 1
fi
exit 0
