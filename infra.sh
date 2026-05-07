#!/usr/bin/env bash
set -euo pipefail

DOCKER_VERSION_STRING="5:27.5.1-1~ubuntu.24.04~noble"
LEGACY_DOCKER_PACKAGES="docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc"
DOCKER_CE_PACKAGES="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

sudo apt update -y
sudo apt upgrade -y
sudo apt autoremove -y

sudo apt-mark unhold ${LEGACY_DOCKER_PACKAGES} ${DOCKER_CE_PACKAGES} 2>/dev/null || true

OLD_DOCKER_PKGS="$(dpkg --get-selections \
  ${LEGACY_DOCKER_PACKAGES} 2>/dev/null \
  | awk '$2 != "deinstall" {print $1}')"
if [ -n "${OLD_DOCKER_PKGS}" ]; then
  sudo apt remove -y ${OLD_DOCKER_PKGS}
fi

sudo apt install -y \
  ca-certificates curl pass gnupg2 tmux \
  python3 python3-pip python3-docopt python3-requests python3-yaml

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update -y

echo "install docker-ce=${DOCKER_VERSION_STRING}"
sudo apt install -y --allow-downgrades \
  "docker-ce=${DOCKER_VERSION_STRING}" \
  "docker-ce-cli=${DOCKER_VERSION_STRING}" \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Keep legacy docker-compose command working for existing camdeploy scripts.
sudo tee /usr/local/bin/docker-compose >/dev/null <<'EOF'
#!/usr/bin/env bash
exec docker compose "$@"
EOF
sudo chmod +x /usr/local/bin/docker-compose

# update memory dirty page bytes, avoid dirty page write back storm
sudo tee /etc/sysctl.d/99-oom-tuning.conf >/dev/null <<'EOF'
vm.dirty_bytes = 2147483648
vm.dirty_background_bytes = 536870912
vm.dirty_expire_centisecs = 800
vm.dirty_writeback_centisecs = 200
vm.swappiness = 1
EOF
sudo sysctl --system
sysctl -n vm.dirty_bytes vm.dirty_background_bytes vm.dirty_expire_centisecs vm.dirty_writeback_centisecs vm.swappiness

sudo usermod -aG docker $USER 
# change default shell to bash 
sudo chsh -s $(which bash) $USER 

# install and config chrony service for AWS
if [ ! -f /etc/chrony/chrony.conf ]; then
    echo 'install chrony'
    sudo apt install chrony -y
    sudo cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
    sudo sed -i '16a server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' /etc/chrony/chrony.conf
    sudo /etc/init.d/chrony restart
    chronyc tracking
fi

# configure docker daemon
sudo mkdir -p /etc/docker
cat <<'EOF' | sudo tee /etc/docker/daemon.json >/dev/null
{
  "log-opts": {
    "max-size": "500m",
    "max-file": "5",
    "compress": "true"
  }
}
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now docker
sudo systemctl restart docker

echo 'mark docker service not auto-upgrade'
sudo apt-mark hold ${DOCKER_CE_PACKAGES}
