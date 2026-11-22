#!/usr/bin/env bash
# Prueba local de vigilar.sh con un Telegram y un sitio de juguete (T-185). No toca Telegram ni ningún sitio real.
#
#   bash probar.sh
#
# Levanta un servidor de node que hace de Telegram (guarda los mensajes que le mandan) y de sitio (/ok da 200, /caido da 503), y corre
# vigilar.sh en los casos de la llave: sin llave, STOP TODO, llave vencida, mal formada, vacía y mantenimiento de un host.
set -uo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT

cat > "$tmp/servidor.mjs" <<'JS'
import http from 'node:http';
import fs from 'node:fs';
const salida = process.argv[2];
const srv = http.createServer((req, res) => {
  let cuerpo = '';
  req.on('data', (c) => { cuerpo += c; });
  req.on('end', () => {
    if (req.url.startsWith('/bot')) { fs.appendFileSync(salida, new URLSearchParams(cuerpo).get('text') + '\n---\n'); res.end('{"ok":true}'); return; }
    const lat = (banda, min) => JSON.stringify({ banda, minutosSinLatido: 45, latidos: [{ equipo: 'EQ', fuente: 'llave', minutos: min }] });
    if (req.url === '/latidos-ok') { res.end(lat('laboral', 5)); return; }
    if (req.url === '/latidos-viejo') { res.end(lat('laboral', 90)); return; }
    if (req.url === '/latidos-fuera') { res.end(lat('nocturna', 600)); return; }
    if (req.url === '/latidos-403') { res.statusCode = 403; res.end('{}'); return; }
    if (req.url === '/latidos-500') { res.statusCode = 500; res.end('{}'); return; }
    if (req.url === '/sano') { res.end('{ "estado": "ok" }'); return; }
    if (req.url === '/pagina-de-error') { res.end('<h1>Error</h1> {"estado":"error"}'); return; }
    res.statusCode = req.url === '/caido' ? 503 : 200;
    res.end('x');
  });
});
srv.listen(0, '127.0.0.1', () => { console.log(srv.address().port); });
JS
: > "$tmp/mensajes.txt"
node "$tmp/servidor.mjs" "$tmp/mensajes.txt" > "$tmp/puerto.txt" &
pid=$!
for _ in $(seq 1 50); do [[ -s "$tmp/puerto.txt" ]] && break; sleep 0.1; done
puerto=$(cat "$tmp/puerto.txt")
export TELEGRAM_API="http://127.0.0.1:$puerto" TELEGRAM_BOT_TOKEN=token-de-juguete TELEGRAM_CHAT_ID=1

printf 'http://127.0.0.1:%s/ok\nhttp://localhost:%s/caido\n' "$puerto" "$puerto" > "$tmp/sitios.txt"
fallos=0
chequear() {   # chequear "descripción" <condición de bash>
  local d="$1"; shift
  if "$@"; then echo "  ok   $d"; else echo "  MAL  $d"; fallos=$((fallos + 1)); fi
}
mensajes() { grep -c 'http://' "$tmp/mensajes.txt" || true; }   # una línea con la URL por cada sitio avisado
ahora=$(date +%s)

corrida() {   # (con DEBUG=1 muestra la salida) corrida "LLAVE" → vuelca la salida en $tmp/salida.txt; el estado es $tmp/estado.txt
  LLAVE="$1" bash vigilar.sh "$tmp/sitios.txt" "$tmp/estado.txt" > "$tmp/salida.txt" 2>&1
  echo "$?" > "$tmp/codigo.txt"
  [[ -n "${DEBUG:-}" ]] && { cat "$tmp/salida.txt"; echo "--- mensajes:"; cat "$tmp/mensajes.txt"; }
}

echo "1. sin llave: avisa el sitio caído y lo guarda en el estado"
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
corrida ""
chequear "avisó una vez" [ "$(mensajes)" = 1 ]
chequear "el estado tiene el sitio caído" grep -q caido "$tmp/estado.txt"

echo "2. STOP TODO vigente: no avisa, no toca el estado y termina bien"
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
corrida "{\"estado\":\"stop-todo\",\"vence\":$((ahora + 600))}"
chequear "no avisó" [ "$(mensajes)" = 0 ]
chequear "no creó el estado" [ ! -e "$tmp/estado.txt" ]
chequear "terminó en 0" [ "$(cat "$tmp/codigo.txt")" = 0 ]
chequear "el log dice STOP TODO" grep -q 'STOP TODO' "$tmp/salida.txt"
corrida ""
chequear "al volver, la primera corrida avisa lo que sigue caído" [ "$(mensajes)" = 1 ]

echo "3. llave vencida, vacía o mal formada: vigila como siempre y lo dice"
for llave in "{\"estado\":\"stop-todo\",\"vence\":$((ahora - 60))}" "no es json" "[]"; do
  rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
  corrida "$llave"
  chequear "avisó con «$llave»" [ "$(mensajes)" = 1 ]
  chequear "lo dice en el log" grep -q 'LLAVE' "$tmp/salida.txt"
done
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
corrida "   "
chequear "vacía: avisa y no dice nada raro" [ "$(mensajes)" = 1 ]

