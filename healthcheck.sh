#!/bin/sh
set -eu

HTTPS_LISTEN_PORT=${HTTPS_LISTEN_PORT:-10443}
NGINX_RELOAD_INTERVAL=${NGINX_RELOAD_INTERVAL:-43200}
reload_file=/run/nginx/nginx_reload.txt

case "$NGINX_RELOAD_INTERVAL" in
    ''|*[!0-9]*) echo "ERROR: NGINX_RELOAD_INTERVAL must be a non-negative integer." >&2; exit 1 ;;
esac
if [ "${#NGINX_RELOAD_INTERVAL}" -gt 9 ]; then
    echo "ERROR: NGINX_RELOAD_INTERVAL must be at most 999999999 seconds." >&2
    exit 1
fi
if [ "$NGINX_RELOAD_INTERVAL" -lt 300 ]; then
    NGINX_RELOAD_INTERVAL=300
fi

if [ ! -f "$reload_file" ]; then
    touch "$reload_file"
fi
now=$(date +%s)
last_reload=$(stat -c %Y "$reload_file")
if [ "$((now - last_reload))" -gt "$NGINX_RELOAD_INTERVAL" ]; then
    echo "Validating and reloading NGINX."
    nginx -e /dev/stderr -t
    nginx -e /dev/stderr -s reload
    touch "$reload_file"
fi

status=$(curl --head --silent --show-error --insecure --ipv4 --noproxy '*' --max-time 5 \
    --output /dev/null --write-out '%{http_code}' \
    "https://localhost:$HTTPS_LISTEN_PORT/ping")
if [ "$status" != 200 ]; then
    echo "ERROR: NGINX health check returned HTTP $status." >&2
    exit 1
fi
echo "NGINX health check passed."
