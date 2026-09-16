#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

echo "Checking for orphan renovate branches..."
git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"

branches=$(git ls-remote --heads origin | awk '{print $2}' | grep 'refs/heads/renovate/' || true)

if [[ -z "$branches" ]]; then
  echo "No renovate branches found."
  exit 0
fi

for branch in $branches; do
  branch_name=${branch#refs/heads/}
  echo "Checking branch: $branch_name"

  if ! gh pr list --head "$branch_name" --state open --json number --jq '.[].number' | grep -q .; then
    echo "Deleting orphan branch: $branch_name"
    git push origin --delete "$branch_name" || echo "Failed to delete $branch_name (may already be deleted)"
  else
    echo "Branch $branch_name has an open PR, skipping."
  fi
done

echo "Orphan branch cleanup completed."
