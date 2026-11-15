#!/usr/bin/env bash
# Adds "IncludeOptional conf.d/php85-<site>*.inc" right before each active PHP ProxyPassMatch line of a conf2.d vhost.
# conf2.d is shared by both servers, conf.d is each server's own. While no server has that file the line matches
# nothing and the vhost works as before; a server that has it (scripts/site-inc.sh) sends PHP to the 8.5 pool, because
# the first matching ProxyPassMatch wins. gitpull.php stays on 74NN, so its line must come before the PHP line.
# usage: scripts/vhost-add-include.sh <conf2.d/NN_httpd_74NN_<site>.conf> <site> > <new vhost>
set -euo pipefail
src=${1:?usage: $0 <vhost> <site>}
site=${2:?usage: $0 <vhost> <site>}
[[ $site =~ ^[A-Za-z0-9.-]+$ ]] || { echo "bad site name: $site" >&2; exit 1; }
inc="IncludeOptional conf.d/php85-${site}*.inc"
if grep -qF "$inc" "$src"; then
    echo "$src: already has '$inc'" >&2
    cat "$src"
    exit 0
fi
awk -v inc="$inc" '
    /^[[:space:]]*<VirtualHost/ { php = 0 }
    /^[[:space:]]*ProxyPassMatch[[:space:]]+"?\/gitpull\.php/ { if (php) bad = bad " " NR }
    /^[[:space:]]*ProxyPassMatch[[:space:]]+"?\^\/\(\.\*\\\.php/ {
        match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) inc; php = 1; n++
    }
    { print }
    END {
        if (!n) { print FILENAME ": no active PHP ProxyPassMatch line" > "/dev/stderr"; exit 1 }
        if (bad) { print FILENAME ": gitpull line after the PHP line (line" bad "), it would move to 8.5" > "/dev/stderr"; exit 1 }
    }' "$src"
