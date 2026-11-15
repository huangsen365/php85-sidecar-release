#!/usr/bin/env bash
# Turns a site's php74 pool into its php85 pool: same settings and session dir, port 74NN -> 85NN,
# logs under php85, no user/group lines (the sidecar's master already runs as sshuser).
# disable_functions is global in the sidecar (conf/99-sidecar.ini, see there why), so the pool's own list is dropped:
# functions only the php74 pool blocked are named on stderr, and a pool that allows one the global list blocks is
# refused, because the site would break on 8.5.
# usage: scripts/pool-from-php74.sh <php74 php-fpm2.d/php-fpm_74NN_<site>_*.conf> > <POOL_DIR>/php-fpm_85NN_<site>.conf
set -euo pipefail
src=${1:?usage: $0 <php74 pool file>}
ini=$(dirname "$0")/../conf/99-sidecar.ini

fn_set() { tr ',' '\n' | tr -d ' \t\r' | sed '/^$/d' | sort -u; }
global=$(sed -nE 's/^\s*disable_functions\s*=\s*//p' "$ini" | fn_set)
pool=$(sed -nE 's/^\s*php_(admin_)?value\[disable_functions\]\s*=\s*//p' "$src" | fn_set)
needs=$(comm -23 <(echo "$global") <(echo "$pool") | sed '/^$/d')
if [[ -n $needs ]]; then
    echo "$src: the site may call $(echo $needs | tr ' ' ','), which the sidecar disables for every pool" \
        "(conf/99-sidecar.ini); it cannot move to 8.5 as is" >&2
    exit 1
fi
extra=$(comm -13 <(echo "$global") <(echo "$pool") | sed '/^$/d')
[[ -z $extra ]] || echo "$src: note: callable on 8.5, disabled on 7.4: $(echo $extra | tr ' ' ',')" >&2

out=$(sed -E \
    -e '/^\s*(user|group|listen\.(allowed_clients|owner|group|mode))\s*=/d' \
    -e '/^\s*php_(admin_)?value\[disable_functions\]/d' \
    -e 's/^\[(.*)-php74\]/[\1-php85]/' \
    -e 's/^(\s*listen\s*=\s*)(127\.0\.0\.1:)?74([0-9]{2})\s*$/\185\3/' \
    -e 's#/var/opt/remi/php74/log/#/var/opt/remi/php85/log/#g' \
    "$src")

if ! grep -qE '^\s*listen\s*=\s*85(0[1-9]|1[0-9])\s*$' <<<"$out"; then
    echo "$src: no 'listen = 127.0.0.1:74NN' line; only php74 site pools on 7401-7419 map onto 8501-8519" >&2
    exit 1
fi
if ! grep -qE '^\[.*-php85\]' <<<"$out"; then
    echo "$src: pool name does not end in -php74" >&2
    exit 1
fi
if ! grep -qE '^\s*pm\.status_path\s*=' <<<"$out"; then
    # Reachable over 172.17.0.1:85NN only (httpd forwards *.php paths): shows whether requests reach this pool.
    out+=$'\n; Added by scripts/pool-from-php74.sh: accepted conn etc., read through 172.17.0.1:85NN only\npm.status_path = /fpm-status'
fi
printf '; Generated from %s by scripts/pool-from-php74.sh\n%s\n' "$src" "$out"
