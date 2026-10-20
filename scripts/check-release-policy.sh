#!/bin/bash
set -euo pipefail
: "${GITHUB_REPOSITORY:?Required GITHUB_REPOSITORY}"
# Local operator preflight: requires Administration(read), unavailable to GITHUB_TOKEN.
# Run with the repository administrator's gh authentication before pushing a release tag.
test "$(gh api "repos/$GITHUB_REPOSITORY/immutable-releases" --jq .enabled)" = true || {
  echo 'Enable immutable releases in repository settings before publishing' >&2; exit 1
}
