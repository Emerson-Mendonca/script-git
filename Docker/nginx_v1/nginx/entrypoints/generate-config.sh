#!/bin/bash
set -e

# Variáveis esperadas:
#   BACKENDS e POSTGRES_SERVICE

# Onde estão seus templates?
TEMPLATE_DIR=/etc/nginx/templates

# Onde escrever as configs
NGINX_CONF_OUT=/etc/nginx/nginx.conf
HTTP_OUT=/etc/nginx/conf.d/http
STREAM_OUT=/etc/nginx/conf.d/stream

# Garante que as pastas existam
mkdir -p "$HTTP_OUT" "$STREAM_OUT"

# Add hosts to /etc/hosts for local DNS resolution as a fallback
echo "Adding hosts to /etc/hosts as a fallback..."

# Parse BACKENDS and add them to /etc/hosts
for svc in $BACKENDS; do
  name=${svc%%:*}
  port=${svc##*:}
  
  # Try to resolve using Docker DNS
  if getent hosts $name > /dev/null; then
    ip=$(getent hosts $name | awk '{ print $1 }')
    echo "Resolved $name to $ip, adding to /etc/hosts"
    echo "$ip $name" >> /etc/hosts
  else
    echo "Could not resolve $name, will rely on runtime DNS resolution"
  fi
done

# Parse POSTGRES_SERVICE and add to /etc/hosts
pg_host=${POSTGRES_SERVICE%%:*}
pg_port=${POSTGRES_SERVICE##*:}

if getent hosts $pg_host > /dev/null; then
  pg_ip=$(getent hosts $pg_host | awk '{ print $1 }')
  echo "Resolved $pg_host to $pg_ip, adding to /etc/hosts"
  echo "$pg_ip $pg_host" >> /etc/hosts
else
  echo "Could not resolve $pg_host, will rely on runtime DNS resolution"
fi

# 1) Gera o nginx.conf principal
echo "Generating main nginx.conf..."
envsubst < "$TEMPLATE_DIR/nginx.conf.tmpl" > "$NGINX_CONF_OUT"

# 2) Gera cada HTTP .conf
echo "Generating HTTP configurations..."
for svc in $BACKENDS; do
  name=${svc%%:*}
  port=${svc##*:}
  echo "Generating config for $name:$port"
  sed "s/{{name}}/$name/g; s/{{port}}/$port/g" \
      "$TEMPLATE_DIR/http.tmpl" \
    > "$HTTP_OUT/${name}.conf"
done

# 3) Gera o stream .conf (Postgres)
echo "Generating PostgreSQL stream configuration..."
host=${POSTGRES_SERVICE%%:*}
port=${POSTGRES_SERVICE##*:}
sed "s/{{host}}/$host/g; s/{{port}}/$port/g" \
    "$TEMPLATE_DIR/stream.tmpl" \
  > "$STREAM_OUT/postgres.conf"

# Create a fallback index.html
mkdir -p /usr/share/nginx/html
cat > /usr/share/nginx/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>NGINX Proxy</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
        h1 { color: #336699; }
    </style>
</head>
<body>
    <h1>NGINX Proxy is Running</h1>
    <p>Available services:</p>
    <ul>
        <li><a href="/app_service/">App Service 1</a></li>
        <li><a href="/app_service_2/">App Service 2</a></li>
    </ul>
    <p>Generated on: $(date)</p>
</body>
</html>
EOF

# Create a default server configuration
cat > "$HTTP_OUT/default.conf" << EOF

server {
    listen 80 default_server;
    server_name _;
    
    # Root location
    location = / {
        root /usr/share/nginx/html;
        index index.html;
    }
    
    # Health check endpoint
    location = /health {
        access_log off;
        return 200 "NGINX Proxy is running\n";
    }
    
    # Detailed health status
    location = /status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }
    
    # Show error page for unmatched locations
    location / {
        return 404 "Service not found\n";
    }
}
EOF

# Check configuration before starting
echo "Checking NGINX configuration..."
nginx -t || {
  echo "NGINX configuration test failed. Using fallback configuration."
  
  # If config test failed, create a minimal working config
  cat > "$NGINX_CONF_OUT" << EOF
user  nginx;
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
  worker_connections 1024;
}

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  
  server {
    listen 80 default_server;
    server_name _;
    
    location / {
      root /usr/share/nginx/html;
      index index.html;
    }
  }
}
EOF

  # Clean up the failed configs
  rm -f "$HTTP_OUT"/*.conf "$STREAM_OUT"/*.conf
  
  # Create a basic index.html
  cat > /usr/share/nginx/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>NGINX Fallback Page</title>
</head>
<body>
    <h1>NGINX Fallback Configuration</h1>
    <p>The main configuration failed to load. This is a fallback configuration.</p>
    <p>Please check the logs for more information.</p>
</body>
</html>
EOF
}

# 4) Inicia o nginx
echo "Starting NGINX..."
exec nginx -g 'daemon off;'