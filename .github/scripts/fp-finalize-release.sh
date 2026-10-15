#!/usr/bin/env bash
# FashionPoint: the last job of fp-release.yml. Names the release's files FPRemote-Clinic-* / FPRemote-Staff-*,
# attaches the clinic install scripts and keeps the release a draft with its tag. The run's artifacts are deleted
# only after a successful build (anyone can download a public repo's artifacts): after a failed build they stay,
# because "Re-run failed jobs" rebuilds only what failed, and those jobs restore artifacts of the earlier attempt
# (bridge-artifact). The re-run ends with this script again, so it can run more than once for one release: a file
# uploaded again replaces the one renamed before.
# Environment: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_SHA, RELEASE_TAG, EDITION (clinic or staff),
# BUILD_RESULT (needs.build.result).
set -euo pipefail

title=$([ "$EDITION" = staff ] && echo Staff || echo Clinic)
release=$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
  --jq "map(select(.tag_name == \"$RELEASE_TAG\")) | first | .id // empty")
if [ -z "$release" ]; then
  echo "No release $RELEASE_TAG: the build uploaded nothing." >&2
  exit 1
fi

assets=$(gh api "repos/$GITHUB_REPOSITORY/releases/$release/assets?per_page=100" --jq '.[] | "\(.id) \(.name)"')
while read -r id name; do
  case "$name" in
    rustdesk*) ;;
    *) continue ;;
  esac
  target="FPRemote-$title${name#rustdesk}"
  earlier=$(awk -v target="$target" '$2 == target { print $1 }' <<<"$assets")
  if [ -n "$earlier" ]; then
    gh api -X DELETE "repos/$GITHUB_REPOSITORY/releases/assets/$earlier"
    echo "replaced the earlier $target"
  fi
  gh api -X PATCH "repos/$GITHUB_REPOSITORY/releases/assets/$id" -f name="$target" --jq .name
done <<<"$assets"

if [ "$EDITION" = clinic ]; then
  # Windows (.ps1) and macOS (.sh) install and uninstall scripts.
  gh release upload "$RELEASE_TAG" res/fashionpoint/clinic/*.ps1 res/fashionpoint/clinic/*.sh --clobber -R "$GITHUB_REPOSITORY"
fi

# tag_name too: a draft edited without it loses its tag (it becomes untagged-<hash>, seen 14.10.2026).
gh api -X PATCH "repos/$GITHUB_REPOSITORY/releases/$release" -F draft=true -f tag_name="$RELEASE_TAG" \
  -f name="FPRemote $title $RELEASE_TAG" \
  -f body="FPRemote, $EDITION edition, built from $GITHUB_SHA (run $GITHUB_RUN_ID). Build result: $BUILD_RESULT." \
  --jq '"draft=\(.draft) name=\(.name)"'

if [ "$BUILD_RESULT" = success ]; then
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?per_page=100" --paginate \
    --jq '.artifacts[] | "\(.id) \(.name)"' |
    while read -r id name; do
      gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/artifacts/$id" && echo "deleted the artifact $name"
    done
else
  echo "Build result $BUILD_RESULT: the run's artifacts stay for \"Re-run failed jobs\" (docs: fp-remote client.md)."
  echo "If this run is abandoned instead, delete its artifacts by hand."
fi
