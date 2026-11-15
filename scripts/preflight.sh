#!/usr/bin/env bash
# Read-only check of a host before the sidecar is deployed there: is this the layout the sidecar was made for, which
# sites can move to PHP 8.5 as they are, and which values belong in .env. It changes nothing on the host or in any
# container. Run it on the host, as root or as a user who may use docker.
# usage: scripts/preflight.sh [--env] [old container]
#   old container   name or id; default: the only running container that has Remi's php74 (/etc/opt/remi/php74)
#   --env           print only the .env lines on stdout (the report goes to stderr):
#                     IMAGE=<image tag> scripts/preflight.sh --env > .env
#   CONTAINER=name  the sidecar's container name, if it is not php85-sidecar;  LOG_DIR=dir  another log directory
# Ends with RESULT: OK, RESULT: WARN (deployable; read the WARN lines first) or RESULT: FAILED (not as it is).
set -uo pipefail
export LC_ALL=C

envonly=0 old=
for a in "$@"; do
    case $a in
        --env) envonly=1 ;;
        -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $a" >&2; exit 2 ;;
        *) old=$a ;;
    esac
done
if [[ $envonly == 1 ]]; then exec 3>&1 1>&2; fi       # --env: fd 3 is the real stdout, the report goes to stderr

SC=${CONTAINER:-php85-sidecar}
fails=0 warns=0
ok()   { echo "OK    $*"; }
info() { echo "      $*"; }
warn() { echo "WARN  $*"; warns=$((warns + 1)); }
bad()  { echo "FAIL  $*"; fails=$((fails + 1)); }
finish() {
    if [[ $fails -gt 0 ]]; then echo "RESULT: FAILED ($fails)"; exit 1; fi
    if [[ $warns -gt 0 ]]; then echo "RESULT: WARN ($warns)"; else echo "RESULT: OK"; fi
    exit 0
}

# --- the host
command -v docker > /dev/null || { bad "docker is not installed on this host"; finish; }
dv=$(docker version --format '{{.Server.Version}}' 2> /dev/null || true)
[[ -n $dv ]] || { bad "cannot talk to the docker daemon (run as root, or as a user in the docker group)"; finish; }
ok "docker $dv, kernel $(uname -r)"
arch=$(uname -m)
[[ $arch == x86_64 ]] || bad "architecture $arch: the published image is x86_64 only"
if cv=$(docker compose version --short 2> /dev/null); then ok "docker compose $cv"
else bad "the docker compose plugin (v2) is missing; compose.yaml needs it (README: 适用环境)"; fi

BIND_IP=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2> /dev/null | grep -m1 -F . || true)
if [[ -n $BIND_IP ]]; then ok "default bridge gateway $BIND_IP (BIND_IP)"
else bad "the default bridge network has no IPv4 gateway; the old container reaches the sidecar through it"; BIND_IP=172.17.0.1; fi

deployed=0
names=$(docker ps -a --format '{{.Names}}')
if grep -qx -- "$SC" <<< "$names"; then
    deployed=1
    warn "a container named $SC exists here already ($(docker inspect -f '{{.Config.Image}}, {{.State.Status}}' "$SC")); check it with tests/smoke.sh"
else
    if command -v ss > /dev/null; then listening=$(ss -ltn 2> /dev/null | awk 'NR > 1 {print $4}')
    else listening=$(netstat -ltn 2> /dev/null | awk 'NR > 2 {print $4}'); fi
    busy=$(grep -oE ':85(0[0-9]|1[0-9])$' <<< "$listening" | tr -d : | sort -u | tr '\n' ' ')
    [[ -z $busy ]] && ok "ports 8500-8519 are free" || bad "ports the sidecar publishes are in use: $busy"
fi
droot=$(docker info -f '{{.DockerRootDir}}' 2> /dev/null || true)
free_mb=$(df -Pk "${droot:-/var/lib/docker}" 2> /dev/null | awk 'NR == 2 {print int($4 / 1024)}')
if [[ ${free_mb:-0} -ge 2048 ]]; then ok "${free_mb} MB free under ${droot:-/var/lib/docker}"
else warn "${free_mb:-?} MB free under ${droot:-/var/lib/docker}; the image takes about 550 MB, twice that while it loads from a tarball"; fi