echo "4. mantenimiento de un host: se saltean sus URL y se conserva su renglón del estado"
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
corrida "{\"mantenimiento\":[{\"sitio\":\"localhost\",\"vence\":$((ahora + 600))}]}"
chequear "no avisó el sitio caído de ese host" [ "$(mensajes)" = 0 ]
chequear "el otro host sigue vigilado" grep -q "127.0.0.1" "$tmp/salida.txt"
chequear "dice que saltea" grep -q 'en mantenimiento' "$tmp/salida.txt"
echo "http://localhost:$puerto/caido" > "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
corrida "{\"mantenimiento\":[{\"sitio\":\"localhost\",\"vence\":$((ahora + 600))}]}"
chequear "con el sitio ya caído antes, conserva el renglón y no avisa que volvió" grep -q caido "$tmp/estado.txt"
chequear "y no mandó nada" [ "$(mensajes)" = 0 ]

echo "5. contenido esperado: un 200 sin el contenido es un sitio caído (T-192)"
printf 'http://127.0.0.1:%s/sano | "estado":"ok"
http://127.0.0.1:%s/pagina-de-error | "estado":"ok"
http://127.0.0.1:%s/ok | texto que no está
' "$puerto" "$puerto" "$puerto" > "$tmp/sitios.txt"
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
corrida ""
chequear "avisó los dos que no tienen el contenido" [ "$(mensajes)" = 2 ]
chequear "el que tiene el contenido (con espacios) no se avisó" bash -c "! grep -q /sano $tmp/mensajes.txt"
chequear "el log no trae el cuerpo de la respuesta" bash -c "! grep -q 'Error' '$tmp/salida.txt'"
chequear "el log dice «contenido esperado»" grep -q 'contenido esperado: no' "$tmp/salida.txt"

echo "6. certificados: aviso desde los 14 días, una vez por día y otra vez a los 3 (T-192)"
printf 'https://127.0.0.1:1/
' > "$tmp/sitios.txt"
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
CERT_VENCE_DE_PRUEBA=$((ahora + 10 * 86400)) corrida ""
chequear "avisó el certificado a 10 días" grep -q 'CERTIFICADO' "$tmp/mensajes.txt"
: > "$tmp/mensajes.txt"
CERT_VENCE_DE_PRUEBA=$((ahora + 10 * 86400)) corrida ""
chequear "el mismo día no vuelve a avisar" bash -c "! grep -q CERTIFICADO '$tmp/mensajes.txt'"
: > "$tmp/mensajes.txt"
CERT_VENCE_DE_PRUEBA=$((ahora + 2 * 86400)) corrida ""
chequear "a los 3 días avisa otra vez" grep -q 'CERTIFICADO' "$tmp/mensajes.txt"
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
CERT_VENCE_DE_PRUEBA=$((ahora - 86400)) corrida ""
chequear "vencido: avisa que venció" grep -q 'venci' "$tmp/mensajes.txt"
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
CERT_VENCE_DE_PRUEBA=$((ahora + 40 * 86400)) corrida ""
chequear "a 40 días no avisa certificado" bash -c "! grep -q CERTIFICADO '$tmp/mensajes.txt'"

echo "7. latido del ciclo (T-192)"
printf 'http://127.0.0.1:%s/ok
' "$puerto" > "$tmp/sitios.txt"
export LATIDOS_EQUIPO=EQ LATIDOS_CLAVE=clave-de-juguete
latido() { LATIDOS_URL="http://127.0.0.1:$puerto/$1" corrida ""; }
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
latido latidos-ok
chequear "latido al día: no avisa" [ "$(grep -c . "$tmp/mensajes.txt")" = 0 ]
latido latidos-viejo
chequear "latido viejo en banda laboral: avisa" grep -q 'no manda latido hace 90' "$tmp/mensajes.txt"
: > "$tmp/mensajes.txt"; latido latidos-viejo
chequear "no repite el aviso" [ "$(grep -c . "$tmp/mensajes.txt")" = 0 ]
latido latidos-500
chequear "Soporte caído: no avisa ni da por vuelto" [ "$(grep -c . "$tmp/mensajes.txt")" = 0 ]
latido latidos-ok
chequear "al volver el latido, avisa que volvió" grep -q 'VOLVI.*el latido' "$tmp/mensajes.txt"
rm -f "$tmp/estado.txt"; : > "$tmp/mensajes.txt"
latido latidos-fuera
chequear "fuera de la banda laboral: no avisa" [ "$(grep -c . "$tmp/mensajes.txt")" = 0 ]
latido latidos-403
chequear "credencial rechazada: avisa" grep -q 'la credencial respondi.* 403' "$tmp/mensajes.txt"
chequear "el log no trae la clave ni el equipo" bash -c "! grep -q -e clave-de-juguete -e EQ '$tmp/salida.txt'"
unset LATIDOS_CLAVE
: > "$tmp/mensajes.txt"; latido latidos-viejo
chequear "sin credencial: no mira" [ "$(grep -c . "$tmp/mensajes.txt")" = 0 ]

echo
if [[ $fallos -eq 0 ]]; then echo "Todo bien."; else echo "$fallos fallo(s)."; exit 1; fi
