#!/usr/bin/env bash
# Installiert den Garmin-Dienst für die Health-App auf diesem Server.
# Aufruf im Repository-Ordner:  sudo bash install.sh
# Fasst nichts anderes auf dem Server an (eigener Benutzer, eigener Ordner, eigener Dienst).
set -euo pipefail

APP_DIR=/opt/garmin-mcp
DATA_DIR=/var/lib/garmin-mcp
ENV_FILE=/etc/garmin-mcp.env
SERVICE=garmin-mcp
SVC_USER=garmin
PORT="${GARMIN_MCP_PORT:-8765}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten: sudo bash install.sh"; exit 1; }

say "1/6 Voraussetzungen prüfen"
command -v apt-get >/dev/null || { echo "Dieses Skript ist für Ubuntu/Debian gemacht."; exit 1; }
PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' \
  || { echo "Python $PYV ist zu alt (mind. 3.10 nötig)."; exit 1; }
if ss -ltn "sport = :$PORT" | grep -q LISTEN && ! systemctl is-active --quiet "$SERVICE"; then
  echo "Port $PORT ist schon belegt. Starte mit anderem Port: sudo GARMIN_MCP_PORT=8766 bash install.sh"; exit 1
fi
apt-get update -qq >/dev/null && apt-get install -y -qq python3-venv curl >/dev/null

say "2/6 Benutzer und Ordner anlegen"
id "$SVC_USER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SVC_USER"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 700 "$DATA_DIR"
install -d -m 755 "$APP_DIR"
install -m 644 "$SRC_DIR/server.py" "$SRC_DIR/login.py" "$SRC_DIR/requirements.txt" "$APP_DIR/"

say "3/6 Python-Pakete installieren (dauert 1–2 Minuten)"
[ -x "$APP_DIR/.venv/bin/python" ] || python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install -q --upgrade pip
"$APP_DIR/.venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

say "4/6 Geheimen Pfad erzeugen"
if [ ! -f "$ENV_FILE" ]; then
  SECRET=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
  umask 027
  cat > "$ENV_FILE" <<EOF
GARMIN_MCP_SECRET=$SECRET
GARMIN_MCP_PORT=$PORT
GARMIN_TOKENSTORE=$DATA_DIR/.garminconnect
EOF
  umask 022
  echo "Neu erzeugt."
else
  echo "Bestehender geheimer Pfad bleibt."
fi
chown root:"$SVC_USER" "$ENV_FILE"; chmod 640 "$ENV_FILE"

say "5/6 Dienst einrichten"
cat > /etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=Garmin-Dienst für Noels Health-App (MCP)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$ENV_FILE
Environment=HOME=$DATA_DIR
Environment=TZ=Europe/Zurich
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/server.py
Restart=on-failure
RestartSec=5
# Grenzen, damit der Dienst andere Programme auf dem Server nie ausbremst
Nice=10
CPUQuota=50%
MemoryMax=300M
# Absicherung
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/garmin-login <<EOF
#!/usr/bin/env bash
# Einmalige Garmin-Anmeldung für den Health-App-Dienst
set -e
[ "\$(id -u)" -eq 0 ] || { echo "Bitte so starten: sudo garmin-login"; exit 1; }
sudo -u $SVC_USER HOME=$DATA_DIR GARMIN_TOKENSTORE=$DATA_DIR/.garminconnect $APP_DIR/.venv/bin/python $APP_DIR/login.py
systemctl restart $SERVICE
EOF
chmod 755 /usr/local/bin/garmin-login

systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"
sleep 3

say "6/6 Prüfen"
if systemctl is-active --quiet "$SERVICE"; then
  echo "Dienst läuft."
else
  echo "Dienst läuft NICHT. Log:"; journalctl -u "$SERVICE" -n 30 --no-pager; exit 1
fi
SECRET=$(grep '^GARMIN_MCP_SECRET=' "$ENV_FILE" | cut -d= -f2-)
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/$SECRET/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' || true)
WRONG=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/falsch/mcp" || true)
echo "Antwort mit geheimem Pfad: $CODE (erwartet 200) · ohne: $WRONG (erwartet 404)"

say "Fertig. Nächste Schritte:"
if [ -f "$DATA_DIR/.garminconnect/garmin_tokens.json" ]; then
  echo "  Garmin-Tokens sind schon da."
else
  echo "  1. Garmin anmelden:        sudo garmin-login"
fi
echo "  2. Tunnel einrichten:      sudo bash tunnel.sh"
