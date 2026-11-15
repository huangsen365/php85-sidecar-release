#!/usr/bin/env bash
# Prints one server's conf.d/php85-<site>.inc: the vhost's PHP ProxyPassMatch line pointed at the 8.5 pool
# (127.0.0.1:74NN -> ${BIND_IP:-172.17.0.1}:85NN). Only a server that has this file sends the site to 8.5 (the vhost
# needs the line from scripts/vhost-add-include.sh). Rollback on that server: delete the file, then graceful.
# usage: scripts/site-inc.sh <conf2.d vhost> > <old container>:/etc/httpd/conf.d/php85-<site>.inc
set -euo pipefail
src=${1:?usage: $0 <conf2.d vhost>}
bind=${BIND_IP:-172.17.0.1}
lines=$(grep -E '^\s*ProxyPassMatch\s+"?\^/\(\.\*\\\.php' "$src" | sed -E 's/^\s+//; s/\s+$//' | sort -u)
n=$(grep -c . <<<"$lines" || true)
if [[ $n != 1 ]]; then
    echo "$src: expected one distinct active PHP ProxyPassMatch line, found $n" >&2
    exit 1
fi
if ! grep -qE 'fcgi://127\.0\.0\.1:74(0[1-9]|1[0-9])/' <<<"$lines"; then
    echo "$src: the PHP line does not go to 127.0.0.1:7401-7419: $lines" >&2
    exit 1
fi
printf '# php85-sidecar: on this server only, PHP for this vhost goes to 8.5.\n'
printf '# Generated %s from %s by scripts/site-inc.sh.\n' "$(date '+%F %T')" "$src"
printf '# Rollback: delete this file, then apachectl -t && apachectl -k graceful.\n'
sed -E "s#fcgi://127\.0\.0\.1:74([0-9]{2})/#fcgi://${bind}:85\1/#" <<<"$lines"
