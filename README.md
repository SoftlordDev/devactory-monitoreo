# Monitoreo de los sitios de Devactory

Cada 5 minutos, GitHub Actions mira los sitios de [`sitios.txt`](sitios.txt) y avisa por Telegram cuando uno cae y
cuando vuelve (no en cada corrida). Está fuera del servidor a propósito: si el VPS cae, un vigilante que viviera
adentro caería con él.

- Probar el aviso: `gh workflow run monitoreo.yml -R SoftlordDev/devactory-monitoreo -f url_de_prueba=https://no-existe.invalid/`
- Secrets del repo: `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID`.
