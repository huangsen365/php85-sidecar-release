#!/usr/bin/env bash
# Prepares a site's switch without touching anything live. Into staging/<site>/ it writes the site's vhost with the
# include line added (scripts/vhost-add-include.sh) and this host's php85-<site>.inc (scripts/site-inc.sh), keeps the
# vhost as it is now in backup/ (first run only), and prints the difference.
# Next: scripts/vhost-test.sh <site> on every server that reads this vhost, then scripts/vhost-apply.sh <site>.
# usage: scripts/vhost-stage.sh <site>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
site=${1:-}; check_site "$site"
php74_pool "$site"
site_vhost
b=$(basename "$VHOST")
S=$WORK/staging/$site
mkdir -p "$S" "$WORK/backup"
[[ -e $WORK/backup/$b ]] || cp -p "$VHOST" "$WORK/backup/$b"
"$ROOT/scripts/vhost-add-include.sh" "$VHOST" "$site" > "$S/$b" || { rm -f "$S/$b"; die "cannot add the include line to $VHOST (see above)"; }
"$ROOT/scripts/site-inc.sh" "$VHOST" > "$S/php85-$site.inc" || { rm -f "$S/php85-$site.inc"; die "cannot write the .inc for $VHOST (see above)"; }
cp -p "$VHOST" "$S/$b.live"
echo "$b" > "$S/vhost.name"
echo "site $site: php74 pool on $PORT74, vhost $VHOST"
echo "== the vhost with the include line (staged, not live):"
diff -U2 "$VHOST" "$S/$b" || true
echo "== this host's .inc (staged, not live): $(grep -v '^#' "$S/php85-$site.inc")"
echo "== kept: $WORK/backup/$b (the vhost before this tool touched it)"
echo "RESULT: OK"
