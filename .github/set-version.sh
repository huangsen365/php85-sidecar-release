#!/usr/bin/env bash
# Writes an image tag into the files that name one: IMAGE= in .env.example and the example in scripts/deploy.sh.
# usage: .github/set-version.sh <tag>      e.g. 8.5.13-20261122
# The release workflow runs it when it publishes; nothing else in the tree depends on the version.
set -euo pipefail
tag=${1:?usage: $0 <tag>, e.g. 8.5.13-20261122}
[[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]{8}$ ]] || { echo "not an image tag: $tag" >&2; exit 2; }
cd "$(dirname "$0")/.."
sed -i -E "s|^(IMAGE=.*/php85-sidecar):.*\$|\1:$tag|" .env.example
sed -i -E "s|(/php85-sidecar):[0-9]+\.[0-9]+\.[0-9]+-[0-9]{8}|\1:$tag|g" scripts/deploy.sh
grep -q "^IMAGE=.*/php85-sidecar:$tag\$" .env.example || { echo ".env.example has no IMAGE line to set" >&2; exit 1; }
grep -H "php85-sidecar:$tag" .env.example scripts/deploy.sh
