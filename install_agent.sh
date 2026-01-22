#!/usr/bin/env bash
set -euo pipefail

# --- Settings ---
LTFS_REPO="${LTFS_REPO:-https://github.com/LinearTapeFileSystem/ltfs.git}"
LTFS_DIR="${LTFS_DIR:-/opt/ltfs}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/ltfs}"
INSTALL_USER="${SUDO_USER:-$USER}"

echo "==> Base packages (covers local SAS/FC AND iSCSI-attached libraries)"
sudo apt-get update -y

sudo apt-get install -y \
  open-iscsi \
  sg3-utils lsscsi \
  mtx mt-st \
  git \
  build-essential \
  automake \
  autoconf \
  libtool \
  fuse \
  libfuse-dev \
  uuid-dev \
  pkg-config \
  libxml2-dev \
  libsnmp-dev

echo "==> Enable iSCSI service (harmless if unused)"
sudo systemctl enable --now iscsid 2>/dev/null || true
sudo systemctl enable --now open-iscsi 2>/dev/null || true

echo "==> Load kernel modules needed for tape + sg passthrough"
sudo modprobe sg || true
sudo modprobe st || true

echo "==> Persist module load at boot"
echo -e "sg\nst" | sudo tee /etc/modules-load.d/tape.conf >/dev/null

echo "==> Ensure tape group and add user: ${INSTALL_USER}"
sudo groupadd -f tape
sudo usermod -aG tape "${INSTALL_USER}"

echo "==> udev rules for /dev/st*, /dev/nst*, /dev/sg* (tape + changer)"
sudo tee /etc/udev/rules.d/99-tape.rules >/dev/null <<'EOF'
# Tape drives char devices
KERNEL=="st[0-9]*",  MODE="0660", GROUP="tape"
KERNEL=="nst[0-9]*", MODE="0660", GROUP="tape"

# SCSI generic nodes:
# type 1 = tape, type 8 = medium changer
#SUBSYSTEM=="scsi_generic", ATTRS{type}=="1", MODE="0660", GROUP="tape"
SUBSYSTEM=="scsi_generic", ENV{DEVTYPE}=="scsi_tape", MODE="0660", GROUP="tape"
SUBSYSTEM=="scsi_generic", ATTRS{type}=="8", MODE="0660", GROUP="tape"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger

echo "==> Create mount point: ${MOUNTPOINT}"
sudo mkdir -p "${MOUNTPOINT}"
sudo chown "${INSTALL_USER}:${INSTALL_USER}" "${MOUNTPOINT}"

echo "==> Build + install LTFS from source (portable across environments)"
if [ ! -d "${LTFS_DIR}/.git" ]; then
  sudo mkdir -p "$(dirname "${LTFS_DIR}")"
  sudo chown "${INSTALL_USER}:${INSTALL_USER}" "$(dirname "${LTFS_DIR}")"
  sudo -u "${INSTALL_USER}" git clone "${LTFS_REPO}" "${LTFS_DIR}"
fi

cd "${LTFS_DIR}"
git submodule update --init --recursive || true

./autogen.sh
./configure
make -j"$(nproc)"
sudo make install
sudo ldconfig

echo
echo "==> Versions"
ltfs --version || true
mt --version 2>/dev/null || true
mtx -V 2>/dev/null || true

echo
echo "==> Detect: do we have iSCSI sessions?"
if command -v iscsiadm >/dev/null 2>&1; then
  sudo iscsiadm -m session 2>/dev/null || echo "(no active iSCSI sessions)"
fi

# echo
# echo "==> Detect: SCSI tape drives + changers (lsscsi)"
# lsscsi -g || true

echo
echo "==> Detect: filter likely tape/changer lines"
lsscsi -g | grep -Ei 'tape|medium|changer' || true

echo
# echo "==> Detect: LTFS devlist"
# ltfs -o devlist || true
echo "==> Detect: ltfs version"
echo "LTFS exists here: $(which ltfs)"

echo
echo "==> Detect: mtx"
echo "MTX exists here: $(which mtx)"

echo
echo "==> Downloading tape agent"
sudo wget -O tape_agent.tar.gz.gpg https://raw.githubusercontent.com/mircha/tape_agent/main/tape_agent.tar.gz.gpg

echo "==> Decrypting tape agent"
mkdir -p /tape_agent

sudo read -s -p "Tape Agent passphrase: " PASSPHRASE
echo
  
sudo gpg --batch --yes --pinentry-mode loopback --passphrase "${PASSPHRASE}" \
  --decrypt tape_agent.tar.gz.gpg | sudo tar -xz -C /tape_agent

sudo unset PASSPHRASE

sudo chmod +x /tape_agent/main
sudo ln -sf /tape_agent/main /usr/local/bin/tape_agent
echo "==> Installation complete!"
sudo /usr/local/bin/tape_agent

cat <<'NOTE'

NOTE:
- Adding the user to the 'tape' group requires a NEW login session.
  (SSH disconnect/reconnect, or reboot.)
- This script installs iSCSI tools even if unused. If the library shows up as local SAS/FC,
  nothing breaks; iSCSI services will simply sit idle.

- Next steps (once you know which /dev/nstX is your drive):
    # Example mount:
    sudo ltfs -o device=/dev/nst0 /mnt/ltfs
  Use:
    ltfs -o devlist
    lsscsi -g
  to identify the correct device nodes.

NOTE
