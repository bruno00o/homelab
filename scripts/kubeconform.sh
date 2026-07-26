#!/usr/bin/env bash
# Schema-validate every manifest under kubernetes/, CRDs included.
#
# Called by both `task validate` and .github/workflows/ci.yaml so local and remote
# validation cannot drift apart.
#
# Flux substitutes ${VAR} from cluster-settings and cluster-secrets at apply time, so the
# files on disk are not what the API server sees. Validating them raw makes every
# templated hostname fail its schema pattern. This script therefore resolves the same
# variables Flux would, and mirrors Flux's behaviour of leaving unknown ones untouched
# (that is what keeps ${datasource} in the Grafana dashboards intact).
set -euo pipefail

cd "$(dirname "$0")/.."

SETTINGS="kubernetes/flux/vars/cluster-settings.yaml"
SECRETS="kubernetes/flux/vars/cluster-secrets.sops.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Real values for settings; a dummy for secrets, whose plaintext is irrelevant to schemas
# (SOPS keeps the keys readable, so no decryption is needed here).
{
  yq -r '.stringData // .data | keys | .[]' "$SECRETS" | sed 's|.*|s/${&}/validation-placeholder/g|'
  yq -r '.data | to_entries | .[] | "s|${" + .key + "}|" + .value + "|g"' "$SETTINGS"
} > "$WORK/subst.sed"

find kubernetes -name '*.yaml' -not -name '*.sops.yaml' | while read -r f; do
  mkdir -p "$WORK/$(dirname "$f")"
  sed -f "$WORK/subst.sed" "$f" > "$WORK/$f"
done

# Schemas are cached so a second run needs no network — otherwise this cannot be used as
# a pre-commit hook. The Flux cache is keyed on the version pinned in .mise.toml, both to
# validate against the CRDs actually deployed and to invalidate itself when Renovate
# bumps it.
FLUX_VERSION=$(grep -oP '(?<=^flux2 = ")[^"]+' .mise.toml)
CACHE=".cache/kubeconform"
FLUX_CRDS="$CACHE/flux-$FLUX_VERSION"
mkdir -p "$CACHE/schemas"

if [ ! -d "$FLUX_CRDS" ]; then
  if ! curl -sfL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/crd-schemas.tar.gz" |
    tar xz -C "$CACHE" --one-top-level="flux-$FLUX_VERSION"; then
    rm -rf "$FLUX_CRDS"
    echo "Cannot download Flux $FLUX_VERSION CRD schemas (offline?), and no cache exists." >&2
    exit 1
  fi
fi

# kustomization.yaml files are kustomize config, not API resources, and no catalog holds a
# schema for KumaEntity or for CRDs themselves. Declaring them skipped keeps them out of
# the summary and, more importantly, stops kubeconform from re-requesting schemas that will
# never exist — those lookups are not cacheable and hang when offline.
find "$WORK/kubernetes" -name '*.yaml' -not -name 'kustomization.yaml' -print0 | xargs -0 kubeconform \
  -strict \
  -ignore-missing-schemas \
  -skip KumaEntity,CustomResourceDefinition \
  -cache "$CACHE/schemas" \
  -schema-location default \
  -schema-location "$FLUX_CRDS/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -summary
