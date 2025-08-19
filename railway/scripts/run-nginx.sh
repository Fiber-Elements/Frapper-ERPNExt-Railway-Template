#!/usr/bin/env bash
set -euo pipefail

BACKEND=${BACKEND:-127.0.0.1:8000}
SOCKETIO=${SOCKETIO:-127.0.0.1:9000}
PROXY_READ_TIMEOUT=${PROXY_READ_TIMEOUT:-120}
CLIENT_MAX_BODY_SIZE=${CLIENT_MAX_BODY_SIZE:-50m}
FRAPPE_SITE_NAME_HEADER=${FRAPPE_SITE_NAME_HEADER:-}

SITE_HEADER_DIRECTIVE="proxy_set_header X-Frappe-Site-Name $host;"
if [[ -n "$FRAPPE_SITE_NAME_HEADER" ]]; then
  SITE_HEADER_DIRECTIVE="proxy_set_header X-Frappe-Site-Name $FRAPPE_SITE_NAME_HEADER;"
fi

cat > /etc/nginx/nginx.conf <<NGINX
worker_processes auto;
error_log /dev/stderr info;
pid /var/run/nginx.pid;

events { worker_connections 1024; }

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  sendfile      on;
  tcp_nopush    on;
  tcp_nodelay   on;
  keepalive_timeout  65;
  client_max_body_size ${CLIENT_MAX_BODY_SIZE};

  map $http_upgrade $connection_upgrade { default upgrade; '' close; }

  server {
    listen 8080;

    # Static assets
    location /assets/ {
      alias /home/frappe/frappe-bench/sites/assets/;
      expires 30d;
      add_header Cache-Control "public, max-age=2592000, immutable";
      try_files $uri =404;
    }

    # Websocket
    location /socket.io/ {
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header Host $http_host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_read_timeout ${PROXY_READ_TIMEOUT}s;
      proxy_pass http://${SOCKETIO};
    }

    # Backend
    location / {
      proxy_set_header Host $http_host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      ${SITE_HEADER_DIRECTIVE}
      proxy_read_timeout ${PROXY_READ_TIMEOUT}s;
      proxy_pass http://${BACKEND};
    }
  }
}
NGINX

exec nginx -g 'daemon off;'
