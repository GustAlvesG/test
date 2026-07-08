#!/usr/bin/env bash
#
# setup-https-nginx.sh
# Configura o Nginx da VM (DMZ) para servir a aplicacao Next.js em HTTPS,
# usando um certificado .crt/.key JA EXISTENTE (sem Let's Encrypt).
#
# Mantem a stack atual: Nginx (proxy reverso) + systemd (nextjs-app.service).
# NAO usa Apache nem PM2.
#
# Pre-requisitos (faca ANTES de rodar):
#   - Certificado em: /etc/nginx/ssl/espacos.crt   (com a cadeia da CA, se houver)
#   - Chave privada em: /etc/nginx/ssl/espacos.key  (chmod 600)
#   - Servico nextjs-app rodando na porta 3000
#
# Rodar como ROOT:
#   sudo bash setup-https-nginx.sh
#
set -uo pipefail

DOMAIN="espacos.clubedosfuncionarios.com.br"
CRT="/etc/nginx/ssl/espacos.crt"
KEY="/etc/nginx/ssl/espacos.key"
APP_PORT=3000
SITE="/etc/nginx/sites-available/nextjs-app"
STAMP="$(date +%Y%m%d-%H%M%S)"

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)."; exit 1; }

echo "== Verificando pre-requisitos"
[ -f "$CRT" ] || { echo "ERRO: certificado nao encontrado em $CRT"; exit 1; }
[ -f "$KEY" ] || { echo "ERRO: chave privada nao encontrada em $KEY"; exit 1; }

# Confere se a chave corresponde ao certificado (modulos devem bater)
MOD_CRT="$(openssl x509 -noout -modulus -in "$CRT" 2>/dev/null | openssl md5)"
MOD_KEY="$(openssl rsa  -noout -modulus -in "$KEY" 2>/dev/null | openssl md5)"
if [ -n "$MOD_CRT" ] && [ "$MOD_CRT" != "$MOD_KEY" ]; then
  echo "ATENCAO: o modulo do .crt e do .key NAO batem."
  echo "  O certificado e a chave podem nao ser um par. Verifique antes de prosseguir."
  echo "  (Se for chave EC em vez de RSA, este teste pode falhar mesmo estando correto.)"
  read -p "  Continuar mesmo assim? [s/N] " r
  [ "$r" = "s" ] || { echo "Abortado."; exit 1; }
else
  echo "  OK: certificado e chave conferem."
fi

# Mostra validade do certificado
echo "== Validade do certificado:"
openssl x509 -noout -dates -subject -in "$CRT" 2>/dev/null

echo "== Backup do site atual (se existir) -> ${SITE}.bak-${STAMP}"
[ -f "$SITE" ] && cp "$SITE" "${SITE}.bak-${STAMP}"

echo "== Escrevendo configuracao HTTPS do Nginx"
cat > "$SITE" <<EOF
# HTTP -> redireciona tudo para HTTPS
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

# HTTPS
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CRT};
    ssl_certificate_key ${KEY};

    # Protocolos e ciphers modernos
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # HSTS (forca HTTPS no navegador por 1 ano)
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Proxy para a aplicacao Next.js (systemd, porta ${APP_PORT})
    location / {
        limit_req zone=appzone burst=20 nodelay;
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Garante que o site esta habilitado
ln -sf "$SITE" /etc/nginx/sites-enabled/nextjs-app
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

echo "== Testando a configuracao do Nginx"
if nginx -t; then
  echo "== Config OK. Recarregando Nginx."
  systemctl reload nginx
else
  echo "ERRO na configuracao do Nginx. Restaurando backup."
  [ -f "${SITE}.bak-${STAMP}" ] && cp "${SITE}.bak-${STAMP}" "$SITE"
  nginx -t && systemctl reload nginx
  exit 1
fi

echo "== Garantindo que o firewall libera 443"
ufw allow 443/tcp 2>/dev/null || true

echo ""
echo "== Testes locais:"
echo -n "  HTTP  (deve dar 301 redirect): "
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1 -H "Host: ${DOMAIN}"
echo -n "  HTTPS (deve dar 200 ou 307)  : "
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1 -H "Host: ${DOMAIN}"

echo ""
echo "=================================================================="
echo " Configuracao concluida."
echo " Teste do seu navegador: https://${DOMAIN}"
echo ""
echo " Se o navegador reclamar de certificado, verifique se o ${CRT}"
echo " inclui a CADEIA INTERMEDIARIA da CA (certificado do site + chain)."
echo "=================================================================="