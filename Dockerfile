FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk upgrade --no-cache && apk add --no-cache \
      ca-certificates gettext-envsubst nginx nginx-mod-http-naxsi openssl && \
    addgroup -g 1000 hofnginx && adduser -D -H -u 1000 -G hofnginx hofnginx && \
    mkdir -p /etc/keys /etc/nginx/naxsi.d /var/lib/nginx/runtime \
      /var/lib/nginx/tmp/client_body /var/lib/nginx/tmp/proxy \
      /var/lib/nginx/tmp/fastcgi /var/lib/nginx/tmp/uwsgi /var/lib/nginx/tmp/scgi \
      /run/nginx && \
    chown -R hofnginx:hofnginx /etc/keys /var/lib/nginx /run/nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY server.conf.template /etc/nginx/server.conf.template
COPY html/ /usr/share/nginx/html/
COPY entrypoint.sh /entrypoint.sh
COPY licenses/ /usr/share/licenses/hof-nginx/
RUN chmod +x /entrypoint.sh

USER 1000
EXPOSE 10080 10443
ENTRYPOINT ["/entrypoint.sh"]
