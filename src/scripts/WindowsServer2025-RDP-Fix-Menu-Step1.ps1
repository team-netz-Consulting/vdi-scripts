#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Menügestützte Konfiguration für Windows Server 2025 RDP-Stabilitätsmaßnahmen.

.DESCRIPTION
    Zeigt beim Start den aktuellen Status von sechs Maßnahmen an.
    In dieser Version sind Schritt 1 bis 3 umgesetzt.

    Quelle der Maßnahmen:
    https://www.a6n.co.uk/2025/08/fixing-windows-server-2025-rdp-crashes.html
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TerminalServicesPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'

function Write-StatusLine {
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Status,

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host ('[{0}] {1,-34} : ' -f $Number, $Name) -NoNewline
    Write-Host $Status -ForegroundColor $Color
}

function Get-RegistryDword {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return [int]$item.$Name
    }
    catch {
        return $null
    }
}

function Get-RdpFixStatus {
    $networkDetection = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableNetworkDetection'
    $wddmDriver      = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableWddmDriver'
    $useWddmDrivers = Get-RegistryDword -Path $TerminalServicesPath -Name 'UseWDDMDrivers'
    $udp             = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableUDP'
    $disableHw       = Get-RegistryDword -Path $TerminalServicesPath -Name 'fDisableHWAcceleration'
    $remoteFx        = Get-RegistryDword -Path $TerminalServicesPath -Name 'bEnableRemoteFXAdvancedRemoteApp'
    $softwareRender  = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableSoftwareRendering'

    $serviceNames = @('TermService', 'SessionEnv', 'UmRdpService')
    $services = foreach ($serviceName in $serviceNames) {
        Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        NetworkDetection = if ($networkDetection -eq 1) {
            @{ Text = 'Aktiv'; Color = 'Green' }
        }
        elseif ($null -eq $networkDetection) {
            @{ Text = 'Nicht konfiguriert'; Color = 'Yellow' }
        }
        else {
            @{ Text = "Inaktiv (Wert: $networkDetection)"; Color = 'Red' }
        }

        Wddm = if (($wddmDriver -eq 0) -and ($useWddmDrivers -eq 0)) {
            @{ Text = 'Deaktiviert'; Color = 'Green' }
        }
        elseif (($null -eq $wddmDriver) -and ($null -eq $useWddmDrivers)) {
            @{ Text = 'Nicht konfiguriert'; Color = 'Yellow' }
        }
        else {
            @{ Text = 'Nicht vollständig deaktiviert'; Color = 'Red' }
        }

        Udp = if ($udp -eq 0) {
            @{ Text = 'Deaktiviert'; Color = 'Green' }
        }
        elseif ($null -eq $udp) {
            @{ Text = 'Nicht konfiguriert'; Color = 'Yellow' }
        }
        else {
            @{ Text = "Aktiv (Wert: $udp)"; Color = 'Red' }
        }

        GraphicsAcceleration = if (($disableHw -eq 1) -and ($remoteFx -eq 0) -and ($softwareRender -eq 1)) {
            @{ Text = 'Deaktiviert / Software-Rendering aktiv'; Color = 'Green' }
        }
        elseif (($null -eq $disableHw) -and ($null -eq $remoteFx) -and ($null -eq $softwareRender)) {
            @{ Text = 'Nicht konfiguriert'; Color = 'Yellow' }
        }
        else {
            @{ Text = 'Nicht vollständig konfiguriert'; Color = 'Red' }
        }

        Cache = @{
            Text = 'Kein dauerhafter Status prüfbar'
            Color = 'DarkYellow'
        }

        Services = if ($services.Count -eq 3 -and @($services | Where-Object Status -ne 'Running').Count -eq 0) {
            @{ Text = 'Alle RDP-Dienste laufen'; Color = 'Green' }
        }
        else {
            $notRunning = @($services | Where-Object Status -ne 'Running' | ForEach-Object Name)
            if ($notRunning.Count -gt 0) {
                @{ Text = "Nicht laufend: $($notRunning -join ', ')"; Color = 'Red' }
            }
            else {
                @{ Text = 'Mindestens ein Dienst nicht gefunden'; Color = 'Yellow' }
            }
        }
    }
}

