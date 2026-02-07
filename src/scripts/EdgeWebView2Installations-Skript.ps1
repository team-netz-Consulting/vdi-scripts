# EdgeWebView2 Installations-Skript
# Dieses Skript bietet mehrere Optionen: Deinstallation, Setzen von Registrierungsschlüsseln und Installation.

# Menü anzeigen
function Show-Menu {
    Write-Host "Wählen Sie eine Option:" -ForegroundColor Green
    Write-Host "1. Deinstallation von EdgeWebView2"
    Write-Host "2. Registrierungseinträge setzen"
    Write-Host "3. EdgeWebView2 für alle Benutzer installieren"
    Write-Host "4. Beenden"
}

# Funktion zur Deinstallation von EdgeWebView2
function Uninstall-EdgeWebView2 {
    $installerPath = Join-Path $env:LocalAppData 'Microsoft\EdgeWebView\Application\1*\Installer'
    if (Test-Path $installerPath) {
        Write-Host "Deinstalliere EdgeWebView2..." -ForegroundColor Yellow
        Start-Process -FilePath "setup.exe" -ArgumentList "--uninstall --msedgewebview --verbose-logging --force-uninstall" -WorkingDirectory $installerPath -NoNewWindow -Wait
        Write-Host "EdgeWebView2 wurde deinstalliert." -ForegroundColor Green
    } else {
        Write-Host "Installer-Pfad nicht gefunden." -ForegroundColor Red
    }
}

# Funktion zum Setzen von Registrierungseinträgen
function Set-Registry {
    Write-Host "Setze Registrierungseinträge..." -ForegroundColor Yellow
    # Show in Control Panel
    Set-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView" -Name "SystemComponent" -Value 0 -ErrorAction SilentlyContinue

    # Disable AutoUpdate
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" -Name "Update" -Type DWord -Value 0

    # Disable MSEdgeUpdate
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate" -Name "UpdateDefault" -Type DWord -Value 2

    Write-Host "Registrierungseinträge wurden gesetzt." -ForegroundColor Green
}

# Funktion zur Installation von EdgeWebView2
function Install-EdgeWebView2 {
    $installerURL = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
    $installerPath = "C:\Support\MicrosoftEdgeWebView2RuntimeInstallerX64.exe"

    if (-Not (Test-Path "C:\Support")) {
        New-Item -ItemType Directory -Path "C:\Support" | Out-Null
    }

    Write-Host "Lade EdgeWebView2 Installer herunter..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $installerURL -OutFile $installerPath

    Write-Host "Installiere EdgeWebView2 für alle Benutzer..." -ForegroundColor Yellow
    Start-Process -FilePath $installerPath -NoNewWindow -Wait

    Write-Host "EdgeWebView2 wurde installiert." -ForegroundColor Green
}

# Hauptprogramm
while ($true) {
    Show-Menu
    $option = Read-Host "Ihre Auswahl"

    switch ($option) {
        "1" { Uninstall-EdgeWebView2 }
        "2" { Set-Registry }
        "3" { Install-EdgeWebView2 }
        "4" {
            exit
            break }
        default { Write-Host "Ungültige Auswahl. Bitte erneut versuchen." -ForegroundColor Red }
    }
}
