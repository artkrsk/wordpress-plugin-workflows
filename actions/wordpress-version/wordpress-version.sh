#!/bin/bash
# Names the WordPress versions a plugin's "Tested up to" is measured against, from wordpress.org's version
# check, as key=value lines on stdout:
#   stable  major.minor of the latest stable release (7.1)
#   newest  the major.minor to declare: the release candidate's while one is out (rc channel), else stable
#   build   the newest build of BRANCH (7.2-RC2, 7.1.5); empty when wordpress.org offers none
#   zip     that build's ZIP
#
# Env: CHANNEL (rc | stable, default rc), BRANCH (major.minor, default: newest).
set -euo pipefail

CHANNEL=${CHANNEL:-rc}
case $CHANNEL in
  rc | stable) ;;
  *) echo "::error::channel must be rc or stable, not '$CHANNEL'" >&2; exit 1 ;;
esac

# 7.1.4 → 7.1, 7.2-RC2 → 7.2
major_minor() {
  local base=${1%%-*}
  IFS=. read -r major minor _ <<<"$base"
  echo "${major}${minor:+.$minor}"
}

offers=$(curl -fsS --retry 3 'https://api.wordpress.org/core/version-check/1.7/?channel=beta')
stable=$(jq -r '[.offers[] | select(.response == "upgrade")][0].current // empty' <<<"$offers")
development=$(jq -r '[.offers[] | select(.response == "development")][0].current // empty' <<<"$offers")
if [[ -z $stable ]]; then
  echo "::error::wordpress.org named no stable version" >&2
  exit 1
fi

stable=$(major_minor "$stable")
newest=$stable
if [[ $CHANNEL == rc && $development == *-RC* ]]; then
  newest=$(major_minor "$development")
fi

branch=${BRANCH:-$newest}
build='' zip=''
while IFS=$'\t' read -r current download; do
  if [[ $(major_minor "$current") == "$branch" ]]; then
    build=$current
    zip=$download
    break
  fi
done < <(jq -r '.offers[] | [.current, .download] | @tsv' <<<"$offers")

echo "WordPress stable $stable, to declare $newest; newest $branch build: ${build:-none}" >&2
printf 'stable=%s\nnewest=%s\nbuild=%s\nzip=%s\n' "$stable" "$newest" "$build" "$zip"
