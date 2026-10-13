#!/usr/bin/env bash
# Richtet den Cloudflare Tunnel ein: https://<HOSTNAME> -> Garmin-Dienst auf localhost.
# Aufruf:  sudo bash tunnel.sh            (Standard: garmin.weissnoel.com)
#          sudo bash tunnel.sh anderer.name.ch
# Bricht ab, statt eine bestehende Cloudflare-Konfiguration zu überschreiben.
set -euo pipefail

HOSTNAME_PUBLIC="${1:-garmin.weissnoel.com}"
TUNNEL_NAME=garmin-health
ENV_FILE=/etc/garmin-mcp.env
CF_DIR=/etc/cloudflared

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Bitte mit sudo starten: sudo bash tunnel.sh"; exit 1; }
[ -f "$ENV_FILE" ] || { echo "Zuerst install.sh ausführen."; exit 1; }
PORT=$(grep '^GARMIN_MCP_PORT=' "$ENV_FILE" | cut -d= -f2-)
SECRET=$(grep '^GARMIN_MCP_SECRET=' "$ENV_FILE" | cut -d= -f2-)

if [ -f "$CF_DIR/config.yml" ] && ! grep -q "$HOSTNAME_PUBLIC" "$CF_DIR/config.yml"; then
  echo "Auf diesem Server gibt es schon einen anderen Cloudflare Tunnel ($CF_DIR/config.yml)."
  echo "Ich überschreibe ihn nicht. Bitte Claude im Chat Bescheid geben."; exit 1
fi

say "1/5 cloudflared installieren"
if ! command -v cloudflared >/dev/null; then
  ARCH=$(dpkg --print-architecture)
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/cloudflared.deb" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH.deb"
  dpkg -i "$TMP/cloudflared.deb" >/dev/null
  rm -rf "$TMP"
fi
cloudflared --version

say "2/5 Bei Cloudflare anmelden"
if [ ! -f /root/.cloudflared/cert.pem ]; then
  echo "Gleich erscheint ein Link. Öffne ihn im Browser, melde dich bei Cloudflare an"
  echo "und wähle die Domain $(echo "$HOSTNAME_PUBLIC" | awk -F. '{print $(NF-1)"."$NF}'). Danach geht es hier automatisch weiter."
  cloudflared tunnel login
else
  echo "Schon angemeldet."
fi

say "3/5 Tunnel anlegen"
if ! cloudflared tunnel info "$TUNNEL_NAME" >/dev/null 2>&1; then
  cloudflared tunnel create "$TUNNEL_NAME"
fi
TUNNEL_ID=$(cloudflared tunnel list --output json | python3 -c "import json,sys; print(next(t['id'] for t in json.load(sys.stdin) if t['name']=='$TUNNEL_NAME'))")
install -d -m 755 "$CF_DIR"
install -m 600 "/root/.cloudflared/$TUNNEL_ID.json" "$CF_DIR/$TUNNEL_ID.json"
cat > "$CF_DIR/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CF_DIR/$TUNNEL_ID.json
ingress:
  - hostname: $HOSTNAME_PUBLIC
    service: http://127.0.0.1:$PORT
  - service: http_status:404
EOF

say "4/5 Adresse $HOSTNAME_PUBLIC eintragen"
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME_PUBLIC" || echo "(Eintrag existiert vermutlich schon, weiter.)"

say "5/5 Tunnel als Dienst starten"
if ! systemctl list-unit-files | grep -q '^cloudflared.service'; then
  cloudflared service install
fi
systemctl enable --now cloudflared >/dev/null 2>&1
systemctl restart cloudflared
sleep 6

URL="https://$HOSTNAME_PUBLIC/$SECRET/mcp"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' || true)
echo "Test von aussen: $CODE (erwartet 200; direkt nach dem Einrichten kann es 1–2 Minuten dauern)"

say "Connector-Adresse für claude.ai (geheim halten, wie ein Passwort):"
echo "$URL"
