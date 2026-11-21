#!/bin/bash
# For a pull request that changes the plugin's "Tested up to" (composer.json, the `wordpress` block): writes
# .wp-env.override.json so the job's wp-env runs the newest build of the declared WordPress version, and
# prints version=<that build> on stdout. Any other event or pull request prints and writes nothing.
#
# Env: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_EVENT_NAME, GITHUB_EVENT_PATH. Run from the repository root.
set -euo pipefail

[[ ${GITHUB_EVENT_NAME:-} == pull_request ]] || exit 0

tested_up_to() {
  jq -r '.wordpress["Tested up to"] // empty'
}

base_sha=$(jq -r '.pull_request.base.sha' "$GITHUB_EVENT_PATH")
head=$(tested_up_to <composer.json)
base=$(gh api -H 'Accept: application/vnd.github.raw' "repos/$GITHUB_REPOSITORY/contents/composer.json?ref=$base_sha" | tested_up_to)
if [[ -z $head || $head == "$base" ]]; then
  exit 0
fi

versions=$(BRANCH=$head bash "$(dirname "$0")/../wordpress-version/wordpress-version.sh")
build=$(sed -n 's/^build=//p' <<<"$versions")
zip=$(sed -n 's/^zip=//p' <<<"$versions")
if [[ -z $build ]]; then
  echo "::error::composer.json declares \"Tested up to\": \"$head\", and wordpress.org offers no $head build" >&2
  exit 1
fi

jq -n --arg core "$zip" '{core: $core}' >.wp-env.override.json
echo "::notice::\"Tested up to\" moves from ${base:-nothing} to $head: this job runs on WordPress $build" >&2
echo "version=$build"
