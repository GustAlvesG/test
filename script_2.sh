#!/usr/bin/env bash
#
# check-case-imports.sh
# Detecta divergencias de MAIUSCULA/MINUSCULA entre os imports "@/..." do codigo
# e os arquivos/pastas que existem de fato no disco.
#
# Motivo: o projeto builda no Windows/Mac (case-insensitive) mas falha no Linux
# (case-sensitive). Um import "@/components/checkout/x" (minusculo) que aponta pra
# uma pasta "Checkout" (maiusculo) passa no Win/Mac e QUEBRA no Linux.
#
# Uso:
#   cd /opt/nextjs-app
#   sudo -u nextapp bash check-case-imports.sh
#
# Gera: ./check-case-imports.log   (nao altera nada, so relata)

PROJ="${1:-$(pwd)}"
LOG="$PROJ/check-case-imports.log"
exec > >(tee "$LOG") 2>&1

echo "=================================================================="
echo " Verificacao de case de imports  -  $(date)"
echo " Projeto: $PROJ"
echo "=================================================================="
echo ""

# Mapa de prefixos de alias -> pasta base real (lido do tsconfig, aqui hardcoded
# conforme o log enviado). Ajuste se o tsconfig mudar.
declare -A ALIASMAP=(
  ["@/components/"]="app/components/"
  ["@/hooks/"]="app/hooks/"
  ["@/styles/"]="styles/"
  ["@/services/"]="services/"
  ["@/context/"]="context/"
  ["@/images/"]="public/images/"
  ["@/api/"]="src/pages/api/"
  ["@/utils/"]="src/utils/"
  ["@/pages/"]="app/"
  ["@/public/"]="public/"
)

problemas=0
verificados=0

# Percorre TODOS os arquivos de codigo do projeto (fora de node_modules/.next)
while IFS= read -r arquivo; do
  # Extrai cada import "@/..." do arquivo
  grep -oE "from ['\"]@/[^'\"]+['\"]" "$arquivo" 2>/dev/null | \
  sed -E "s/from ['\"]//; s/['\"]//" | while IFS= read -r imp; do

    # Descobre qual prefixo de alias casa com esse import
    base=""
    resto=""
    for prefixo in "${!ALIASMAP[@]}"; do
      if [[ "$imp" == "$prefixo"* ]]; then
        base="${ALIASMAP[$prefixo]}"
        resto="${imp#$prefixo}"
        break
      fi
    done
    [ -z "$base" ] && continue

    caminho_pedido="$PROJ/$base$resto"

    # Testa se existe com QUALQUER extensao/como pasta, ignorando case (-i via find)
    dir_pedido="$(dirname "$caminho_pedido")"
    nome_pedido="$(basename "$caminho_pedido")"

    # Existe com o case EXATO (arquivo .tsx/.ts/.jsx/.js/.css ou pasta/index)?
    exato=0
    for ext in "" ".tsx" ".ts" ".jsx" ".js" ".module.css" ".css" "/index.tsx" "/index.ts"; do
      [ -e "${caminho_pedido}${ext}" ] && exato=1 && break
    done

    if [ "$exato" -eq 1 ]; then
      : # ok, case exato existe, nada a relatar
    else
      # Nao existe com case exato. Existe com case DIFERENTE? (find -iname)
      encontrado="$(find "$dir_pedido" -maxdepth 1 -iname "${nome_pedido}*" 2>/dev/null | head -1)"
      # Tambem tenta a pasta pai com case diferente
      if [ -z "$encontrado" ] && [ ! -d "$dir_pedido" ]; then
        pai_real="$(find "$PROJ/$base" -maxdepth 3 -ipath "*${resto}*" 2>/dev/null | head -1)"
        encontrado="$pai_real"
      fi

      if [ -n "$encontrado" ]; then
        echo "### DIVERGENCIA DE CASE ###"
        echo "  Arquivo com o import : ${arquivo#$PROJ/}"
        echo "  Import escrito       : $imp"
        echo "  Esperado no disco    : ${caminho_pedido#$PROJ/}"
        echo "  Existe de fato como  : ${encontrado#$PROJ/}"
        echo ""
      else
        echo "### IMPORT SEM ARQUIVO CORRESPONDENTE (verificar manualmente) ###"
        echo "  Arquivo com o import : ${arquivo#$PROJ/}"
        echo "  Import escrito       : $imp"
        echo "  Procurado em         : ${caminho_pedido#$PROJ/}"
        echo ""
      fi
    fi
  done
done < <(find "$PROJ" \( -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" \) \
          -not -path "*/node_modules/*" -not -path "*/.next/*" 2>/dev/null)

echo "=================================================================="
echo " Verificacao concluida."
echo " Se aparecerem blocos 'DIVERGENCIA DE CASE' acima, essa e a causa:"
echo " o import usa um case diferente do arquivo real. No Windows/Mac"
echo " funciona; no Linux (case-sensitive) quebra."
echo ""
echo " Correcao: alinhar o import ao nome real do arquivo (ou renomear o"
echo " arquivo). O ideal e corrigir no REPOSITORIO (com o Erick) para nao"
echo " voltar no proximo git pull."
echo "=================================================================="