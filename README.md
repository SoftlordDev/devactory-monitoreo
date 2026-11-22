# Monitoreo de los sitios de Devactory

Cada 5 minutos, GitHub Actions mira los sitios de [`sitios.txt`](sitios.txt) y avisa por Telegram cuando uno cae y
cuando vuelve (no en cada corrida). Está fuera del servidor a propósito: si el VPS cae, un vigilante que viviera
adentro caería con él.

- Probar el aviso: `gh workflow run monitoreo.yml -R SoftlordDev/devactory-monitoreo -f url_de_prueba=https://no-existe.invalid/`
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
