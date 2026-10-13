# Richtet den Cloudflare Tunnel ein: https://garmin.weissnoel.com -> Garmin-Dienst auf diesem Windows-Server.
# In PowerShell als Administrator einfügen (nach install.ps1):
#   [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/NoelWeiss/garmin-mcp/main/windows/tunnel.ps1 | iex
# Eigener Tunnel "garmin-health" und eigene geplante Aufgabe "GarminTunnel". Bestehende Tunnel bleiben unberührt.

function Install-GarminTunnel {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $HostName   = 'garmin.weissnoel.com'
    $TunnelName = 'garmin-health'
    $Root = 'C:\garmin-mcp'
    $Data = "$Root\data"
    $Cf   = "$Root\cloudflared.exe"
    $Task = 'GarminTunnel'
    $cfg  = "$Data\config.env"

    function Say($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Host 'Bitte PowerShell als Administrator starten.' -ForegroundColor Red; return }
    if (-not (Test-Path $cfg)) { Write-Host 'Zuerst install.ps1 ausfuehren.' -ForegroundColor Red; return }
    $conf = @{}
    Get-Content $cfg | Where-Object { $_ -match '=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $conf[$k.Trim()] = $v.Trim() }
    $Port = $conf['GARMIN_MCP_PORT']; $Secret = $conf['GARMIN_MCP_SECRET']

    Say '1/5 cloudflared herunterladen'
    if (-not (Test-Path $Cf)) {
        Invoke-WebRequest -UseBasicParsing 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $Cf
    }
    & $Cf --version

    Say '2/5 Bei Cloudflare anmelden'
    $certDir = "$env:USERPROFILE\.cloudflared"
    if (-not (Test-Path "$certDir\cert.pem")) {
        Write-Host 'Gleich oeffnet sich ein Browser-Fenster (oder es erscheint ein Link: kopieren und im Browser oeffnen).' -ForegroundColor Yellow
        Write-Host 'Bei Cloudflare anmelden und die Domain weissnoel.com waehlen, dann "Authorize". Danach geht es hier automatisch weiter.' -ForegroundColor Yellow
        & $Cf tunnel login
        if (-not (Test-Path "$certDir\cert.pem")) { Write-Host 'Anmeldung bei Cloudflare nicht abgeschlossen.' -ForegroundColor Red; return }
    } else { Write-Host 'Schon angemeldet.' }

    Say '3/5 Tunnel anlegen'
    $ErrorActionPreference = 'Continue'
    $list = (& $Cf tunnel list --output json 2>$null) | Out-String | ConvertFrom-Json
    $t = $list | Where-Object { $_.name -eq $TunnelName } | Select-Object -First 1
    if (-not $t) {
        & $Cf tunnel create $TunnelName
        $list = (& $Cf tunnel list --output json 2>$null) | Out-String | ConvertFrom-Json
        $t = $list | Where-Object { $_.name -eq $TunnelName } | Select-Object -First 1
    }
    $ErrorActionPreference = 'Stop'
    if (-not $t) { Write-Host 'Tunnel konnte nicht angelegt werden.' -ForegroundColor Red; return }
    $id = $t.id
    $credSrc = "$certDir\$id.json"
    if (-not (Test-Path $credSrc)) { Write-Host "Zugangsdatei $credSrc fehlt. Bitte Claude Bescheid geben." -ForegroundColor Red; return }
    Copy-Item $credSrc "$Data\tunnel-$id.json" -Force
    @(
        "tunnel: $id",
        "credentials-file: $Data\tunnel-$id.json",
        'ingress:',
        "  - hostname: $HostName",
        "    service: http://127.0.0.1:$Port",
        '  - service: http_status:404'
    ) | Set-Content -Path "$Data\cloudflared.yml" -Encoding ASCII

    Say "4/5 Adresse $HostName eintragen"
    $ErrorActionPreference = 'Continue'
    & $Cf tunnel route dns $TunnelName $HostName 2>&1 | Out-Host
    $ErrorActionPreference = 'Stop'

    Say '5/5 Tunnel als Dienst starten (startet automatisch mit Windows)'
    $action    = New-ScheduledTaskAction -Execute $Cf -Argument "tunnel --no-autoupdate --config `"$Data\cloudflared.yml`" run" -WorkingDirectory $Root
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -Priority 7
    Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $Task
    Write-Host 'Warte 20 Sekunden, bis der Tunnel steht...'
    Start-Sleep -Seconds 20

    $url = "https://$HostName/$Secret/mcp"
    $body = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $url -ContentType 'application/json' -Headers @{ Accept = 'application/json, text/event-stream' } -Body $body
        if ($r.Content -like '*garmin_tageswerte*') { Write-Host 'Test von aussen: OK' -ForegroundColor Green }
    } catch { Write-Host "Test von aussen noch nicht erfolgreich ($($_.Exception.Message)). Das kann 1-2 Minuten dauern." -ForegroundColor Yellow }

    Say 'Connector-Adresse fuer claude.ai (geheim halten wie ein Passwort):'
    Write-Host $url -ForegroundColor Green
    try { Set-Clipboard -Value $url; Write-Host '(In die Zwischenablage kopiert.)' } catch {}
}

Install-GarminTunnel
