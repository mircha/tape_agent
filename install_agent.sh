#!/usr/bin/env bash

#####################
### version 1.3.1 ###
#####################

set -euo pipefail

# --- Settings ---
LTFS_REPO="${LTFS_REPO:-https://github.com/LinearTapeFileSystem/ltfs.git}"
LTFS_DIR="${LTFS_DIR:-./ltfs}"
LTFS_TARBALL="${LTFS_TARBALL:-./ltfs.tar.gz}"   # you can override this path to point to a local tarball if desired

MOUNTPOINT="${MOUNTPOINT:-/mnt/ltfs}"
INSTALL_USER="${SUDO_USER:-$USER}"

TAPE_AGENT_TAR="${TAPE_AGENT_TAR:-./tape_agent.tar.gz}"
TAPE_AGENT_GPG="${TAPE_AGENT_GPG:-./tape_agent.tar.gz.gpg}"
TAPE_AGENT_URL="https://raw.githubusercontent.com/mircha/tape_agent/main/tape_agent.tar.gz.gpg"

### Logging
DEPS_LOG="dependencies.log"
: > "${DEPS_LOG}"   # truncate log each run (remove this line if you want to append instead)
LTFS_LOG="ltfs_install.log"
: > "${LTFS_LOG}"   # truncate log each run (remove if you want append)
TAPE_AGENT_LOG="tape_agent_install.log"
: > "${TAPE_AGENT_LOG}"   # truncate log each run (remove if you want append)

echo "==> Base packages (covers local SAS/FC AND iSCSI-attached libraries)"
echo "==> Installing required packages (see ${DEPS_LOG})"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y -qq 1>> "${DEPS_LOG}" 2>&1

if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq\
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
  libsnmp-dev \
  1>> "${DEPS_LOG}" 2>&1
then
  echo "==> Package installation complete (see ${DEPS_LOG})"
else
  echo "==> Package installation encountered ERRORS (see ${DEPS_LOG})"
  exit 1
fi

#Configure iSCSI service, tape groups, udev rules, etc.
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

echo "==> udev rules for /dev/st*, /dev/nst* (tape + changer)"
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

# Create mount point
echo "==> Create mount point: ${MOUNTPOINT}"
sudo mkdir -p "${MOUNTPOINT}"
sudo chown "${INSTALL_USER}:${INSTALL_USER}" "${MOUNTPOINT}"

# Build and install LTFS from source
echo
echo "==> Build + install LTFS from source (portable across environments)"
#check if ltfs already installed?
if command -v ltfs >/dev/null 2>&1; then
  echo "==> LTFS already installed at: $(command -v ltfs)"
  echo "==> Skipping LTFS build/install."
  
else
  if (
      
    if [ -f "${LTFS_TARBALL}" ]; then
      echo "==> Found LTFS tarball: ${LTFS_TARBALL}"
      echo "==> Extracting to: ${LTFS_DIR}"

      sudo mkdir -p "${LTFS_DIR}"
      sudo chown "${INSTALL_USER}:${INSTALL_USER}" "${LTFS_DIR}"

      # Clean existing dir contents (optional but recommended)
      sudo -u "${INSTALL_USER}" rm -rf "${LTFS_DIR:?}/"*

      # Extract
      sudo -u "${INSTALL_USER}" tar -xzf "${LTFS_TARBALL}" -C "${LTFS_DIR}" --strip-components=1

    else
      echo "==> No tarball found; using git clone from ${LTFS_REPO}"
      if [ ! -d "${LTFS_DIR}/.git" ]; then
        sudo mkdir -p "$(dirname "${LTFS_DIR}")"
        sudo chown "${INSTALL_USER}:${INSTALL_USER}" "$(dirname "${LTFS_DIR}")"
        sudo -u "${INSTALL_USER}" git clone "${LTFS_REPO}" "${LTFS_DIR}"
      fi
    fi

    cd "${LTFS_DIR}"

    git submodule update --init --recursive || true

    ./autogen.sh
    ./configure
    make -j"$(nproc)"
    sudo make install
    sudo ldconfig
  ) 1>> "${LTFS_LOG}" 2>&1
  then
    echo "==> LTFS source setup complete (see ${LTFS_LOG})"
  else
    echo "==> LTFS source setup encountered ERRORS (see ${LTFS_LOG})"
    exit 1
  fi
