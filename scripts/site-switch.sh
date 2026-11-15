#!/usr/bin/env bash
# Switches one site on THIS host: "on" sends its PHP to the 8.5 pool, "off" sends it back to php74 (the rollback).
# on:  copies the staged php85-<site>.inc into the old container's conf.d, checks httpd -t (and takes the file out
#      again if that fails), then reloads httpd gracefully.
# off: deletes that file, checks httpd -t, reloads httpd gracefully. The vhost's include line may stay.
# Other servers and other sites are not touched. php74's php-fpm is never reloaded.
# usage: scripts/site-switch.sh on|off <site>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
mode=${1:-}; site=${2:-}
case $mode in on | off) ;; *) die "usage: $0 on|off <site>" ;; esac
check_site "$site"
need_old
inc=/etc/httpd/conf.d/php85-$site.inc
if [[ $mode == on ]]; then
    need_sidecar
    S=$WORK/staging/$site
    [[ -s $S/php85-$site.inc && -s $S/vhost.name ]] || die "nothing staged for $site on this host; run scripts/vhost-stage.sh $site first"
    b=$(cat "$S/vhost.name")
    grep -qF "IncludeOptional conf.d/php85-${site}*.inc" "$VHOST_DIR/$b" 2> /dev/null \
        || die "the live vhost $VHOST_DIR/$b has no include line yet; run scripts/vhost-apply.sh $site first"
    port85=$(grep -oE 'fcgi://[^/]+:85[0-9]{2}/' "$S/php85-$site.inc" | grep -oE '85[0-9]{2}/$' | tr -d / | head -1)
    docker exec -e REQUEST_METHOD=GET -e SCRIPT_NAME=/fpm-status -e SCRIPT_FILENAME=/fpm-status "$SC" \
        cgi-fcgi -bind -connect "127.0.0.1:$port85" < /dev/null 2> /dev/null | grep -q "^pool: *$site-php85" \
        || die "the pool $site-php85 does not answer on port $port85 in $SC on this host; run scripts/pool-add.sh $site here first"
    docker cp "$S/php85-$site.inc" "$OLD:$inc" > /dev/null || die "cannot copy the .inc into $OLD"
    ox sh -c "chown root:root $inc && chmod 644 $inc"
    if ! httpd_test; then
        ox rm -f "$inc"
        die "httpd -t fails with the .inc in $OLD; the file was taken out again and httpd was not reloaded"
    fi
else
    ox rm -f "$inc"
    httpd_test || die "httpd -t fails in $OLD after removing the .inc; httpd was not reloaded"
fi
httpd_reload
echo "$(hostname): $site is on $([[ $mode == on ]] && echo "PHP 8.5 (the sidecar)" || echo "php74 (the old container)") after a graceful reload of httpd in $OLD"
on85=$(ox sh -c 'ls /etc/httpd/conf.d/php85-*.inc 2>/dev/null' | sed -E 's#.*/php85-(.*)\.inc#\1#' | tr '\n' ' ')
echo "    sites on 8.5 on this host: ${on85:-(none)}"
echo "RESULT: OK"
