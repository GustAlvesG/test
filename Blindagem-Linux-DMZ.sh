#!/usr/bin/env bash
#
# Blindagem-Linux-DMZ.sh
# Hardening de uma VM Ubuntu Server em DMZ hospedando uma aplicacao Next.js.
# Rodar como root, LOGO APOS a instalacao limpa do sistema, ANTES de subir a aplicacao.
#
# Uso: sudo bash Blindagem-Linux-DMZ.sh
#
set -euo pipefail

# ============================
# PARAMETROS - AJUSTE AQUI
# ============================
NEW_SSH_PORT=2222                 # nunca deixe SSH na 22 exposta em DMZ
APP_USER="nextapp"                # usuario nao-root que roda a aplicacao
APP_DIR="/opt/nextjs-app"
NODE_MAJOR=20                     # versao LTS do Node
ADMIN_SSH_KEY=""                  # cole aqui a chave publica do administrador (obrigatorio)

if [[ -z "$ADMIN_SSH_KEY" ]]; then
  echo "ERRO: defina ADMIN_SSH_KEY com sua chave publica antes de rodar o script." >&2
  exit 1
fi

echo "==> 1/10 Atualizando o sistema"
apt update && apt -y full-upgrade
apt -y install unattended-upgrades apt-listchanges
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> 2/10 Criando usuario de aplicacao sem privilegios"
if ! id "$APP_USER" &>/dev/null; then
  useradd -m -s /usr/sbin/nologin "$APP_USER"
fi
mkdir -p "$APP_DIR"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

echo "==> 3/10 Hardening de SSH (chave publica, sem root, sem senha, porta alternativa)"
mkdir -p /root/.ssh
echo "$ADMIN_SSH_KEY" >> /root/.ssh/authorized_keys 2>/dev/null || true
SSHD_CONFIG=/etc/ssh/sshd_config
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
sed -i \
  -e "s/^#\?Port .*/Port ${NEW_SSH_PORT}/" \
  -e "s/^#\?PermitRootLogin .*/PermitRootLogin no/" \
  -e "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" \
  -e "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" \
  -e "s/^#\?X11Forwarding .*/X11Forwarding no/" \
  -e "s/^#\?AllowTcpForwarding .*/AllowTcpForwarding no/" \
  -e "s/^#\?MaxAuthTries .*/MaxAuthTries 3/" \
  "$SSHD_CONFIG"
systemctl restart ssh

echo "==> 4/10 Firewall (ufw) - nega tudo, libera so o essencial"
apt -y install ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow "${NEW_SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "==> 5/10 fail2ban contra brute-force (SSH e Nginx)"
apt -y install fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port    = ${NEW_SSH_PORT}
maxretry = 4
bantime  = 3600
findtime = 600

[nginx-http-auth]
enabled = true

[nginx-limit-req]
enabled = true
EOF
systemctl enable --now fail2ban

echo "==> 6/10 Deteccao de rootkit/malware e integridade de arquivos"
apt -y install rkhunter chkrootkit aide clamav clamav-daemon auditd
aideinit
freshclam || true
cat > /etc/cron.d/seguranca-dmz <<'EOF'
0 3 * * * root /usr/bin/rkhunter --check --skip-keypress --report-warnings-only
0 4 * * * root /usr/bin/chkrootkit
0 5 * * * root /usr/bin/clamscan -r --infected /opt /home --log=/var/log/clamav/scan.log
0 6 * * 0 root /usr/bin/aide --check
EOF

echo "==> 7/10 AppArmor ativo e reforcado"
apt -y install apparmor apparmor-utils
aa-enforce /etc/apparmor.d/* 2>/dev/null || true

echo "==> 8/10 Node.js e Next.js rodando como usuario restrito via systemd"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt -y install nodejs
npm install -g pm2 --unsafe-perm=false

cat > /etc/systemd/system/nextjs-app.service <<EOF
[Unit]
Description=Aplicacao Next.js (DMZ)
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/node ${APP_DIR}/node_modules/.bin/next start
Restart=on-failure
RestartSec=5

# --- Restricoes de seguranca do systemd ---
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

echo "==> 9/10 Nginx como reverse proxy com cabecalhos de seguranca e rate limit"
apt -y install nginx
cat > /etc/nginx/conf.d/security.conf <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-XSS-Protection "1; mode=block" always;
server_tokens off;
limit_req_zone $binary_remote_addr zone=appzone:10m rate=10r/s;
EOF

cat > /etc/nginx/sites-available/nextjs-app <<'EOF'
server {
    listen 80;
    server_name _;

    location / {
        limit_req zone=appzone burst=20 nodelay;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF
ln -sf /etc/nginx/sites-available/nextjs-app /etc/nginx/sites-enabled/nextjs-app
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

echo "==> 10/10 Auditoria e log de sistema"
systemctl enable --now auditd
cat >> /etc/audit/rules.d/dmz.rules <<'EOF'
-w /etc/passwd -p wa -k identidade
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /opt/nextjs-app -p wa -k app_files
EOF
augenrules --load || true

echo ""
echo "===================================================================="
echo "Blindagem concluida."
echo "SSH agora esta na porta ${NEW_SSH_PORT}, apenas com chave publica."
echo "Antes de fechar esta sessao, ABRA UM NOVO TERMINAL e confirme que"
echo "consegue logar: ssh -p ${NEW_SSH_PORT} root@<ip-da-vm>"
echo "Depois faca deploy da aplicacao em ${APP_DIR}, rode 'npm ci --omit=dev'"
echo "(nunca 'npm install' solto em producao) e habilite o servico:"
echo "  systemctl enable --now nextjs-app"
echo "===================================================================="