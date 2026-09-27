#!/usr/bin/env bash
# Prints the machine config of one node: talos/machineconfig.yaml.j2 rendered with that node's
# entry in talos/nodes.yaml and the secrets bundle.
#
# The output holds every cluster secret. Pipe it into talosctl (`--file /dev/stdin`), never
# into a file: the bundle is decrypted into this pipeline and nowhere else.
#
#   scripts/talos-render.sh luffy | talosctl apply-config --nodes 10.0.20.11 --file /dev/stdin
#
# TALOS_SECRETS_FILE and TALOS_SCHEMATIC stand in for the real bundle and the Image Factory
# call, so validate:talos renders through this same path offline and without the age key.
set -euo pipefail

TALOS_DIR="$(cd "$(dirname "$0")/../talos" && pwd)"
NODE="${1:?usage: $0 <hostname or IP>}"

NAME=$(yq -r ".nodes[] | select(.hostname == \"$NODE\" or .ipAddress == \"$NODE\") | .hostname" \
  "$TALOS_DIR/nodes.yaml")
if [ -z "$NAME" ]; then
  echo "$NODE is not in talos/nodes.yaml" >&2
  exit 1
fi

# The ID is a hash of the schematic, so asking the factory costs nothing and never drifts
# from the file the way a copied ID would.
SCHEMATIC="${TALOS_SCHEMATIC:-$(curl -fsS --retry 3 -X POST --data-binary "@$TALOS_DIR/schematic.yaml" \
  https://factory.talos.dev/schematics | jq -r .id)}"
if ! [[ "$SCHEMATIC" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Image Factory returned no schematic ID" >&2
  exit 1
fi

secrets() {
  if [ -n "${TALOS_SECRETS_FILE:-}" ]; then
    cat "$TALOS_SECRETS_FILE"
  else
    sops -d "$TALOS_DIR/talsecret.sops.yaml"
  fi
}

# One data document: nodes.yaml and the bundle side by side. Their top-level keys do not
# overlap, so the merge only places them next to each other. The bundle stores certificates
# and keys base64-encoded, as the v1alpha1 fields take them; the newer documents take PEM,
# which minijinja cannot decode, so `pem` carries them decoded. Built from to_entries rather
# than map_values, which decodes `certs` in place as well.
# --strict turns a missing value into an error instead of an empty field in a valid config.
secrets \
  | yq eval-all '. as $doc ireduce ({}; . * $doc)
      | .pem = (.certs | to_entries | map({"key": .key, "value": (.value | to_entries
          | map({"key": .key, "value": (.value | @base64d)}) | from_entries)}) | from_entries)' \
      "$TALOS_DIR/nodes.yaml" - \
  | minijinja-cli --autoescape none --no-newline --strict --trim-blocks --lstrip-blocks \
      --format yaml --define "node=$NAME" --define "schematic=$SCHEMATIC" \
      "$TALOS_DIR/machineconfig.yaml.j2" -
