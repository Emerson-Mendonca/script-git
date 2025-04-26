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
  echo "✔️ Portainer instalado e rodando em http://localhost:9000 (ou IP do servidor)."
else
  echo "✔️ Portainer já existe no Docker."
fi

# 5) Kubernetes (kubeadm, kubelet, kubectl)
echo "🔧 Verificando componentes do Kubernetes..."
if ! command -v kubeadm &>/dev/null; then
  echo "▶️ Instalando Kubernetes..."

  # Remover repositórios antigos
  echo "✔️ Limpando repositórios antigos do Kubernetes..."
  rm -f /etc/apt/sources.list.d/kubernetes* || true
  sed -i.bak '/cloud.google.com\/apt/d;/kubernetes-xenial/d' /etc/apt/sources.list || true

  # Registrar chave GPG de forma moderna
  echo "✔️ Registrando chave GPG do Kubernetes..."
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
    | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg

  # Adicionar repositório oficial
  echo "✔️ Adicionando repositório oficial pkgs.k8s.io"
  cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
# Kubernetes official repository
deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /
EOF

  # Atualizar e instalar pacotes
  apt-get update
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  echo "✔️ Kubernetes instalado com sucesso."
else
  echo "✔️ Kubernetes já está instalado."
fi

# 6) Desabilitar swap (requisito kubeadm)
echo "🔧 Desabilitando swap (se ativo)..."
if swapon --summary | grep -q '^'; then
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab
  echo "✔️ Swap desabilitado."
else
  echo "✔️ Swap já está desabilitado."
fi

# 7) Ajustes de rede para Kubernetes
echo "🔧 Configurando parâmetros de rede..."
modprobe br_netfilter || true
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

# Finalização
echo "✅ Instalação concluída!"
echo " - Docker, Portainer e Kubernetes prontos para uso."
echo " - Para iniciar um cluster de teste: kubeadm init"
echo " - Não esqueça de configurar seu CNI (Weave, Flannel, Calico, etc.) e acessar o Portainer para gerenciamento."
