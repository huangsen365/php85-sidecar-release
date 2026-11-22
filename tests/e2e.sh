#!/usr/bin/env bash
# End to end on a test host (not on a server that runs the real sidecar): starts the stack with throwaway dirs and an
# "old container" (CentOS 7's httpd 2.4.6 with a vhost and a php74 pool file in the form the servers use), then does
# what an operator does, with the same scripts: preflight, deploy, lint, pool, vhost stage/test/apply, switch on,
# checks, switch off, and the two undo scripts. The sidecar's www pool (8500, memory_limit 128M) plays the old 74NN
# pool, reached through a forwarder on 127.0.0.1:7401 in the old container. Removes everything it started.
# usage: tests/e2e.sh [image]      (default: newest php85-sidecar tag)      Run it as root: it sets file owners.
set -uo pipefail
[[ $EUID == 0 ]] || { echo "tests/e2e.sh gives files to the pool user (1000:1000): run it as root, e.g. sudo tests/e2e.sh" >&2; exit 2; }
export LC_ALL=C
cd "$(dirname "$0")/.."
ROOT=$(pwd)
P=php85-e2e
IMAGE=${1:-$(docker images php85-sidecar --format '{{.Repository}}:{{.Tag}}' | head -1)}
BIND_IP=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' | grep -m1 -F .)
fails=0
ok()  { echo "OK    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }

if docker ps -a --format '{{.Names}}' | grep -qx php85-sidecar; then
    echo "php85-sidecar runs on this host; e2e needs its ports. Run it on a test host." >&2
    exit 2
fi
[[ -n $IMAGE ]] || { echo "no php85-sidecar image; run ./build.sh first" >&2; exit 2; }

tmp=$(mktemp -d /tmp/$P.XXXXXX)
cleanup() {
    docker rm -f $P-httpd >/dev/null 2>&1
    docker compose -p $P --env-file "$tmp/.env" down >/dev/null 2>&1
    rm -rf "$tmp"
}
trap cleanup EXIT
# The scripts under test read this run's .env and keep their staging/ and backup/ in the throwaway dir.
run() { ENV_FILE="$tmp/.env" SIDECAR_WORK="$tmp/work" "$@" 2>&1; }
brief() { grep -E 'FAIL|RESULT' <<<"$1" | cut -c1-400 | tr '\n' ';'; }

mkdir -p "$tmp"/{work,conf2.d,php74lib/session/test.local,php74lib/wsdlcache/test.local,remi-etc/php74/php-fpm2.d}
cp -a tests/e2e/www "$tmp/www"
mkdir -p "$tmp/www/html"     # the main config's DocumentRoot, as on the servers' /var/www
cp tests/e2e/php-fpm_7401_test.local_NEW2.conf "$tmp/remi-etc/php74/php-fpm2.d/"
cp tests/e2e/01_httpd_7401_test.local.conf "$tmp/conf2.d/"
# Compiles on 7.4, not on 8: what scripts/lint-compare.sh is for.
printf '<?php $s = "abc"; echo $s{0};\n' > "$tmp/www/test.local/public/legacy.php"
chown -R 1000:1000 "$tmp/php74lib"
# A session written by php74 (files handler, php serializer): the 8.5 pool must pick it up.
printf 'n|i:41;user|s:5:"alice";' > "$tmp/php74lib/session/test.local/sess_php74written0000000000"
chown 1000:1000 "$tmp/php74lib/session/test.local/sess_php74written0000000000"

if scripts/pool-from-php74.sh tests/e2e/php-fpm_7401_test.local_NEW2.conf > "$tmp/pool.out"; then
    ok "pool converted: $(grep -E '^\[|^listen' "$tmp/pool.out" | tr '\n' ' ')"
else
    bad "pool conversion"
fi
# The old container: its vhosts, php74 pool files, code and session dir come from the host, as on the servers.
HTTPD_IMAGE=php85-e2e-httpd:el7-2
if ! docker image inspect $HTTPD_IMAGE >/dev/null 2>&1; then
    docker build -q -t $HTTPD_IMAGE tests/e2e/httpd-el7 >/dev/null || { bad "build $HTTPD_IMAGE"; exit 1; }
fi
docker run -d --name $P-httpd --network bridge -e OLD_POOL="$BIND_IP:8500" \
    -v "$tmp/conf2.d:/etc/httpd/conf2.d:ro" -v "$tmp/www:/var/www:ro" -v "$tmp/remi-etc:/etc/opt/remi:ro" \
    -v "$tmp/php74lib:/var/opt/remi/php74/lib/php:ro" $HTTPD_IMAGE >/dev/null
web=$(docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' $P-httpd)
for _ in $(seq 20); do curl -s -o /dev/null "http://$web/" && break; sleep 0.5; done
echo "      $(docker exec $P-httpd httpd -v | head -1)"

# scripts/preflight.sh: finds the site pool, its user and the host directories; refuses what is no old container.
pf=$(CONTAINER=$P scripts/preflight.sh $P-httpd 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q "1 php74 site pool(s) can move as they are (74NN becomes 85NN): 7401:test.local" <<<"$pf" \
    && grep -q "pool user sshuser is 1000:1000" <<<"$pf" && grep -q "^OK    1 vhost file(s) send PHP to" <<<"$pf" \
    && [[ $(tail -1 <<<"$pf") == "RESULT: OK" ]] \
    && ok "preflight: site pool, pool user and vhost found, nothing to warn about" \
    || bad "preflight (exit $rc): $(grep -E '^(FAIL|WARN|RESULT)' <<<"$pf" | tr '\n' ';')"
pn=$(CONTAINER=$P scripts/preflight.sh 2>&1 $P-httpd-nosuch); rc=$?
[[ $rc == 1 ]] && grep -q '^RESULT: FAILED' <<<"$pn" && ok "preflight fails on a container that does not exist" \
    || bad "preflight on a missing container: exit $rc, $(tail -1 <<<"$pn")"

# scripts/deploy.sh: .env from the old container's mounts, the container, smoke, reachability. Throwaway names and
# log dir instead of the real ones.
dep() { CONTAINER=$P COMPOSE_PROJECT_NAME=$P LOG_DIR="$tmp/log" ENV_FILE="$tmp/.env" scripts/deploy.sh "$@" 2>&1; }
o=$(dep "$IMAGE" $P-httpd); rc=$?
want="BIND_IP=$BIND_IP CONTAINER_NAME=$P IMAGE=$IMAGE LOG_DIR=$tmp/log OLD_CONTAINER=$P-httpd PHP74_LIB_DIR=$tmp/php74lib PHP74_POOL_DIR=$tmp/remi-etc/php74/php-fpm2.d POOL_DIR=$tmp/remi-etc/php85/php-fpm2.d VHOST_DIR=$tmp/conf2.d WWW_DIR=$tmp/www "
got=$(grep -v '^#' "$tmp/.env" 2>/dev/null | sort | tr '\n' ' ')
[[ $rc == 0 && $got == "$want" ]] && grep -q "reaches the sidecar on $BIND_IP:8500" <<<"$o" \
    && ok "deploy: .env written from the old container's mounts, sidecar up, smoke passed, old container reaches it" \
    || bad "deploy (exit $rc): $(brief "$o") .env: $got"
o=$(dep "$IMAGE" $P-httpd); rc=$?
[[ $rc == 0 ]] && grep -q 'using the existing' <<<"$o" && [[ $(grep -v '^#' "$tmp/.env" | sort | tr '\n' ' ') == "$want" ]] \
    && ok "deploy again: the existing .env is used, not overwritten" || bad "deploy again (exit $rc): $(brief "$o")"
o=$(dep php85-sidecar:no-such-tag $P-httpd); rc=$?
[[ $rc == 1 ]] && grep -q 'is not on this host' <<<"$o" && ok "deploy refuses an image that is not on the host" \
    || bad "deploy with a missing image: exit $rc, $(brief "$o")"
pn=$(CONTAINER=$P scripts/preflight.sh $P 2>&1); rc=$?
[[ $rc == 1 ]] && grep -q '^RESULT: FAILED' <<<"$pn" && ok "preflight refuses a container that is no old container" \
    || bad "preflight on the sidecar itself: exit $rc, $(tail -1 <<<"$pn")"

# Site ports past 7409 (servers whose php74 sites already use 7402-7410): 7411 maps to 8511, and 8519 is published.
sed 's/7401/7411/g' tests/e2e/php-fpm_7401_test.local_NEW2.conf > "$tmp/php-fpm_7411_test.local_NEW2.conf"
sed 's/7401/7411/g' tests/e2e/01_httpd_7401_test.local.conf > "$tmp/01_httpd_7411_test.local.conf"
l=$(scripts/pool-from-php74.sh "$tmp/php-fpm_7411_test.local_NEW2.conf" 2>/dev/null | grep -E '^\s*listen\s*=' | tr -d ' ')
i=$(BIND_IP=$BIND_IP scripts/site-inc.sh "$tmp/01_httpd_7411_test.local.conf" 2>/dev/null | grep -o 'fcgi://[^/]*')
[[ $l == listen=8511 && $i == "fcgi://$BIND_IP:8511" ]] && ok "port 7411 maps to 8511 (pool $l, .inc $i)" \
    || bad "7411 mapping: pool '$l', .inc '$i'"
p=$(docker port $P 8519/tcp)
[[ $p == "$BIND_IP:8519" ]] && ok "8519 published on $BIND_IP" || bad "8519 published as '$p'"

# Composer as sshuser in a site dir: a dist zip through the Tencent mirror (the image has no git), a script through
# proc_open (only the wrapper lifts disable_functions), and files owned by 1000:1000 like the rest of the site.
mkdir -p "$tmp/www/composer.test"
cat > "$tmp/www/composer.test/composer.json" <<'JSON'
{"name": "e2e/composer-test", "require": {"psr/log": "^3"},
 "scripts": {"marker": "@php -r \"echo 'proc_open-ok', PHP_EOL;\""}}
JSON
chown -R 1000:1000 "$tmp/www/composer.test"
co=$(docker exec -u sshuser -w /var/www/composer.test $P composer install --no-interaction --no-progress -vvv 2>&1)
[[ -f $tmp/www/composer.test/vendor/psr/log/composer.json ]] && grep -q 'mirrors.tencent.com' <<<"$co" \
    && ok "composer install: psr/log through the Tencent mirror" || bad "composer install: $(tail -3 <<<"$co")"
own=$(stat -c %u:%g "$tmp/www/composer.test/vendor" "$tmp/www/composer.test/composer.lock" 2>/dev/null | sort -u | tr '\n' ' ')
[[ $own == "1000:1000 " ]] && ok "vendor/ and composer.lock owned by 1000:1000" || bad "composer file owners: '$own'"
m=$(docker exec -u sshuser -w /var/www/composer.test $P composer run-script marker 2>&1)
grep -q 'proc_open-ok' <<<"$m" && ok "composer run-script (proc_open inside the wrapper)" || bad "composer run-script: $m"

mem() { curl -s "http://$web/$1" | grep -o '"memory_limit":"[^"]*"' | cut -d'"' -f4; }

a=$(mem index.php) g=$(mem gitpull.php)
[[ $a == 128M && $g == 128M ]] && ok "before: index.php and gitpull.php on the old pool (127.0.0.1:7401)" \
    || bad "before: index.php=$a gitpull.php=$g, both expected on the old pool (128M)"

lc=$(run scripts/lint-compare.sh test.local/public)
grep -q '^NEW-8.5  ./legacy.php' <<<"$lc" && grep -q ': 1 break only on 8.5, 0 are broken on php74 too' <<<"$lc" \
    && ok "lint-compare: $(grep '^NEW-8.5' <<<"$lc" | cut -c1-90)" || bad "lint-compare: $(brief "$lc")"

# The switch, step by step, as the README describes it.
o=$(run scripts/pool-add.sh test.local); rc=$?
[[ $rc == 0 ]] && grep -q "pool test.local-php85 answers on $BIND_IP:8501" <<<"$o" \
    && ok "pool-add: pool written, sidecar reloaded, smoke passed with the site pool" || bad "pool-add: $(brief "$o")"
o=$(run scripts/pool-add.sh test.local); rc=$?
[[ $rc == 0 ]] && grep -q 'pool file exists, kept' <<<"$o" && ok "pool-add again: the pool file is kept" \
    || bad "pool-add again: $(brief "$o")"

o=$(run scripts/vhost-stage.sh test.local); rc=$?
b=01_httpd_7401_test.local.conf
[[ $rc == 0 ]] && cmp -s "$tmp/conf2.d/$b" tests/e2e/$b && [[ $(grep -c 'IncludeOptional conf.d/php85-test.local\*.inc' "$tmp/work/staging/test.local/$b") == 1 ]] \
    && grep -q "fcgi://$BIND_IP:8501/" "$tmp/work/staging/test.local/php85-test.local.inc" && cmp -s "$tmp/work/backup/$b" tests/e2e/$b \
    && ok "vhost-stage: vhost with the include line and the .inc staged, backup kept, live vhost untouched" \
    || bad "vhost-stage: $(brief "$o")"
o=$(run scripts/vhost-test.sh test.local); rc=$?
[[ $rc == 0 && $(grep -c '^OK ' <<<"$o") == 4 ]] && cmp -s "$tmp/conf2.d/$b" tests/e2e/$b \
    && ok "vhost-test: valid without and with the .inc, the include is real, live config untouched" \
    || bad "vhost-test: $(brief "$o")"
o=$(run scripts/site-switch.sh on test.local); rc=$?
[[ $rc == 1 ]] && grep -q 'has no include line yet' <<<"$o" && ok "site-switch on refuses before vhost-apply" \
    || bad "site-switch on before vhost-apply: exit $rc, $(brief "$o")"
o=$(run scripts/vhost-apply.sh test.local); rc=$?
[[ $rc == 0 ]] && cmp -s "$tmp/conf2.d/$b" "$tmp/work/staging/test.local/$b" && ok "vhost-apply: the vhost with the include line is live" \
    || bad "vhost-apply: $(brief "$o")"
o=$(run scripts/vhost-apply.sh test.local); rc=$?
[[ $rc == 0 ]] && grep -q 'already has the include line' <<<"$o" && ok "vhost-apply again: nothing to do" \
    || bad "vhost-apply again: $(brief "$o")"
docker exec $P-httpd httpd -k graceful; sleep 2
a=$(mem index.php) g=$(mem gitpull.php)
[[ $a == 128M && $g == 128M ]] && ok "no .inc: the include line changes nothing (index.php and gitpull.php on the old pool)" \
    || bad "no .inc: index.php=$a gitpull.php=$g, both expected on the old pool (128M)"

o=$(run scripts/site-switch.sh on test.local); rc=$?
[[ $rc == 0 ]] && grep -q 'test.local is on PHP 8.5' <<<"$o" && ok "site-switch on: $(grep 'sites on 8.5' <<<"$o" | sed 's/^ *//')" \
    || bad "site-switch on: $(brief "$o")"
jar=$tmp/cookies
r1=$(curl -s -c "$jar" -b "$jar" "http://$web/index.php")
r2=$(curl -s -c "$jar" -b "$jar" "http://$web/")
echo "      $r1"
grep -q '"php":"8\.5\.' <<<"$r1" && grep -q '"n":1' <<<"$r1" && ok "with .inc: index.php on the site's 8.5 pool (8501)" \
    || bad "first request: $r1"
g=$(mem gitpull.php)
[[ $g == 128M ]] && ok "with .inc: gitpull.php still on the old pool" || bad "with .inc: gitpull.php memory_limit=$g"
grep -q '"n":2' <<<"$r2" && ok "session kept across requests (DirectoryIndex index.php too)" || bad "second request: $r2"
grep -q '"system_disabled":true' <<<"$r1" && grep -q '"upload_max_filesize":"100M"' <<<"$r1" \
    && grep -q '"memory_limit":"512M"' <<<"$r1" && ok "site pool settings carried over from php74" \
    || bad "pool settings: $r1"
grep -q '"script":"/var/www/test.local/public/index.php"' <<<"$r1" && ok "SCRIPT_FILENAME under /var/www" \
    || bad "script path: $r1"

r3=$(curl -s -b 'PHPSESSID=php74written0000000000' "http://$web/index.php")
grep -q '"n":42' <<<"$r3" && grep -q '"user":"alice"' <<<"$r3" && ok "reads a session php74 wrote" \
    || bad "php74 session: $r3"
owner=$(stat -c %u:%g "$tmp"/php74lib/session/test.local/sess_* | sort -u | tr '\n' ' ')
[[ $owner == "1000:1000 " ]] && ok "session files owned by 1000:1000" || bad "session file owners: $owner"

curl -s -o /dev/null "http://$web/index.php?warn=1"
grep -q 'php85-e2e warning' "$tmp/log/test.local-error.log" 2>/dev/null && ok "site error log written to LOG_DIR" \
    || bad "no warning in $tmp/log/test.local-error.log"

o=$(run scripts/site-status.sh test.local); rc=$?
[[ $rc == 0 ]] && grep -q 'test.local is switched to PHP 8.5' <<<"$o" && grep -q 'php85-e2e warning' <<<"$o" \
    && [[ $(sed -nE 's/^ *accepted conn: *([0-9]+)/\1/p' <<<"$o") -ge 4 ]] \
    && ok "site-status: $(grep -E 'pool:|accepted conn:' <<<"$o" | tr -s ' ' | tr '\n' ' ')" || bad "site-status: $(brief "$o")"

o=$(run scripts/site-switch.sh off test.local); rc=$?
a=$(mem index.php)
[[ $rc == 0 && $a == 128M ]] && ok "rollback: site-switch off, index.php back on the old pool" || bad "rollback: index.php=$a, $(brief "$o")"
o=$(run scripts/site-status.sh test.local)
grep -q 'test.local is on php74 on this host' <<<"$o" && ok "site-status after the rollback: on php74" || bad "site-status after rollback: $(brief "$o")"

# The two undo scripts: the vhost and the pool as they were before.
o=$(run scripts/vhost-restore.sh test.local); rc=$?
[[ $rc == 0 ]] && cmp -s "$tmp/conf2.d/$b" tests/e2e/$b && ok "vhost-restore: the vhost is the original again" \
    || bad "vhost-restore: $(brief "$o")"
o=$(run scripts/pool-remove.sh test.local); rc=$?
[[ $rc == 0 ]] && ! ls "$tmp"/remi-etc/php85/php-fpm2.d/*.conf >/dev/null 2>&1 && [[ -f $tmp/work/backup/php-fpm_8501_test.local.conf.removed ]] \
    && ok "pool-remove: the pool file is in backup/, the sidecar dropped the pool, smoke passed" || bad "pool-remove: $(brief "$o")"
o=$(run scripts/site-switch.sh on test.local); rc=$?
[[ $rc == 1 ]] && ok "site-switch on refuses once the vhost and the pool are gone" || bad "site-switch on after the undo: exit $rc, $(brief "$o")"

if [[ $fails -eq 0 ]]; then echo "RESULT: OK"; else echo "RESULT: FAILED ($fails)"; exit 1; fi
