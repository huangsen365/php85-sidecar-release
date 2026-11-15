# The old container for tests/e2e.sh: CentOS 7 httpd 2.4.6 (the servers this was made for run httpd-2.4.6-99),
# conf.d per server, then conf2.d (shared storage on the servers) included last, as there. The pool user sshuser is
# 1000:1000 and in group apache. There is no php74 here: a stub answers for its CLI, and a forwarder listens where
# the site's php74 pool would (127.0.0.1:7401) and passes requests to OLD_POOL, the sidecar's www pool.
FROM centos:7
ARG MIRROR=https://mirrors.aliyun.com/centos-vault/7.9.2009
RUN set -eux; \
    sed -i -e 's/^mirrorlist=/#mirrorlist=/' \
        -e "s|^#baseurl=http://mirror.centos.org/centos/\$releasever|baseurl=${MIRROR}|" /etc/yum.repos.d/CentOS-Base.repo; \
    yum -y -q install httpd socat; \
    yum clean all; rm -rf /var/cache/yum; \
    rm -f /etc/httpd/conf.d/welcome.conf; \
    mkdir -p /etc/httpd/conf2.d /opt/remi/php74/root/usr/bin; \
    echo 'IncludeOptional conf2.d/*.conf' >> /etc/httpd/conf/httpd.conf; \
    echo 'ServerName e2e.local' >> /etc/httpd/conf/httpd.conf; \
    groupadd -g 1000 sshuser; \
    useradd -u 1000 -g sshuser -G apache -M -s /sbin/nologin sshuser; \
    printf '%s\n' '#!/bin/sh' '# Stands in for php74: it reports version 7.4 and finds every file valid.' \
        'case "$*" in *PHP_VERSION*) printf 7.4.33 ;; esac' 'exit 0' > /opt/remi/php74/root/usr/bin/php; \
    chmod 755 /opt/remi/php74/root/usr/bin/php
ENV OLD_POOL=172.17.0.1:8500
CMD ["sh", "-c", "socat TCP-LISTEN:7401,bind=127.0.0.1,fork,reuseaddr TCP:$OLD_POOL & exec httpd -DFOREGROUND"]