fi

# Detect existing iSCSI sessions
echo
echo "==> Detect: do we have iSCSI sessions?"
if command -v iscsiadm >/dev/null 2>&1; then
  sudo iscsiadm -m session 2>/dev/null || echo "(no active iSCSI sessions)"
fi

# Download and install tape agent
echo

echo "==> Determining tape agent source"

mkdir -p tape_agent

if (

  if [ -f "${TAPE_AGENT_TAR}" ]; then
    echo "==> Found local unencrypted tarball: ${TAPE_AGENT_TAR}"
    echo "==> Extracting tape agent..."
    sudo tar -xzf "${TAPE_AGENT_TAR}" -C tape_agent

  else
    # Need encrypted blob (.gpg)
    if [ -f "${TAPE_AGENT_GPG}" ]; then
      echo "==> Found local encrypted tarball: ${TAPE_AGENT_GPG}"
    else
      echo "==> Downloading encrypted tape agent (${TAPE_AGENT_URL})"
      sudo wget -O "${TAPE_AGENT_GPG}" "${TAPE_AGENT_URL}"
    fi


  fi
) 1>> "${TAPE_AGENT_LOG}" 2>&1

then
  echo "==> Tape agent find source complete (see ${TAPE_AGENT_LOG})"
else
  echo "==> Tape agent find source encountered ERRORS (see ${TAPE_AGENT_LOG})"
  exit 1
fi

echo "==> Installing tape agent"

if [ ! -f "${TAPE_AGENT_TAR}" ] && [ -f "${TAPE_AGENT_GPG}" ]; then


    echo "==> Decrypting tape agent"
    read -r -s -p "Tape Agent passphrase: " PASSPHRASE
    echo

    sudo gpg --batch --yes --pinentry-mode loopback --passphrase "${PASSPHRASE}" \
      --decrypt "${TAPE_AGENT_GPG}" | sudo tar -xz -C tape_agent
    unset PASSPHRASE
fi

  sudo chmod +x /tape_agent/main
  sudo ln -sf /tape_agent/main /usr/local/bin/tape_agent

echo "==> Installation complete!"
#Download and install completed

cat <<'NOTE'

NOTE:
- Adding the user to the 'tape' group requires a NEW login session. (SSH disconnect/reconnect, or reboot.)

- iSCSI login
  sudo iscsiadm -m discovery -t sendtargets -p <TARGET_IP>
  sudo iscsiadm -m node -l

- Next steps (once you know which /dev/nstX is your drive):
    # Example mount: sudo ltfs -o device=/dev/nst0 /mnt/ltfs
  Use: >> ltfs -o devlist OR  lsscsi -g to identify the correct device nodes.

- Start tape agent:
    sudo tape_agent

NOTE


# Output core software detection info
echo
echo "==> Detect: ltfs version... LTFS exists here: $(command -v ltfs || echo 'NOT FOUND')"

echo
echo "==> Detect: mtx... MTX exists here: $(command -v mtx || echo 'NOT FOUND')"

echo
echo "Tape agent installed... $(command -v tape_agent || echo 'NOT FOUND')"

#Show detected tape/changer devices?
echo
read -r -p "Show tape/changer detection output now? [Y/n] " ans
ans="${ans:-Y}"

if [[ "$ans" =~ ^[Yy]$ ]]; then
  echo
  echo "==> Detect: filter likely tape/changer lines"
  lsscsi -g | grep -Ei 'tape|medium|changer' || true
fi

#Show ltfs devices?
echo
read -r -p "Show ltfs devices? [Y/n] " ans
ans="${ans:-Y}"

if [[ "$ans" =~ ^[Yy]$ ]]; then
  echo
  echo "==> Detect: LTFS devlist"
  ltfs -o devlist || true
fi

#Run tape agent now?
echo
read -r -p "Run tape agent now? [Y/n] " ans
ans="${ans:-Y}"
if [[ "$ans" =~ ^[Yy]$ ]]; then
  echo
  echo "==> Running tape agent..."
  sudo /usr/local/bin/tape_agent
fi
