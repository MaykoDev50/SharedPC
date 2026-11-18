#!/bin/bash
# SharedPC - Oracle Cloud server setup.
# Paste this whole file into "Cloud-init script" (Advanced options) when creating the instance.
# It installs: desktop (XFCE) + Remote Desktop (xrdp) + Firefox + Office + Hebrew + per-customer GB limits + the SharedPC web panel.
exec > /var/log/sharedpc-setup.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
ADMIN_PASSWORD='p5i9G7VD9gprKA7!'

mkdir -p /etc/sharedpc
printf '%s' "$ADMIN_PASSWORD" > /etc/sharedpc/admin-password
chmod 600 /etc/sharedpc/admin-password

# ---- firewall: Oracle's Ubuntu image blocks everything except SSH ----
iptables -I INPUT 1 -p tcp --dport 3389 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 8080 -j ACCEPT
(command -v netfilter-persistent && netfilter-persistent save) || (mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4)

# ---- 4GB swap (helps with many customers) ----
if [ ! -f /swapfile ]; then fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi

# ---- desktop + remote desktop + apps ----
apt-get update
apt-get install -y xfce4 xfce4-goodies xrdp xorgxrdp dbus-x11 fonts-noto-core fonts-noto-color-emoji fonts-culmus \
    libreoffice-writer libreoffice-calc libreoffice-impress quota python3 curl software-properties-common
add-apt-repository -y ppa:mozillateam/ppa
printf 'Package: *\nPin: release o=LP-PPA-mozillateam\nPin-Priority: 1001\n' > /etc/apt/preferences.d/mozilla-firefox
apt-get update
apt-get install -y firefox

# every customer gets the XFCE desktop
echo 'startxfce4' > /etc/skel/.xsession
cat > /etc/xrdp/startwm.sh <<'WM'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
. /etc/profile
exec startxfce4
WM
chmod 755 /etc/xrdp/startwm.sh
adduser xrdp ssl-cert
# no "authentication required" pop-ups inside remote sessions
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/02-sharedpc.rules <<'PK'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") == 0 ||
      action.id == "org.freedesktop.packagekit.system-sources-refresh" ||
      action.id == "org.freedesktop.NetworkManager.network-control") { return polkit.Result.YES; }
});
PK
# Hebrew keyboard (Alt+Shift switches English/Hebrew)
cat > /etc/xdg/autostart/sharedpc-keyboard.desktop <<'KB'
[Desktop Entry]
Type=Application
Name=Keyboard EN/HE
Exec=setxkbmap -layout us,il -option grp:alt_shift_toggle
KB
systemctl enable xrdp
systemctl restart xrdp

# ---- per-customer GB limits (disk quotas) ----
apt-get install -y "linux-modules-extra-$(uname -r)" || true
modprobe quota_v2 || true
if ! grep -qE '^[^#]+\s/\s+\S+\s+\S*usrquota' /etc/fstab; then
  awk '$2=="/" && $1!~/^#/ { $4=$4",usrquota" } { print }' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
fi
mount -o remount / && quotacheck -cum / && quotaon -v / || echo "quota setup failed - GB limits will not be enforced"

# ---- SharedPC web panel (admin + customers) on port 8080 ----
curl -fsSL -o /usr/local/bin/sharedpc-portal.py https://raw.githubusercontent.com/MaykoDev50/SharedPC/main/oracle/sharedpc-portal.py
chmod 755 /usr/local/bin/sharedpc-portal.py
cat > /etc/systemd/system/sharedpc.service <<'SVC'
[Unit]
Description=SharedPC web panel
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/sharedpc-portal.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable --now sharedpc

# ---- automatic security updates ----
apt-get install -y unattended-upgrades

date > /etc/sharedpc/setup-done
