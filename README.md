# Monitoreo de los sitios de Devactory

Cada 5 minutos, GitHub Actions mira los sitios de [`sitios.txt`](sitios.txt) y avisa por Telegram cuando uno cae y
cuando vuelve (no en cada corrida). Está fuera del servidor a propósito: si el VPS cae, un vigilante que viviera
adentro caería con él.

- Probar el aviso: `gh workflow run monitoreo.yml -R SoftlordDev/devactory-monitoreo -f url_de_prueba=https://no-existe.invalid/`
- Probar el contenido esperado: `... -f url_de_prueba=https://portal.ucp.edu.ar/ -f contenido_de_prueba='texto que no está'` avisa «caído».
- Probar el certificado: `... -f url_de_prueba=https://expired.badssl.com/` avisa el certificado vencido.
- Secrets del repo: `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID`.

## La llave del circuito (T-185)

Diego puede callar al monitor a propósito, con vencimiento, desde Telegram, la consola de Soporte o la sesión de Claude Code
(`/stop todo 2h`, `/mantenimiento cdoc.ucp.edu.ar 1h`). El equipo C pone la variable de repo `LLAVE_MONITOREO` con `gh variable set` y la borra
cuando no queda nada; el workflow la pasa a `vigilar.sh` como `LLAVE`. Es un JSON **sin nombres ni canal** (este repo es público):

    {"estado":"stop-todo","vence":1790000000,"mantenimiento":[{"sitio":"cdoc.ucp.edu.ar","vence":1790000000}]}

- **`stop-todo` vigente:** no avisa, no toca el estado y termina en verde. Al volver, la primera corrida avisa lo que siga caído.
- **Un sitio en mantenimiento:** se saltean sus URL (por host) y se conserva su renglón del estado.
- **Vacía, mal formada o vencida:** vigila como siempre, y lo dice en el log.
- Vale también con `url_de_prueba`, que es como se prueba contra el monitor real. Sin GitHub: `bash probar.sh` corre `vigilar.sh` con un Telegram y un
  sitio de juguete en los casos de arriba.

## Contenido, certificados y latido (T-192)

- **Contenido esperado:** una línea de `sitios.txt` puede ser `URL | contenido`: un texto o un par JSON como `"estado":"ok"` (de un par JSON se ignoran
  los espacios). Si la respuesta no lo trae, el sitio se da por caído aunque conteste 200 (se mira dos veces antes de avisar). El cuerpo nunca se imprime.
- **Certificados:** de cada host https se lee cuántos días faltan. Avisa desde los 14 días, una vez por día, y otra vez cuando faltan 3 o menos.
- **Latido del ciclo:** si `GET /api/circuito/latidos` dice que el ciclo no manda latido hace más de 45 minutos (`LATIDOS_MINUTOS`), en banda laboral o
  extendida, avisa; y avisa cuando vuelve. Si Soporte no responde no se avisa: eso ya es una caída de Soporte. Si la credencial es rechazada, avisa una vez.
  Necesita el secret `LATIDOS_CLAVE_MONITOR` (la credencial de solo lectura) y la variable de repo `LATIDOS_EQUIPO`; sin ellos no mira.
- `bash probar.sh` cubre todo esto con un Telegram y un sitio de juguete (tarda un par de minutos por las esperas entre reintentos).
