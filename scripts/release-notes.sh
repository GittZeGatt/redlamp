#!/usr/bin/env bash
#
# Prints a release's notes, which its GitHub release and the update window show (scripts/appcast.sh):
# its highlights, chosen in the release room (docs/releases/<version>.md, as <highlights ref> has it,
# or else the release's own commit), then a line for each commit no earlier release has. GitHub
# refuses a release whose notes pass 125,000 characters, as 0.3.0-alpha's did with 1,020 commits, so
# when the list would take them past that, a link to the comparison of the two releases takes its
# place, where GitHub lists every commit.
#
#   scripts/release-notes.sh <version> <commit> [<highlights ref>]
#
# A release that's tagged already is compared with the release tagged before it, so
#
#   scripts/release-notes.sh 0.3.0-alpha v0.3.0-alpha origin/main
#
# prints 0.3.0-alpha's notes as the release task makes them. What it did goes to stderr.

set -euo pipefail

USAGE="usage: release-notes.sh <version> <commit> [<highlights ref>]"
VERSION="${1:?$USAGE}"
COMMIT="${2:?$USAGE}"
FROM="${3:-$COMMIT}"
TAG="v$VERSION"
HIGHLIGHTS="docs/releases/$VERSION.md"
COMPARE="https://github.com/pdcgomes/redlamp/compare"
# Leaves room for the changelog line GitHub adds (--generate-notes).
LIMIT=120000

git rev-parse -q --verify "$COMMIT^{commit}" >/dev/null || { echo "error: no commit $COMMIT" >&2; exit 1; }

# The releases before this one, newest first: every v* tag, or once this one is tagged, those tagged
# before it. A release made from an earlier commit is tagged off main, so it's found by date.
MADE="$(git for-each-ref --format='%(creatordate:unix)' "refs/tags/$TAG")"
EARLIER="$(git for-each-ref --sort=-creatordate --format='%(creatordate:unix) %(refname)' 'refs/tags/v*' \
    | awk -v tag="refs/tags/$TAG" -v made="$MADE" '$2 != tag && (made == "" || $1 < made) { print $2 }')"
PREVIOUS="$(sed -n '1s#^refs/tags/##p' <<<"$EARLIER")"
[ -n "$PREVIOUS" ] || { echo "error: no release before $TAG" >&2; exit 1; }

highlights() {
    local ref
    for ref in "$FROM" "$COMMIT"; do
        if git cat-file -e "$ref:$HIGHLIGHTS" 2>/dev/null; then
            git show "$ref:$HIGHLIGHTS"
            echo
            return
        fi
    done
}

thousands() {
    sed -E -e ':a' -e 's/([0-9])([0-9]{3})($|,)/\1,\2\3/' -e 'ta' <<<"$1"
}

characters() {
    LC_ALL=en_US.UTF-8 wc -m | tr -d ' '
}

# The version bumps and the cask's commits aren't changes to the app.
SKIP=(--no-merges --invert-grep --grep='^Cask: ' --grep='^Version [0-9]')
# shellcheck disable=SC2086
COUNT="$(git rev-list --count "${SKIP[@]}" "$COMMIT" --not $EARLIER)"
NOTES="$(
    highlights
    echo "Changes since ${PREVIOUS#v}:"
    echo
    # shellcheck disable=SC2086
    git log --format='- %s' "${SKIP[@]}" "$COMMIT" --not $EARLIER
)"
LISTED="$(characters <<<"$NOTES")"
if [ "$LISTED" -le "$LIMIT" ]; then
    echo "==> Notes: $(thousands "$COUNT") commits since ${PREVIOUS#v}, each listed ($(thousands "$LISTED") characters)" >&2
else
    NOTES="$(
        highlights
        echo "Changes since ${PREVIOUS#v}: $(thousands "$COUNT") commits, too many to list here; the comparison has every one: $COMPARE/$PREVIOUS...$TAG"
    )"
    SHORT="$(characters <<<"$NOTES")"
    echo "==> Notes: $(thousands "$COUNT") commits since ${PREVIOUS#v}, $(thousands "$LISTED") characters with each listed, over GitHub's limit; the highlights and the comparison's link instead ($(thousands "$SHORT") characters)" >&2
    if [ "$SHORT" -gt "$LIMIT" ]; then
        echo "error: $HIGHLIGHTS alone takes the notes past GitHub's limit" >&2
        exit 1
    fi
fi
printf '%s\n' "$NOTES"
