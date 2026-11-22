#!/usr/bin/env bash
# Mira los sitios de la lista y avisa por Telegram cuando uno cae y cuando vuelve (no en cada corrida).
#
#   vigilar.sh <archivo-de-sitios> <archivo-de-estado>
#
# Corre en GitHub Actions (.github/workflows/monitoreo.yml de este repo): tiene que estar FUERA del VPS, porque una caída del
# servidor apagaría también al vigilante. Variables: TELEGRAM_BOT_TOKEN y TELEGRAM_CHAT_ID (secrets del repo).
# TELEGRAM_API solo se cambia en las pruebas, para apuntar a un servidor local. El token nunca se imprime.
#
# La llave del circuito (T-185): la variable LLAVE (que sale de la variable de repo LLAVE_MONITOREO, la pone el equipo C) deja a Diego callar
# al monitor a propósito y con vencimiento. Es un JSON sin nombres ni canal (este repo es público):
#   {"estado":"stop-todo","vence":<epoch s>,"mantenimiento":[{"sitio":"cdoc.ucp.edu.ar","vence":<epoch s>}]}
#   STOP TODO vigente   no avisa, no toca el estado y termina bien (al volver, la primera corrida avisa lo que siga caído);
#   mantenimiento       se saltean las URL de ese host y se conserva su renglón del estado, así no avisa ni «caído» ni «volvió» de más;
#   vacía, mal formada o vencida   vigila como siempre, y lo dice en el log.
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

# La llave, leída con node (viene en el runner, y así no se depende de jq). Imprime «STOP <vence>», «MANT <host>» o «MAL».
leer_llave() {
  node -e '
    let v;
    try { v = JSON.parse(process.env.LLAVE); } catch { console.log("MAL"); process.exit(0); }
    if (!v || typeof v !== "object" || Array.isArray(v)) { console.log("MAL"); process.exit(0); }
    const ahora = Math.floor(Date.now() / 1000);
    if (v.estado === "stop-todo" && typeof v.vence === "number" && v.vence > ahora) console.log("STOP " + v.vence);
    for (const m of Array.isArray(v.mantenimiento) ? v.mantenimiento : []) {
      if (m && typeof m.sitio === "string" && typeof m.vence === "number" && m.vence > ahora) console.log("MANT " + m.sitio.toLowerCase());
    }
  ' 2>/dev/null || echo "MAL"
}

en_mantenimiento=""
if [[ -n "$(printf '%s' "${LLAVE:-}" | tr -d '[:space:]')" ]]; then
  llave=$(leer_llave)
  if [[ "$llave" == "MAL" ]]; then
    echo "LLAVE mal formada: se vigila como siempre."
  elif [[ -z "$llave" ]]; then
    echo "LLAVE vencida o sin nada vigente: se vigila como siempre."
  else
    while IFS= read -r l; do
      case "$l" in
        "STOP "*)
          echo "STOP TODO hasta $(date -u -d "@${l#STOP }" '+%F %H:%M' 2>/dev/null || echo "${l#STOP }") UTC: no se avisa ni se toca el estado."
          exit 0 ;;
        "MANT "*)
          en_mantenimiento+=" ${l#MANT } "
          echo "Mantenimiento de ${l#MANT }: se saltean sus URL." ;;
      esac
    done <<< "$llave"
  fi
fi

host_de() {   # el host de una URL, en minúscula y sin puerto
  local h="${1#*://}"
  h="${h%%/*}"
  h="${h%%:*}"
  echo "${h,,}"
}

touch "$ESTADO"
actuales=$(mktemp)
fallo_aviso=0
caidos_ahora=""

while IFS= read -r url; do
  [[ -z "$url" || "$url" == \#* ]] && continue
  if [[ "$en_mantenimiento" == *" $(host_de "$url") "* ]]; then
    echo "mant   -    $url (en mantenimiento)"
    # Su renglón del estado se conserva: si estaba caído, al terminar el mantenimiento recién ahí avisa que volvió.
    if grep -qxF "$url" "$ESTADO"; then echo "$url" >> "$actuales"; fi
    continue
  fi
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
