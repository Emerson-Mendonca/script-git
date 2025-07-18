FROM nginx:stable-alpine

RUN apk add --no-cache bash gettext curl

RUN mkdir -p /etc/nginx/templates \
             /etc/nginx/conf.d/http \
             /etc/nginx/conf.d/stream

COPY templates/ /etc/nginx/templates/
COPY entrypoints/generate-config.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/generate-config.sh

ENTRYPOINT ["/usr/local/bin/generate-config.sh"]