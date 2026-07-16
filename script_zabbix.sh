#!/usr/bin/env bash
#
# instalar-zabbix-agent.sh
# Instala o Zabbix Agent 2 em modo ATIVO na VM DMZ (Ubuntu 24.04).
#
# Modo ATIVO: o agente INICIA a conexao com o servidor (DMZ -> interna, porta 10051).
# NAO abre nenhuma porta de entrada na DMZ. E o modelo seguro para DMZ.
#
# Pre-requisito de rede: saida liberada da VM para <IP_ZABBIX_SERVER>:10051.
#
# Rodar como root:  sudo bash instalar-zabbix-agent.sh
#
set -uo pipefail

# ============ PARAMETROS - AJUSTE ============
ZABBIX_SERVER_IP="192.168.10.20"      # IP do seu servidor Zabbix (ajuste!)
HOSTNAME_ZBX="DMZ-NextJS-Web02"       # nome que ESTE host tera no Zabbix (deve bater com o host criado la)
ZABBIX_VERSION="7.0"                  # linha LTS do Zabbix (ajuste conforme seu server)

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)."; exit 1; }

echo "== 1/5 Adicionando o repositorio oficial do Zabbix"
UBUNTU_CODENAME="$(. /etc/os-release && echo $VERSION_CODENAME)"
RELEASE_DEB="zabbix-release_latest_${ZABBIX_VERSION}+ubuntu24.04_all.deb"
cd /tmp
wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/${RELEASE_DEB}" \
  || wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/${RELEASE_DEB}"
dpkg -i "${RELEASE_DEB}"
apt update

echo "== 2/5 Instalando o Zabbix Agent 2"
apt -y install zabbix-agent2 zabbix-agent2-plugin-*

echo "== 3/5 Configurando o agente em modo ATIVO"
CONF=/etc/zabbix/zabbix_agent2.conf
cp "$CONF" "${CONF}.bak"

# Zera as diretivas relevantes e reescreve
sed -i \
  -e "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" \
  -e "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}/" \
  -e "s/^Hostname=.*/Hostname=${HOSTNAME_ZBX}/" \
  "$CONF"

# Garante as linhas mesmo que estivessem comentadas
grep -q "^ServerActive=" "$CONF" || echo "ServerActive=${ZABBIX_SERVER_IP}" >> "$CONF"
grep -q "^Hostname=" "$CONF" || echo "Hostname=${HOSTNAME_ZBX}" >> "$CONF"

# Habilita UserParameters customizados (arquivo separado)
grep -q "^Include=/etc/zabbix/zabbix_agent2.d/\*.conf" "$CONF" || \
  echo "Include=/etc/zabbix/zabbix_agent2.d/*.conf" >> "$CONF"

echo "== 4/5 Instalando os UserParameters de SEGURANCA (sinais de invasao)"
mkdir -p /etc/zabbix/zabbix_agent2.d
cat > /etc/zabbix/zabbix_agent2.d/seguranca-dmz.conf <<'EOF'
# --- Sinais de comprometimento (licoes do incidente) ---

# Executaveis rodando a partir de /dev/shm ou /tmp (era onde o malware evT2NFG vivia)
UserParameter=dmz.proc.shm_tmp,ls -l /proc/*/exe 2>/dev/null | grep -cE "/dev/shm/|/tmp/"

# Numero de conexoes de saida estabelecidas (pico anomalo = possivel bot de DDoS/C2)
UserParameter=dmz.net.outbound_established,ss -tun state established 2>/dev/null | tail -n +2 | wc -l

# Arquivos com permissao 777 dentro do diretorio da app (o ataque usou chmod 777)
UserParameter=dmz.app.world_writable,find /opt/nextjs-app -type f -perm -0002 -not -path "*/node_modules/*" 2>/dev/null | wc -l

# A aplicacao esta escutando na porta 3000?
UserParameter=dmz.app.port3000,ss -tln 2>/dev/null | grep -c ":3000 "

# Estado do servico da aplicacao (1 = ativo)
UserParameter=dmz.app.service_active,systemctl is-active nextjs-app >/dev/null 2>&1 && echo 1 || echo 0

# Numero de IPs banidos pelo fail2ban (pico = sob ataque)
UserParameter=dmz.f2b.banned,fail2ban-client status sshd 2>/dev/null | grep -oP "Currently banned:\s*\K[0-9]+" || echo 0

# Alertas do ModSecurity nas ultimas checagens (linhas novas no audit log)
UserParameter=dmz.waf.alerts,grep -c "ModSecurity" /var/log/nginx/modsec_audit.log 2>/dev/null || echo 0

# Dias ate o certificado SSL expirar (backup do auto-renew do Let's Encrypt)
UserParameter=dmz.ssl.days_left,expiry=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/espacos.clubedosfuncionarios.com.br/cert.pem 2>/dev/null | cut -d= -f2); [ -n "$expiry" ] && echo $(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 )) || echo -1

# Ultima modificacao do build da app (mudanca inesperada = possivel adulteracao)
UserParameter=dmz.app.build_mtime,stat -c %Y /opt/nextjs-app/.next/BUILD_ID 2>/dev/null || echo 0
EOF

# Permite ao usuario zabbix rodar fail2ban-client (necessario para o item de ban)
if ! grep -q "zabbix.*fail2ban-client" /etc/sudoers.d/zabbix 2>/dev/null; then
  echo "zabbix ALL=(root) NOPASSWD: /usr/bin/fail2ban-client status sshd" > /etc/sudoers.d/zabbix
  chmod 440 /etc/sudoers.d/zabbix
  # ajusta o userparameter para usar sudo
  sed -i 's#fail2ban-client status sshd#sudo fail2ban-client status sshd#' /etc/zabbix/zabbix_agent2.d/seguranca-dmz.conf
fi

echo "== 5/5 Iniciando o agente"
systemctl enable --now zabbix-agent2
systemctl restart zabbix-agent2
sleep 2
systemctl status zabbix-agent2 --no-pager | head -6

echo ""
echo "=================================================================="
echo " Zabbix Agent 2 instalado em modo ATIVO."
echo " Servidor: ${ZABBIX_SERVER_IP} | Hostname: ${HOSTNAME_ZBX}"
echo ""
echo " PROXIMOS PASSOS (no SERVIDOR Zabbix):"
echo " 1. Crie um Host chamado EXATAMENTE '${HOSTNAME_ZBX}'."
echo " 2. Vincule o template 'Linux by Zabbix agent active'."
echo " 3. Adicione os itens de seguranca (ver guia zabbix-itens-seguranca.md)."
echo ""
echo " Teste de conectividade (a saida DMZ->${ZABBIX_SERVER_IP}:10051 precisa estar liberada):"
echo "   nc -zv ${ZABBIX_SERVER_IP} 10051"
echo "=================================================================="