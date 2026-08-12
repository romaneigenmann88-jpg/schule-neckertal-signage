<#
  Schule Neckertal Signage – Fix-Rollout auf BESTEHENDE Raspberry Pis.

  Spielt die aktuellen bin/-Skripte (inkl. Selbst-Updater in render-sync.py) aus
  diesem Repo auf laufende Pis. Danach halten sich die Pis per render-sync selbst
  aktuell – dieser Rollout ist also EINMALIG pro bestehendem Pi noetig, damit sie
  die Selbst-Update-Faehigkeit ueberhaupt bekommen. Frisch geflashte Pis brauchen
  ihn NICHT (setup.sh zieht bereits das gefixte Repo).

  Voraussetzung: Dieser PC ist im SELBEN Netz wie die Pis. SSH-User = 'admin'.
  Beim ersten Kontakt fragt SSH einmal das Pi-Passwort ab (danach laeuft alles
  ueber den installierten Key ~/.ssh/signage_pi).

  Beispiele:
    .\rollout-fix.ps1 -Ips 192.168.1.94,192.168.1.95        # Screen 1 + 2 (OS)
    .\rollout-fix.ps1 -Ips 192.168.1.60 -User admin         # ein OZN-Screen
#>
param(
  [Parameter(Mandatory=$true)][string[]]$Ips,
  [string]$User = "admin"
)

$repo = Split-Path $PSScriptRoot -Parent
$key  = Join-Path $env:USERPROFILE ".ssh\signage_pi"
if (-not (Test-Path "$key.pub")) { throw "Public-Key $key.pub nicht gefunden." }
$pub  = (Get-Content "$key.pub" -Raw).Trim()

$files = @(
  "pi\display-schedule.sh",
  "pi\heartbeat.sh",
  "pi\command-poll.sh",
  "pi\render-sync.py",
  "tools\build_manifest.py",
  "tools\normalize_slides.py"
) | ForEach-Object { Join-Path $repo $_ }

foreach ($ip in $Ips) {
  Write-Host "`n=== $ip ===" -ForegroundColor Cyan
  try {
    # 1) Key installieren (idempotent). Erster Kontakt: einmal Pi-Passwort eingeben.
    $installKey = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && " +
                  "(grep -q claude-signage-setup ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys) && " +
                  "chmod 600 ~/.ssh/authorized_keys && echo KEY_OK"
    Write-Host "[1/3] Key installieren (ggf. Pi-Passwort eingeben) ..." -ForegroundColor Yellow
    ssh -o StrictHostKeyChecking=accept-new "$User@$ip" $installKey

    # 2) Skripte per Key kopieren (admin besitzt /opt/school-signage -> kein sudo).
    Write-Host "[2/3] Skripte kopieren ..." -ForegroundColor Yellow
    scp -i $key -o StrictHostKeyChecking=accept-new $files "$User@${ip}:/opt/school-signage/bin/"

    # 3) Ausfuehrbar machen + einmal sofort synchronisieren.
    Write-Host "[3/3] Aktivieren + Sofort-Sync ..." -ForegroundColor Yellow
    $activate = 'chmod +x /opt/school-signage/bin/*.sh /opt/school-signage/bin/render-sync.py; ' +
                'python3 /opt/school-signage/bin/render-sync.py >/dev/null 2>&1; ' +
                'echo FERTIG auf $(hostname)'
    ssh -i $key "$User@$ip" $activate
  }
  catch {
    Write-Host "FEHLER bei $ip : $_" -ForegroundColor Red
  }
}
Write-Host "`nRollout abgeschlossen." -ForegroundColor Green
