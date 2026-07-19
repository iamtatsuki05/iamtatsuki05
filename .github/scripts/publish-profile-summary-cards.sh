#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <source-directory> <publish-branch> <remote>" >&2
  exit 64
fi

invocation_directory=$(pwd -P)
source_directory=$1
publish_branch=$2
remote=$3

if [[ "$source_directory" != /* ]]; then
  source_directory="${invocation_directory}/${source_directory}"
fi

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(git -C "$script_directory" rev-parse --show-toplevel)
cd "$repository_root"

git check-ref-format --branch "$publish_branch" >/dev/null

expected_files=(
  "radical/0-profile-details.svg"
  "radical/1-repos-per-language.svg"
  "radical/2-most-commit-language.svg"
  "radical/3-stats.svg"
  "radical/4-productive-time.svg"
)

for relative_path in "${expected_files[@]}"; do
  source_path="${source_directory}/${relative_path}"

  if [[ ! -s "$source_path" ]]; then
    echo "Missing or empty profile summary card: ${source_path}" >&2
    exit 1
  fi

  if grep -Eqi 'ERROR!!!|temporarily rate limited' "$source_path"; then
    echo "Profile summary card contains an upstream error: ${source_path}" >&2
    exit 1
  fi

  if ! python3 - "$source_path" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except (OSError, ET.ParseError) as error:
    raise SystemExit(error)

if root.tag != "{http://www.w3.org/2000/svg}svg":
    raise SystemExit(f"unexpected root element: {root.tag}")
PY
  then
    echo "Invalid profile summary card: ${source_path}" >&2
    exit 1
  fi
done

source_directory=$(cd "$source_directory" && pwd -P)
publish_worktree=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/profile-summary-cards.XXXXXX")
worktree_registered=false

cleanup() {
  if [[ "$worktree_registered" = true ]]; then
    git worktree remove --force "$publish_worktree" >/dev/null 2>&1 || true
  else
    rmdir "$publish_worktree" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

git worktree add --detach --no-checkout "$publish_worktree" HEAD
worktree_registered=true
git -C "$publish_worktree" read-tree --empty

destination="${publish_worktree}/profile-summary-card-output/radical"
mkdir -p "$destination"

for relative_path in "${expected_files[@]}"; do
  cp "${source_directory}/${relative_path}" "$destination/"
done

git -C "$publish_worktree" add profile-summary-card-output
snapshot_tree=$(git -C "$publish_worktree" write-tree)

# A single orphan commit keeps generated snapshots out of the repository's growing history.
snapshot_commit=$(
  printf '%s\n' "Update profile summary cards" |
    GIT_AUTHOR_NAME="github-actions[bot]" \
      GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com" \
      GIT_COMMITTER_NAME="github-actions[bot]" \
      GIT_COMMITTER_EMAIL="41898282+github-actions[bot]@users.noreply.github.com" \
      git -C "$publish_worktree" commit-tree "$snapshot_tree"
)
git -C "$publish_worktree" push --force "$remote" "${snapshot_commit}:refs/heads/${publish_branch}"
