#!/usr/bin/env bash
# Deploys the sidecar on this host: one new container next to the old one. No site changes its PHP version.
# It runs the preflight and stops if that fails; writes .env from the old container's mounts, unless a .env exists
# (an existing one is used as it is and never overwritten); creates the log and pool directories; starts the
# container; runs tests/smoke.sh; and checks that the old container reaches the sidecar.
# usage: scripts/deploy.sh <image> [old container]
#        e.g. scripts/deploy.sh ghcr.io/huangsen365/php85-sidecar:8.5.13-20261122
# Run it again after changing IMAGE in .env to move to another image (README: 升级镜像).
# Undo: docker compose down, while no site is switched to 8.5 on this host.
set -uo pipefail
cd "$(dirname "$0")/.."
ENV_FILE=${ENV_FILE:-$PWD/.env}
fail() { echo "$*" >&2; echo "RESULT: FAILED"; exit 1; }
image=${1:-} old=${2:-}
[[ -n $image ]] || fail "usage: $0 <image> [old container]"
docker image inspect "$image" > /dev/null 2>&1 \
    || fail "the image $image is not on this host; pull it or load the release tarball first (README: 获取镜像)"
if [[ -e $ENV_FILE ]]; then
    echo "using the existing $ENV_FILE as it is (move it away to have it written again)"
    has=$(sed -n 's/^IMAGE=//p' "$ENV_FILE")
    [[ $has == "$image" ]] || fail "that file says IMAGE=$has, not $image; change IMAGE in it yourself if you mean to change the image"
else
    IMAGE=$image scripts/preflight.sh --env ${old:+"$old"} > "$ENV_FILE.new" \
        || { rm -f "$ENV_FILE.new"; fail "the preflight failed (see above); nothing was changed"; }
    [[ -z ${CONTAINER:-} ]] || echo "CONTAINER_NAME=$CONTAINER" >> "$ENV_FILE.new"
    mv "$ENV_FILE.new" "$ENV_FILE"
    echo "written: $ENV_FILE"
fi
. scripts/lib.sh
need_old
install -d -o 1000 -g 1000 "$LOG_DIR" || fail "cannot create $LOG_DIR"
install -d "$POOL_DIR" || fail "cannot create $POOL_DIR"
[[ -d $PHP74_LIB_DIR ]] || install -d -o 1000 -g 1000 "$PHP74_LIB_DIR" "$PHP74_LIB_DIR/session" || fail "cannot create $PHP74_LIB_DIR"
up=$(docker compose --env-file "$ENV_FILE" up -d 2>&1) || { echo "$up" | tail -5; fail "docker compose up failed"; }
echo "$up" | grep -E 'Started|Running|Recreated' | sed 's/^ */    /'
smoke=$(CONTAINER=$SC BIND_IP=$BIND_IP tests/smoke.sh 2>&1); rc=$?
sed 's/^/    smoke: /' <<< "$smoke"
[[ $rc == 0 ]] || fail "tests/smoke.sh failed; the container $SC is left as it is for you to look at (docker logs $SC)"
ox bash -c "exec 3<>/dev/tcp/$BIND_IP/8500" 2> /dev/null \
    || fail "the old container $OLD cannot reach the sidecar on $BIND_IP:8500 (a firewall, or a network of its own?)"
echo "the old container $OLD reaches the sidecar on $BIND_IP:8500"
echo "the sidecar $SC runs on this host; no site uses it yet"
echo "RESULT: OK"
