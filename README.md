# Garmin-Dienst für die Health-App

Holt Noels Garmin-Tageswerte (Schlaf, Schritte, Ruhepuls, aktive kcal, Gewicht) und stellt sie der Health-App in claude.ai als Connector bereit. Läuft auf dem Hetzner-Server trader-01, unabhängig vom PC.

```
Uhr/Waage → Garmin-Cloud → dieser Dienst (trader-01, nur localhost)
          → Cloudflare Tunnel (garmin.weissnoel.com, geheimer Pfad)
          → Connector in claude.ai → Health-App auf jedem Gerät
```

## Einrichtung auf trader-01 (einmalig)

```bash
git clone https://github.com/NoelWeiss/garmin-mcp.git ~/garmin-mcp
cd ~/garmin-mcp
sudo bash install.sh     # Dienst installieren und starten
sudo garmin-login        # Garmin-E-Mail, Passwort und MFA-Code eingeben (Passwort wird nicht gespeichert)
sudo bash tunnel.sh      # Cloudflare-Link im Browser öffnen, Domain weissnoel.com wählen
```

`tunnel.sh` zeigt am Schluss die **Connector-Adresse**. Sie ist geheim wie ein Passwort: Wer sie kennt, kann die Garmin-Werte lesen.

Danach in claude.ai: Einstellungen → Connectors → Eigenen Connector hinzufügen → Name `Garmin`, URL = Connector-Adresse.

## Was wo liegt

| Was | Wo |
|---|---|
| Programm | `/opt/garmin-mcp` |
| Garmin-Tokens | `/var/lib/garmin-mcp/.garminconnect` (nur Benutzer `garmin`) |
| Geheimer Pfad, Port | `/etc/garmin-mcp.env` |
| Dienste | `garmin-mcp`, `cloudflared` |

Der Dienst läuft unter eigenem Benutzer, darf höchstens 50 % eines Kerns und 300 MB RAM nutzen und fasst nichts anderes auf dem Server an.

## Nützliche Befehle

```bash
systemctl status garmin-mcp            # läuft der Dienst?
journalctl -u garmin-mcp -n 50         # letzte Meldungen
sudo garmin-login                      # Garmin neu anmelden (falls die App «Anmeldung abgelaufen» meldet)
cd ~/garmin-mcp && git pull && sudo bash install.sh   # Update einspielen
```

## Neuer geheimer Pfad (falls die Adresse in falsche Hände geraten ist)

```bash
sudo rm /etc/garmin-mcp.env && cd ~/garmin-mcp && sudo bash install.sh && sudo bash tunnel.sh
```
Danach die neue Adresse im Connector in claude.ai eintragen.

## Entfernen

```bash
sudo systemctl disable --now garmin-mcp
sudo rm -rf /opt/garmin-mcp /var/lib/garmin-mcp /etc/garmin-mcp.env /etc/systemd/system/garmin-mcp.service /usr/local/bin/garmin-login
sudo userdel garmin
# Tunnel: sudo cloudflared service uninstall && sudo cloudflared tunnel delete garmin-health
```
