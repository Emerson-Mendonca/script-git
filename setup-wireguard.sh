#!/bin/bash

# === VARIÁVEIS BÁSICAS ===
WG_INTERFACE="wg0"
SERVER_PORT=51820
VPN_SUBNET="10.10.0.0/24"
SERVER_IP="10.10.0.1"
CLIENT_IP="10.10.0.2"
WG_DIR="/etc/wireguard"
EASY_PANEL_PORT=3000

# === INSTALAÇÃO ===
echo "[1/6] Instalando WireGuard..."
apt update && apt install -y wireguard ufw

echo "[2/6] Gerando chaves..."
cd $WG_DIR
umask 077
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)
CLIENT_PRIVATE_KEY=$(cat client_private.key)
CLIENT_PUBLIC_KEY=$(cat client_public.key)

# === CONFIGURAR SERVIDOR ===
echo "[3/6] Criando wg0.conf..."
cat > $WG_DIR/$WG_INTERFACE.conf <<EOF
[Interface]
Address = $SERVER_IP/24
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIVATE_KEY
PostUp = ufw route allow in on $WG_INTERFACE out on eth0; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = ufw route delete allow in on $WG_INTERFACE out on eth0; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# === HABILITAR IP FORWARDING ===
echo "[4/6] Habilitando IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf

# === INICIAR WIREGUARD ===
echo "[5/6] Iniciando WireGuard..."
wg-quick down $WG_INTERFACE 2>/dev/null
wg-quick up $WG_INTERFACE
systemctl enable wg-quick@$WG_INTERFACE

# === FIREWALL ===
echo "[6/6] Configurando UFW..."
ufw allow $SERVER_PORT/udp
ufw allow from $VPN_SUBNET to any port $EASY_PANEL_PORT proto tcp
ufw deny $EASY_PANEL_PORT/tcp
ufw enable

# === GERAR CONFIG DO CLIENTE ===
echo "Gerando arquivo de configuração do cliente..."
CLIENT_CONF_PATH="$WG_DIR/client.conf"

cat > $CLIENT_CONF_PATH <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $(curl -s ifconfig.me):$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "======================================"
echo "✅ VPN configurada com sucesso!"
echo "📄 Arquivo de configuração do cliente salvo em:"
echo "   $CLIENT_CONF_PATH"
echo "💡 Use esse arquivo no app WireGuard para conectar."
echo "======================================"
