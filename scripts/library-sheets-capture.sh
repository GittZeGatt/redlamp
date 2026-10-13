#!/usr/bin/env bash
#
# Captures the library's sheets and windows from the harness's Library scenes (LIB-49), each in its states, on the
# harness's own library, with its --snapshot: no Screen Recording needed. Build the harness first (mise run h).
#
# usage: scripts/library-sheets-capture.sh <out folder> [harness arguments...]
#   e.g. scripts/library-sheets-capture.sh /tmp/sheets-dark
#        scripts/library-sheets-capture.sh /tmp/sheets-light --appearance light
#        ONLY="lightroom:opened rename-photos:opened" scripts/library-sheets-capture.sh /tmp/two
#
# Each shot launches the harness on its own, in the background; once the library is ready and the surface open (or
# after WAIT seconds, 180), it writes <out>/<surface>-<state>.png and quits.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${1:?usage: scripts/library-sheets-capture.sh <out folder> [harness arguments...]}"
# Absolute: the harness, launched by open, starts in /.
OUT="$(cd "$1" && pwd)"
shift
BUNDLE="$ROOT/build/DerivedData/Build/Products/${CONFIGURATION:-Debug}/RedlampHarness.app"
[[ -d "$BUNDLE" ]] || { echo "error: build the harness first (mise run h)" >&2; exit 1; }

SHOTS=(
    library-import:import-photos:opened library-import:import-photos:finished
    library-import:import-photos:interrupted library-import:import-photos:minimum
    library-lightroom:lightroom:no-catalog library-lightroom:lightroom:opened library-lightroom:lightroom:imported
    library-lightroom:lightroom:undone library-lightroom:lightroom:minimum
)
for surface in new-collection new-collection-set rename-collection add-to-collection new-smart-collection \
    edit-smart-collection custom-labels edit-keyword create-keyword merge-keyword code-replacements edit-capture-time \
    metadata-presets rename-photos duplicates move-edits; do
    SHOTS+=("library-sheets:$surface:opened")
done

caffeinate -u -d -w $$ &
for shot in "${SHOTS[@]}"; do
    IFS=: read -r scene surface state <<<"$shot"
    [[ -n "${ONLY:-}" && " $ONLY " != *" $surface:$state "* ]] && continue
    echo "--scene $scene --library-surface $surface --library-state $state --snapshot $OUT/$surface-$state.png" \
        "--snapshot-delay ${WAIT:-180} $*" >/tmp/redlamp-harness-args
    open -n -g -W "$BUNDLE"
    [[ -f "$OUT/$surface-$state.png" ]] && echo "==> $OUT/$surface-$state.png" || echo "missing: $surface-$state"
done
