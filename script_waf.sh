#!/usr/bin/env bash
#
# instalar-waf.sh
# Instala e configura ModSecurity v3 + OWASP Core Rule Set (CRS) como WAF no Nginx.
# Ubuntu Server 24.04.
#
# IMPORTANTE - leia antes:
#   - Comeca em modo DETECTION ONLY (so registra, nao bloqueia). Isso e proposital:
#     um WAF em blocking mode logo de cara vai gerar falsos positivos e pode
#     quebrar sua aplicacao (login, pagamento). Voce roda em deteccao, analisa os
#     logs por alguns dias, ajusta as excecoes, e SO ENTAO liga o bloqueio.
#   - NAO substitui a correcao do codigo (ja feita). E camada extra, defesa em profundidade.
#
# Rodar como root:  sudo bash instalar-waf.sh
#
set -uo pipefail

DOMAIN="espacos.clubedosfuncionarios.com.br"
SITE_CONF="/etc/nginx/sites-available/nextjs-app"
STAMP="$(date +%Y%m%d-%H%M%S)"

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)."; exit 1; }

echo "=================================================================="
echo " Instalacao de WAF (ModSecurity + OWASP CRS) - modo DETECCAO"
echo "=================================================================="

echo "== 1/6 Instalando ModSecurity e o conector do Nginx"
apt update
# No Ubuntu 24.04 este pacote traz o modulo do ModSecurity para o Nginx:
if apt -y install libnginx-mod-http-modsecurity libmodsecurity3 modsecurity-crs 2>/dev/null; then
  echo "   Pacotes instalados via APT."
  PKG_OK=1
else
  echo "   AVISO: pacote libnginx-mod-http-modsecurity nao disponivel/ falhou."
  echo "   Nesta versao pode ser necessario compilar o conector manualmente."
  echo "   Veja a secao 'Instalacao manual' no final deste script (comentada)."
  PKG_OK=0
fi

echo "== 2/6 Preparando configuracao base do ModSecurity"
mkdir -p /etc/nginx/modsec

# Baixa o arquivo de recomendacao base, se nao existir
if [ ! -f /etc/nginx/modsec/modsecurity.conf ]; then
  if [ -f /etc/modsecurity/modsecurity.conf-recommended ]; then
    cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf
  elif [ -f /usr/share/modsecurity-crs/modsecurity.conf-recommended ]; then
    cp /usr/share/modsecurity-crs/modsecurity.conf-recommended /etc/nginx/modsec/modsecurity.conf
  else
    # Config minima se o arquivo recomendado nao existir
    cat > /etc/nginx/modsec/modsecurity.conf <<'EOF'
SecRuleEngine DetectionOnly
SecRequestBodyAccess On
SecResponseBodyAccess Off
SecAuditEngine RelevantOnly
SecAuditLogParts ABIJDEFHZ
SecAuditLog /var/log/nginx/modsec_audit.log
SecAuditLogType Serial
SecDebugLog /var/log/nginx/modsec_debug.log
SecDebugLogLevel 0
SecRequestBodyLimit 13107200
SecRequestBodyNoFilesLimit 131072
EOF
  fi
fi

# GARANTE modo DETECCAO (nao bloqueia ainda) - ponto critico para nao quebrar a app
sed -i 's/^SecRuleEngine .*/SecRuleEngine DetectionOnly/' /etc/nginx/modsec/modsecurity.conf
grep -q "^SecRuleEngine" /etc/nginx/modsec/modsecurity.conf || echo "SecRuleEngine DetectionOnly" >> /etc/nginx/modsec/modsecurity.conf

echo "== 3/6 Configurando o OWASP Core Rule Set (CRS)"
CRS_SETUP=""
for p in /usr/share/modsecurity-crs/crs-setup.conf.example /etc/modsecurity-crs/crs-setup.conf.example /etc/nginx/modsec/crs/crs-setup.conf.example; do
  [ -f "$p" ] && CRS_SETUP="$p" && break
done

if [ -n "$CRS_SETUP" ]; then
  CRS_DIR="$(dirname "$CRS_SETUP")"
  cp "$CRS_SETUP" "${CRS_DIR}/crs-setup.conf" 2>/dev/null || true
  # Monta o arquivo principal que carrega tudo
  cat > /etc/nginx/modsec/main.conf <<EOF
