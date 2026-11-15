#!/usr/bin/env bash
# Read-only. Where a site's PHP runs on this host and how its 8.5 pool is doing: whether the old container has the
# site's .inc, the pool's status (accepted conn grows when requests reach 8.5) and the end of its error log.
# usage: scripts/site-status.sh <site>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
site=${1:-}; check_site "$site"
need_old; need_sidecar
if ox test -e "/etc/httpd/conf.d/php85-$site.inc"; then echo "$(hostname): $site is switched to PHP 8.5 on this host"
else echo "$(hostname): $site is on php74 on this host (no php85-$site.inc in $OLD)"; fi
pool=$(grep -lF "[$site-php85]" "$POOL_DIR"/*.conf 2> /dev/null | head -1)
[[ -n $pool ]] || die "no 8.5 pool [$site-php85] in $POOL_DIR"
port=$(sed -nE 's/^\s*listen\s*=\s*(85[0-9]{2})\s*$/\1/p' "$pool" | head -1)
st=$(docker exec -e REQUEST_METHOD=GET -e SCRIPT_NAME=/fpm-status -e SCRIPT_FILENAME=/fpm-status "$SC" \
    cgi-fcgi -bind -connect "127.0.0.1:$port" < /dev/null 2>&1 | grep -E '^(pool|start since|accepted conn|listen queue|active processes|max children reached|slow requests):')
[[ -n $st ]] || die "the pool on port $port does not answer its status page (is it loaded? scripts/pool-add.sh $site)"
sed 's/^/    /' <<< "$st"
echo "    (accepted conn counts this query too, and each smoke test and switch: it rises by 1 per check even with no"
echo "     visitor. Requests reach 8.5 when it rises by more than your own checks.)"
log=$LOG_DIR/$site-error.log
if [[ -s $log ]]; then echo "== last lines of $log"; tail -n 10 "$log" | cut -c1-300
else echo "== $log: empty or not there (no PHP errors logged)"; fi
echo "RESULT: OK"
