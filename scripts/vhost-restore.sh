#!/usr/bin/env bash
# Undoes scripts/vhost-apply.sh for a site: puts the vhost kept in backup/ (as it was before this tool touched it)
# back in place, in one rename, checks httpd -t in this host's old container and puts the current vhost back if that
# fails. httpd is not reloaded. It refuses while the site is switched to 8.5 on this host.
# On shared storage the vhost changes for every server: one where the site is still switched goes back to php74 at
# its next httpd reload, so switch the site off everywhere first.
# usage: scripts/vhost-restore.sh <site>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
site=${1:-}; check_site "$site"
need_old
S=$WORK/staging/$site
[[ -s $S/vhost.name ]] || die "nothing staged for $site on this host, so the vhost's file name is not known; the originals are in $WORK/backup/"
b=$(cat "$S/vhost.name")
orig=$WORK/backup/$b
live=${VHOST_DIR:-}/$b
[[ -f $orig && -f $live ]] || die "need both $orig and $live"
ox test -e "/etc/httpd/conf.d/php85-$site.inc" 2> /dev/null && die "$site is switched to 8.5 on this host; scripts/site-switch.sh off $site first"
if cmp -s "$live" "$orig"; then echo "the live vhost is the original already: $live"; echo "RESULT: OK"; exit 0; fi
cp -p "$live" "$S/$b.before-restore"
vhost_put "$orig" "$live" || die "cannot write $live"
if ! httpd_test; then
    vhost_put "$S/$b.before-restore" "$live"
    die "httpd -t fails with the original vhost in $OLD; the vhost from before this command is back in place"
fi
echo "restored: $live is the vhost from $orig; httpd was not reloaded"
echo "RESULT: OK"
