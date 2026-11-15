#!/usr/bin/env bash
# Undoes scripts/pool-add.sh for a site on this host: moves the site's 8.5 pool file into backup/, reloads the
# sidecar gracefully and runs tests/smoke.sh. It refuses while the site is switched to 8.5 on this host.
# With POOL_DIR on shared storage the file is gone for every server at once: make sure no server has the site on
# 8.5, then run this on each of them (where the file is gone already it only reloads that sidecar).
# usage: scripts/pool-remove.sh <site>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
site=${1:-}; check_site "$site"
need_sidecar
if [[ -n $OLD ]] && ox test -e "/etc/httpd/conf.d/php85-$site.inc" 2> /dev/null; then
    die "$site is switched to 8.5 on this host; scripts/site-switch.sh off $site first"
fi
pool=$(grep -lF "[$site-php85]" "$POOL_DIR"/*.conf 2> /dev/null | head -1)
if [[ -n $pool ]]; then
    mkdir -p "$WORK/backup"
    mv "$pool" "$WORK/backup/$(basename "$pool").removed" || die "cannot move $pool"
    echo "pool file moved to $WORK/backup/$(basename "$pool").removed"
else
    echo "no pool file for [$site-php85] in $POOL_DIR; reloading the sidecar so that it drops the pool"
fi
docker kill -s USR2 "$SC" > /dev/null || die "cannot signal $SC"
sleep 3
smoke=$(CONTAINER=$SC BIND_IP=$BIND_IP "$ROOT/tests/smoke.sh" 2>&1); rc=$?
sed 's/^/    smoke: /' <<< "$smoke"
[[ $rc == 0 ]] || die "tests/smoke.sh failed after the reload"
grep -q "pool $site-php85 via" <<< "$smoke" && die "the sidecar still has the pool $site-php85"
echo "RESULT: OK"
