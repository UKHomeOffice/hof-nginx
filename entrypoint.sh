#!/bin/sh
set -eu

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

if env | grep -qE '^ALLOW_COUNTRY_CSV(_[0-9]+)?=.+' ||
   env | grep -qE '^DENY_COUNTRY_ON(_[0-9]+)?=TRUE$'; then
    fail "GeoIP country filtering is not supported; configure filtering elsewhere."
fi

if env | grep -qE '^(NAXSI_RULES_URL_CSV|NAXSI_RULES_MD5_CSV|CLIENT_CERT_REQUIRED|USE_UPSTREAM_CLIENT_CERT|VERIFY_SERVER_CERT|BASIC_AUTH|CUSTOM_PROXY_CONFIG|ADD_NGINX_(LOCATION|SERVER|HTTP)_CFG|REQS_PER_MIN_PER_IP|CONCURRENT_CONNS_PER_IP|LOCATIONS_CSV|LOAD_BALANCER_CIDR|ERROR_REDIRECT_CODES|SSL_PROTOCOLS|SSL_CIPHERS|PORT_IN_HOST_HEADER|ENABLE_UUID_PARAM)(_[0-9]+)?=.+$' ||
   env | grep -qE '^(PROXY_SERVICE_HOST|PROXY_SERVICE_PORT|EXTRA_NAXSI_RULES)_[0-9]+=.+$' ||
   env | grep -qE '^NAXSI_USE_DEFAULT_RULES(_[0-9]+)?=FALSE$'; then
    fail "A legacy proxy setting is not supported by this image; review the migration documentation."
fi

: "${PROXY_SERVICE_HOST:?PROXY_SERVICE_HOST is required}"
: "${PROXY_SERVICE_PORT:?PROXY_SERVICE_PORT is required}"

case "$PROXY_SERVICE_HOST" in
    http://*) scheme=http; host=${PROXY_SERVICE_HOST#http://} ;;
    https://*) scheme=https; host=${PROXY_SERVICE_HOST#https://} ;;
    *) scheme=http; host=$PROXY_SERVICE_HOST ;;
esac
printf '%s\n' "$host" | grep -Eq '^([a-zA-Z0-9][a-zA-Z0-9.-]*|\[[0-9a-fA-F:]+\])$' ||
    fail "PROXY_SERVICE_HOST must be a hostname or IP address, optionally preceded by http:// or https://."

validate_port() {
    case "$2" in
        ''|*[!0-9]*) fail "$1 must be a port number between 1 and 65535." ;;
    esac
    [ "${#2}" -le 5 ] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ] ||
        fail "$1 must be a port number between 1 and 65535."
}

HTTP_LISTEN_PORT=${HTTP_LISTEN_PORT:-10080}
HTTPS_LISTEN_PORT=${HTTPS_LISTEN_PORT:-10443}
validate_port PROXY_SERVICE_PORT "$PROXY_SERVICE_PORT"
validate_port HTTP_LISTEN_PORT "$HTTP_LISTEN_PORT"
validate_port HTTPS_LISTEN_PORT "$HTTPS_LISTEN_PORT"

if [ -z "${NAME_RESOLVER:-}" ]; then
    NAME_RESOLVER=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf)
    case "$NAME_RESOLVER" in *:*) NAME_RESOLVER="[$NAME_RESOLVER]" ;; esac
fi
printf '%s\n' "$NAME_RESOLVER" | grep -Eq '^([0-9.]+(:[0-9]+)?|\[[0-9a-fA-F:]+\](:[0-9]+)?)$' ||
    fail "NAME_RESOLVER must be an IP address, optionally with a port."

SERVER_CERT=${SERVER_CERT:-/etc/keys/crt}
SERVER_KEY=${SERVER_KEY:-/etc/keys/key}
for file in "$SERVER_CERT" "$SERVER_KEY"; do
    printf '%s\n' "$file" | grep -Eq '^/[a-zA-Z0-9_./-]+$' ||
        fail "Certificate paths must be absolute and contain only letters, digits, dot, underscore, slash or hyphen."
done
if [ "$SERVER_CERT" = /etc/keys/crt ] && [ "$SERVER_KEY" = /etc/keys/key ] &&
   [ ! -e "$SERVER_CERT" ] && [ ! -e "$SERVER_KEY" ]; then
    echo "Generating a self-signed test certificate; mount a real certificate for production." >&2
    umask 077
    openssl req -x509 -newkey rsa:2048 -keyout "$SERVER_KEY" -out "$SERVER_CERT" \
        -days 360 -nodes -subj '/CN=test' >/dev/null 2>&1
fi
[ -r "$SERVER_CERT" ] && [ -r "$SERVER_KEY" ] || fail "Server certificate and key must be readable by UID 1000."

case "${HTTPS_REDIRECT:-TRUE}" in
    TRUE)
        if [ -n "${HTTPS_REDIRECT_PORT:-}" ]; then
            validate_port HTTPS_REDIRECT_PORT "$HTTPS_REDIRECT_PORT"
            redirect_port=":$HTTPS_REDIRECT_PORT"
        else
            redirect_port=
        fi
        printf 'if ($scheme = http) { return 301 https://$host%s$request_uri; }\n' "$redirect_port" \
            > /var/lib/nginx/runtime/redirect.conf
        ;;
    FALSE) : > /var/lib/nginx/runtime/redirect.conf ;;
    *) fail "HTTPS_REDIRECT must be TRUE or FALSE." ;;
esac

printf '%s\n' "${EXTRA_NAXSI_RULES:-}" > /var/lib/nginx/runtime/extra-naxsi.rules
UPSTREAM_URL="$scheme://$host:$PROXY_SERVICE_PORT"
export HTTP_LISTEN_PORT HTTPS_LISTEN_PORT SERVER_CERT SERVER_KEY NAME_RESOLVER UPSTREAM_URL
envsubst '${HTTP_LISTEN_PORT} ${HTTPS_LISTEN_PORT} ${SERVER_CERT} ${SERVER_KEY} ${NAME_RESOLVER} ${UPSTREAM_URL}' \
    < /etc/nginx/server.conf.template > /var/lib/nginx/runtime/server.conf

nginx -e /dev/stderr -t
exec nginx -e /dev/stderr -g 'daemon off;'
