#!/usr/bin/env bash
# Are the tools a task is about to run the ones .mise.toml pins?
#
# Nothing guarantees it. A Renovate bump changes the pin without installing anything, and
# a shell opened before the bump keeps resolving the previous install directory — so a
# task runs an outdated binary and reports success. Both halves have happened here: a
# `validate` pass rendered by the flate that came before the pinned one, and a pre-push
# hook that blocked on a tool the bump had never installed.
#
# A taskfile cannot fix this on its own. PATH is the one variable go-task will not let it
# override, so every task inherits whatever the caller's shell resolved, however old.
#
# So install what is missing, then compare what PATH answers against what mise resolves,
# and say which is which. The commands to check are read out of mise's own directories and
# kept to those this repo actually invokes: no hand-written map of tool name to command
# name to drift, and none of the side binaries a tool ships but nobody here calls.
set -euo pipefail

cd "$(dirname "$0")/.."

# Only when there is something to do: mise narrates "all tools are installed" on stderr
# otherwise, and this runs in front of every task.
if [ -n "$(mise ls --missing)" ]; then
  mise install
fi

status=0
# Every tracked shell script, not just scripts/: two of the drift detectors live beside
# the manifests they read, and a tool used only there would otherwise go unchecked.
mapfile -t callers < <(git ls-files 'taskfile.yaml' 'lefthook.yml' '*.sh')

while read -r dir; do
  [ -d "$dir" ] || continue
  for path in "$dir"/*; do
    [ -x "$path" ] && [ ! -d "$path" ] || continue
    bin=$(basename "$path")
    grep -qwF -- "$bin" "${callers[@]}" || continue
    found=$(command -v "$bin" 2>/dev/null || true)
    if [ -z "$found" ]; then
      echo "  $bin: pinned but not on PATH — expected $path"
      status=1
    elif [ "$found" != "$path" ]; then
      echo "  $bin: PATH resolves $found, .mise.toml pins $path"
      status=1
    fi
  done
done < <(mise bin-paths)

if [ "$status" -ne 0 ]; then
  cat >&2 <<'MSG'

Your shell resolves a different version than this repo pins. Tasks would run it and pass.
Open a new shell, or prefix the command with `mise exec --`.
MSG
fi

exit "$status"
