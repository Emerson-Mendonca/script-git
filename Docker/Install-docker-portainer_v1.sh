#!/usr/bin/env bash
set -euo pipefail

#--------------------------------------------------
# Script de instalação: Docker + Portainer + Kubernetes (kubeadm)
# Suporta Ubuntu/Debian (20.04, 22.04, etc.)
# Execute como root ou com sudo:
#   chmod +x install-docker-k8s-portainer.sh
#   sudo ./install-docker-k8s-portainer.sh
#--------------------------------------------------

# 1) Verificações iniciais
if [ "$EUID" -ne 0 ]; then
  echo "❌ Execute este script como root ou via sudo."
  exit 1
fi

# Detectar versão do Ubuntu/Debian
if ! command -v lsb_release &>/dev/null; then
  apt-get update
  apt-get install -y lsb-release
fi
DISTRO=$(lsb_release -si)
CODENAME=$(lsb_release -sc)
ARCH=$(dpkg --print-architecture)

echo "✔️ Distribuição detectada: $DISTRO $CODENAME ($ARCH)"

# 2) Instalar pré-requisitos comuns
apt-get update
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  software-properties-common

# 3) Docker
echo "🔧 Verificando Docker..."
if ! command -v docker &>/dev/null; then
  echo "▶️ Instalando Docker CE..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  USER_TO_ADD=${SUDO_USER:-$(whoami)}
  usermod -aG docker "$USER_TO_ADD" || true
  echo "✔️ Docker instalado com sucesso."
else
  echo "✔️ Docker já está instalado."
fi

# 4) Portainer
echo "🔧 Verificando Portainer..."
if ! docker ps -a --format '{{.Names}}' | grep -w portainer &>/dev/null; then
  echo "▶️ Instalando Portainer..."
  docker volume create portainer_data || true
  docker run -d \
    --name portainer \
    --restart=always \
    -p 8000:8000 \
    -p 9000:9000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
  echo "✔️ Portainer instalado e rodando em http://$(hostname -I | awk '{print $1}'):9000 (ou IP do servidor)."
else
  echo "✔️ Portainer já existe no Docker."
fi

# Finalização
###########################################################
echo -e "\n----------------------------------------------------"
echo "Verificação final:"
[ -x "$(command -v docker)" ] && echo "Docker: $(docker --version)"
docker ps -a | grep -q portainer && echo "Portainer: Container presente"
echo -e "Acesso ao Portainer: http://$(hostname -I | awk '{print $1}'):9000"
echo "----------------------------------------------------"

