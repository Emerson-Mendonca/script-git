#!/bin/bash

# Função para verificar se um comando existe
check_installed() {
    command -v "$1" >/dev/null 2>&1
}

# Atualizar repositórios e pacotes
sudo apt-get update -y && sudo apt-get upgrade -y

# 1. Instalação do Docker (se não estiver instalado)
###########################################################
if ! check_installed docker; then
    echo "Instalando Docker..."
    
    # Instalar dependências
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
    
    # Adicionar repositório
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Instalar Docker
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    
    # Configurar serviço
    sudo systemctl enable docker && sudo systemctl start docker
    sudo usermod -aG docker $USER
else
    echo "Docker já está instalado. Pulando instalação..."
fi

# 2. Instalação do Portainer (se não existir)
###########################################################
if ! docker ps -a --format '{{.Names}}' | grep -q 'portainer'; then
    echo "Instalando Portainer..."
    
    # Criar volume e container
    docker volume create portainer_data
    docker run -d -p 9000:9000 --name portainer \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest
else
    echo "Portainer já está instalado. Pulando instalação..."
fi

# 3. Instalação do kubectl (se não estiver instalado)
###########################################################
if ! check_installed kubectl; then
    echo "Instalando kubectl..."
    
    # Baixar binário
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    
    # Validar checksum (opcional)
    # curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
    # echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
    
    # Instalar
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
else
    echo "kubectl já está instalado. Pulando instalação..."
fi

# 4. Verificações finais
###########################################################
echo -e "\n----------------------------------------------------"
echo "Verificação final:"
[ -x "$(command -v docker)" ] && echo "Docker: $(docker --version)"
[ -x "$(command -v kubectl)" ] && echo "kubectl: $(kubectl version --client --short 2>/dev/null)"
docker ps -a | grep -q portainer && echo "Portainer: Container presente"
echo -e "Acesso ao Portainer: http://$(hostname -I | awk '{print $1}'):9000"
echo "----------------------------------------------------"

# Aviso sobre grupos do usuário
if ! groups $USER | grep -q docker; then
    echo -e "\nAVISO: Reinicie a sessão ou execute 'newgrp docker' para aplicar as permissões do Docker"
fi