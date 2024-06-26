#!/bin/bash

set -e

# exec > >(while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') $line"; done) 2>&1

# Define download location
WORKDIR=$(pwd)/temp
ISO_PATH=$WORKDIR
#ISO_FILE="ubuntu-22.04.4-live-server-arm64.iso"
ISO_FILE="ubuntu-24.04-live-server-arm64.iso"
#ISO_URL="https://cdimage.ubuntu.com/ubuntu/releases/22.04/release/${ISO_FILE}"
ISO_URL="https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/${ISO_FILE}"
VM_NAME="ubuntu-vm"
VM_TIMEZONE="America/New_York"
MODIFIED_ISO="custom-ubuntu.iso"
USER_NAME=v
USER_PASSWORD=q

[ -d "$WORKDIR" ] && find $WORKDIR -mindepth 1 ! -name "$ISO_FILE" -delete

# Check if the ISO file already exists
if [ ! -f "${ISO_PATH}/${ISO_FILE}" ]; then
    echo "Ubuntu ISO not found. Downloading now..."
    mkdir -p $ISO_PATH
    curl -f -L -o "${ISO_PATH}/${ISO_FILE}" $ISO_URL
    echo "Download completed."
else
    echo "Ubuntu ISO already exists. No download needed."
fi

# Check if download was successful
if [ ! -f "${ISO_PATH}/${ISO_FILE}" ]; then
    echo "Failed to download Ubuntu ISO. Exiting..."
    exit 1
else
    echo "Download successful."
fi

# Prepare user-data and meta-data
cat <<EOF > $WORKDIR/user-data
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: ubuntu-vm
    username: $USER_NAME
    password: "$(openssl passwd -6 -salt saltsalt $USER_PASSWORD)"
  ssh:
    install-server: yes
    authorized-keys:
      - $(cat ~/.ssh/id_rsa.pub)
    allow-pw: no
  storage:
    layout:
      name: lvm
  timezone: $VM_TIMEZONE
  packages:
    - zsh
    - dkms
    - libelf-dev
    - build-essential
  package_update: true
  package_upgrade: true
  late-commands:
    - echo '$USER_NAME ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/$USER_NAME
EOF

# echo "instance-id: iid-local01; local-hostname: cloudimg" > $WORKDIR/source-files/server/meta-data
echo "" > $WORKDIR/meta-data

cat <<EOF > $WORKDIR/grub.cfg
set timeout=1

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
menuentry "Autoinstall Ubuntu Server" {
    set gfxpayload=keep
    linux   /casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/server/  ---
    initrd  /casper/initrd
}
EOF

if [ ! -f "${ISO_PATH}/${MODIFIED_ISO}" ]; then
    echo "Modified ISO not found. Creating now..."

    xorriso -indev "$ISO_PATH/$ISO_FILE" \
            -outdev "$ISO_PATH/$MODIFIED_ISO" \
            -map $WORKDIR/user-data /server/user-data \
            -map $WORKDIR/meta-data /server/meta-data \
            -map $WORKDIR/grub.cfg /boot/grub/grub.cfg \
            -boot_image any replay
    
    echo "Modification completed."
else
    echo "Modified ISO already exists. No modification needed."
fi

# Create a new VM
echo "Creating a new VM..."
prlctl create $VM_NAME --distribution ubuntu
prlctl set $VM_NAME --device-set cdrom0 --image "${ISO_PATH}/${MODIFIED_ISO}" --connect
prlctl start $VM_NAME

 function sshtmp
 {
    ssh $USER_NAME@$VM_NAME \
        -o "ConnectTimeout 3" \
        -o "StrictHostKeyChecking no" \
        -o "UserKnownHostsFile /dev/null" \
        -o "BatchMode yes" \
        "$@"
 }

while ! sshtmp echo "Hello from $VM_NAME"
do
    sleep 5
    echo "Trying ssh again..."
done

echo "Updating & upgrading packages..."
sshtmp sudo apt update
sshtmp "sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y"

echo "Changing default shell for the user $USER_NAME to zsh..."
sshtmp sudo chsh -s $(which zsh) $USER_NAME

echo "Installing oh-my-zsh..."
sshtmp 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'

echo "Removing $VM_NAME mentioning from known_hosts..."
ssh-keygen -R $VM_NAME

echo "Installing Parallels Desktop Tools..."
PRL_TOOLS_ISO_PATH=$(if [[ $(uname -m) == "x86_64" ]]; then echo "/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin.iso"; elif [[ $(uname -m) == "arm64" ]]; then echo "/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin-arm.iso"; fi)
prlctl set $VM_NAME --device-set cdrom0 --image "$PRL_TOOLS_ISO_PATH" --connect
sshtmp 'sudo mkdir -p /media/cdrom0 && \
        sudo apt-get install -y dkms libelf-dev linux-headers-$(uname -r) build-essential && \
        sudo mount -o exec /dev/sr0 /media/cdrom0 && \
        cd /media/cdrom0 && \
        sudo ./install --install-unattended --progress
    '

echo "Share all host disks with $VM_NAME..."
prlctl set ubuntu-vm --shf-host-defined alldisks

echo -e "VM $VM_NAME is created. Use this command to connect:\n  ssh v@$VM_NAME"
echo -e "The connection uses your default ssh key, the password is mostly not required, but if you need it, your password is \
    \n$USER_PASSWORD\n \
    User name: $USER_NAME"

