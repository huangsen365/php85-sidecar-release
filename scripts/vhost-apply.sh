#!/usr/bin/env bash
# Puts the staged vhost (with the include line) in place of the live one. The line does nothing on a server that has
# no php85-<site>.inc, so no site changes its PHP version here and httpd is not reloaded. On shared storage every
# server reads the new vhost at its next reload: run scripts/vhost-test.sh <site> on each of them first.
# It refuses when the live vhost changed since scripts/vhost-stage.sh, replaces the file in one rename, checks
# httpd -t in this host's old container and puts the previous vhost back if that fails.
# Undo: scripts/vhost-restore.sh <site>.
# usage: scripts/vhost-apply.sh <site>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
site=${1:-}; check_site "$site"
need_old
S=$WORK/staging/$site
[[ -s $S/vhost.name ]] || die "nothing staged for $site on this host; run scripts/vhost-stage.sh $site first"
b=$(cat "$S/vhost.name")
[[ -n ${VHOST_DIR:-} && -f $VHOST_DIR/$b ]] || die "no $b in VHOST_DIR (${VHOST_DIR:-unset})"
live=$VHOST_DIR/$b
if cmp -s "$live" "$S/$b"; then
    echo "the live vhost already has the include line: $live"
    httpd_test || die "httpd -t fails in $OLD (not caused by this script: nothing was changed)"
    echo "RESULT: OK"; exit 0
fi
cmp -s "$live" "$S/$b.live" || die "$live changed since scripts/vhost-stage.sh $site; run that again and look at the difference"
vhost_put "$S/$b" "$live" || die "cannot write $live"
if ! httpd_test; then
    vhost_put "$S/$b.live" "$live"
    die "httpd -t fails with the new vhost in $OLD; the previous vhost is back in place"
fi
echo "installed: $live ($(grep -c 'IncludeOptional conf.d/php85-' "$live") include line(s)); httpd was not reloaded"
echo "RESULT: OK"
