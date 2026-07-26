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

curl -sfL https://github.com/fluxcd/flux2/releases/latest/download/crd-schemas.tar.gz |
  tar xz -C "$WORK" --one-top-level=flux-crds

find "$WORK/kubernetes" -name '*.yaml' -print0 | xargs -0 kubeconform \
  -strict \
  -ignore-missing-schemas \
  -schema-location default \
  -schema-location "$WORK/flux-crds/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -summary
