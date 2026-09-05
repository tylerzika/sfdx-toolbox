#!/usr/bin/env bash
# Build the image. Safe to re-run; nothing in $HOME is touched.
set -euo pipefail
IMAGE="${IMAGE:-localhost/fedora-sfdx-toolbox:44}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Images live in the host's podman storage, so build on the host.
if [ -f /run/.containerenv ]; then
  RUN=(flatpak-spawn --host)
else
  RUN=()
fi

echo ">> building $IMAGE"
"${RUN[@]}" podman build --pull=newer -t "$IMAGE" -f "$DIR/Containerfile" "$DIR"
echo ">> done: $IMAGE"
