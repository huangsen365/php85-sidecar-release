#!/usr/bin/env bash
# Tests a staged vhost in this host's old container, read-only for the live configuration. A copy of httpd.conf that
# reads a temporary copy of the vhost directory, with the staged vhost in it, is checked twice: without the .inc (how
# a server that has not switched reads the vhost) and with it. Then the .inc gets a broken line, which must make the
# check fail: that proves the include line really pulls the .inc in. Run it on EVERY server that reads this vhost
# (shared storage) before scripts/vhost-apply.sh: a vhost with a syntax error stops httpd's next reload on all of them.
# usage: scripts/vhost-test.sh <site>        (after scripts/vhost-stage.sh <site> on this host)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
site=${1:-}; check_site "$site"
need_old
S=$WORK/staging/$site
[[ -s $S/vhost.name && -s $S/php85-$site.inc ]] || die "nothing staged for $site on this host; run scripts/vhost-stage.sh $site first"
b=$(cat "$S/vhost.name")
cdir=/etc/httpd/conf.d
ox test -d /etc/httpd/conf2.d && cdir=/etc/httpd/conf2.d
rel=${cdir#/etc/httpd/}
n=$(ox grep -cE "^[[:space:]]*Include(Optional)?[[:space:]]+$rel/\*\.conf" /etc/httpd/conf/httpd.conf)
[[ $n == 1 ]] || die "httpd.conf in $OLD has $n 'Include $rel/*.conf' lines, expected 1; test this vhost by hand"
T=/tmp/php85-vhost-test.$$
cleanup() { ox rm -rf "$T" 2> /dev/null; }
trap cleanup EXIT
ox sh -c "rm -rf $T && mkdir -p $T/v $T/vi $T/inc && cp -a $cdir/*.conf $T/v/" || die "cannot copy $cdir in $OLD"
{ docker cp "$S/$b" "$OLD:$T/v/$b" && docker cp "$S/php85-$site.inc" "$OLD:$T/inc/php85-$site.inc"; } > /dev/null || die "cannot copy the staged files into $OLD"
ox sh -c "cd $T && cp -a v/*.conf vi/ &&
    sed -E 's#^([[:space:]]*Include(Optional)?[[:space:]]+)$rel/\*\.conf#\1$T/v/*.conf#' /etc/httpd/conf/httpd.conf > httpd.conf &&
    sed -E 's#^([[:space:]]*Include(Optional)?[[:space:]]+)$rel/\*\.conf#\1$T/vi/*.conf#' /etc/httpd/conf/httpd.conf > httpd.inc.conf &&
    sed -i 's#IncludeOptional conf.d/php85-#IncludeOptional $T/inc/php85-#' vi/*.conf" || die "cannot build the test configuration in $OLD"
fails=0
check() {       # <label> <httpd.conf in the container>
    local out
    out=$(ox httpd -t -f "$2" 2>&1 | grep -v AH00558)
    if ox httpd -t -f "$2" > /dev/null 2>&1; then echo "OK    $1: $out"; else echo "FAIL  $1: $out"; fails=$((fails + 1)); fi
}
echo "$(hostname), old container $OLD, $(ox httpd -v | sed -n 's/^Server version: *//p')"
check "without the .inc (a server that has not switched)" "$T/httpd.conf"
check "with the .inc (a server that has switched)" "$T/httpd.inc.conf"
ox sh -c "echo BrokenDirectiveForTest >> $T/inc/php85-$site.inc"
if ox httpd -t -f "$T/httpd.inc.conf" > /dev/null 2>&1; then
    echo "FAIL  the .inc is not included: a broken line in it went unnoticed"; fails=$((fails + 1))
else
    echo "OK    the include line pulls the .inc in (a broken line in it is noticed)"
fi
check "the live configuration, unchanged" /etc/httpd/conf/httpd.conf
[[ $fails -eq 0 ]] && echo "RESULT: OK" || { echo "RESULT: FAILED ($fails)"; exit 1; }
