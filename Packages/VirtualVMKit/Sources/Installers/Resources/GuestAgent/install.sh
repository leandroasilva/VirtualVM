#!/bin/sh
# Installs the VirtualVM guest tools in a Linux system, or replaces an older copy of them.
#
# They are one small program, the guest agent, that lets the VirtualVM app on the Mac see this
# system's version and addresses, set its clock after the virtual machine was suspended, mount
# the folders shared with it and shut it down. It talks to the app over the virtual machine's
# socket device, so none of that needs a network.
#
# Run it as root:    sudo sh install.sh
# To remove it all:  sudo sh install.sh --remove
#
# Everything it installs is in this file, in plain text, below.
set -eu

directory=/usr/local/lib/virtualvm
units=/etc/systemd/system

fail() {
    echo "virtualvm: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "this has to run as root, for example: sudo sh $0"
command -v systemctl >/dev/null 2>&1 || fail "this system doesn't use systemd, which the guest agent needs"

if [ "${1:-}" = "--remove" ]; then
    systemctl disable --now virtualvm-agent.service virtualvm-sshd-vsock.socket >/dev/null 2>&1 || true
    rm -f "$units/virtualvm-agent.service" "$units/virtualvm-sshd-vsock.socket" "$units/virtualvm-sshd-vsock@.service"
    rm -rf "$directory"
    systemctl daemon-reload
    echo "The VirtualVM guest tools are removed."
    exit 0
fi

[ -x /usr/bin/python3 ] || fail "the guest agent needs Python 3 at /usr/bin/python3. Install it and run this again"

mkdir -p "$directory"
umask 022

cat > "$directory/virtualvm-agent.py.new" <<'VIRTUALVM_END_OF_FILE'
@@virtualvm-agent.py@@
VIRTUALVM_END_OF_FILE
chmod 755 "$directory/virtualvm-agent.py.new"
mv -f "$directory/virtualvm-agent.py.new" "$directory/virtualvm-agent.py"

cat > "$units/virtualvm-agent.service" <<'VIRTUALVM_END_OF_FILE'
@@virtualvm-agent.service@@
VIRTUALVM_END_OF_FILE

cat > "$units/virtualvm-sshd-vsock.socket" <<'VIRTUALVM_END_OF_FILE'
@@virtualvm-sshd-vsock.socket@@
VIRTUALVM_END_OF_FILE

cat > "$units/virtualvm-sshd-vsock@.service" <<'VIRTUALVM_END_OF_FILE'
@@virtualvm-sshd-vsock@.service@@
VIRTUALVM_END_OF_FILE

# A copy of this file stays behind, for removing the tools again. It may be the file that is running,
# under another spelling of its name: then there is nothing to copy, and cp saying so is no failure.
case "$0" in
    */install.sh | install.sh) cp "$0" "$directory/install.sh" 2>/dev/null || true ;;
esac

systemctl daemon-reload
systemctl --quiet enable virtualvm-agent.service virtualvm-sshd-vsock.socket
# Restarting is what puts a newer agent in the place of a running older one.
systemctl restart virtualvm-agent.service
# Does nothing where systemd itself already puts the SSH server on the socket device.
systemctl start virtualvm-sshd-vsock.socket >/dev/null 2>&1 || true

echo "The VirtualVM guest tools are installed."
