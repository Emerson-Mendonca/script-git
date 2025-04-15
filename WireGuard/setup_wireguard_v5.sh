#!/bin/bash

# Script para configurar o WireGuard com configuração persistente, baseado na Wiki do Arch Linux
# Garante que portas listadas sejam acessíveis apenas via VPN e portas removidas sejam acessíveis externamente

# Funções para mensagens coloridas
print_message() {
    echo -e "\033[32m$1\033[0m"
}

print_error() {
    echo -e "\033[31m$1\033[0m"
}

print_warning() {
    echo -e "\033[33m$1\033[0m"
}

# Função para verificar e instalar dependências
check_and_install_dependencies() {
    print_message "Verificando dependências..."
    for cmd in wg iptables qrencode ip; do
        if ! command -v $cmd &> /dev/null; then
            print_message "$cmd não encontrado. Instalando..."
            sudo apt-get update
            if ! sudo apt-get install -y wireguard iptables qrencode iproute2; then
                print_error "Erro ao instalar dependências. Verifique sua conexão e permissões."
                exit 1
            fi
            break
        fi
    done
    print_message "Dependências instaladas."

    # Verifica se o módulo WireGuard está carregado
    if ! lsmod | grep -q wireguard; then
        print_message "Carregando módulo WireGuard..."
        if ! sudo modprobe wireguard; then
            print_error "Falha ao carregar o módulo WireGuard."
            exit 1
        fi
    fi
}

# Função para verificar a disponibilidade da porta
check_port() {
    local port=$1
    if sudo netstat -tuln | grep -q ":$port "; then
        print_error "A porta $port já está em uso. Escolha outra porta."
        exit 1
    fi
}

# Função para habilitar encaminhamento de IP
enable_ip_forwarding() {
    print_message "Habilitando encaminhamento de IP..."
    if ! sysctl -w net.ipv4.ip_forward=1; then
        print_error "Falha ao habilitar o encaminhamento de IP."
        exit 1
    fi
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
    sysctl -p
}

# Função para desativar gerenciamento de iptables pelo Docker
disable_docker_iptables() {
    if command -v docker &> /dev/null && systemctl is-active docker &> /dev/null; then
        print_message "Desativando gerenciamento de iptables pelo Docker..."
        echo '{"iptables": false}' | sudo tee /etc/docker/daemon.json
        sudo systemctl restart docker
        print_message "Docker reiniciado com iptables desativado."
    fi
}

# Função para limpar configurações antigas
cleanup_old_configs() {
    print_message "Limpando configurações antigas do WireGuard..."
    sudo systemctl stop wg-quick@wg0 2>/dev/null
    sudo systemctl disable wg-quick@wg0 2>/dev/null
    sudo ip link delete wg0 2>/dev/null
    sudo rm -f /etc/wireguard/wg0.conf /etc/wireguard/privatekey /etc/wireguard/publickey /etc/wireguard/allowed_ports.txt
    sudo rm -rf /root/wireguard-client
    sudo iptables -F
    sudo iptables -X
    sudo iptables -t nat -F
    sudo iptables -t nat -X
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT
    print_message "Configurações antigas limpas com sucesso."
}

# Função para configurar o firewall
setup_firewall() {
    print_message "Configurando regras do firewall..."
    
    # Define a política padrão como DROP para a cadeia INPUT
    sudo iptables -P INPUT DROP
    
    # Permite tráfego na interface wg0 para as portas configuradas
    if [ -f /etc/wireguard/allowed_ports.txt ]; then
        while read -r port; do </dev/tty
            sudo iptables -A INPUT -i wg0 -p tcp --dport "$port" -j ACCEPT
            sudo iptables -A INPUT -i wg0 -p udp --dport "$port" -j ACCEPT
        done < /etc/wireguard/allowed_ports.txt
    fi
    
    # Bloqueia as portas configuradas em interfaces não-wg0
    if [ -f /etc/wireguard/allowed_ports.txt ]; then
        while read -r port; do </dev/tty
            sudo iptables -A INPUT -p tcp --dport "$port" -i ! wg0 -j REJECT --reject-with tcp-reset
            sudo iptables -A INPUT -p udp --dport "$port" -i ! wg0 -j REJECT --reject-with icmp-port-unreachable
        done < /etc/wireguard/allowed_ports.txt
    fi
    
    # Permite tráfego estabelecido e relacionado
    sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Permite tráfego na interface de loopback
    sudo iptables -A INPUT -i lo -j ACCEPT
    
    # Permite tráfego WireGuard na porta 51820
    sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
    
    print_message "Regras do firewall configuradas."
}

