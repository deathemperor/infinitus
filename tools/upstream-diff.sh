#!/bin/sh
# What changed upstream since we last mirrored it. Reads upstream/<name>.json
# (the marked commit and the watched paths), fetches the upstream branch, and
# prints commits + diffstat per watched theme. The weekly workflow
# (.github/workflows/upstream-watch.yml) posts this to an issue; run it by
# hand before applying a batch, then `--mark <sha>` once the batch landed.
#
#   tools/upstream-diff.sh t3code            # report since the marked commit
#   tools/upstream-diff.sh t3code --mark HEAD  # move the mark (after applying)
set -eu
name="${1:?usage: tools/upstream-diff.sh <name> [--mark <sha>]}"; shift
manifest="$(dirname "$0")/../upstream/$name.json"
[ -f "$manifest" ] || { echo "no manifest at $manifest" >&2; exit 2; }
field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['$1'])" "$manifest"; }
repo=$(field repo); branch=$(field branch); mark=$(field commit)
cache="${UPSTREAM_CACHE:-${TMPDIR:-/tmp}/upstream-$name.git}"
if [ ! -d "$cache" ]; then
    git clone -q --bare --filter=blob:none --single-branch --branch "$branch" "https://github.com/$repo" "$cache"
else
    git --git-dir "$cache" fetch -q origin "+refs/heads/$branch:refs/heads/$branch"
fi
head=$(git --git-dir "$cache" rev-parse "$branch")
if [ "${1:-}" = "--mark" ]; then
    new=$(git --git-dir "$cache" rev-parse "${2:-$branch}")
    python3 - "$manifest" "$new" <<'PY'
import json, sys, datetime
p, sha = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["commit"] = sha; d["markedAt"] = datetime.date.today().isoformat()
json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
PY
    echo "marked $name at $new"; exit 0
fi
echo "# $repo $branch: $(git --git-dir "$cache" rev-list --count "$mark..$head") commits since $(echo "$mark" | cut -c1-7) ($(field markedAt)), head $(echo "$head" | cut -c1-7)"
echo
python3 -c "import json,sys; [print(str(w['phase'])+'\t'+w['theme']+'\t'+' '.join(w['paths'])+'\t'+' '.join(w['ours'])) for w in json.load(open(sys.argv[1]))['watch']]" "$manifest" \
| while IFS="$(printf '\t')" read -r phase theme paths ours; do
    # shellcheck disable=SC2086
    n=$(git --git-dir "$cache" rev-list --count "$mark..$head" -- $paths)
    [ "$n" = 0 ] && continue
    echo "## Phase $phase — $theme ($n commits)"
    echo "Ours: $ours"
    echo
    # shellcheck disable=SC2086
    git --git-dir "$cache" log --format='- %h %ad %s' --date=short "$mark..$head" -- $paths | head -40
    echo
    # shellcheck disable=SC2086
    git --git-dir "$cache" diff --stat=110 "$mark" "$head" -- $paths | tail -25 | sed 's/^/    /'
    echo
done
