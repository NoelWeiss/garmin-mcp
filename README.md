# Garmin-Dienst für die Health-App

Holt Noels Garmin-Tageswerte (Schlaf, Schritte, Ruhepuls, aktive kcal, Gewicht) und stellt sie der Health-App in claude.ai als Connector bereit. Läuft auf dem Server trader-01, unabhängig vom PC.

```
Uhr/Waage → Garmin-Cloud → dieser Dienst (trader-01, nur localhost:8765)
          → Cloudflare Tunnel (garmin.weissnoel.com, geheimer Pfad)
          → Connector in claude.ai → Health-App auf jedem Gerät
```

## Einrichtung auf Windows (trader-01)

PowerShell **als Administrator** öffnen (Start → «PowerShell» → Rechtsklick → Als Administrator ausführen) und nacheinander einfügen:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/NoelWeiss/garmin-mcp/main/windows/install.ps1 | iex
```
Danach Garmin anmelden: `C:\garmin-mcp\garmin-login.cmd` mit Rechtsklick → Als Administrator ausführen (E-Mail, Passwort, MFA-Code; das Passwort wird nicht gespeichert).

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/NoelWeiss/garmin-mcp/main/windows/tunnel.ps1 | iex
```
Bei Cloudflare anmelden, Domain `weissnoel.com` wählen. Am Schluss steht die **Connector-Adresse** (auch in der Zwischenablage). Sie ist geheim wie ein Passwort.

Danach in claude.ai: Einstellungen → Connectors → Eigenen Connector hinzufügen → Name `Garmin`, URL = Connector-Adresse.

### Was wo liegt (Windows)

| Was | Wo |
|---|---|
| Programm | `C:\garmin-mcp\app` |
| Python-Umgebung | `C:\garmin-mcp\venv` |
| Einstellungen, geheimer Pfad, Garmin-Tokens, Log | `C:\garmin-mcp\data` (nur SYSTEM und Administratoren) |
| Dienste | Aufgabenplanung: `GarminMCP` (Dienst), `GarminTunnel` (Cloudflare) – starten automatisch mit Windows |

### Nützlich (PowerShell als Administrator)

```powershell
Get-ScheduledTask GarminMCP, GarminTunnel | Select TaskName, State   # laufen beide?
Get-Content C:\garmin-mcp\data\server.log -Tail 30                  # letzte Meldungen
# Update einspielen: install.ps1-Befehl oben nochmals einfügen (Einstellungen und Tokens bleiben)
```

Garmin neu anmelden (wenn die App «Anmeldung abgelaufen» meldet): `C:\garmin-mcp\garmin-login.cmd` als Administrator.

Neuer geheimer Pfad: `C:\garmin-mcp\data\config.env` löschen, install.ps1 und tunnel.ps1 nochmals ausführen, neue Adresse im Connector eintragen.

### Entfernen (Windows)

```powershell
Unregister-ScheduledTask GarminMCP, GarminTunnel -Confirm:$false
Remove-Item C:\garmin-mcp -Recurse -Force
# Tunnel bei Cloudflare löschen: Zero Trust → Networks → Tunnels → garmin-health
```

## Einrichtung auf Linux (Ubuntu/Debian)

```bash
git clone https://github.com/NoelWeiss/garmin-mcp ~/garmin-mcp && cd ~/garmin-mcp
sudo bash install.sh && sudo garmin-login && sudo bash tunnel.sh
```
Programm in `/opt/garmin-mcp`, Tokens in `/var/lib/garmin-mcp`, Einstellungen in `/etc/garmin-mcp.env`, Dienste `garmin-mcp` und `cloudflared`.
