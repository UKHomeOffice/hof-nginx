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

if env | grep -qE '^(NAXSI_RULES_URL_CSV|NAXSI_RULES_MD5_CSV|CLIENT_CERT_REQUIRED|USE_UPSTREAM_CLIENT_CERT|VERIFY_SERVER_CERT|BASIC_AUTH|CUSTOM_PROXY_CONFIG|ADD_NGINX_(LOCATION|HTTP)_CFG|CONCURRENT_CONNS_PER_IP|LOCATIONS_CSV|LOAD_BALANCER_CIDR|ERROR_REDIRECT_CODES|SSL_PROTOCOLS|SSL_CIPHERS|PORT_IN_HOST_HEADER|ENABLE_UUID_PARAM)(_[0-9]+)?=.+$' ||
   env | grep -qE '^ADD_NGINX_SERVER_CFG_[0-9]+=.+$' ||
   env | grep -qE '^REQS_PER_MIN_PER_IP_[0-9]+=.+$' ||
   env | grep -qE '^(PROXY_SERVICE_HOST|PROXY_SERVICE_PORT|EXTRA_NAXSI_RULES)_[0-9]+=.+$' ||
   env | grep -qE '^NAXSI_USE_DEFAULT_RULES(_[0-9]+)?=FALSE$'; then
    fail "A legacy proxy setting is not supported by this image; review the migration documentation."
fi

: "${PROXY_SERVICE_HOST:?PROXY_SERVICE_HOST is required}"
: "${PROXY_SERVICE_PORT:?PROXY_SERVICE_PORT is required}"

for asset in /public/css/app.css /public/images/govuk-logo.svg; do
    [ -f "$asset" ] && [ -r "$asset" ] && [ -s "$asset" ] ||
        fail "Required shared asset $asset must be a non-empty file readable by UID 1000."
done

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
RATE_LIMIT_ENABLED=${RATE_LIMIT_ENABLED:-FALSE}
REQS_PER_MIN_PER_IP=${REQS_PER_MIN_PER_IP:-60}
RATE_LIMIT_BURST=${RATE_LIMIT_BURST:-20}
TRUSTED_PROXY_CIDRS=${TRUSTED_PROXY_CIDRS:-}
validate_port PROXY_SERVICE_PORT "$PROXY_SERVICE_PORT"
validate_port HTTP_LISTEN_PORT "$HTTP_LISTEN_PORT"
validate_port HTTPS_LISTEN_PORT "$HTTPS_LISTEN_PORT"

: > /var/lib/nginx/runtime/real-ip.conf
if [ -n "$TRUSTED_PROXY_CIDRS" ]; then
    case "$TRUSTED_PROXY_CIDRS" in
        *[!0-9a-fA-F:.,/]*) fail "TRUSTED_PROXY_CIDRS must be a comma-separated list of IP addresses or CIDRs." ;;
    esac
    printf '%s\n' "$TRUSTED_PROXY_CIDRS" |
        grep -Eq '^(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9a-fA-F:]*:[0-9a-fA-F:.]*)(/[0-9]{1,3})?)(,([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9a-fA-F:]*:[0-9a-fA-F:.]*)(/[0-9]{1,3})?)*$' ||
        fail "TRUSTED_PROXY_CIDRS must be a comma-separated list of IP addresses or CIDRs."
    printf '%s\n' "$TRUSTED_PROXY_CIDRS" | tr ',' '\n' |
        while IFS= read -r proxy; do
            printf 'set_real_ip_from %s;\n' "$proxy"
        done > /var/lib/nginx/runtime/real-ip.conf
    printf 'real_ip_header X-Forwarded-For;\nreal_ip_recursive on;\n' \
        >> /var/lib/nginx/runtime/real-ip.conf
fi

ACCESS_LOG_FORMAT=${ACCESS_LOG_FORMAT:-combined}
case "$ACCESS_LOG_FORMAT" in
    combined|extended_text|extended_json) ;;
    *) fail "ACCESS_LOG_FORMAT must be combined, extended_text or extended_json." ;;
esac
TEXT_BODY_LOG=
JSON_BODY_LOG=
case "${LOG_REQUEST_BODY:-FALSE}" in
    TRUE)
        [ "$ACCESS_LOG_FORMAT" != combined ] ||
            fail "LOG_REQUEST_BODY=TRUE requires ACCESS_LOG_FORMAT=extended_text or extended_json."
        echo "WARNING: Request-body logging can expose sensitive data." >&2
        TEXT_BODY_LOG="' \"\$request_body\"'"
        JSON_BODY_LOG="', \"request_body\": \"\$request_body\"'"
        ;;
    FALSE) ;;
    *) fail "LOG_REQUEST_BODY must be TRUE or FALSE." ;;
