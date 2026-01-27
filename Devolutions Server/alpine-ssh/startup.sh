#!/bin/sh
set -e

apk add --no-cache openssh

mkdir -p /run/sshd
ssh-keygen -A

echo "root:mysecretpassword" | chpasswd

sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config || true

exec /usr/sbin/sshd -D -e
