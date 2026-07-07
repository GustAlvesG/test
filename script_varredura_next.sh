#!/usr/bin/env bash
#
# diagnostico-nextjs.sh
# Varre um projeto Next.js e coleta tudo que pode explicar erros de
# "Module not found: Can't resolve '@/...'" para analise offline.
#
# Uso:
#   cd /opt/nextjs-app
#   sudo -u nextapp bash diagnostico-nextjs.sh
# ou apontando o caminho:
#   bash diagnostico-nextjs.sh /opt/nextjs-app
#
# Gera: ./diagnostico-nextjs.log  (na pasta do projeto)

PROJ="${1:-$(pwd)}"
LOG="$PROJ/diagnostico-nextjs.log"

# Redireciona tudo (stdout+stderr) para o log e tambem mostra na tela
exec > >(tee "$LOG") 2>&1

sep() { echo ""; echo "======================================================================"; echo "== $1"; echo "======================================================================"; }

sep "0. METADADOS"
echo "Data.............: $(date)"
echo "Projeto.........: $PROJ"
echo "Usuario.........: $(whoami)"
echo "pwd -P..........: $(cd "$PROJ" && pwd -P)"
echo "readlink -f.....: $(readlink -f "$PROJ")"

sep "1. VERSOES"
echo "node: $(node -v 2>/dev/null)"
echo "npm.: $(npm -v 2>/dev/null)"
echo "next (instalado no node_modules):"
cat "$PROJ/node_modules/next/package.json" 2>/dev/null | grep '"version"' | head -1
echo "next/react/typescript no package.json:"
grep -E '"(next|react|typescript)"' "$PROJ/package.json" 2>/dev/null

sep "2. ARQUIVOS DE CONFIG DE TS/JS (procura duplicatas fora de node_modules)"
find "$PROJ" \( -name "tsconfig*.json" -o -name "jsconfig*.json" \) -not -path "*/node_modules/*" 2>/dev/null

sep "2b. CONTEUDO DE CADA tsconfig/jsconfig ENCONTRADO + VALIDACAO JSON"
while IFS= read -r f; do
  echo "----- $f -----"
  cat "$f"
  echo ""
  echo "[Validacao JSON]:"
  node -e "try{JSON.parse(require('fs').readFileSync('$f','utf8'));console.log('  -> JSON VALIDO')}catch(e){console.log('  -> JSON INVALIDO: '+e.message)}" 2>/dev/null
  echo ""
done < <(find "$PROJ" \( -name "tsconfig*.json" -o -name "jsconfig*.json" \) -not -path "*/node_modules/*" 2>/dev/null)

sep "3. NEXT CONFIG"
for cfg in next.config.js next.config.mjs next.config.ts; do
  if [ -f "$PROJ/$cfg" ]; then
    echo "----- $cfg -----"
    cat "$PROJ/$cfg"
    echo ""
  fi
done

