#!/usr/bin/env bash
#
# fix-next-alias.sh
# Solucao definitiva para "Module not found: @/..." no build de producao.
#
# Causa comprovada: o Next.js NAO esta aplicando os "paths" do tsconfig.json
# neste ambiente (import relativo funciona, import "@/" falha). A correcao e
# definir o alias "@" DIRETAMENTE no webpack, dentro do next.config.ts, que
# e sempre lido tanto em dev quanto em build, sem depender do tsconfig.
#
# Mapeia "@/..." para a RAIZ do projeto, replicando o comportamento esperado
# pelos paths do tsconfig (onde @/components -> ./app/components etc).
# Como os paths do tsconfig usam bases diferentes (./, ./app, ./src, ./styles),
# criamos TODOS os aliases especificos no webpack, iguais ao tsconfig.
#
# Seguro: backup + rollback automatico se o build falhar.
#
# Uso:
#   cd /opt/nextjs-app
#   sudo -u nextapp bash fix-next-alias.sh
#
set -uo pipefail

PROJ="${1:-$(pwd)}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Descobre qual next.config existe
CFG=""
for c in next.config.ts next.config.mjs next.config.js; do
  [ -f "$PROJ/$c" ] && CFG="$PROJ/$c" && break
done
[ -z "$CFG" ] && { echo "ERRO: nenhum next.config encontrado"; exit 1; }
BAK="${CFG}.bak-${STAMP}"

echo "== Projeto : $PROJ"
echo "== Config  : $CFG"
echo "== 1) Backup -> $BAK"
cp "$CFG" "$BAK"

echo "== 2) Injetando alias de webpack no next.config"
# Usa node para reescrever o arquivo: garante import do 'path' e insere a
# funcao webpack() dentro do objeto de config, sem quebrar o que ja existe.
node - "$CFG" <<'NODE'
const fs = require('fs');
const cfgPath = process.argv[2];
let src = fs.readFileSync(cfgPath, 'utf8');

// Se ja tem alias '@' configurado por nos, nao duplica.
if (src.includes('// [alias-fix]')) {
  console.log('   Alias ja aplicado anteriormente. Nada a fazer.');
  process.exit(0);
}

// 1) Garante 'import path from "path"' no topo (para arquivos TS/ESM).
if (!/from\s+['"]path['"]/.test(src) && !/require\(['"]path['"]\)/.test(src)) {
  // insere logo apos a primeira linha de import, ou no topo se nao houver
  if (/^import\s.+$/m.test(src)) {
    src = src.replace(/(^import\s.+$)/m, `$1\nimport path from "path";`);
  } else {
    src = `import path from "path";\n` + src;
  }
}

// 2) Bloco webpack a inserir dentro do objeto de config.
const webpackBlock = `
  // [alias-fix] resolve "@/..." direto no webpack, independente do tsconfig
  webpack: (config) => {
    config.resolve = config.resolve || {};
    config.resolve.alias = {
      ...(config.resolve.alias || {}),
      "@/components": path.resolve(__dirname, "app/components"),
      "@/hooks": path.resolve(__dirname, "app/hooks"),
      "@/styles": path.resolve(__dirname, "styles"),
      "@/services": path.resolve(__dirname, "services"),
      "@/context": path.resolve(__dirname, "context"),
      "@/images": path.resolve(__dirname, "public/images"),
      "@/api": path.resolve(__dirname, "src/pages/api"),
      "@/utils": path.resolve(__dirname, "src/utils"),
      "@/pages": path.resolve(__dirname, "app"),
      "@/public": path.resolve(__dirname, "public"),
      "@": path.resolve(__dirname, "."),
    };
    return config;
  },`;

// 3) Insere o bloco logo apos "const nextConfig ... = {"
const anchor = /(const\s+nextConfig[^=]*=\s*\{)/;
if (anchor.test(src)) {
  src = src.replace(anchor, `$1\n${webpackBlock}`);
} else {
  console.error('   NAO encontrei "const nextConfig = {" para inserir o bloco.');
  console.error('   Abortando para nao corromper o arquivo.');
  process.exit(1);
}

fs.writeFileSync(cfgPath, src, 'utf8');
console.log('   Alias de webpack inserido com sucesso.');
NODE

if [ $? -ne 0 ]; then
  echo "ERRO ao editar o next.config. Restaurando backup."
  cp "$BAK" "$CFG"
  exit 1
fi

echo ""
echo "== 3) next.config resultante (para conferencia):"
echo "-------------------------------------------------------------"
sed -n '1,40p' "$CFG"
echo "-------------------------------------------------------------"

echo "== 4) Limpando cache"
rm -rf "$PROJ/.next"
find "$PROJ" -maxdepth 1 -name "*.tsbuildinfo" -delete 2>/dev/null

echo "== 5) Build de teste..."
cd "$PROJ"
if npm run build; then
  echo ""
  echo "=================================================================="
  echo " BUILD PASSOU! O alias agora e resolvido pelo webpack."
  echo " Backup do next.config original em: $BAK"
  echo ""
  echo " Leve essa mesma alteracao para o REPOSITORIO (com o Erick):"
  echo " adicionar o bloco webpack() com os alias no next.config.ts."
  echo " Assim funciona em qualquer ambiente e nao volta no git pull."
  echo "=================================================================="
else
  echo ""
  echo "=================================================================="
  echo " BUILD AINDA FALHOU. Restaurando next.config original."
  echo "=================================================================="
  cp "$BAK" "$CFG"
  echo " Original restaurado. Me envie a saida completa deste build."
  exit 2
fi