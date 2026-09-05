#!/usr/bin/env bash
# Create (or replace) the toolbox from the built image, then provision $HOME.
#   ./create.sh              -> create if missing
#   ./create.sh --replace    -> delete the existing container first
set -euo pipefail
IMAGE="${IMAGE:-localhost/fedora-sfdx-toolbox:44}"
BOX="${BOX:-sfdx}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f /run/.containerenv ]; then RUN=(flatpak-spawn --host); else RUN=(); fi

replace=0
[ "${1:-}" = "--replace" ] && replace=1

exists=0
"${RUN[@]}" podman container exists "$BOX" 2>/dev/null && exists=1

if [ "$exists" = 1 ] && [ "$replace" = 0 ]; then
  echo "toolbox '$BOX' already exists."
  echo "Re-run with --replace to rebuild it, or set BOX=<name> for a new one."
  echo "Nothing in \$HOME (orgs, extensions, settings) is affected either way."
  exit 1
fi

if [ "$exists" = 1 ]; then
  echo ">> removing old '$BOX' (container only -- \$HOME is untouched)"
  "${RUN[@]}" podman rm -f "$BOX" >/dev/null
fi

echo ">> creating toolbox '$BOX' from $IMAGE"
"${RUN[@]}" toolbox create --image "$IMAGE" "$BOX"

echo ">> provisioning \$HOME inside '$BOX'"
"${RUN[@]}" toolbox run -c "$BOX" bash "$DIR/provision-home.sh"

echo
echo ">> verifying Salesforce orgs still authenticated:"
"${RUN[@]}" toolbox run -c "$BOX" bash -lc \
  'export NVM_DIR=$HOME/.nvm; . $NVM_DIR/nvm.sh >/dev/null 2>&1; sf org list 2>/dev/null | tail -n +2' || true
