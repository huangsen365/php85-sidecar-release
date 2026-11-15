#!/usr/bin/env bash
# Read-only. Compiles every .php file of a code directory with PHP 8.5 in the sidecar, then rechecks each failure with
# the old container's php74:  NEW-8.5 = breaks only on 8.5 (to fix before the switch), also-7.4 = broken already.
# Lint finds compile errors only (for example $s{0}); removed functions and changed behaviour show up at run time.
# It prints file names and messages, no code.
# usage: scripts/lint-compare.sh <directory under /var/www>       e.g. www.example.com/www
#        EXCLUDE='./runtime/*' (default) names paths to skip, as find -path patterns separated by spaces
set -uo pipefail
. "$(dirname "$0")/lib.sh"
code=${1:-}
[[ -n $code && $code != /* && $code != *..* ]] || die "usage: $0 <directory under /var/www>"
need_old; need_sidecar
docker exec "$SC" test -d "/var/www/$code" < /dev/null || die "no /var/www/$code in $SC"
skip=()
set -f
for p in ${EXCLUDE-./runtime/*}; do skip+=(-not -path "$p"); done
set +f
F=$(mktemp); R=$(mktemp); trap 'rm -f "$F" "$R"' EXIT
docker exec -w "/var/www/$code" "$SC" find . -name '*.php' ${skip[@]+"${skip[@]}"} -print0 < /dev/null \
    | docker exec -i -w "/var/www/$code" "$SC" xargs -0 -r -n 100 -P 4 sh -c \
        'for f; do php -n -l "$f" > /tmp/lint.$$ 2>&1 || printf "%s: %s\n" "$f" "$(grep -m1 -i error /tmp/lint.$$)"; done; rm -f /tmp/lint.$$' _ > "$F" 2>&1
total=$(docker exec -w "/var/www/$code" "$SC" find . -name '*.php' ${skip[@]+"${skip[@]}"} < /dev/null | wc -l)
while IFS= read -r line; do
    [[ -n $line ]] || continue
    f=${line%%: *}
    if docker exec -w "/var/www/$code" "$OLD" /opt/remi/php74/root/usr/bin/php -n -l "$f" > /dev/null 2>&1 < /dev/null; then tag=NEW-8.5
    else tag=also-7.4; fi
    echo "$tag  $(sed -E 's/ in \.\/.* on line / line /' <<< "$line" | cut -c1-200)"
done < "$F" > "$R"
sort "$R"
echo "$total .php files under /var/www/$code: $(grep -c '^NEW-8.5' "$R" || true) break only on 8.5, $(grep -c '^also-7.4' "$R" || true) are broken on php74 too"
echo "RESULT: OK"