# Função para reaplicar regras do firewall
reapply_firewall() {
    print_message "Reaplicando regras do firewall..."
    sudo iptables -F INPUT
    sudo iptables -X
    setup_firewall
}

# Função para configurar o WireGuard
setup_wireguard() {
    print_message "Configurando o WireGuard..."
    WG_CONFIG="/etc/wireguard/wg0.conf"
    CLIENT_DIR="/root/wireguard-client"
    CLIENT_CONFIG="$CLIENT_DIR/wg-client.conf"
    QRCODE_FILE="$CLIENT_DIR/qrcode.txt"
    WG_PORT="51820"
    
    # Cria diretório para configuração do cliente
    mkdir -p "$CLIENT_DIR"
    
    # Verifica se a configuração do servidor já existe
    if [ -f "$WG_CONFIG" ]; then
        print_warning "Configuração do WireGuard ($WG_CONFIG) já existe. Pulando criação."
        return
    fi

    mkdir -p /root/wireguard-client
    
    # Verifica a disponibilidade da porta
    check_port "$WG_PORT"
    
    # Gera chaves do servidor
    umask 077
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
    SERVER_PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
    SERVER_PUBLIC_KEY=$(cat /etc/wireguard/publickey)
    
    # Gera chaves do cliente
    wg genkey | tee "$CLIENT_DIR/client_privatekey" | wg pubkey > "$CLIENT_DIR/client_publickey"
    CLIENT_PRIVATE_KEY=$(cat "$CLIENT_DIR/client_privatekey")
    CLIENT_PUBLIC_KEY=$(cat "$CLIENT_DIR/client_publickey")
    
    # Obtém IP público do servidor
    SERVER_IP=$(curl -s ifconfig.me)
    if [ -z "$SERVER_IP" ]; then
        print_error "Não foi possível obter o IP público do servidor. Verifique sua conexão."
        exit 1
    fi
    
    # Identificar interface de rede principal
    MAIN_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
    if [ -z "$MAIN_INTERFACE" ]; then
        print_warning "Não foi possível identificar a interface de rede principal. Usando 'eth0'."
        MAIN_INTERFACE="eth0"
    fi
    print_message "Usando interface de rede: $MAIN_INTERFACE"
    
    # Cria arquivo de configuração do servidor (wg0.conf)
cat << EOF | sudo tee $WG_CONFIG
[Interface]
    PrivateKey = $SERVER_PRIVATE_KEY
    Address = 10.0.0.1/24
    ListenPort = $WG_PORT

    PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
    PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

[Peer]
    PublicKey = $CLIENT_PUBLIC_KEY
    AllowedIPs = 10.0.0.2/32
EOF

    # Habilitar forwarding de IP
    print_message "Habilitando encaminhamento de IP..."
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf  # Remove qualquer configuração existente
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    
    # Define permissões corretas
    sudo chmod 600 $WG_CONFIG /etc/wireguard/privatekey /etc/wireguard/publickey
    
    # Verifica se o arquivo do servidor foi criado
    if [ ! -f "$WG_CONFIG" ]; then
        print_error "Falha ao criar o arquivo de configuração do servidor ($WG_CONFIG)."
        exit 1
    fi
    print_message "Arquivo de configuração do servidor ($WG_CONFIG) criado com sucesso."
    cat $WG_CONFIG
    
# Cria arquivo de configuração do cliente (wg-client.conf)
cat << EOF | tee $CLIENT_CONFIG
[Interface]
    PrivateKey = $CLIENT_PRIVATE_KEY
    Address = 10.0.0.2/24
    DNS = 1.1.1.1

[Peer]
    PublicKey = $SERVER_PUBLIC_KEY
    Endpoint = ${SERVER_IP}:51820
    AllowedIPs = 10.0.0.0/24, ${SERVER_IP}/32
    PersistentKeepalive = 25
EOF
    
    # Define permissões corretas
    sudo chmod 600 $CLIENT_CONFIG
    
    sudo systemctl restart wg-quick@wg0.service
    
    # Verifica se o arquivo do cliente foi criado
    if [ ! -f "$CLIENT_CONFIG" ]; then
        print_error "Falha ao criar o arquivo de configuração do cliente ($CLIENT_CONFIG)."
        exit 1
    fi
    print_message "Arquivo de configuração do cliente ($CLIENT_CONFIG) criado com sucesso."
    cat $CLIENT_CONFIG
    
    # Gera QR code para configuração do cliente
    qrencode -t ansiutf8 < "$CLIENT_CONFIG" > "$QRCODE_FILE"
    if [ ! -f "$QRCODE_FILE" ] || [ ! -s "$QRCODE_FILE" ]; then
        print_warning "Falha ao criar o QR code, mas a configuração continua funcional."
    else
        print_message "QR code gerado em $QRCODE_FILE."
    fi
    
    # Valida o arquivo de configuração do servidor
    if ! wg showconf wg0 >/dev/null 2>&1; then
        print_error "Erro na validação do arquivo de configuração do servidor ($WG_CONFIG). Verifique o conteúdo."
        cat $WG_CONFIG
        exit 1
    fi
    
    # Ativa e inicia o serviço, conforme a Wiki do Arch
    sudo systemctl enable wg-quick@wg0
    if ! sudo systemctl start wg-quick@wg0; then
        print_error "Falha ao iniciar o serviço WireGuard. Verifique os logs com:"
        echo "  systemctl status wg-quick@wg0.service"
        echo "  journalctl -xeu wg-quick@wg0.service"
        cat $WG_CONFIG
        exit 1
    fi
    print_message "Serviço WireGuard iniciado com sucesso."
}

