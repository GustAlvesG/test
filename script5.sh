#!/usr/bin/env bash
#
# fix-nextjs-service.sh
# Corrige o servico systemd nextjs-app.service que esta em crash-loop
# com SIGTRAP (status=5/TRAP).
#
# CAUSA: a diretiva de hardening "MemoryDenyWriteExecute=true" impede memoria
# gravavel+executavel, que o motor V8/Node PRECISA para o JIT. O Node e morto
# com SIGTRAP ao compilar. Removemos SO essa flag e ajustamos o ExecStart,
# mantendo TODAS as demais protecoes de seguranca (que sao compativeis).
#
# Rodar como ROOT (mexe em /etc/systemd).
#   sudo bash fix-nextjs-service.sh
#
set -uo pipefail

SVC="/etc/systemd/system/nextjs-app.service"
APP_DIR="/opt/nextjs-app"
APP_USER="nextapp"
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="${SVC}.bak-${STAMP}"

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)."; exit 1; }
[ -f "$SVC" ] || { echo "ERRO: $SVC nao existe."; exit 1; }

echo "== Backup do service -> $BAK"
cp "$SVC" "$BAK"

# Descobre o caminho real do next (binario) para um ExecStart robusto.
NEXT_BIN="$APP_DIR/node_modules/next/dist/bin/next"
if [ ! -f "$NEXT_BIN" ]; then
  # fallback para o symlink .bin/next
  NEXT_BIN="$APP_DIR/node_modules/.bin/next"
fi
NODE_BIN="$(command -v node)"

echo "== node : $NODE_BIN"
echo "== next : $NEXT_BIN"

echo "== Reescrevendo $SVC"
cat > "$SVC" <<EOF
[Unit]
Description=Aplicacao Next.js (DMZ)
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=NODE_ENV=production
Environment=PORT=3000
ExecStart=${NODE_BIN} ${NEXT_BIN} start -p 3000
Restart=on-failure
RestartSec=5

# --- Restricoes de seguranca COMPATIVEIS com Node/V8 ---
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
# MemoryDenyWriteExecute REMOVIDO: incompativel com o JIT do V8/Node (causa SIGTRAP).
# CapabilityBoundingSet vazio: processo nao precisa de nenhuma capability de root.
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF

echo "== Recarregando systemd e reiniciando o servico"
systemctl daemon-reload
systemctl reset-failed nextjs-app 2>/dev/null || true
systemctl enable --now nextjs-app

sleep 4
echo ""
echo "== Status:"
systemctl status nextjs-app --no-pager || true

echo ""
echo "== Teste local na porta 3000:"
sleep 2
if curl -sf -o /dev/null -w "  HTTP %{http_code}\n" http://127.0.0.1:3000; then
  echo ""
  echo "=================================================================="
  echo " SERVICO NO AR. Agora teste o Nginx: curl -I http://127.0.0.1"
  echo " Backup do service anterior em: $BAK"
  echo "=================================================================="
else
  echo ""
  echo "=================================================================="
  echo " Ainda nao respondeu na 3000. Veja o log:"
  echo "   journalctl -u nextjs-app -n 40 --no-pager"
  echo " Se o erro mudou de SIGTRAP para outra coisa, me envie o novo log."
  echo "=================================================================="
fi