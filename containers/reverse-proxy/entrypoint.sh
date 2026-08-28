#!/bin/sh
# Substitui __SUBOT_DOMAIN__ no template pelo domínio real (SUBOT_DOMAIN em .env) e sobe o Apache.
set -eu

: "${SUBOT_DOMAIN:?defina SUBOT_DOMAIN em .env}"

sed "s/__SUBOT_DOMAIN__/${SUBOT_DOMAIN}/g" \
    /usr/local/apache2/conf/httpd.conf.template > /usr/local/apache2/conf/httpd.conf

exec httpd-foreground