function Show-RdpFixStatus {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' Windows Server 2025 – RDP-Stabilitätsmaßnahmen (Schritte 1-3)' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host

    $status = Get-RdpFixStatus

    Write-StatusLine 1 'Network Detection'       $status.NetworkDetection.Text      $status.NetworkDetection.Color
    Write-StatusLine 2 'WDDM-Treiber deaktivieren' $status.Wddm.Text                $status.Wddm.Color
    Write-StatusLine 3 'RDP über UDP deaktivieren'  $status.Udp.Text                 $status.Udp.Color
    Write-StatusLine 4 'Grafikbeschleunigung aus'   $status.GraphicsAcceleration.Text $status.GraphicsAcceleration.Color
    Write-StatusLine 5 'RDP-/Grafik-Cache leeren'   $status.Cache.Text               $status.Cache.Color
    Write-StatusLine 6 'RDP-Dienste neu starten'    $status.Services.Text            $status.Services.Color

    Write-Host
    Write-Host 'Hinweis: Bei Schritt 5 und 6 lässt sich nur der aktuelle Zustand,' -ForegroundColor DarkGray
    Write-Host 'nicht sicher eine frühere Ausführung nachweisen.' -ForegroundColor DarkGray
    Write-Host
}

function Enable-NetworkDetection {
    Write-Host
    Write-Host 'Schritt 1: Network Detection aktivieren' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $TerminalServicesPath)) {
        New-Item -Path $TerminalServicesPath -Force | Out-Null
        Write-Host "Registry-Pfad wurde erstellt: $TerminalServicesPath" -ForegroundColor Yellow
    }

    $oldValue = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableNetworkDetection'

    if ($oldValue -eq 1) {
        Write-Host 'Network Detection ist bereits aktiviert.' -ForegroundColor Green
        return
    }

    Set-ItemProperty `
        -LiteralPath $TerminalServicesPath `
        -Name 'fEnableNetworkDetection' `
        -Type DWord `
        -Value 1 `
        -Force

    $newValue = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableNetworkDetection'

    if ($newValue -ne 1) {
        throw 'Die Registry-Einstellung konnte nicht verifiziert werden.'
    }

    if ($null -eq $oldValue) {
        Write-Host 'Network Detection wurde aktiviert (vorher nicht konfiguriert).' -ForegroundColor Green
    }
    else {
        Write-Host "Network Detection wurde aktiviert (vorheriger Wert: $oldValue)." -ForegroundColor Green
    }

    Write-Host 'Registry-Wert:' -ForegroundColor DarkGray
    Write-Host "  $TerminalServicesPath\fEnableNetworkDetection = 1" -ForegroundColor DarkGray
    Write-Host
    Write-Host 'Die Richtlinie wirkt spätestens nach einer Richtlinienaktualisierung' -ForegroundColor Yellow
    Write-Host 'oder einem Neustart. Es wird kein RDP-Dienst automatisch neu gestartet.' -ForegroundColor Yellow
}


function Disable-WddmDriver {
    Write-Host
    Write-Host 'Schritt 2: WDDM-Grafiktreiber deaktivieren' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $TerminalServicesPath)) {
        New-Item -Path $TerminalServicesPath -Force | Out-Null
    }

    Set-ItemProperty -LiteralPath $TerminalServicesPath -Name 'fEnableWddmDriver' -Type DWord -Value 0 -Force
    Set-ItemProperty -LiteralPath $TerminalServicesPath -Name 'UseWDDMDrivers' -Type DWord -Value 0 -Force

    $value1 = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableWddmDriver'
    $value2 = Get-RegistryDword -Path $TerminalServicesPath -Name 'UseWDDMDrivers'

    if (($value1 -ne 0) -or ($value2 -ne 0)) {
        throw 'Die WDDM-Registry-Werte konnten nicht verifiziert werden.'
    }

    Write-Host 'WDDM-Grafiktreiber für RDP wurde deaktiviert.' -ForegroundColor Green
    Write-Host "  fEnableWddmDriver = $value1" -ForegroundColor DarkGray
    Write-Host "  UseWDDMDrivers    = $value2" -ForegroundColor DarkGray
    Write-Host
    Write-Host 'Ein Neustart des Servers oder der RDP-Dienste wird empfohlen.' -ForegroundColor Yellow
}

function Disable-RdpUdp {
    Write-Host
    Write-Host 'Schritt 3: RDP über UDP deaktivieren' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $TerminalServicesPath)) {
        New-Item -Path $TerminalServicesPath -Force | Out-Null
    }

    $oldValue = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableUDP'

    if ($oldValue -eq 0) {
        Write-Host 'RDP über UDP ist bereits deaktiviert.' -ForegroundColor Green
        return
    }

    Set-ItemProperty `
        -LiteralPath $TerminalServicesPath `
        -Name 'fEnableUDP' `
        -Type DWord `
        -Value 0 `
        -Force

    $newValue = Get-RegistryDword -Path $TerminalServicesPath -Name 'fEnableUDP'

    if ($newValue -ne 0) {
        throw 'Der Registry-Wert fEnableUDP konnte nicht verifiziert werden.'
    }

    if ($null -eq $oldValue) {
        Write-Host 'RDP über UDP wurde deaktiviert (vorher nicht konfiguriert).' -ForegroundColor Green
    }
    else {
        Write-Host "RDP über UDP wurde deaktiviert (vorheriger Wert: $oldValue)." -ForegroundColor Green
    }

    Write-Host 'Registry-Wert:' -ForegroundColor DarkGray
    Write-Host "  $TerminalServicesPath\fEnableUDP = 0" -ForegroundColor DarkGray
    Write-Host
    Write-Host 'Bestehende RDP-Sitzungen werden nicht automatisch getrennt.' -ForegroundColor Yellow
    Write-Host 'Die Änderung greift spätestens nach Neustart der RDP-Dienste oder des Servers.' -ForegroundColor Yellow
}

