#!/usr/bin/env bash
# Checks the running sidecar on this host, read-only: health, extensions against php74, config, published
# addresses, and every pool reached the way the old httpd reaches it (a container on docker0 -> BIND_IP:85NN).
# usage: tests/smoke.sh            (CONTAINER=php85-sidecar, BIND_IP=docker0 gateway by default)
set -uo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C
C=${CONTAINER:-php85-sidecar}
BIND_IP=${BIND_IP:-$(docker network inspect bridge -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' | grep -m1 -F .)}
fails=0
ok()  { echo "OK    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }

health=missing
for _ in $(seq 30); do
    health=$(docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null || echo missing)
    [[ $health == starting ]] || break
    sleep 2
done
if [[ $health != healthy ]]; then
    bad "container $C is $health"
    echo "RESULT: FAILED"
    exit 1
fi
ok "container $C healthy"
image=$(docker inspect -f '{{.Config.Image}}' "$C")

ver=$(docker exec "$C" php -r 'echo PHP_VERSION;')
[[ $ver == 8.5.* ]] && ok "php $ver ($image)" || bad "php version $ver"

missing=$(comm -23 <(sort -u baseline/php74-modules.txt) \
    <(docker exec "$C" php -m | grep -vE '^\[|^$' | sort -u) | grep -vxF -f baseline/expected-missing.txt)
[[ -z $missing ]] && ok "all php74 extensions present, apart from baseline/expected-missing.txt" \
    || bad "missing extensions: $(echo $missing)"

if fpm=$(docker exec "$C" php-fpm -t -y /etc/opt/remi/php85/php-fpm.conf 2>&1); then
    ok "php-fpm -t"
else
    bad "php-fpm -t: $(tail -1 <<<"$fpm")"
fi

# composer prints its version lines on two streams, so their order varies: take the line, not the first one.
cv=$(docker exec -w /tmp "$C" composer --version 2>&1 | grep -m1 '^Composer version')
[[ $cv == Composer\ version\ 2.* ]] && ok "composer: $cv" || bad "composer: $cv"
po=$(docker exec -w /tmp "$C" php -r 'echo is_callable("proc_open") ? "callable" : "disabled";' 2>&1)
[[ $po == disabled ]] && ok "proc_open disabled outside the composer wrapper" || bad "proc_open outside composer: $po"

per_pool=$(docker exec "$C" sh -c 'grep -lE "^\s*php_(admin_)?value\[disable_functions\]" \
    /etc/opt/remi/php85/php-fpm.d/*.conf /etc/opt/remi/php85/php-fpm2.d/*.conf 2>/dev/null' || true)
[[ -z $per_pool ]] && ok "no per-pool disable_functions" \
    || bad "per-pool disable_functions (breaks opcache across pools, see conf/99-sidecar.ini): $per_pool"

outside=$(docker port "$C" | grep -v " -> ${BIND_IP}:" || true)
[[ -z $outside ]] && ok "ports published on $BIND_IP only" || bad "ports published elsewhere: $outside"

pools=$(docker exec "$C" sh -c 'grep -hE "^\s*(\[|listen\s*=)" /etc/opt/remi/php85/php-fpm.d/*.conf \
    /etc/opt/remi/php85/php-fpm2.d/*.conf 2>/dev/null' | paste -d' ' - - | sed -E 's/^\[(.*)\] *listen *= *([0-9]+)$/\1 \2/')
while read -r pool port; do
    [[ -n ${port:-} ]] || continue
    out=$(docker run --rm --network bridge --entrypoint cgi-fcgi -e REQUEST_METHOD=GET \
        -e SCRIPT_FILENAME=/opt/sidecar/selftest.php -e SCRIPT_NAME=/selftest.php \
        "$image" -bind -connect "$BIND_IP:$port" 2>&1)
    json=$(grep '^{' <<<"$out")
    problems=()
    grep -q '"php":"8\.5\.' <<<"$json" || problems+=(php)
    grep -q '"uid":1000,"gid":1000' <<<"$json" || problems+=(uid)
    grep -qE '"groups":\[[^]]*\b48\b' <<<"$json" || problems+=(group48)
    grep -q '"tz":"Asia/Shanghai"' <<<"$json" || problems+=(tz)
    grep -q '"opcache":true' <<<"$json" || problems+=(opcache)
    grep -q '"session_writable":true' <<<"$json" || problems+=(session)
    grep -q '"www_readable":true' <<<"$json" || problems+=(www)
    grep -q '"tmp_writable":true' <<<"$json" || problems+=(tmp)
    if [[ ${#problems[@]} -eq 0 ]]; then
        ok "pool $pool via $BIND_IP:$port $json"
    else
        bad "pool $pool via $BIND_IP:$port (${problems[*]}): ${json:-$out}"
    fi
done <<<"$pools"

if [[ $fails -eq 0 ]]; then echo "RESULT: OK"; else echo "RESULT: FAILED ($fails)"; exit 1; fi