Include /etc/nginx/modsec/modsecurity.conf
Include ${CRS_DIR}/crs-setup.conf
Include ${CRS_DIR}/rules/*.conf
EOF
  echo "   CRS encontrado em: $CRS_DIR"
else
  echo "   AVISO: CRS nao encontrado automaticamente."
  echo "   Instale com: apt install modsecurity-crs  (ou baixe de github.com/coreruleset/coreruleset)"
  cat > /etc/nginx/modsec/main.conf <<EOF
Include /etc/nginx/modsec/modsecurity.conf
EOF
fi

echo "== 4/6 Ativando o modulo e o ModSecurity no Nginx"
# Garante o carregamento do modulo (load_module) no nginx.conf principal
if [ "$PKG_OK" -eq 1 ] && ! grep -q "ngx_http_modsecurity_module" /etc/nginx/nginx.conf; then
  # No Ubuntu, o pacote costuma criar /etc/nginx/modules-enabled/ com o load automatico.
  # Se nao, adiciona manualmente no topo:
  if [ -f /usr/share/nginx/modules-available/mod-http-modsecurity.conf ] || ls /etc/nginx/modules-enabled/*modsecurity* >/dev/null 2>&1; then
    echo "   Modulo ja habilitado via modules-enabled."
  else
    sed -i '1i load_module modules/ngx_http_modsecurity_module.so;' /etc/nginx/nginx.conf
  fi
fi

# Ativa o ModSecurity dentro do server block do site (backup antes)
cp "$SITE_CONF" "${SITE_CONF}.bak-${STAMP}"
if ! grep -q "modsecurity on" "$SITE_CONF"; then
  # Insere as diretivas logo apos a primeira ocorrencia de "listen 443"
  sed -i '/listen 443/a\    modsecurity on;\n    modsecurity_rules_file /etc/nginx/modsec/main.conf;' "$SITE_CONF"
fi

echo "== 5/6 Testando a configuracao do Nginx"
if nginx -t; then
  systemctl reload nginx
  echo "   Nginx recarregado com o WAF em modo DETECCAO."
else
  echo "   ERRO na config do Nginx. Restaurando backup do site."
  cp "${SITE_CONF}.bak-${STAMP}" "$SITE_CONF"
  nginx -t && systemctl reload nginx
  echo "   Config do site restaurada. Verifique se o modulo carregou corretamente."
  exit 1
fi

echo "== 6/6 Concluido (modo DETECCAO)"
echo ""
echo "=================================================================="
echo " WAF instalado em modo DETECTION ONLY (registra, NAO bloqueia)."
echo ""
echo " PROXIMOS PASSOS (nao pule):"
echo " 1. Use a aplicacao normalmente por alguns dias (login, pagamento, etc)."
echo " 2. Analise o que o WAF PEGARIA como ataque:"
echo "      sudo tail -f /var/log/nginx/modsec_audit.log"
echo " 3. Se aparecerem FALSOS POSITIVOS (acoes legitimas da sua app sendo"
echo "    marcadas), crie regras de excecao (SecRuleRemoveById) para elas."
echo " 4. SO DEPOIS de ajustar, ligue o bloqueio de verdade:"
echo "      troque 'SecRuleEngine DetectionOnly' por 'SecRuleEngine On'"
echo "      em /etc/nginx/modsec/modsecurity.conf, depois:"
echo "      sudo nginx -t && sudo systemctl reload nginx"
echo ""
echo " Backup do site: ${SITE_CONF}.bak-${STAMP}"
echo "=================================================================="

# --------------------------------------------------------------------------
# INSTALACAO MANUAL (se o pacote APT nao funcionar no seu 24.04):
# O ModSecurity v3 + conector Nginx precisa ser compilado. Passos gerais:
#   apt install -y git g++ make automake libtool pkg-config libcurl4-openssl-dev \
#       liblua5.3-dev libfuzzy-dev libpcre2-dev libxml2-dev libyajl-dev zlib1g-dev
#   git clone --depth 1 -b v3/master https://github.com/owasp-modsecurity/ModSecurity /opt/ModSecurity
#   cd /opt/ModSecurity && git submodule update --init && ./build.sh && ./configure && make && make install
#   git clone --depth 1 https://github.com/owasp-modsecurity/ModSecurity-nginx /opt/ModSecurity-nginx
#   # recompilar o Nginx com --add-dynamic-module=/opt/ModSecurity-nginx (versao igual a instalada)
# Se precisar deste caminho, me avise que detalho para a sua versao de Nginx.
# --------------------------------------------------------------------------