#!/bin/zsh
# Új verzió kiadása: git-címke, build, GitHub Release a letölthető alkalmazással.
# Használat: ./scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
if [[ ! $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "Használat: scripts/release.sh X.Y.Z  (pl. 0.2.0)" >&2
    exit 1
fi
TAG="v$VERSION"

fail() { echo "Hiba: $1" >&2; exit 1; }
[[ $(git branch --show-current) == main ]] || fail "csak a main ágról lehet kiadni."
[[ -z $(git status --porcelain) ]] || fail "vannak nem commitolt változások."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "a $TAG címke már létezik."
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "a helyi main nem egyezik az origin/main-nel (push vagy pull kell)."

# Kiadási jegyzet a legutóbbi címke óta készült commitok első sorából, típus szerint csoportosítva.
PREVIOUS=$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)
RANGE=${PREVIOUS:+$PREVIOUS..}HEAD
typeset -a FEATURES FIXES OTHERS
for commit in $(git rev-list --reverse "$RANGE"); do
    subject=$(git log -1 --format=%B "$commit" | head -1)
    description=${subject#*: }
    case $subject in
        feat*) FEATURES+=("- $description") ;;
        fix*) FIXES+=("- $description") ;;
        *) OTHERS+=("- $description") ;;
    esac
done
NOTES=""
(( ${#FEATURES} )) && NOTES+="### Új funkciók"$'\n'"${(F)FEATURES}"$'\n\n'
(( ${#FIXES} )) && NOTES+="### Javítások"$'\n'"${(F)FIXES}"$'\n\n'
(( ${#OTHERS} )) && NOTES+="### Egyéb"$'\n'"${(F)OTHERS}"$'\n\n'
NOTES+="Telepítés: töltsd le a zipet, csomagold ki, és húzd a Paperboy.app-ot az Alkalmazások mappába."

echo "== $TAG kiadási jegyzet =="
echo "$NOTES"
echo

git tag -a "$TAG" -m "Paperboy $VERSION"
./scripts/build-app.sh
ZIP="build/Paperboy-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Paperboy.app "$ZIP"

git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Paperboy $VERSION" --notes "$NOTES"
