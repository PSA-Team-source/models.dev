#!/usr/bin/env bash
# publish.sh <dir>: run from a checkout of dev. <dir> is one provider's sync artifact. Puts its patch on
# automation/sync-models-<provider> as one commit on dev, opens or updates the pull request into dev and enables
# auto-merge when the sync is safe. Uses git, gh and jq only; never runs repository code.
set -euo pipefail

: "${GH_REPO:?}" "${BOT_NAME:?}" "${BOT_EMAIL:?}"
dir=$1
git=(git -c core.hooksPath=/dev/null -c "user.name=$BOT_NAME" -c "user.email=$BOT_EMAIL")

provider=$(<"$dir/provider")
name=$(<"$dir/name")
safe=$(<"$dir/safe")
[[ $provider =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "::error::invalid provider: $provider" >&2; exit 1; }
[[ $name =~ ^[^[:cntrl:]]{1,100}$ ]] || { echo "::error::invalid name for $provider" >&2; exit 1; }
[[ $safe =~ ^(true|false)$ ]] || { echo "::error::invalid safe flag for $provider" >&2; exit 1; }

branch="automation/sync-models-$provider"
title="chore(sync): update $name model catalog"
labels=(automation model-sync "provider:$provider")

"${git[@]}" fetch -q --no-tags --depth=1 origin "+refs/heads/dev:refs/remotes/origin/dev"
# Providers publish one after another from the same checkout; drop anything a failed one left behind.
"${git[@]}" checkout -q -f -B "$branch" origin/dev
"${git[@]}" clean -q -fdx
"${git[@]}" apply --index --binary "$dir/changes.patch" || { echo "::error::$provider patch no longer applies to dev" >&2; exit 1; }

# Without rename detection, a rename shows up as a deletion of its source plus an addition, so both are checked.
changed=$(git diff --cached --raw --no-renames)
[ -n "$changed" ] || { echo "::error::$provider patch is empty" >&2; exit 1; }
while IFS=$'\t' read -r meta path; do
  read -r old_mode new_mode _ <<< "${meta#:}"
  [[ $old_mode =~ ^(000000|100644)$ && $new_mode =~ ^(000000|100644)$ ]] || { echo "::error::$provider sync may change only regular files: $path" >&2; exit 1; }
  [[ $path =~ ^(models|providers)/.+\.toml$ ]] || { echo "::error::$provider sync may change only catalog TOML: $path" >&2; exit 1; }
done <<< "$changed"

"${git[@]}" commit -q --no-verify -m "$title"

# Only a same-repository pull request is the bot's; a fork can use the same branch name.
find_pr() {
  gh pr list --repo "$GH_REPO" --base dev --head "$branch" --state open --json number,isCrossRepository \
    --jq 'map(select(.isCrossRepository | not)) | .[0].number // empty'
}
pr=$(find_pr)

if [ "$safe" != true ] && [ -n "$pr" ]; then
  gh pr merge "$pr" --repo "$GH_REPO" --disable-auto || true
  if [ "$(gh pr view "$pr" --repo "$GH_REPO" --json autoMergeRequest --jq '.autoMergeRequest == null')" != true ]; then
    echo "::error::failed to disable auto-merge for unsafe sync pull request #$pr" >&2
    exit 1
  fi
fi

"${git[@]}" push -q --no-verify --force origin "HEAD:refs/heads/$branch"

for label in "${labels[@]}"; do
  gh label create "$label" --repo "$GH_REPO" --color "0E8A16" --description "Automated model catalog sync" >/dev/null 2>&1 || true
done
label_list=$(IFS=,; echo "${labels[*]}")

if [ -n "$pr" ]; then
  gh pr edit "$pr" --repo "$GH_REPO" --title "$title" --body-file "$dir/report.md" --add-label "$label_list"
else
  gh pr create --repo "$GH_REPO" --base dev --head "$branch" --title "$title" --body-file "$dir/report.md" --label "$label_list"
  pr=$(find_pr)
fi

if [ "$safe" = true ]; then
  gh pr merge "$pr" --repo "$GH_REPO" --auto --squash
elif [ "$(gh pr view "$pr" --repo "$GH_REPO" --json autoMergeRequest --jq '.autoMergeRequest == null')" != true ]; then
  echo "::error::unsafe sync pull request #$pr still has auto-merge enabled" >&2
  exit 1
fi

echo "$provider: #$pr (safe=$safe)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
