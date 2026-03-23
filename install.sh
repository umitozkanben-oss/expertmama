#!/bin/bash
set -e

echo "================================================"
echo " ExpertMAMA Cloud — Kurulum (Ubuntu 24)"
echo "================================================"

# 1. Sistem güncelle
echo "[1/8] Sistem güncelleniyor..."
apt-get update -qq && apt-get upgrade -y -qq

# 2. Bağımlılıklar
echo "[2/8] Paketler kuruluyor..."
apt-get install -y -qq python3 python3-pip python3-venv nginx git curl ufw

# 3. Proje klasörü
echo "[3/8] Proje ayarlanıyor..."
cd /opt/expertmama

# 4. Python venv
echo "[4/8] Python ortamı hazırlanıyor..."
python3 -m venv venv
source venv/bin/activate
pip install --quiet -r requirements.txt

# 5. Systemd servisi
echo "[5/8] Servis oluşturuluyor..."
cat > /etc/systemd/system/expertmama.service << 'EOF'
[Unit]
Description=ExpertMAMA Cloud API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/expertmama
ExecStart=/opt/expertmama/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8765 --workers 1
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 6. Nginx
echo "[6/8] Nginx ayarlanıyor..."
cat > /etc/nginx/sites-available/expertmama << 'EOF'
server {
    listen 80;
    server_name _;

    location /api/ {
        proxy_pass         http://127.0.0.1:8765/;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_read_timeout 30;
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Content-Type' always;
        if ($request_method = 'OPTIONS') { return 204; }
    }

    location / {
        root   /opt/expertmama/dashboard;
        index  index.html;
        try_files $uri $uri/ /index.html;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/expertmama /etc/nginx/sites-enabled/expertmama
nginx -t

# 7. Firewall
echo "[7/8] Güvenlik duvarı..."
ufw --force enable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 8765/tcp
ufw reload

# 8. Servisleri başlat
echo "[8/8] Servisler başlatılıyor..."
systemctl daemon-reload
systemctl enable expertmama
systemctl start  expertmama
systemctl enable nginx
systemctl restart nginx

VPS_IP=$(curl -s ifconfig.me)
echo ""
echo "================================================"
echo " KURULUM TAMAM!"
echo "================================================"
echo " Dashboard : http://${VPS_IP}"
echo " API       : http://${VPS_IP}:8765"
echo " MT5 IP    : ${VPS_IP}"
echo "================================================"
