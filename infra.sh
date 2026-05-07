#!/usr/bin/env bash
set -euo pipefail

sudo apt update -y
sudo apt upgrade -y
sudo apt autoremove -y

# Pin Docker to a known-good Ubuntu 24.04 build for CAM deploy/upgrade compatibility.
# Use Ubuntu snapshot service so the exact version remains installable after the
# regular apt indexes move on to newer builds.
ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
  amd64)
    DOCKER_PKG_VERSION="27.5.1-0ubuntu3~24.04.2"
    DOCKER_SNAPSHOT_ID="20250801T111111Z"
    ;;
  arm64)
    DOCKER_PKG_VERSION="24.0.7-0ubuntu4"
    DOCKER_SNAPSHOT_ID="20240501T120000Z"
    ;;
  *)
    echo "unsupported architecture for pinned docker.io: ${ARCH}" >&2
    exit 1
    ;;
esac

echo "install docker.io=${DOCKER_PKG_VERSION} for ${ARCH} from snapshot ${DOCKER_SNAPSHOT_ID}"
sudo apt install -y --allow-downgrades \
  --update \
  --snapshot "${DOCKER_SNAPSHOT_ID}" \
  "docker.io=${DOCKER_PKG_VERSION}" \
  pass gnupg2 docker-compose tmux python3 python3-pip

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
sudo apt-mark hold docker.io
