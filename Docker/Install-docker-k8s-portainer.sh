#!/usr/bin/env bash
set -euo pipefail

#--------------------------------------------------
# Script de instalação: Docker + Kubernetes (kubeadm)
# Suporta Ubuntu/Debian (20.04, 22.04, etc.)
# Execute como root ou com sudo:
#   chmod +x install-docker-k8s.sh
#   sudo ./install-docker-k8s.sh
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

# 3) Instalar Docker
echo "🔧 Instalando Docker CE..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo \
  "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Adicionar usuário ao grupo docker (para não precisar de sudo)
USER_TO_ADD=${SUDO_USER:-$(whoami)}
usermod -aG docker "$USER_TO_ADD" || true

# 4) Instalar Kubernetes (kubeadm, kubelet, kubectl)
echo "🔧 Instalando Kubernetes components..."
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF

apt-get update
apt-get install -y kubelet kubeadm kubectl

# Evita atualizações automáticas desses pacotes
apt-mark hold kubelet kubeadm kubectl

# 5) Desabilitar swap (requisito do kubeadm)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 6) Ajustes de rede para Kubernetes
modprobe br_netfilter || true
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "✅ Instalação completa!"
echo " - Docker e Kubernetes instalados com sucesso."
echo " - Para iniciar um cluster de teste: kubeadm init"
echo " - Lembre-se de configurar seu CNI (Weave, Flannel, Calico, etc.)"
