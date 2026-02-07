<#
    Installiert Citrix VDA 2507
    optional mit Cleanup von deviceTRUST Agent & uberAgent.

    Beispiele Aufruf:
    - Nur Installation:
      powershell.exe -ExecutionPolicy Bypass -File .\Install_VDA2507.ps1

    - Installation + Cleanup:
      powershell.exe -ExecutionPolicy Bypass -File .\Install_VDA2507.ps1 -DoCleanup

    - Nur Cleanup (kein VDA-Setup mehr ausführen, z.B. nachträglich):
      powershell.exe -ExecutionPolicy Bypass -File .\Install_VDA2507.ps1 -SkipInstall -DoCleanup
#>

[CmdletBinding()]
param(
    [switch]$SkipInstall,  # wenn gesetzt: VDA-Installation wird übersprungen
    [switch]$DoCleanup     # wenn gesetzt: deviceTRUST & uberAgent werden entfernt
)

# ---------------------------------------------------------
# Einstellungen
# ---------------------------------------------------------

$VDASetup = "..\VDAServerSetup_2507.exe"

# ---------------------------------------------------------
# Funktion: Cleanup deviceTRUST Agent & uberAgent
# ---------------------------------------------------------

function Uninstall-AppByNamePattern {
    param(
        [Parameter(Mandatory = $true)][string]$NamePattern
    )

    $uninstallRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }

        Get-ItemProperty "$root\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $NamePattern } |
            ForEach-Object {
                Write-Host "Gefunden: $($_.DisplayName)"

                $uninst = $_.UninstallString
                if (-not $uninst) {
                    Write-Warning "Kein UninstallString für $($_.DisplayName) gefunden."
                    return
                }

                Write-Host "Starte Deinstallation: $uninst"

                # über cmd.exe starten, damit auch komplexe Strings funktionieren
                # ggf. /quiet /norestart anhängen, wenn es eine MSI-Deinstallation ist
                if ($uninst -match "msiexec\.exe" -and $uninst -notmatch "/quiet" -and $uninst -notmatch "/qn") {
                    $uninst = "$uninst /quiet /norestart"
                }

                Start-Process "cmd.exe" -ArgumentList "/c `"$uninst`"" -Wait
            }
    }
}

function Run-Cleanup {
    Write-Host "=== Cleanup: deviceTRUST Agent x64 2507 LTSR ==="
    Uninstall-AppByNamePattern -NamePattern "*deviceTRUST Agent x64 2507 LTSR*"

    Write-Host "=== Cleanup: uberAgent ==="
    Uninstall-AppByNamePattern -NamePattern "*uberAgent*"

    Write-Host "Cleanup abgeschlossen."
}

# ---------------------------------------------------------
# VDA-Installation (optional)
# ---------------------------------------------------------

if (-not $SkipInstall) {
    Write-Host "Starte Installation Citrix VDA 2507..."

    $proc = Start-Process -FilePath $VDASetup -ArgumentList @(
        "/quiet",
        "/components `"VDA`"",
        "/controllers `"degctxddc01.klideg.de degctxddc02.klideg.de`"",
        "/enable_hdx_ports",
        "/enable_remote_assistance",
        "/enable_real_time_transport",
        "/enable_ss_ports"
    ) -Wait -PassThru

    if ($proc.ExitCode -ne 0) {
        Write-Error "VDA-Installation fehlgeschlagen. ExitCode: $($proc.ExitCode)"
        exit $proc.ExitCode
    }

    Write-Host "VDA-Installation abgeschlossen (ExitCode $($proc.ExitCode))."
}

# ---------------------------------------------------------
# Optionales Cleanup
# ---------------------------------------------------------

if ($DoCleanup) {
    Run-Cleanup
} else {
    Write-Host "Cleanup wurde nicht angefordert (-DoCleanup fehlt)."
}

Write-Host "Skript beendet."
exit 0
