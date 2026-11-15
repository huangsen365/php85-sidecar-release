# Sourced by the scripts that work on a host where the sidecar is deployed. Reads .env (ENV_FILE to use another one)
# and names the two containers. SIDECAR_WORK moves staging/ and backup/ out of the project directory.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${ENV_FILE:-$ROOT/.env}
die() { echo "$*" >&2; echo "RESULT: FAILED"; exit 1; }
[[ -f $ENV_FILE ]] || die "no $ENV_FILE; write it first: IMAGE=<image tag> scripts/preflight.sh --env > .env"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
SC=${CONTAINER:-${CONTAINER_NAME:-php85-sidecar}}
OLD=${OLD_CONTAINER:-}
WORK=${SIDECAR_WORK:-$ROOT}
BIND_IP=${BIND_IP:-172.17.0.1}
export BIND_IP

need_old() {
    [[ -n $OLD ]] || die "OLD_CONTAINER is not set in $ENV_FILE (the old container's name; scripts/preflight.sh prints it)"
    docker exec "$OLD" true < /dev/null 2> /dev/null || die "the old container $OLD is not running on this host"
}
need_sidecar() {
    [[ $(docker inspect -f '{{.State.Running}}' "$SC" 2> /dev/null) == true ]] || die "the sidecar container $SC is not running on this host"
}
ox() { docker exec "$OLD" "$@" < /dev/null; }
check_site() { [[ ${1:-} =~ ^[A-Za-z0-9.-]+$ ]] || die "bad or missing site name: '${1:-}' (the php74 pool is named [<site>-php74])"; }

# Sets POOL74 (the site's php74 pool file on this host; a copy under staging/ when the pools are inside the old
# container) and PORT74 (74NN). The pool is found by its name, [<site>-php74], whatever the file is called.
php74_pool() {
    local site=$1 found n
    if [[ -n ${PHP74_POOL_DIR:-} && -d $PHP74_POOL_DIR ]]; then
        found=$(grep -lF "[$site-php74]" "$PHP74_POOL_DIR"/*.conf 2> /dev/null || true)
        n=$(grep -c . <<< "$found" || true)
        [[ $n == 1 ]] || die "expected one php74 pool file with [$site-php74] in $PHP74_POOL_DIR, found $n: $(echo $found)"
        POOL74=$found
    else
        need_old
        found=$(ox sh -c "grep -lF '[$site-php74]' /etc/opt/remi/php74/php-fpm2.d/*.conf /etc/opt/remi/php74/php-fpm.d/*.conf 2>/dev/null" || true)
        n=$(grep -c . <<< "$found" || true)
        [[ $n == 1 ]] || die "expected one php74 pool file with [$site-php74] in $OLD, found $n: $(echo $found)"
        mkdir -p "$WORK/staging/$site"
        POOL74=$WORK/staging/$site/$(basename "$found")
        ox cat "$found" > "$POOL74"
    fi
    PORT74=$(sed -nE 's/^\s*listen\s*=\s*(127\.0\.0\.1:)?(74(0[1-9]|1[0-9]))\s*$/\2/p' "$POOL74" | head -1)
    [[ -n $PORT74 ]] || die "$POOL74: no 'listen = 127.0.0.1:7401' to 7419 line; this pool cannot move as it is"
}

# Sets VHOST (the one vhost file on this host that sends PHP to the site's php74 pool, 127.0.0.1:$PORT74).
site_vhost() {
    local found n
    [[ -n ${VHOST_DIR:-} && -d $VHOST_DIR ]] || die "VHOST_DIR is not set in $ENV_FILE: the vhosts are inside the old container, which these scripts do not handle (README: 适用环境)"
    found=$(grep -lE "^\s*ProxyPassMatch\s+\"?\^/\(\.\*\\\\\.php.*fcgi://127\.0\.0\.1:$PORT74/" "$VHOST_DIR"/*.conf 2> /dev/null || true)
    n=$(grep -c . <<< "$found" || true)
    [[ $n == 1 ]] || die "expected one vhost file in $VHOST_DIR that sends PHP to 127.0.0.1:$PORT74, found $n: $(echo $found)"
    VHOST=$found
}

# Replaces a live vhost by <src> in one rename, keeping the live file's owner and mode.
vhost_put() {
    local src=$1 live=$2 tmp
    tmp=$(dirname "$live")/.$(basename "$live").php85tmp
    cp -p "$live" "$tmp" && cat "$src" > "$tmp" && mv -f "$tmp" "$live" || { rm -f "$tmp"; return 1; }
}

# httpd in the old container: syntax check, and a graceful reload the way that container runs it.
httpd_test() { ox httpd -t 2>&1 | grep -v AH00558; ox httpd -t > /dev/null 2>&1; }
httpd_reload() {
    if ox sh -c 'test -d /run/systemd/system && systemctl is-active -q httpd' 2> /dev/null; then ox systemctl reload httpd
    else ox httpd -k graceful; fi
    sleep 2
    ox sh -c 'p=$(cat /run/httpd/httpd.pid 2> /dev/null) && kill -0 "$p" 2> /dev/null || pgrep -x httpd > /dev/null 2>&1' \
        || die "httpd is not running in $OLD after the reload"
}
