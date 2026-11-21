#!/bin/bash
# Points the job's wp-env at the newest build of the WordPress version the plugin declares as "Tested up to"
# (composer.json, the `wordpress` block): writes .wp-env.override.json, which beats the core .wp-env.json
# names, and prints version=<that build> on stdout. A release candidate is that build from the day the
# value is raised to it, the latest patch release after that. A composer.json that declares nothing prints
# and writes nothing.
#
# Run from the repository root.
set -euo pipefail

tested=$(jq -r '.wordpress["Tested up to"] // empty' composer.json)
if [[ -z $tested ]]; then
  exit 0
fi

versions=$(BRANCH=$tested bash "$(dirname "$0")/../wordpress-version/wordpress-version.sh")
build=$(sed -n 's/^build=//p' <<<"$versions")
zip=$(sed -n 's/^zip=//p' <<<"$versions")
if [[ -z $build ]]; then
  echo "::error::composer.json declares \"Tested up to\": \"$tested\", and wordpress.org offers no $tested build" >&2
  exit 1
fi

jq -n --arg core "$zip" '{core: $core}' >.wp-env.override.json
echo "::notice::\"Tested up to\" is $tested: this job runs on WordPress $build" >&2
echo "version=$build"
