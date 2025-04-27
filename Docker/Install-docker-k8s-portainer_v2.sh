#!/usr/bin/env bash
set -euo pipefail

MASTER_IP=192.168.15.165
MASTER_HOST=k8s-master-noble

# 0. ROOT CHECK
if [[ $EUID -ne 0 ]]; then
  echo "⚠️ Execute como root ou use sudo." >&2
  exit 1
fi

# 1. HOSTNAME e /etc/hosts
echo "🔧 Configurando hostname e /etc/hosts..."
hostnamectl set-hostname $MASTER_HOST
cat <<EOF >> /etc/hosts
${MASTER_IP}  ${MASTER_HOST}
192.168.15.166  k8s-worker01-noble
192.168.15.167  k8s-worker02-noble
EOF

# 2. Swap off e módulos
echo "🔧 Desativando swap e ajustando kernel..."
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab
modprobe overlay
modprobe br_netfilter
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
cat <<EOF > /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 3. containerd
echo "⚙️ Instalando containerd..."
apt-get update
apt-get install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/trusted.gpg.d/containerd.gpg
add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install -y containerd.io
mkdir -p /etc/containerd
containerd config default \
  | sed 's/SystemdCgroup = false/SystemdCgroup = true/' \
  > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# 4. kubeadm, kubelet, kubectl
echo "⚙️ Instalando kubeadm, kubelet e kubectl..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/k8s.gpg
cat <<EOF > /etc/apt/sources.list.d/k8s.list
deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /
EOF
chmod 644 /etc/apt/keyrings/k8s.gpg /etc/apt/sources.list.d/k8s.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 5. Inicializa o master (se ainda não inicializado)
if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  echo "🔧 Inicializando master Kubernetes..."
  kubeadm init \
    --control-plane-endpoint=${MASTER_IP}:6443 \
    --upload-certs \
    | tee /root/kubeadm-init.out

  mkdir -p /root/.kube
  cp -i /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config
else
  echo "🟢 Master já inicializado (admin.conf detectado)."
fi

# 6. Gera comando de join para workers
echo
echo "🔗 Comando para adicionar WORKERS (execute em cada worker):"
kubeadm token create --print-join-command

# 7. Calico network plugin
echo "⚙️ Aplicando Calico network plugin..."
kubectl --kubeconfig=/root/.kube/config apply \
  -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

# 8. Docker Engine
if ! command -v docker &>/dev/null; then
  echo "⚙️ Instalando Docker Engine..."
  apt-get install -y ca-certificates curl gnupg lsb-release
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  cat <<EOF > /etc/apt/sources.list.d/docker.list
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker && systemctl start docker
else
  echo "🟢 Docker já instalado."
fi

# 9. Portainer CE
if ! docker ps -a --format '{{.Names}}' | grep -Fxq portainer; then
  echo "⚙️ Instalando Portainer CE..."
  docker volume create portainer_data
  docker run -d --name portainer --restart=always \
    -p 9443:9443 -p 8000:8000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:lts
else
  echo "🟢 Portainer já instalado."
fi

echo
echo "🎉 Tudo pronto! Acesse o Portainer em https://${MASTER_IP}:9443"