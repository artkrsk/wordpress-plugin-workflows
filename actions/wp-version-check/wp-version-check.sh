#!/bin/bash
# Compares the plugin readme's "Tested up to" with the current WordPress versions and keeps one `wpvc` issue
# in step: opened (or retitled) while the plugin is behind, commented on and closed once it catches up. The
# same rules, titles and texts as skaut/wordpress-version-checker v2.2.3, which this replaces without a Node
# runtime.
#
# Env: GH_TOKEN, GITHUB_REPOSITORY, README (path in the repository, read from the default branch), CHANNEL
# (stable | rc | beta), ASSIGNEES (comma- or space-separated logins, applied to a new issue only).
# Testing: DRY_RUN=1 prints what would change and writes nothing; README_FILE reads a local file instead.
set -euo pipefail

REPO=${GITHUB_REPOSITORY:?}
CHANNEL=${CHANNEL:-rc}
LABEL=wpvc

case $CHANNEL in
  stable | rc | beta) ;;
  *) echo "::error::channel must be stable, rc or beta, not '$CHANNEL'" >&2; exit 1 ;;
esac

# major.minor, as the checker compares: 7.1.4 → 7.1, 7.2-beta5 → 7.2
major_minor() {
  local base=${1%%-*}
  IFS=. read -r major minor _ <<<"$base"
  echo "${major}${minor:+.$minor}"
}

# Whether version $1 is lower than $2
older() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]
}

if [[ -n ${README_FILE:-} ]]; then
  readme=$(cat "$README_FILE")
else
  readme=$(gh api -H 'Accept: application/vnd.github.raw' "repos/$REPO/contents/${README:?}")
fi

tested=$(printf '%s\n' "$readme" | tr -d '\r' | sed -nE 's/^[[:space:]]*Tested up to:[[:space:]]*([.0-9]+)[[:space:]]*$/\1/p' | head -n 1)
if [[ -z $tested ]]; then
  echo "::error::No \"Tested up to\" line in ${README_FILE:-$README}" >&2
  exit 1
fi

offers=$(curl -fsS --retry 3 'https://api.wordpress.org/core/version-check/1.7/?channel=beta')
stable=$(jq -r '[.offers[] | select(.response == "upgrade")][0].current // empty' <<<"$offers")
development=$(jq -r '[.offers[] | select(.response == "development")][0].current // empty' <<<"$offers")
if [[ -z $stable ]]; then
  echo "::error::wordpress.org named no stable version" >&2
  exit 1
fi

stable=$(major_minor "$stable")
rc='' beta=''
if [[ $development == *-RC* ]]; then
  rc=$(major_minor "$development")
fi
if [[ $development == *-beta* || $development == *-RC* ]]; then
  beta=$(major_minor "$development")
fi
echo "Tested up to $tested; WordPress stable $stable${rc:+, RC $rc}${beta:+, beta $beta} (channel $CHANNEL)"

# shellcheck disable=SC2016 # Markdown backticks, not an expansion
fix='Please test it and then raise "Tested up to" in composer.json (the `wordpress` block), which the release writes into the plugin readme.'
title='' body=''
if older "$tested" "$stable"; then
  title="The plugin hasn't been tested with the latest version of WordPress"
  intro="There is a new WordPress version that the plugin hasn't been tested with. $fix"
  version_line="**Latest version:** $stable"
elif [[ $CHANNEL != stable && -n $rc ]] && older "$tested" "$rc"; then
  title="The plugin hasn't been tested with an upcoming version of WordPress"
  intro="There is an upcoming WordPress version in the **release candidate** stage that the plugin hasn't been tested with. $fix"
  version_line="**Upcoming version:** $rc"
elif [[ $CHANNEL == beta && -n $beta ]] && older "$tested" "$beta"; then
  title="The plugin hasn't been tested with a beta version of WordPress"
  intro="There is an upcoming WordPress version in the **beta** stage that the plugin hasn't been tested with."
  version_line="**Beta version:** $beta"
fi
if [[ -n $title ]]; then
  body="$intro

**Tested up to:** $tested
$version_line

This issue will be closed automatically when the versions match."
fi

# The newest open issue this check opened
issue=$(gh api "repos/$REPO/issues?state=open&labels=$LABEL&creator=github-actions%5Bbot%5D&per_page=1" --jq '.[0] | select(. != null) | .number')

run() {
  if [[ -n ${DRY_RUN:-} ]]; then
    echo "[dry-run] gh $*"
  else
    gh "$@" >/dev/null
  fi
}

if [[ -z $title ]]; then
  echo "Up to date."
  if [[ -n $issue ]]; then
    run api "repos/$REPO/issues/$issue/comments" -f body='The "Tested up to" version in the readme matches the latest version now, closing this issue.'
    run api -X PATCH "repos/$REPO/issues/$issue" -f state=closed -f state_reason=completed
    echo "Closed #$issue."
  fi
  exit 0
fi

echo "Outdated: $title"
if [[ -n $issue ]]; then
  current=$(gh api "repos/$REPO/issues/$issue" --jq '[.title, .body] | @json')
  if [[ $current != "$(jq -cnr --arg t "$title" --arg b "$body" '[$t, $b] | @json')" ]]; then
    run api -X PATCH "repos/$REPO/issues/$issue" -f title="$title" -f body="$body"
    echo "Updated #$issue."
  else
    echo "#$issue already says so."
  fi
  exit 0
fi

args=(api "repos/$REPO/issues" -f title="$title" -f body="$body" -f "labels[]=$LABEL")
for login in ${ASSIGNEES//,/ }; do
  args+=(-f "assignees[]=$login")
done
run "${args[@]}"
if [[ -n ${DRY_RUN:-} ]]; then
  printf '[dry-run] issue body:\n%s\n' "$body"
fi
echo "Opened an issue."
