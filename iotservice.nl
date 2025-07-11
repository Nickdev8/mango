# /etc/nginx/sites-available/iotservice.nl

# ── HTTP: redirect all to HTTPS ─────────────────────────────────────────────
server {
    listen      80 default_server;
    server_name iotservice.nl www.iotservice.nl;
    return      301 https://$host$request_uri;
}

# ── HTTPS: serve client & proxy Socket.io ────────────────────────────────────
server {
    listen       443 ssl http2 default_server;
    server_name  iotservice.nl www.iotservice.nl;

    ssl_certificate     /etc/letsencrypt/live/iotservice.nl/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/iotservice.nl/privkey.pem;

    root   /var/www/escape-room-client;
    index  index.html;

    # 1) Svelte SPA
    location / {
      try_files $uri $uri/ /index.html;
    }

    # 2) Socket.io WebSockets & HTTP polling → Game Server on 3080
    location /socket.io/ {
        proxy_pass             http://127.0.0.1:3080/socket.io/;
        proxy_http_version     1.1;
        proxy_set_header       Upgrade $http_upgrade;
        proxy_set_header       Connection "Upgrade";
        proxy_set_header       Host $host;
        proxy_set_header       X-Real-IP $remote_addr;
        proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 3) Physics Server API endpoints → Game Server on 3080
    location /api/ {
        proxy_pass             http://127.0.0.1:3080/api/;
        proxy_http_version     1.1;
        proxy_set_header       Host $host;
        proxy_set_header       X-Real-IP $remote_addr;
        proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header       X-Forwarded-Proto $scheme;
    }

    # 4) Physics Server health check → Game Server on 3080
    location /health {
        proxy_pass             http://127.0.0.1:3080/health;
        proxy_http_version     1.1;
        proxy_set_header       Host $host;
        proxy_set_header       X-Real-IP $remote_addr;
        proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header       X-Forwarded-Proto $scheme;
    }

    # 5) Lobby Server API → Lobby Server on 3081
    location /lobby/ {
        proxy_pass             http://127.0.0.1:3081/;
        proxy_http_version     1.1;
        proxy_set_header       Host $host;
        proxy_set_header       X-Real-IP $remote_addr;
        proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 6) Lobby Socket.io → Lobby Server on 3081
    location /lobby-socket.io/ {
        proxy_pass             http://127.0.0.1:3081/socket.io/;
        proxy_http_version     1.1;
        proxy_set_header       Upgrade $http_upgrade;
        proxy_set_header       Connection "Upgrade";
        proxy_set_header       Host $host;
        proxy_set_header       X-Real-IP $remote_addr;
        proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 7) Game Server WebSocket → Game Server on 3080 (for Godot)
    location /game-ws/ {
        proxy_pass             http://127.0.0.1:3080/;
        proxy_http_version     1.1;
        proxy_set_header       Upgrade $http_upgrade;
        proxy_set_header       Connection "Upgrade";
        proxy_set_header       Host $host;
        proxy_set_header       X-Real-IP $remote_addr;
        proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header       X-Forwarded-Proto $scheme;
    }

    # 8) Godot Game Files
    location /godot-game/ {
        alias /var/www/escape-room-client/godot-game/;
        try_files $uri $uri/ =404;
        
        # Add CORS headers for Godot
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
        add_header Access-Control-Allow-Headers "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range";
    }
}