esac
export ACCESS_LOG_FORMAT TEXT_BODY_LOG JSON_BODY_LOG
envsubst '${ACCESS_LOG_FORMAT} ${TEXT_BODY_LOG} ${JSON_BODY_LOG}' \
    < /etc/nginx/logging.conf.template > /var/lib/nginx/runtime/logging.conf

case "${GZIP_ENABLED:-FALSE}" in
    TRUE) printf 'gzip on;\n' > /var/lib/nginx/runtime/gzip.conf ;;
    FALSE) printf 'gzip off;\n' > /var/lib/nginx/runtime/gzip.conf ;;
    *) fail "GZIP_ENABLED must be TRUE or FALSE." ;;
esac

VERBOSE_ERROR_PAGES=${VERBOSE_ERROR_PAGES:-FALSE}
case "$VERBOSE_ERROR_PAGES" in
    TRUE|FALSE) ;;
    *) fail "VERBOSE_ERROR_PAGES must be TRUE or FALSE." ;;
esac
FEEDBACK_EMAIL=${FEEDBACK_EMAIL:-}
if [ -n "$FEEDBACK_EMAIL" ]; then
    printf '%s\n' "$FEEDBACK_EMAIL" | grep -Eq '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$' ||
        fail "FEEDBACK_EMAIL must be a simple email address."
fi
validate_positive_integer() {
    case "$2" in
        ''|*[!0-9]*) fail "$1 must be an integer between 1 and 2147483647." ;;
    esac
    [ "${#2}" -le 10 ] && [ "$2" -ge 1 ] && [ "$2" -le 2147483647 ] ||
        fail "$1 must be an integer between 1 and 2147483647."
}

validate_nonnegative_integer() {
    case "$2" in
        ''|*[!0-9]*) fail "$1 must be an integer between 0 and 2147483647." ;;
    esac
    [ "${#2}" -le 10 ] && [ "$2" -le 2147483647 ] ||
        fail "$1 must be an integer between 0 and 2147483647."
}

validate_positive_integer REQS_PER_MIN_PER_IP "$REQS_PER_MIN_PER_IP"
validate_nonnegative_integer RATE_LIMIT_BURST "$RATE_LIMIT_BURST"

case "$RATE_LIMIT_ENABLED" in
    TRUE)
        printf 'limit_req_zone $binary_remote_addr zone=per_ip:10m rate=%sr/m;\n' \
            "$REQS_PER_MIN_PER_IP" > /var/lib/nginx/runtime/rate-limit.conf
        if [ "$RATE_LIMIT_BURST" -eq 0 ]; then
            printf 'limit_req zone=per_ip;\nlimit_req_status 429;\n' \
                > /var/lib/nginx/runtime/rate-limit-location.conf
        else
            printf 'limit_req zone=per_ip burst=%s;\nlimit_req_status 429;\n' \
                "$RATE_LIMIT_BURST" > /var/lib/nginx/runtime/rate-limit-location.conf
        fi
        ;;
    FALSE)
        : > /var/lib/nginx/runtime/rate-limit.conf
        : > /var/lib/nginx/runtime/rate-limit-location.conf
        ;;
    *) fail "RATE_LIMIT_ENABLED must be TRUE or FALSE." ;;
esac

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
printf '%s\n' "${ADD_NGINX_SERVER_CFG:-}" > /var/lib/nginx/runtime/extra-server.conf
UPSTREAM_URL="$scheme://$host:$PROXY_SERVICE_PORT"
export HTTP_LISTEN_PORT HTTPS_LISTEN_PORT SERVER_CERT SERVER_KEY NAME_RESOLVER UPSTREAM_URL VERBOSE_ERROR_PAGES FEEDBACK_EMAIL
envsubst '${HTTP_LISTEN_PORT} ${HTTPS_LISTEN_PORT} ${SERVER_CERT} ${SERVER_KEY} ${NAME_RESOLVER} ${UPSTREAM_URL} ${VERBOSE_ERROR_PAGES} ${FEEDBACK_EMAIL}' \
    < /etc/nginx/server.conf.template > /var/lib/nginx/runtime/server.conf

nginx -e /dev/stderr -t
exec nginx -e /dev/stderr -g 'daemon off;'
