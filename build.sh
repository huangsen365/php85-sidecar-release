#!/usr/bin/env bash
# Builds the image and tags it php85-sidecar:<php version>-<yyyymmdd>.
# --fresh  builds without the layer cache, so the image gets the newest packages (use it for a release).
# --save   also writes dist/<tag>.tar.gz (+ .sha256) for servers that cannot pull from a registry.
# REGISTRY_IMAGE=<registry>/<owner>/php85-sidecar adds that name with the same tag (and to the tarball), so that a
# loaded tarball and a pulled image carry the same name.
# SOURCE_URL=<repository url> is recorded in the image (org.opencontainers.image.source); a registry such as ghcr.io
# links the image to that repository.
set -euo pipefail
cd "$(dirname "$0")"
fresh=() save=0
for a in "$@"; do
    case $a in
        --fresh) fresh=(--no-cache) ;;
        --save) save=1 ;;
        *) echo "usage: [REGISTRY_IMAGE=...] [SOURCE_URL=...] $0 [--fresh] [--save]" >&2; exit 2 ;;
    esac
done

labels=(--label org.opencontainers.image.title=php85-sidecar --label org.opencontainers.image.licenses=Apache-2.0
        --label "org.opencontainers.image.description=PHP 8.5 php-fpm sidecar for hosts whose main container is CentOS 7 with Remi php74")
[[ -z ${SOURCE_URL:-} ]] || labels+=(--label "org.opencontainers.image.source=$SOURCE_URL")
docker build --pull ${fresh[@]+"${fresh[@]}"} "${labels[@]}" -t php85-sidecar:build .
ver=$(docker run --rm php85-sidecar:build php -r 'echo PHP_VERSION;')
tag=${ver}-$(date +%Y%m%d)
names=("php85-sidecar:$tag")
docker tag php85-sidecar:build "php85-sidecar:$tag"
if [[ -n ${REGISTRY_IMAGE:-} ]]; then
    docker tag php85-sidecar:build "$REGISTRY_IMAGE:$tag"
    names+=("$REGISTRY_IMAGE:$tag")
fi
docker rmi php85-sidecar:build >/dev/null
echo "IMAGE=${names[*]}"

if [[ $save == 1 ]]; then
    mkdir -p dist
    out=dist/php85-sidecar_$tag.tar.gz
    docker save "${names[@]}" | gzip > "$out"
    (cd dist && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
    ls -lh "$out"
fi