# Função para exibir o QR code
show_qrcode() {
    QRCODE_FILE="/root/wireguard-client/qrcode.txt"
    if [ -f "$QRCODE_FILE" ] && [ -s "$QRCODE_FILE" ]; then
        print_message "Exibindo QR code para configuração do cliente:"
        cat "$QRCODE_FILE"
        print_message "Escaneie o QR code acima com o aplicativo WireGuard em seu dispositivo."
    else
        print_error "Arquivo QR code ($QRCODE_FILE) não encontrado ou está vazio."
    fi
}

# Função para adicionar porta
add_port() {
    read -p "Digite a porta para adicionar (1-65535): " port </dev/tty
    if [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
        if ! grep -Fx "$port" /etc/wireguard/allowed_ports.txt > /dev/null; then
            echo "$port" >> /etc/wireguard/allowed_ports.txt
            reapply_firewall
            print_message "Porta $port adicionada com sucesso."
        else
            print_warning "Porta $port já está na lista."
        fi
    else
        print_error "Porta inválida. Deve ser um número entre 1 e 65535."
    fi
}

# Função para remover porta
remove_port() {
    read -p "Digite a porta para remover: " port
    if [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
        if grep -Fx "$port" /etc/wireguard/allowed_ports.txt > /dev/null; then
            grep -vFx "$port" /etc/wireguard/allowed_ports.txt > /tmp/allowed_ports.tmp
            mv /tmp/allowed_ports.tmp /etc/wireguard/allowed_ports.txt
            sudo iptables -D INPUT -i wg0 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            sudo iptables -D INPUT -i wg0 -p udp --dport "$port" -j ACCEPT 2>/dev/null
            sudo iptables -D INPUT -p tcp --dport "$port" -i ! wg0 -j REJECT --reject-with tcp-reset 2>/dev/null
            sudo iptables -D INPUT -p udp --dport "$port" -i ! wg0 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null
            sudo iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            sudo iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            print_message "Porta $port removida com sucesso e agora acessível externamente."
        else
            print_error "Porta $port não encontrada na lista."
        fi
    else
        print_error "Porta inválida. Deve ser um número entre 1 e 65535."
    fi
}

# Função para listar portas
list_ports() {
    print_message "Portas atualmente configuradas para VPN:"
    if [ -f /etc/wireguard/allowed_ports.txt ] && [ -s /etc/wireguard/allowed_ports.txt ]; then
        cat /etc/wireguard/allowed_ports.txt | sort -n
    else
        print_warning "Nenhuma porta configurada."
    fi
}

# Função para verificar status final
check_final_status() {
    print_message "Verificando status final dos serviços..."
    if ip a | grep -q wg0; then
        print_message "✅ Interface WireGuard (wg0) está ativa"
    else
        print_error "❌ Interface WireGuard (wg0) não está ativa"
    fi
    if ufw status | grep -q "Status: active"; then
        print_warning "⚠️ Firewall UFW está ativo. Desative o UFW para evitar conflitos com iptables."
        print_message "Use: sudo ufw disable"
    else
        print_message "✅ Firewall UFW está desativado"
    fi
}

# Função para exibir o menu
show_menu() {
    clear
    echo "=========================================="
    echo "    GERENCIADOR DE PORTAS VPN WIREGUARD"
    echo "=========================================="
    echo "1. Adicionar porta ao acesso exclusivo via VPN"
    echo "2. Remover porta do controle VPN (permite acesso externo)"
    echo "3. Listar portas controladas"
    echo "4. Exibir QR code do cliente"
    echo "5. Limpar configuração"
    echo "6. Sair"
    echo "=========================================="
}

# Função para exibir resumo final
show_summary() {
    SERVER_IP=$(curl -s ifconfig.me)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="SEU_IP_PÚBLICO"
        print_warning "Não foi possível obter o IP público. Substitua 'SEU_IP_PÚBLICO' no comando scp."
    fi
    echo ""
    echo "=============================================="
    echo "     CONFIGURAÇÃO WIREGUARD CONCLUÍDA!"
    echo "=============================================="
    echo ""
    print_message "Sua VPN WireGuard está configurada e pronta para uso!"
    echo ""
    print_message "Informações importantes:"
    echo "- IP da VPN: 10.0.0.1 (servidor) / 10.0.0.2 (cliente)"
    echo "- Arquivo de configuração do cliente: /root/wireguard-client/wg-client.conf"
    echo "- QR Code para configuração rápida: /root/wireguard-client/qrcode.txt"
    echo ""
    print_message "Para gerenciar portas com acesso exclusivo via VPN:"
    echo "Execute: /usr/local/bin/wireguard-port-manager"
    echo ""
    print_message "Para resolver problemas comuns:"
    echo "Execute: /usr/local/bin/check-wireguard-service"
    echo ""
    print_message "Para configurar seu cliente:"
    echo "1. Copie o arquivo wg-client.conf para seu computador/dispositivo"
    echo "   Use: scp root@${SERVER_IP}:/root/wireguard-client/wg-client.conf ."
    echo ""
    echo "2. Importe este arquivo em seu cliente WireGuard"
    echo "   - Windows/MacOS/Linux: Use o cliente WireGuard oficial"
    echo "   - Android/iOS: Use o aplicativo WireGuard e escaneie o QR code"
    echo ""
    echo "=============================================="
    
    # Lista as portas configuradas
    list_ports
}

# Função principal
main() {
    # Verifica se é root
    if [ "$EUID" -ne 0 ]; then
        print_error "Este script precisa ser executado como root."
        exit 1
    fi

    # Cria diretório do WireGuard
    mkdir -p /etc/wireguard
    if [ ! -f /etc/wireguard/allowed_ports.txt ]; then
        touch /etc/wireguard/allowed_ports.txt
        print_message "Arquivo allowed_ports.txt criado."
    fi
    enable_ip_forwarding

    # Instala dependências e configura o WireGuard
    check_and_install_dependencies
    setup_wireguard
    setup_firewall

    # Copia o script para gerenciar portas
    cp "$0" /usr/local/bin/wireguard-port-manager
    chmod +x /usr/local/bin/wireguard-port-manager
    
    # Cria script de verificação de serviço
    cat << EOF | tee /usr/local/bin/check-wireguard-service
#!/bin/bash
systemctl status wg-quick@wg0
ip a show wg0
iptables -L -v -n
iptables -t nat -L -v -n
EOF
    chmod +x /usr/local/bin/check-wireguard-service

    whileBool=true

    while $whileBool; do
        show_menu
        read -p "Selecione uma opção (1-5): " choice </dev/tty
        case $choice in
            1)
                add_port
                read -p "Pressione Enter para continuar..." </dev/tty
                ;;
            2)
                remove_port
                read -p "Pressione Enter para continuar..." </dev/tty
                ;;
            3)
                list_ports
                read -p "Pressione Enter para continuar..." </dev/tty
                ;;
            4)
                show_qrcode
                read -p "Pressione Enter para continuar..." </dev/tty
                ;;
            5)
                print_message "Limpar configurações antigas..."
                cleanup_old_configs
                setup_firewall
                read -p "Pressione Enter para continuar..." </dev/tty
                ;;
            6)
                print_message "Saindo..."
                whileBool=false
                ;;
            *)
                print_error "Opção inválida. Por favor, selecione 1, 2, 3, 4, 5 ou 6."
                read -p "Pressione Enter para continuar..." </dev/tty
                ;;
        esac
    done
}


main
check_final_status
show_summary

