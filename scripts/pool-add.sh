#!/usr/bin/env bash
# Gives a site its PHP 8.5 pool on this host: converts the site's php74 pool (scripts/pool-from-php74.sh) into
# POOL_DIR/php-fpm_85NN_<site>.conf, checks the sidecar's configuration with it, reloads the sidecar gracefully and
# runs tests/smoke.sh. No request reaches the pool yet: the site stays on php74 until scripts/site-switch.sh.
# A pool file that exists is kept (POOL_DIR on shared storage: the first server wrote it), then only loaded here.
# Undo: scripts/pool-remove.sh <site>.
# usage: scripts/pool-add.sh <site>          (the php74 pool is [<site>-php74])
set -uo pipefail
. "$(dirname "$0")/lib.sh"
site=${1:-}; check_site "$site"
need_sidecar
php74_pool "$site"
port85=85${PORT74#74}
dst=$POOL_DIR/php-fpm_${port85}_$site.conf
made=0
if [[ -e $dst ]]; then
    echo "pool file exists, kept: $dst"
else
    "$ROOT/scripts/pool-from-php74.sh" "$POOL74" > "$dst.tmp" || { rm -f "$dst.tmp"; die "the php74 pool cannot be converted (see above)"; }
    chmod 644 "$dst.tmp" && mv -f "$dst.tmp" "$dst" && made=1
    echo "pool file written: $dst"
fi
echo "    $(grep -E '^\[|^\s*listen\s*=' "$dst" | tr '\n' ' ')"
if ! t=$(docker exec "$SC" php-fpm -t -y /etc/opt/remi/php85/php-fpm.conf 2>&1 < /dev/null); then
    echo "$t" | tail -3
    [[ $made == 0 ]] || rm -f "$dst"
    die "php-fpm refuses the configuration with this pool; the sidecar was not reloaded$([[ $made == 1 ]] && echo ' and the new file was removed')"
fi
docker kill -s USR2 "$SC" > /dev/null || die "cannot signal $SC"
sleep 3
smoke=$(CONTAINER=$SC BIND_IP=$BIND_IP "$ROOT/tests/smoke.sh" 2>&1); rc=$?
sed 's/^/    smoke: /' <<< "$smoke"
[[ $rc == 0 ]] || die "tests/smoke.sh failed after loading the pool"
grep -q "^OK    pool $site-php85 via" <<< "$smoke" || die "the pool $site-php85 does not answer on $BIND_IP:$port85"
echo "pool $site-php85 answers on $BIND_IP:$port85"
echo "RESULT: OK"
