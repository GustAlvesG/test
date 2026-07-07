#!/usr/bin/env bash
#
# fix-tsconfig-paths2.sh  (versao corrigida)
# Testa se a sobreposicao de "paths" no tsconfig.json e a causa do
# "Module not found: @/components/..." no build.
#
# Seguro: backup + rollback automatico se o build falhar.
#
# Uso:
#   cd /opt/nextjs-app
#   sudo -u nextapp bash fix-tsconfig-paths2.sh
#
set -uo pipefail

PROJ="${1:-$(pwd)}"
TS="$PROJ/tsconfig.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="$PROJ/tsconfig.json.bak-$STAMP"

echo "== Projeto: $PROJ"
[ -f "$TS" ] || { echo "ERRO: $TS nao encontrado"; exit 1; }

echo "== 1) Backup -> $BAK"
cp "$TS" "$BAK"

echo "== 2) Reescrevendo o bloco paths (especificas antes da generica)"
# Passa o caminho do tsconfig como ARGUMENTO ($1 dentro do node), nao via env.
node - "$TS" <<'NODE'
const fs = require('fs');
const tsPath = process.argv[2];              // <- caminho recebido como argumento
if (!tsPath) { console.error('caminho do tsconfig nao recebido'); process.exit(1); }

const raw = fs.readFileSync(tsPath, 'utf8');
const json = JSON.parse(raw);

const co = json.compilerOptions || {};
co.baseUrl = co.baseUrl || '.';

// Especificas primeiro; generica "@/*" por ultimo, cobrindo raiz E ./app como fallback.
co.paths = {
  "@/components/*": ["./app/components/*"],
  "@/hooks/*":      ["./app/hooks/*"],
  "@/styles/*":     ["./styles/*"],
  "@/services/*":   ["./services/*"],
  "@/context/*":    ["./context/*"],
  "@/images/*":     ["./public/images/*"],
  "@/api/*":        ["./src/pages/api/*"],
  "@/utils/*":      ["./src/utils/*"],
  "@/pages/*":      ["./app/*"],
  "@/public/*":     ["./public/*"],
  "@/*":            ["./*", "./app/*"]
};

json.compilerOptions = co;
fs.writeFileSync(tsPath, JSON.stringify(json, null, 2) + "\n", 'utf8');
console.log("   tsconfig.json reescrito. Novo bloco paths:");
console.log(JSON.stringify(co.paths, null, 2));
NODE

if [ $? -ne 0 ]; then
  echo "ERRO ao reescrever o JSON. Restaurando backup."
  cp "$BAK" "$TS"
  exit 1
fi

echo "== 3) Limpando cache (.next e *.tsbuildinfo)"
rm -rf "$PROJ/.next"
find "$PROJ" -maxdepth 1 -name "*.tsbuildinfo" -delete 2>/dev/null

echo "== 4) Rodando build de teste..."
cd "$PROJ"
if npm run build; then
  echo ""
  echo "=================================================================="
  echo " BUILD PASSOU. A causa era a sobreposicao de paths no tsconfig."
  echo " Backup do original em: $BAK"
  echo " Replique essa ordenacao de 'paths' no tsconfig do REPOSITORIO"
  echo " (com o Erick) para nao voltar no proximo git pull."
  echo "=================================================================="
else
  echo ""
  echo "=================================================================="
  echo " BUILD AINDA FALHOU. A causa nao era o tsconfig."
  echo " Restaurando o original a partir do backup."
  echo "=================================================================="
  cp "$BAK" "$TS"
  echo " Original restaurado. Nada alterado em definitivo."
  exit 2
fi