# --- the old container
if [[ -z $old ]]; then
    cands=()
    while read -r c; do
        [[ -n $c && $c != "$SC" ]] || continue
        docker exec "$c" test -d /etc/opt/remi/php74 < /dev/null 2> /dev/null && cands+=("$c")
    done < <(docker ps --format '{{.Names}}')
    if [[ ${#cands[@]} -eq 0 ]]; then
        bad "no running container has /etc/opt/remi/php74: the sidecar moves sites off Remi's php74 php-fpm pools, and finds none here"
        finish
    fi
    if [[ ${#cands[@]} -gt 1 ]]; then
        bad "several containers have Remi's php74 (${cands[*]}); name the one to check: scripts/preflight.sh <container>"
        finish
    fi
    old=${cands[0]}
elif ! docker inspect "$old" > /dev/null 2>&1; then
    bad "no container named $old"; finish
fi
ex() { docker exec "$old" "$@" < /dev/null 2> /dev/null; }
ex true || { bad "container $old is not running"; finish; }
os=$(ex cat /etc/redhat-release || ex sh -c '. /etc/os-release; echo "$PRETTY_NAME"' || echo unknown)
net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$old")
ok "old container: $old ($os, network $net)"
case $net in default | bridge | host) ;; *) warn "the old container is on network '$net', not the default bridge: after deploying, check that it reaches $BIND_IP:8500 (README: 部署到一台服务器)" ;; esac

hv=$(ex httpd -v | sed -n 's/^Server version: *//p')
if [[ -z $hv ]]; then bad "no httpd in $old: sites are switched through Apache vhosts (ProxyPassMatch to php-fpm)"
else
    ok "httpd: $hv"
    mods=$(ex httpd -M || true)
    grep -q proxy_fcgi <<< "$mods" || bad "httpd has no mod_proxy_fcgi loaded"
    sr=$(ex httpd -V | sed -n 's/.*HTTPD_ROOT="\(.*\)".*/\1/p')
    [[ -z $sr || $sr == /etc/httpd ]] || warn "httpd's ServerRoot is $sr, not /etc/httpd: put the .inc files in $sr/conf.d"
fi
pv=$(ex /opt/remi/php74/root/usr/bin/php -r 'echo PHP_VERSION;' || true)
[[ -n $pv ]] && ok "php74: $pv" || warn "cannot run /opt/remi/php74/root/usr/bin/php in $old (only needed to compare lint results)"

# --- where the old container's directories are on the host
mounts=$(docker inspect -f '{{range .Mounts}}{{.Destination}}|{{.Source}}{{println}}{{end}}' "$old")
hostpath() {                                    # container path -> host path through the longest matching mount
    local p=$1 best= src= d s
    while IFS='|' read -r d s; do
        [[ -n $d ]] || continue
        d=${d%/}
        if [[ ($p == "$d" || $p == "$d"/*) && ${#d} -gt ${#best} ]]; then best=$d; src=$s; fi
    done <<< "$mounts"
    [[ -n $best ]] && echo "${src%/}${p#"$best"}"
    return 0
}
WWW_DIR=$(hostpath /var/www)
if [[ -z $WWW_DIR ]]; then bad "/var/www is inside $old's own filesystem, not on a volume: the sidecar cannot see the sites' code"
elif [[ ! -d $WWW_DIR ]]; then bad "/var/www is mounted from $WWW_DIR, which is not a directory on this host"
else
    ok "/var/www is $WWW_DIR on the host (WWW_DIR)"
    fstype=$(df -PT "$WWW_DIR" 2> /dev/null | awk 'NR == 2 {print $2}')
    case $fstype in nfs* | cifs | fuse* | ceph | glusterfs)
        info "it is shared storage ($fstype): other servers that mount it see the same code, pools and vhosts, so do the shared steps once" ;;
    esac
fi
PHP74_LIB_DIR=$(hostpath /var/opt/remi/php74/lib/php)
if [[ -n $PHP74_LIB_DIR && -d $PHP74_LIB_DIR ]]; then ok "php74's session and wsdl cache directory is $PHP74_LIB_DIR on the host (PHP74_LIB_DIR)"
else
    PHP74_LIB_DIR=/var/lib/php85-sidecar/php74-lib
    warn "/var/opt/remi/php74/lib/php is not on a volume: 8.5 cannot read php74's sessions, so users of a site are logged out when it moves. Create $PHP74_LIB_DIR/session/<site> (owner 1000:1000) for each site that moves"
fi
vdir=/etc/httpd/conf.d
ex test -d /etc/httpd/conf2.d && vdir=/etc/httpd/conf2.d
vhost_host=$(hostpath "$vdir")
if [[ -n $vhost_host && -d $vhost_host ]]; then ok "vhosts: $vdir, $vhost_host on the host (VHOST_DIR)"
else vhost_host=; warn "vhosts ($vdir) are inside $old, not on a volume: scripts/vhost-*.sh need them on the host. Copy a vhost out with docker cp, edit it by the README, test it and copy it back"; fi

# --- the sites
pools=$(ex sh -c 'grep -HE "^[[:space:]]*(\[[^]]+\]|listen[[:space:]]*=|user[[:space:]]*=)" /etc/opt/remi/php74/php-fpm2.d/*.conf /etc/opt/remi/php74/php-fpm.d/*.conf' | awk '
    function flush() { if (name != "" && name != "global") print file "|" name "|" listen "|" user }
    { f = $0; sub(/:.*/, "", f); line = substr($0, length(f) + 2); gsub(/^[ \t]+|[ \t\r]+$/, "", line)
      if (line ~ /^\[/) { flush(); file = f; name = line; gsub(/[\[\]]/, "", name); listen = ""; user = "" }
      else if (line ~ /^listen/) { sub(/^listen[ \t]*=[ \t]*/, "", line); listen = line }
      else { sub(/^user[ \t]*=[ \t]*/, "", line); user = line } }
    END { flush() }')
movable=() stuck=() users=() p74dir=
while IFS='|' read -r file name listen user; do
    [[ -n $name ]] || continue
    if [[ $listen =~ ^(127\.0\.0\.1:)?74(0[1-9]|1[0-9])$ && $name == *-php74 ]]; then
        movable+=("${listen##*:}:${name%-php74}")
        [[ -n $p74dir ]] || p74dir=$(dirname "$file")
        [[ -z $user || " ${users[*]-} " == *" $user "* ]] || users+=("$user")
    elif [[ $name != www && $name != www-php74 ]]; then       # the container's own default pool is no site
        stuck+=("$name (listen = ${listen:-?})")
    fi
done <<< "$pools"
if [[ ${#movable[@]} -gt 0 ]]; then
    ok "${#movable[@]} php74 site pool(s) can move as they are (74NN becomes 85NN): ${movable[*]}"
else
    warn "no php74 site pool can be converted as it is (scripts/pool-from-php74.sh wants '[<site>-php74]' and 'listen = 127.0.0.1:7401' to 7419); a new site that runs on 8.5 only is still possible"
fi
[[ ${#stuck[@]} -eq 0 ]] || { info "pools that cannot move as they are (another port range, a unix socket, or another name):"; printf '        %s\n' "${stuck[@]}"; }
idbad=0
for u in ${users[@]+"${users[@]}"}; do
    ids="$(ex id -u "$u"):$(ex id -g "$u")"
    [[ $ids == 1000:1000 ]] || { idbad=1; bad "the pools run as $u ($ids) in $old; the image runs every pool as 1000:1000, so the sites' files would not be writable"; }
done
[[ ${#users[@]} -eq 0 || $idbad == 1 ]] || ok "pool user ${users[*]} is 1000:1000, as in the image"
PHP74_POOL_DIR=$(hostpath "${p74dir:-/etc/opt/remi/php74/php-fpm2.d}")
if [[ -n $PHP74_POOL_DIR && -d $PHP74_POOL_DIR && $PHP74_POOL_DIR == */php74/* ]]; then
    POOL_DIR=${PHP74_POOL_DIR%/php74/*}/php85/php-fpm2.d
    ok "php74's pools are in $PHP74_POOL_DIR on the host; the 8.5 pools go next to them: $POOL_DIR (POOL_DIR)"
else
    PHP74_POOL_DIR=
    POOL_DIR=/var/lib/php85-sidecar/pools
    warn "php74's pool files are inside $old, not on a volume: scripts/pool-add.sh reads them through docker exec, and the 8.5 pools are kept in $POOL_DIR on each server"
fi
ag=$(ex getent group apache | cut -d: -f3)
[[ -z $ag || $ag == 48 ]] || warn "group apache is $ag in $old; in the image it is 48"
vh=$(ex sh -c 'grep -lE "^[[:space:]]*ProxyPassMatch[[:space:]].*fcgi://127\.0\.0\.1:74(0[1-9]|1[0-9])/" /etc/httpd/conf2.d/*.conf /etc/httpd/conf.d/*.conf' | wc -l)
if [[ $vh -gt 0 ]]; then ok "$vh vhost file(s) send PHP to 127.0.0.1:7401-7419 with ProxyPassMatch, the form scripts/vhost-add-include.sh edits"
elif [[ ${#movable[@]} -gt 0 ]]; then warn "no vhost sends PHP to 127.0.0.1:74NN with ProxyPassMatch: scripts/vhost-add-include.sh and scripts/site-inc.sh will not fit these vhosts"; fi

# --- the values for .env
envlines() {
    echo "IMAGE=${IMAGE:-<the image tag you pulled or loaded>}"
    echo "BIND_IP=$BIND_IP"
    echo "WWW_DIR=${WWW_DIR:-<host directory mounted at /var/www>}"
    echo "PHP74_LIB_DIR=$PHP74_LIB_DIR"
    echo "POOL_DIR=$POOL_DIR"
    echo "LOG_DIR=${LOG_DIR:-/var/log/php85-sidecar}"
    echo "# Read by scripts/*.sh, not by compose: the old container, and where its php74 pools and vhosts are on this host"
    echo "# (empty: they are inside the container, not on a volume)."
    echo "OLD_CONTAINER=$old"
    echo "PHP74_POOL_DIR=$PHP74_POOL_DIR"
    echo "VHOST_DIR=$vhost_host"
}
if [[ $fails -eq 0 ]]; then
    if [[ $envonly == 1 ]]; then envlines >&3
    else echo "      .env for this host (IMAGE=<image tag> scripts/preflight.sh --env > .env writes it):"; envlines | sed 's/^/        /'; fi
fi
[[ $deployed == 0 ]] || info "php85-sidecar is deployed here already; nothing to deploy"
finish
