# PHP 8.5 php-fpm sidecar for hosts whose main container is CentOS 7 (Remi tops out at php83 there).
# AlmaLinux 9 + Remi SCL php85, laid out like the old container (/opt/remi/php85, /etc/opt/remi/php85).
FROM almalinux:9

ARG MIRROR=https://mirrors.aliyun.com
# Remi signs EL9 with its 2021 key (B19527F1478F8947); the mirror does not carry the key files.
ARG REMI_GPG=https://rpms.remirepo.net/RPM-GPG-KEY-remi2021

COPY packages.txt /tmp/packages.txt

RUN set -eux; \
    sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
        -e "s|^# *baseurl=https://repo.almalinux.org/almalinux|baseurl=${MIRROR}/almalinux|" /etc/yum.repos.d/almalinux-*.repo; \
    dnf -y -q install epel-release dnf-plugins-core; \
    sed -i -e 's|^metalink=|#metalink=|' \
        -e "s|^#baseurl=https://download.example/pub/epel|baseurl=${MIRROR}/epel|" /etc/yum.repos.d/epel*.repo; \
    dnf config-manager --set-enabled crb; \
    rpm --import "${REMI_GPG}"; \
    curl -fsSL -o /tmp/remi-release.rpm "${MIRROR}/remi/enterprise/remi-release-9.rpm"; \
    rpm -K /tmp/remi-release.rpm; \
    dnf -y -q install /tmp/remi-release.rpm; rm -f /tmp/remi-release.rpm; \
    sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
        -e "s|^#baseurl=http://rpms.remirepo.net|baseurl=${MIRROR}/remi|" /etc/yum.repos.d/remi*.repo; \
    dnf -y -q --setopt=install_weak_deps=False --nodocs install $(grep -vE '^\s*(#|$)' /tmp/packages.txt); \
    dnf clean all; rm -rf /var/cache/dnf /tmp/packages.txt

# php-fpm already created apache (48); sshuser mirrors the old container (1000, also in apache).
RUN set -eux; \
    test "$(getent group apache | cut -d: -f3)" = 48; \
    groupadd -g 1000 sshuser; \
    useradd -u 1000 -g sshuser -G apache -M -d /home/sshuser -s /sbin/nologin sshuser; \
    rm -f /etc/opt/remi/php85/php-fpm.d/*.conf; \
    install -d -o sshuser -g sshuser /var/opt/remi/php85/log/php-fpm /etc/opt/remi/php85/php-fpm2.d; \
    install -d /var/opt/remi/php74/lib/php /var/www

COPY conf/php-fpm.conf /etc/opt/remi/php85/php-fpm.conf
COPY conf/www.conf /etc/opt/remi/php85/php-fpm.d/www.conf
COPY conf/99-sidecar.ini /etc/opt/remi/php85/php.d/99-sidecar.ini
COPY conf/selftest.php /opt/sidecar/selftest.php

# Composer for the 8.5 sites, run through conf/composer (CLI only; see there). Pinned and checked: bump both ARGs
# together from https://getcomposer.org/download/<version>/composer.phar.sha256sum.
ARG COMPOSER_VERSION=2.11.1
ARG COMPOSER_SHA256=6f1b891e1d4927d62740276c540fb490e47689e19e102c49e8da849794882f8c
COPY conf/composer /usr/local/bin/composer
COPY conf/composer-config.json /opt/sidecar/composer-home/config.json
RUN set -eux; \
    curl -fsSL -o /opt/sidecar/composer.phar "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar"; \
    echo "${COMPOSER_SHA256}  /opt/sidecar/composer.phar" | sha256sum -c -; \
    chmod 0644 /opt/sidecar/composer.phar /opt/sidecar/composer-home/config.json; \
    chmod 0755 /usr/local/bin/composer; \
    printf 'Deny from all\n' > /opt/sidecar/composer-home/.htaccess

ENV PATH=/opt/remi/php85/root/usr/bin:/opt/remi/php85/root/usr/sbin:$PATH \
    TZ=Asia/Shanghai

# The master runs as sshuser too, so pools need no user/group lines and nothing in the container is root.
USER sshuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD REQUEST_METHOD=GET SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping \
        cgi-fcgi -bind -connect 127.0.0.1:8500 | grep -q pong

CMD ["php-fpm", "-F", "-y", "/etc/opt/remi/php85/php-fpm.conf"]
