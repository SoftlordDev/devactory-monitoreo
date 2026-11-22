#!/usr/bin/env bash
# Mira los sitios de la lista y avisa por Telegram cuando uno cae y cuando vuelve (no en cada corrida).
#
#   vigilar.sh <archivo-de-sitios> <archivo-de-estado>
#
# Cada línea de la lista es «URL» o «URL | contenido esperado» (T-192): un texto o un par JSON como "estado":"ok". Si el contenido no está
# en la respuesta, el sitio se da por caído aunque conteste 200 (una página de error que responde 200 no es un sitio sano). Para un par JSON
# se ignoran los espacios. El cuerpo se guarda en un archivo temporal, se compara y se borra: nunca se imprime (el log de Actions es público).
#
# Certificados (T-192): de cada host https se lee cuántos días faltan. Avisa desde los 14 días, una vez por día, y otra vez cuando faltan 3 o
# menos. CERT_VENCE_DE_PRUEBA (epoch s) reemplaza la lectura, solo en las pruebas.
#
# Latido del circuito (T-192): con LATIDOS_CLAVE (secret), LATIDOS_EQUIPO (variable de repo) y LATIDOS_URL, lee GET /api/circuito/latidos y avisa si el
# ciclo no manda latido hace más de LATIDOS_MINUTOS (45), solo en banda laboral o extendida. Si Soporte no responde, no avisa: eso ya es una
# caída de Soporte y la avisa su propia salud. Sin la clave, no mira. Nada de esto muestra la clave ni el nombre del equipo en el log.
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

CUERPO=$(mktemp)
trap 'rm -f "$CUERPO"' EXIT

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
    c=$(curl -s -o "$CUERPO" -w '%{http_code}' --max-time 10 "$url" || true)
    [[ "$c" =~ ^[0-9]{3}$ ]] || c=000
    if [[ "$c" != "000" && "$c" -lt 500 ]]; then echo "$c"; return; fi
    [[ $i -lt 2 ]] && sleep 5
  done
  echo "$c"
}

