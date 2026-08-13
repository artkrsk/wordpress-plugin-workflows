#!/usr/bin/env bash
#
# Registers a repo-scoped GitHub Actions runner on this host (the Raspberry Pi)
# and installs it as a systemd service. Personal accounts can't share runners
# across repositories, so every new plugin repo needs one of these — this is
# part of the new-plugin bootstrap checklist.
#
#   ./provision-runner.sh <repo> [short-name]
#
#   ./provision-runner.sh my-plugin-for-elementor my-plugin
#     → service actions.runner.artkrsk-my-plugin-for-elementor.raspberrypi-my-plugin
#       in /home/art/actions-runner-my-plugin
#
# Run ON the runner host, as the runner user, with `gh` authenticated.
set -euo pipefail

OWNER="${ARTS_GH_OWNER:-artkrsk}"
RUNNER_USER="${ARTS_RUNNER_USER:-art}"

REPO="${1:-}"
SHORT="${2:-$REPO}"

[ -n "$REPO" ] || {
  echo "usage: $0 <repo> [short-name]" >&2
  exit 2
}
command -v gh >/dev/null || { echo "gh CLI not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated." >&2; exit 1; }

DIR="$HOME/actions-runner-$SHORT"
[ -d "$DIR" ] && { echo "$DIR already exists — is this repo already provisioned?" >&2; exit 1; }

# Latest runner release for linux-arm64
VERSION=$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | tr -d 'v')
echo "Runner version: $VERSION"

mkdir -p "$DIR"
cd "$DIR"
curl -sL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-arm64-${VERSION}.tar.gz"
tar xzf runner.tar.gz
rm runner.tar.gz

# Registration tokens are short-lived (1h) and single-purpose; never logged.
TOKEN=$(gh api -X POST "repos/$OWNER/$REPO/actions/runners/registration-token" --jq '.token')

./config.sh --unattended \
  --url "https://github.com/$OWNER/$REPO" \
  --token "$TOKEN" \
  --name "raspberrypi-$SHORT"

sudo ./svc.sh install "$RUNNER_USER"
sudo ./svc.sh start

echo
echo "Verifying with GitHub…"
gh api "repos/$OWNER/$REPO/actions/runners" --jq '.runners[] | "\(.name): \(.status)"'
