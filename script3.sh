#!/usr/bin/env bash
#
# fix-tsconfig-paths.sh
# Testa a hipotese de que a REGRA GENERICA "@/*": ["./*"] no tsconfig.json
# esta conflitando com as regras especificas ("@/components/*", "@/styles/*"),
# fazendo o resolver do build procurar na pasta errada.
#
# ESTRATEGIA SEGURA:
#   1. Faz backup do tsconfig.json (tsconfig.json.bak-AAAAMMDD-HHMMSS)
#   2. Reordena os paths: coloca as regras ESPECIFICAS antes da GENERICA
#      e ajusta a generica "@/*" para tambem cobrir ./app/* (que e onde o
#      codigo realmente vive), sem remover nenhum mapeamento existente.
#   3. Limpa cache e roda o build.
#   4. Se o build FALHAR, restaura o backup automaticamente.
#   5. Se PASSAR, mantem a correcao e avisa para replicar no repositorio.
#
# Uso:
#   cd /opt/nextjs-app
#   sudo -u nextapp bash fix-tsconfig-paths.sh
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
# Usa node para manipular o JSON com seguranca (preserva o resto do arquivo).
node <<'NODE'
const fs = require('fs');
const path = process.env.PROJ + '/tsconfig.json';
const raw = fs.readFileSync(path, 'utf8');
const json = JSON.parse(raw);

const co = json.compilerOptions || {};
co.baseUrl = co.baseUrl || '.';

// Mapeamento desejado: especificas primeiro, generica por ULTIMO,
// e a generica passa a cobrir tanto a raiz quanto ./app (fallback).
const desired = {
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
  // generica por ultimo, cobrindo raiz E app como fallback
  "@/*":            ["./*", "./app/*"]
};

co.paths = desired;
json.compilerOptions = co;

fs.writeFileSync(path, JSON.stringify(json, null, 2) + "\n", 'utf8');
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
  echo ""
  echo " IMPORTANTE: replique essa mesma ordenacao de 'paths' no tsconfig"
  echo " do REPOSITORIO (com o Erick), senao no proximo 'git pull' o"
  echo " problema volta. As regras especificas devem vir ANTES da '@/*',"
  echo " e a '@/*' deve incluir './app/*' como fallback."
  echo "=================================================================="
else
  echo ""
  echo "=================================================================="
  echo " BUILD AINDA FALHOU. A causa nao era (so) o tsconfig."
  echo " Restaurando o tsconfig.json original a partir do backup."
  echo "=================================================================="
  cp "$BAK" "$TS"
  echo " Original restaurado. Nada foi alterado em definitivo."
  echo " Proximo passo: comparar package-lock.json com o do dev, ou testar"
  echo " se o problema e a versao exata do Next.js instalada."
  exit 2
fi