contenido_ok() {   # contenido_ok "esperado": está en el cuerpo guardado (para un par JSON, sin contar los espacios)
  grep -qF -- "$1" "$CUERPO" && return 0
  if [[ "$1" == \"* ]]; then
    local cuerpo esperado
    cuerpo=$(head -c 1000000 "$CUERPO" | tr -d '[:space:]')
    esperado=$(printf '%s' "$1" | tr -d '[:space:]')
    [[ "$cuerpo" == *"$esperado"* ]] && return 0
  fi
  return 1
}

recortar() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; echo "${t%"${t##*[![:space:]]}"}"; }

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
avisos_ahora=""
hoy=$(date -u +%F)
ahora_s=$(date +%s)
hosts_con_cert=" "

# Certificados: «cert:host:tramo:fecha» en el estado es el aviso de hoy ya dado (tramo 14 o 3). Las de otros días no se arrastran.
vigilar_cert() {   # vigilar_cert host
  local host="$1" fin dias tramo clave texto
  if [[ -n "${CERT_VENCE_DE_PRUEBA:-}" ]]; then
    fin="$CERT_VENCE_DE_PRUEBA"
  else
    fin=$(echo | timeout 15 openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    fin=$(date -d "$fin" +%s 2>/dev/null || true)
  fi
  if [[ ! "$fin" =~ ^-?[0-9]+$ ]]; then
    echo "cert   -    $host (no se pudo leer)"
    return
  fi
  dias=$(( (fin - ahora_s) / 86400 ))
  echo "cert   $dias d  $host"
  (( fin - ahora_s > 14 * 86400 )) && return
  tramo=14
  (( fin - ahora_s <= 3 * 86400 )) && tramo=3
  clave="cert:$host:$tramo:$hoy"
  echo "$clave" >> "$actuales"
  grep -qxF "$clave" "$ESTADO" && return
  if (( fin <= ahora_s )); then texto="venció"
  else texto="vence en $dias días"; fi
  avisos_ahora+="🟠 CERTIFICADO: $host $texto"$'\n'
}

while IFS= read -r linea; do
  [[ -z "$linea" || "$linea" == \#* ]] && continue
  url=$(recortar "${linea%%|*}")
  esperado=""
  [[ "$linea" == *"|"* ]] && esperado=$(recortar "${linea#*|}")
  host=$(host_de "$url")
  if [[ "$en_mantenimiento" == *" $host "* ]]; then
    echo "mant   -    $url (en mantenimiento)"
    # Su renglón del estado se conserva: si estaba caído, al terminar el mantenimiento recién ahí avisa que volvió.
    if grep -qxF "$url" "$ESTADO"; then echo "$url" >> "$actuales"; fi
    continue
  fi
  c=$(codigo_de "$url")
  motivo=""
  if [[ "$c" == "000" || "$c" -ge 500 ]]; then
    motivo="respondió $c"
  elif [[ -n "$esperado" ]] && ! contenido_ok "$esperado"; then
    # Una página rota puede ser de un instante: se mira una vez más antes de darlo por caído.
    sleep 5
    c=$(codigo_de "$url")
    if [[ "$c" == "000" || "$c" -ge 500 ]]; then motivo="respondió $c"
    elif ! contenido_ok "$esperado"; then motivo="respondió $c sin el contenido esperado"; fi
  fi
  if [[ -n "$motivo" ]]; then
    echo "CAIDO  $c  $url${esperado:+ (contenido esperado: no)}"
    echo "$url" >> "$actuales"
    if ! grep -qxF "$url" "$ESTADO"; then caidos_ahora+="🔴 CAÍDO: $url ($motivo)"$'\n'; fi
  else
    echo "ok     $c  $url${esperado:+ (contenido esperado: sí)}"
  fi
  if [[ "$url" == https://* && "$hosts_con_cert" != *" $host "* ]]; then
    hosts_con_cert+="$host "
    vigilar_cert "$host"
  fi
done < "$SITIOS"

# El latido del ciclo. Los renglones «latido:…» del estado siguen la misma regla que los sitios: avisa al caer y al volver.
vigilar_latido() {
  local url="${LATIDOS_URL:-https://soporte.devactory.com/api/circuito/latidos}" cod res
  if [[ -z "${LATIDOS_CLAVE:-}" || -z "${LATIDOS_EQUIPO:-}" ]]; then
    echo "latido -    sin credencial o sin equipo configurados: no se mira"
    for k in latido:ciclo latido:credencial; do grep -qxF "$k" "$ESTADO" && echo "$k" >> "$actuales"; done
    return
  fi
  if [[ "$en_mantenimiento" == *" $(host_de "$url") "* ]]; then
    echo "latido -    Soporte en mantenimiento"
    for k in latido:ciclo latido:credencial; do grep -qxF "$k" "$ESTADO" && echo "$k" >> "$actuales"; done
    return
  fi
  cod=$(printf 'X-Clave-Agente: %s\n' "$LATIDOS_CLAVE" \
    | curl -s -o "$CUERPO" -w '%{http_code}' --max-time 15 -H @- "$url" || true)
  [[ "$cod" =~ ^[0-9]{3}$ ]] || cod=000
  case "$cod" in
    200) ;;
    401|403)
      echo "latido $cod  la credencial del monitor no sirve"
      echo "latido:credencial" >> "$actuales"
      grep -qxF "latido:credencial" "$ESTADO" || caidos_ahora+="🔴 El monitor no puede leer el latido del ciclo (la credencial respondió $cod)"$'\n'
      grep -qxF "latido:ciclo" "$ESTADO" && echo "latido:ciclo" >> "$actuales"
      return ;;
    *)
      # Soporte caído ya es una caída de Soporte (su salud está en la lista): no se avisa dos veces, y el estado queda como estaba.
      echo "latido $cod  Soporte no respondió: lo cubre su vigilancia"
      for k in latido:ciclo latido:credencial; do grep -qxF "$k" "$ESTADO" && echo "$k" >> "$actuales"; done
      return ;;
  esac
  res=$(LATIDOS_FUENTE_X="${LATIDOS_FUENTE:-llave}" node -e '
    let v;
    try { v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch { console.log("MAL"); process.exit(0); }
    const f = (Array.isArray(v && v.latidos) ? v.latidos : []).find((l) => l && l.equipo === process.env.LATIDOS_EQUIPO && l.fuente === process.env.LATIDOS_FUENTE_X);
    if (!f || typeof f.minutos !== "number") { console.log("SIN"); process.exit(0); }
    const limite = Number(process.env.LATIDOS_MINUTOS) || 45;
    if (f.minutos <= limite) console.log("OK " + f.minutos);
    else if (v.banda === "laboral" || v.banda === "extendida") console.log("VIEJO " + f.minutos);
    else console.log("FUERA " + f.minutos);
  ' "$CUERPO" 2>/dev/null || echo "MAL")
  case "$res" in
    "OK "*)    echo "latido ok   ${res#OK } min" ;;
    "VIEJO "*) echo "CAIDO  -    latido del ciclo: ${res#VIEJO } min"
               echo "latido:ciclo" >> "$actuales"
               grep -qxF "latido:ciclo" "$ESTADO" || caidos_ahora+="🔴 El ciclo no manda latido hace ${res#VIEJO } min"$'\n' ;;
    "FUERA "*) echo "latido -    ${res#FUERA } min, fuera de la banda laboral: no se avisa"
               grep -qxF "latido:ciclo" "$ESTADO" && echo "latido:ciclo" >> "$actuales" ;;
    *)         echo "latido -    sin dato del ciclo en la respuesta"
               grep -qxF "latido:ciclo" "$ESTADO" && echo "latido:ciclo" >> "$actuales" ;;
  esac
}
vigilar_latido

volvieron=""
while IFS= read -r url; do
  [[ -z "$url" || "$url" == cert:* ]] && continue
  grep -qxF "$url" "$actuales" && continue
  case "$url" in
    latido:ciclo)      volvieron+="🟢 VOLVIÓ: el latido del ciclo"$'\n' ;;
    latido:credencial) volvieron+="🟢 VOLVIÓ: la lectura del latido del ciclo"$'\n' ;;
    *)                 volvieron+="🟢 VOLVIÓ: $url"$'\n' ;;
  esac
done < "$ESTADO"

# El estado solo avanza si el aviso salió: si Telegram falla, la próxima corrida lo vuelve a intentar.
mensaje="$caidos_ahora$avisos_ahora$volvieron"
if [[ -n "$mensaje" ]]; then
  avisar "Monitoreo de Soporte Devactory ($(date -u '+%F %H:%M') UTC)"$'\n'"$mensaje" || fallo_aviso=1
fi

[[ $fallo_aviso -eq 0 ]] && cp "$actuales" "$ESTADO"
rm -f "$actuales"
[[ $fallo_aviso -eq 0 ]] || exit 1
# Con algo caído el trabajo termina en verde a propósito: un trabajo fallido no guarda la caché del estado.