function Show-Menu {
    Write-Host 'Menü' -ForegroundColor White
    Write-Host '  [1] Schritt 1 – Network Detection aktivieren'
    Write-Host '  [2] Schritt 2 – WDDM-Grafiktreiber deaktivieren'
    Write-Host '  [3] Schritt 3 – RDP über UDP deaktivieren'
    Write-Host '  [4] Schritt 4 – noch nicht implementiert' -ForegroundColor DarkGray
    Write-Host '  [5] Schritt 5 – noch nicht implementiert' -ForegroundColor DarkGray
    Write-Host '  [6] Schritt 6 – noch nicht implementiert' -ForegroundColor DarkGray
    Write-Host '  [R] Status aktualisieren'
    Write-Host '  [Q] Beenden'
    Write-Host
}

do {
    Show-RdpFixStatus
    Show-Menu

    $selection = (Read-Host 'Auswahl').Trim().ToUpperInvariant()

    switch ($selection) {
        '1' {
            try {
                Enable-NetworkDetection
            }
            catch {
                Write-Host
                Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
            }

            Write-Host
            [void](Read-Host 'Enter drücken, um zum Menü zurückzukehren')
        }

        '2' {
            try {
                Disable-WddmDriver
            }
            catch {
                Write-Host
                Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
            }

            Write-Host
            [void](Read-Host 'Enter drücken, um zum Menü zurückzukehren')
        }

        '3' {
            try {
                Disable-RdpUdp
            }
            catch {
                Write-Host
                Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
            }

            Write-Host
            [void](Read-Host 'Enter drücken, um zum Menü zurückzukehren')
        }

        { $_ -in @('4', '5', '6') } {
            Write-Host
            Write-Host "Schritt $selection ist in dieser Version noch nicht implementiert." -ForegroundColor Yellow
            Write-Host
            [void](Read-Host 'Enter drücken, um zum Menü zurückzukehren')
        }

        'R' {
            # Die Schleife zeichnet Status und Menü erneut.
        }

        'Q' {
            break
        }

        default {
            Write-Host
            Write-Host 'Ungültige Auswahl.' -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
while ($selection -ne 'Q')