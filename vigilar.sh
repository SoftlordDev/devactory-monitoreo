#!/usr/bin/env bash
# Mira los sitios de la lista y avisa por Telegram cuando uno cae y cuando vuelve (no en cada corrida).
#
#   vigilar.sh <archivo-de-sitios> <archivo-de-estado>
#
# Corre en GitHub Actions (.github/workflows/monitoreo.yml de este repo): tiene que estar FUERA del VPS, porque una caída del
# servidor apagaría también al vigilante. Variables: TELEGRAM_BOT_TOKEN y TELEGRAM_CHAT_ID (secrets del repo).
# TELEGRAM_API solo se cambia en las pruebas, para apuntar a un servidor local. El token nunca se imprime.
set -uo pipefail

SITIOS="${1:?falta el archivo de sitios}"
ESTADO="${2:?falta el archivo de estado}"
API="${TELEGRAM_API:-https://api.telegram.org}"

: "${TELEGRAM_BOT_TOKEN:?falta el secret TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?falta el secret TELEGRAM_CHAT_ID}"

avisar() {   # avisar "texto": falla en voz alta si Telegram no lo recibe, para que el trabajo se vea rojo.
  local codigo
  codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1" \
    "$API/bot$TELEGRAM_BOT_TOKEN/sendMessage")
  if [[ "$codigo" != "200" ]]; then
    echo "No se pudo avisar por Telegram (código $codigo)." >&2
    return 1
  fi
}

codigo_de() {   # dos intentos con 5 s entre ellos: un corte de un segundo no es una caída.
  local url="$1" c i
  for i in 1 2; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)
    [[ "$c" =~ ^[0-9]{3}$ ]] || c=000
    if [[ "$c" != "000" && "$c" -lt 500 ]]; then echo "$c"; return; fi
    [[ $i -lt 2 ]] && sleep 5
  done
  echo "$c"
}

touch "$ESTADO"
actuales=$(mktemp)
fallo_aviso=0
caidos_ahora=""

while IFS= read -r url; do
  [[ -z "$url" || "$url" == \#* ]] && continue
  c=$(codigo_de "$url")
  if [[ "$c" == "000" || "$c" -ge 500 ]]; then
    echo "CAIDO  $c  $url"
    echo "$url" >> "$actuales"
    if ! grep -qxF "$url" "$ESTADO"; then caidos_ahora+="🔴 CAÍDO: $url (respondió $c)"$'\n'; fi
  else
    echo "ok     $c  $url"
  fi
done < "$SITIOS"

volvieron=""
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  grep -qxF "$url" "$actuales" || volvieron+="🟢 VOLVIÓ: $url"$'\n'
done < "$ESTADO"

# El estado solo avanza si el aviso salió: si Telegram falla, la próxima corrida lo vuelve a intentar.
mensaje="$caidos_ahora$volvieron"
if [[ -n "$mensaje" ]]; then
  avisar "Monitoreo de Soporte Devactory ($(date -u '+%F %H:%M') UTC)"$'\n'"$mensaje" || fallo_aviso=1
fi

[[ $fallo_aviso -eq 0 ]] && cp "$actuales" "$ESTADO"
rm -f "$actuales"
[[ $fallo_aviso -eq 0 ]] || exit 1
# Con algo caído el trabajo termina en verde a propósito: un trabajo fallido no guarda la caché del estado.
