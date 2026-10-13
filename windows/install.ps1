# Installiert den Garmin-Dienst für die Health-App auf einem Windows-Server.
# In PowerShell als Administrator einfügen:
#   [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/NoelWeiss/garmin-mcp/main/windows/install.ps1 | iex
# Fasst nichts anderes auf dem Server an: eigener Ordner C:\garmin-mcp, eigene geplante Aufgabe "GarminMCP".

function Install-GarminMcp {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $Root = 'C:\garmin-mcp'
    $App  = "$Root\app"
    $Data = "$Root\data"
    $Venv = "$Root\venv"
    $Port = 8765
    $Task = 'GarminMCP'
    $PyVersion = '3.12.10'

    function Say($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Host 'Bitte PowerShell als Administrator starten (Rechtsklick > Als Administrator ausführen).' -ForegroundColor Red; return }

    Say '1/6 Python prüfen'
    # Vorhandenes Python 3.10+ über die Registry finden (egal in welchem Ordner)
    function Find-Python {
        foreach ($c in @("$Root\python\python.exe", 'C:\Program Files\Python312\python.exe', 'C:\Program Files\Python313\python.exe')) {
            if (Test-Path $c) { return $c }
        }
        foreach ($hive in 'HKLM:', 'HKCU:') {
            foreach ($v in '3.13', '3.12', '3.11', '3.10') {
                $k = "$hive\SOFTWARE\Python\PythonCore\$v\InstallPath"
                if (Test-Path $k) {
                    $p = (Get-ItemProperty $k -ErrorAction SilentlyContinue).ExecutablePath
                    if (-not $p) { $d = (Get-Item $k).GetValue(''); if ($d) { $p = Join-Path $d 'python.exe' } }
                    if ($p -and (Test-Path $p)) { return $p }
                }
            }
        }
        return $null
    }
    $py = Find-Python
    if (-not $py) {
        Write-Host "Python $PyVersion wird installiert (2-3 Minuten)..."
        $inst = "$env:TEMP\python-$PyVersion-amd64.exe"
        Invoke-WebRequest -UseBasicParsing "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-amd64.exe" -OutFile $inst
        $log = "$env:TEMP\python-install.log"
        $pyArgs = "/quiet /log `"$log`" InstallAllUsers=1 PrependPath=0 Include_test=0 Include_launcher=0 TargetDir=$Root\python"
        $proc = Start-Process $inst -ArgumentList $pyArgs -Wait -PassThru
        Remove-Item $inst -Force -ErrorAction SilentlyContinue
        $py = Find-Python
        if (-not $py) {
            Write-Host "Python-Installation fehlgeschlagen (Code $($proc.ExitCode)). Letzte Zeilen aus $log :" -ForegroundColor Red
            if (Test-Path $log) { Get-Content $log -Tail 15 }
            return
        }
    }
    Write-Host "Python: $py"
    & $py --version

    Say '2/6 Programm herunterladen'
    New-Item -ItemType Directory -Force -Path $Root, $Data | Out-Null
    $zip = "$env:TEMP\garmin-mcp.zip"
    Invoke-WebRequest -UseBasicParsing 'https://github.com/NoelWeiss/garmin-mcp/archive/refs/heads/main.zip' -OutFile $zip
    $tmp = "$env:TEMP\garmin-mcp-src"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive $zip -DestinationPath $tmp -Force
    if (Test-Path $App) { Remove-Item $App -Recurse -Force }
    Move-Item "$tmp\garmin-mcp-main" $App
    Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Programm liegt in $App"

    Say '3/6 Python-Pakete installieren (1-2 Minuten)'
    if (-not (Test-Path "$Venv\Scripts\python.exe")) { & $py -m venv $Venv }
    & "$Venv\Scripts\python.exe" -m pip install -q --upgrade pip
    & "$Venv\Scripts\python.exe" -m pip install -q -r "$App\requirements.txt"
    if ($LASTEXITCODE -ne 0) { Write-Host 'Paket-Installation fehlgeschlagen.' -ForegroundColor Red; return }

    Say '4/6 Geheimen Pfad und Einstellungen anlegen'
    $cfg = "$Data\config.env"
    if (-not (Test-Path $cfg)) {
        $bytes = New-Object byte[] 32
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $secret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
        @(
            "GARMIN_MCP_SECRET=$secret",
            "GARMIN_MCP_PORT=$Port",
            "GARMIN_TOKENSTORE=$Data\garminconnect",
            "GARMIN_MCP_TZ=Europe/Zurich"
        ) | Set-Content -Path $cfg -Encoding ASCII
        Write-Host 'Neu erzeugt.'
    } else { Write-Host 'Bestehende Einstellungen bleiben.' }
    # Nur SYSTEM und Administratoren dürfen den Datenordner lesen (Tokens, geheimer Pfad)
    icacls $Data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

    Say '5/6 Dienst einrichten (startet automatisch mit Windows)'
    @(
        '@echo off',
        "`"$Venv\Scripts\python.exe`" `"$App\server.py`" --config `"$cfg`" >> `"$Data\server.log`" 2>&1"
    ) | Set-Content -Path "$Root\run-server.cmd" -Encoding ASCII
    @(
        '@echo off',
        'net session >nul 2>&1 || (echo Bitte als Administrator starten: Rechtsklick ^> Als Administrator ausfuehren & pause & exit /b 1)',
        "`"$Venv\Scripts\python.exe`" `"$App\login.py`" --config `"$cfg`"",
        'pause'
    ) | Set-Content -Path "$Root\garmin-login.cmd" -Encoding ASCII

    $action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$Root\run-server.cmd`"" -WorkingDirectory $App
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -Priority 7
    Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -like "*$App\server.py*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Register-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $Task
    Start-Sleep -Seconds 8

    Say '6/6 Prüfen'
    $secret = ((Get-Content $cfg | Where-Object { $_ -like 'GARMIN_MCP_SECRET=*' }) -split '=', 2)[1]
    $body = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    $hdr = @{ Accept = 'application/json, text/event-stream' }
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/$secret/mcp" -ContentType 'application/json' -Headers $hdr -Body $body
        if ($r.Content -like '*garmin_tageswerte*') { Write-Host 'Dienst laeuft und antwortet.' -ForegroundColor Green }
        else { Write-Host "Unerwartete Antwort: $($r.StatusCode)" -ForegroundColor Yellow }
    } catch {
        Write-Host 'Dienst antwortet NICHT. Letzte Log-Zeilen:' -ForegroundColor Red
        if (Test-Path "$Data\server.log") { Get-Content "$Data\server.log" -Tail 25 }
        return
    }

    Say 'Fertig. Naechste Schritte:'
    if (-not (Test-Path "$Data\garminconnect\garmin_tokens.json")) {
        Write-Host '  1. Garmin anmelden: Doppelklick auf C:\garmin-mcp\garmin-login.cmd (Rechtsklick > Als Administrator ausfuehren)'
    } else { Write-Host '  1. Garmin-Tokens sind schon da.' }
    Write-Host '  2. Tunnel einrichten: im Claude-Chat den Tunnel-Befehl kopieren und hier einfuegen.'
}

Install-GarminMcp
