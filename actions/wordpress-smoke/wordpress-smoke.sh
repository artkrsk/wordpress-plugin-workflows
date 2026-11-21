#!/bin/bash
# Smoke run of the plugin in the wp-env the job already started (plugin-check-action's, where the plugin
# and the plugins it requires are active): the front end, the dashboard, the Plugins screen and, with
# Elementor, the editor of a new page must answer 200, and debug.log may hold no PHP error that names a
# file of the plugin. Proves that the plugin loads and renders on that WordPress, not that every feature
# works.
#
# Env: SLUG. Run from the directory wp-env was started in.
set -euo pipefail

SLUG=${SLUG:?}
site="http://localhost:$(jq -r '.port' .wp-env.json)"
jar=$(mktemp)
body=$(mktemp)

# debug.log starts empty and collects everything from here on; stdout carries only the new page's ID
# shellcheck disable=SC2016 # $0 belongs to the shell inside the container
page=$(wp-env run cli -- bash -c '
  set -e
  wp config set WP_DEBUG true --raw >&2
  wp config set WP_DEBUG_LOG true --raw >&2
  wp config set WP_DEBUG_DISPLAY false --raw >&2
  rm -f wp-content/debug.log
  wp plugin is-active "$0" >&2
  wp post create --post_type=page --post_status=publish --post_title="Smoke run" --porcelain
' "$SLUG" | tr -dc '0-9')
version=$(wp-env run cli -- wp core version 2>/dev/null | tr -d '[:space:]')

curl -fsS -o /dev/null -c "$jar" --data-urlencode 'log=admin' --data-urlencode 'pwd=password' "$site/wp-login.php"

failed=0
# A request that ends on the login screen was not made as the admin, whatever its status
request() {
  local label=$1 url=$2 result status final
  result=$(curl -sS -L -b "$jar" -o "$body" -w '%{http_code} %{url_effective}' "$url") || result="000 $url"
  status=${result%% *}
  final=${result#* }
  if [[ $status == 200 && $final != *wp-login.php* ]]; then
    echo "ok   $label ($status)"
  else
    echo "::error::$label answered $status at $final"
    failed=1
  fi
}

request 'Front end' "$site/?page_id=$page"
request 'Dashboard' "$site/wp-admin/index.php"
request 'Plugins screen' "$site/wp-admin/plugins.php"
if wp-env run cli -- wp plugin is-active elementor 2>/dev/null; then
  request 'Elementor editor' "$site/wp-admin/post.php?post=$page&action=elementor"
fi

log=$(wp-env run cli -- bash -c 'cat wp-content/debug.log 2>/dev/null || true' 2>/dev/null)
echo '::group::debug.log'
echo "$log"
echo '::endgroup::'
own=$(grep -E 'PHP (Fatal error|Parse error|Warning|Notice|Deprecated)' <<<"$log" | grep -F "/plugins/$SLUG/" | sed -E 's/^\[[^]]*\] //' | sort -u || true)
if [[ -n $own ]]; then
  echo "::error::PHP errors from $SLUG on WordPress $version:"
  echo "$own"
  failed=1
fi

if [[ $failed == 0 ]]; then
  echo "Smoke run on WordPress $version: every screen answered 200 and debug.log names no file of the plugin." | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi
exit "$failed"