sep "4. ROTAS DUPLICADAS (varios page.tsx pra mesma rota / conflito app vs pages)"
echo "Todos os page.* fora de node_modules/.next:"
find "$PROJ" -name "page.*" -not -path "*/node_modules/*" -not -path "*/.next/*" 2>/dev/null
echo ""
echo "Especificamente rota checkout:"
find "$PROJ" -path "*checkout*" \( -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" \) -not -path "*/node_modules/*" -not -path "*/.next/*" 2>/dev/null
echo ""
echo "Existe diretorio pages/ E app/ ao mesmo tempo?"
[ -d "$PROJ/pages" ] && echo "  pages/ EXISTE" || echo "  pages/ nao existe"
[ -d "$PROJ/app" ]   && echo "  app/ EXISTE"   || echo "  app/ nao existe"
[ -d "$PROJ/src/pages" ] && echo "  src/pages/ EXISTE" || echo "  src/pages/ nao existe"
[ -d "$PROJ/src/app" ]   && echo "  src/app/ EXISTE"   || echo "  src/app/ nao existe"

sep "5. ESTRUTURA DE PASTAS RELEVANTES (case-sensitive)"
echo "--- app/ (2 niveis) ---"
find "$PROJ/app" -maxdepth 2 -type d 2>/dev/null | sort
echo ""
echo "--- app/components/ (tudo) ---"
find "$PROJ/app/components" -type d 2>/dev/null | sort
echo ""
echo "--- styles/ ---"
find "$PROJ/styles" -maxdepth 1 2>/dev/null | sort
find "$PROJ/app/styles" -maxdepth 1 2>/dev/null | sort

sep "6. ALVOS EXATOS DOS IMPORTS QUE FALHAM (existe? case exato?)"
check() {
  # $1 = descricao do import, $2..= candidatos de caminho
  echo "IMPORT: $1"
  shift
  local achou=0
  for p in "$@"; do
    if [ -e "$p" ]; then
      echo "   [OK] existe: $p"
      achou=1
    fi
  done
  [ "$achou" -eq 0 ] && echo "   [FALTA] nenhum candidato existe"
  echo ""
}
check "@/components/Checkout/checkout" \
  "$PROJ/app/components/Checkout/checkout.tsx" "$PROJ/app/components/Checkout/checkout.ts" \
  "$PROJ/app/components/Checkout/checkout.jsx" "$PROJ/app/components/Checkout/checkout/index.tsx"
check "@/components/Common/footer" \
  "$PROJ/app/components/Common/footer.tsx" "$PROJ/app/components/Common/footer.ts" \
  "$PROJ/app/components/Common/footer/index.tsx"
check "@/components/Common/header" \
  "$PROJ/app/components/Common/header.tsx" "$PROJ/app/components/Common/header.ts" \
  "$PROJ/app/components/Common/header/index.tsx"
check "@/styles/checkout.module.css" \
  "$PROJ/styles/checkout.module.css" "$PROJ/app/styles/checkout.module.css"
check "@/styles/page.module.css" \
  "$PROJ/styles/page.module.css" "$PROJ/app/styles/page.module.css"

sep "6b. LISTAGEM CRUA (ls -la) DAS PASTAS-ALVO - para ver case e permissoes reais"
echo "--- ls app/components/Checkout ---"
ls -la "$PROJ/app/components/Checkout" 2>/dev/null || echo "  (pasta nao existe com esse case exato)"
echo "--- ls app/components/Common ---"
ls -la "$PROJ/app/components/Common" 2>/dev/null || echo "  (pasta nao existe com esse case exato)"
echo "--- ls styles ---"
ls -la "$PROJ/styles" 2>/dev/null || echo "  (pasta nao existe)"

sep "7. CARACTERES OCULTOS / ENCODING no page.tsx do checkout"
CK="$PROJ/app/checkout/page.tsx"
if [ -f "$CK" ]; then
  echo "file: $(file "$CK")"
  echo ""
  echo "--- primeiras 25 linhas com cat -A (mostra ^M de CRLF, ^I de tab, \$ de fim de linha) ---"
  cat -A "$CK" | head -25
  echo ""
  echo "--- tem CRLF (\r)? ---"
  if grep -lU $'\r' "$CK" >/dev/null 2>&1; then echo "  SIM - arquivo tem quebras de linha Windows (CRLF)"; else echo "  nao - Unix (LF)"; fi
  echo ""
  echo "--- tem BOM no inicio? ---"
  head -c 3 "$CK" | od -An -tx1
  echo "  (se aparecer 'ef bb bf' no inicio, tem BOM UTF-8)"
else
  echo "ARQUIVO NAO ENCONTRADO: $CK"
fi

sep "8. GREP DE TODOS OS IMPORTS COM @/ NO checkout/page.tsx"
grep -nE "from ['\"]@/" "$CK" 2>/dev/null

sep "9. GIT - estado do clone e case sensitivity"
cd "$PROJ" 2>/dev/null
echo "git status (resumido):"
git status 2>/dev/null | head -5
echo ""
echo "git config core.ignorecase:"
git config core.ignorecase 2>/dev/null
echo ""
echo "Branch atual:"
git branch --show-current 2>/dev/null
echo ""
echo "Arquivos que o git ACHA que existem em app/components (segundo o indice):"
git ls-files "app/components/Checkout/*" "app/components/Common/*" 2>/dev/null

sep "10. FIM"
echo "Log salvo em: $LOG"
echo "Envie o conteudo desse arquivo para analise."