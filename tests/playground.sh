#!/usr/bin/env bash
# A rehearsal ground on a test host (never on a server that runs real sites): an "old container" in the form the
# servers have, with one site, test.local. You, or your AI assistant, can go through the README there, from
# scripts/preflight.sh to the rollback, before touching production. Everything lives under /tmp/php85-playground.
# usage: tests/playground.sh up [image]   start it and print what to do next (default image: newest php85-sidecar tag)
#        tests/playground.sh status       where the site answers, and what it answers now
#        tests/playground.sh down         remove everything the rehearsal left: the playground's containers and
#                                         directory, the sidecar deployed against it, its .env, staging/, backup/, logs
# It needs the sidecar image on the host, and network access to build the old container once (the centos:7 image and
# a CentOS vault mirror, mirrors.aliyun.com by default).
# The old container is CentOS 7's httpd 2.4.6 with test.local's vhost and php74 pool file. There is no real php74:
# a second container from the sidecar image stands in for the site's php74 pool, and a stub answers for php74's CLI.
# So every answer says "php":"8.5.x"; what tells the two pools apart is memory_limit: 128M from the stand-in (before
# the switch, and after the rollback), 512M from the site's own 8.5 pool (after the switch).
set -euo pipefail
cd "$(dirname "$0")/.."
P=php85-playground
D=/tmp/$P
HTTPD_IMAGE=php85-e2e-httpd:el7-2
web() { docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' $P-old 2> /dev/null; }
case ${1:-} in
up)
    all=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '(^|/)php85-sidecar:[0-9]' || true)
    IMAGE=${2:-$(grep -m1 / <<< "$all" || head -1 <<< "$all")}      # the registry's name first, as .env wants it
    [[ -n $IMAGE ]] || { echo "no php85-sidecar image on this host: pull or load one (README: 获取镜像), or ./build.sh" >&2; exit 2; }
    if docker ps -a --format '{{.Names}}' | grep -q "^$P-"; then echo "the playground exists already; see $0 status, or $0 down first" >&2; exit 2; fi
    mkdir -p $D/{conf2.d,remi-etc/php74/php-fpm2.d,php74lib/session/test.local,php74lib/wsdlcache/test.local}
    cp -a tests/e2e/www $D/www
    mkdir -p $D/www/html
    cp tests/e2e/php-fpm_7401_test.local_NEW2.conf $D/remi-etc/php74/php-fpm2.d/
    cp tests/e2e/01_httpd_7401_test.local.conf $D/conf2.d/
    printf '<?php $s = "abc"; echo $s{0};\n' > $D/www/test.local/public/legacy.php      # compiles on 7.4, not on 8
    chown -R 1000:1000 $D/php74lib
    docker image inspect $HTTPD_IMAGE > /dev/null 2>&1 || docker build -q -t $HTTPD_IMAGE tests/e2e/httpd-el7 > /dev/null
    docker run -d --name $P-php74 --network bridge -v $D/www:/var/www:ro -v $D/php74lib:/var/opt/remi/php74/lib/php \
        "$IMAGE" > /dev/null
    pool=$(docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' $P-php74)
    docker run -d --name $P-old --network bridge -e OLD_POOL="$pool:8500" \
        -v $D/conf2.d:/etc/httpd/conf2.d:ro -v $D/www:/var/www:ro -v $D/remi-etc:/etc/opt/remi:ro \
        -v $D/php74lib:/var/opt/remi/php74/lib/php:ro $HTTPD_IMAGE > /dev/null
    for _ in $(seq 30); do curl -s "http://$(web)/index.php" | grep -q '"memory_limit"' && break; sleep 0.5; done
    echo "The playground is up."
    echo "  old container:  $P-old"
    echo "  site:           test.local   (code directory test.local/public, php74 pool [test.local-php74] on 127.0.0.1:7401)"
    echo "  image:          $IMAGE"
    echo "  the site:       curl -s http://$(web)/index.php     (plain http, reachable from this host only)"
    echo "  it answers now: $(curl -s "http://$(web)/index.php" | grep -o '"memory_limit":"[^"]*"')  = the stand-in for php74;"
    echo "                  after the switch it is \"memory_limit\":\"512M\" (the site's 8.5 pool). \"php\" is 8.5 both times."
    echo "  planted:        test.local/public/legacy.php does not compile on PHP 8, so scripts/lint-compare.sh has one"
    echo "                  NEW-8.5 file to show. No page uses it; go on past it."
    echo "Next, in this directory:  scripts/preflight.sh   then   scripts/deploy.sh $IMAGE"
    echo "When done:  $0 down"
    ;;
status)
    w=$(web) || true
    [[ -n $w ]] || { echo "no playground on this host ($0 up)"; exit 1; }
    echo "the site:       curl -s http://$w/index.php"
    echo "it answers now: $(curl -s "http://$w/index.php" | cut -c1-200)"
    echo "128M = the stand-in for php74, 512M = the site's 8.5 pool"
    ;;
down)
    if grep -qsx "OLD_CONTAINER=$P-old" .env; then          # the sidecar of this rehearsal, and what it left here
        set -a; . ./.env; set +a
        docker compose down > /dev/null 2>&1 || true
        rm -f .env staging/test.local/* backup/01_httpd_7401_test.local.conf backup/php-fpm_8501_test.local.conf.removed
        rmdir staging/test.local staging backup 2> /dev/null || true
        rm -f "${LOG_DIR:?}"/test.local-*.log "$LOG_DIR"/www-*.log
        rmdir "$LOG_DIR" 2> /dev/null || true
        echo "Removed the rehearsal's sidecar, .env, staging/, backup/ entries and logs."
    fi
    docker rm -f $P-old $P-php74 > /dev/null 2>&1 || true
    rm -rf $D
    echo "The playground is gone."
    if docker ps -a --format '{{.Names}}' | grep -qx php85-sidecar; then
        echo "A container php85-sidecar is still on this host. It does not belong to this rehearsal (.env names another old container)."
    fi
    ;;
*)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
