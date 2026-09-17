#!/usr/bin/env bash
# Keep a draft across failed uploads; reruns verify and reuse completed assets.
set -euo pipefail
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_REF_NAME:?}"
: "${GITHUB_SHA:?}"
: "${VERSION:?}"
assets="${1:?asset directory}"
notes="${2:?release notes}"
[[ "$GITHUB_REF_NAME" == "v$VERSION" ]] || { echo "Tag/version mismatch" >&2; exit 1; }
[[ -s "$notes" ]] || { echo "Release notes are empty" >&2; exit 1; }
shopt -s nullglob
files=("$assets"/*)
[[ ${#files[@]} -gt 0 ]] || { echo "No release assets" >&2; exit 1; }

release=$(gh release view "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" \
    --json isDraft,targetCommitish 2>/dev/null || true)
if [[ -z "$release" ]]; then
    args=(--draft --title "Infinitus $VERSION" --notes-file "$notes" --target "$GITHUB_SHA")
    [[ "$VERSION" != *-* ]] || args+=(--prerelease)
    gh release create "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" "${args[@]}"
    published=false
else
    jq -e --arg sha "$GITHUB_SHA" '.targetCommitish == $sha' <<< "$release" >/dev/null || {
        echo "Existing release belongs to a different commit" >&2; exit 1;
    }
    published=$(jq -r '.isDraft | not' <<< "$release")
fi

uploaded() {
    gh release view "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" --json assets |
        jq -e --arg name "$name" --arg digest "sha256:$digest" \
            '.assets | any(.name == $name and .digest == $digest)' >/dev/null
}

for asset in "${files[@]}"; do
    [[ -f "$asset" ]] || { echo "Not a release file: $asset" >&2; exit 1; }
    name="${asset##*/}"
    digest=$(shasum -a 256 "$asset" | cut -d ' ' -f 1)
    if uploaded; then
        echo "Verified existing asset: $name"
        continue
    fi
    [[ "$published" == false ]] || {
        echo "Published release has a missing or different asset: $name" >&2; exit 1;
    }
    for delay in 0 5 15; do
        sleep "$delay"
        # A failed HTTP response can still have saved the asset. Check its
        # digest before retrying; never discard the other completed uploads.
        if uploaded; then break; fi
        timeout 5m gh release upload "$GITHUB_REF_NAME" "$asset" \
            --repo "$GITHUB_REPOSITORY" --clobber || true
        if uploaded; then break; fi
    done
    uploaded || { echo "Upload failed; draft retained for retry: $name" >&2; exit 1; }
done

if [[ "$published" == false ]]; then
    gh release edit "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" --draft=false
fi
echo "Published and verified $GITHUB_REF_NAME."
