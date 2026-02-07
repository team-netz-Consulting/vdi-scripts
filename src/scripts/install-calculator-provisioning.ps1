#requires -version 5.1
<#
    .SYNOPSIS
        Windows Server 2025 RDS – Windows Calculator (Microsoft.WindowsCalculator)
        Zentrale Bereitstellung (Provisioning) inkl. Status / Install / Update / Remove


        Dieses Skript dient als Vorlage für Automatisierungs-Skripte in VDI-/RDS-Umgebungen.
        Es ist kompatibel zum Orchestrator (src/run.ps1) und unterstützt NonInteractive,
        Logging, WhatIf/Verbose und einheitliche ExitCodes.

    .DESCRIPTION
        Dieses script installiert den Windows Calculator.


    .EXAMPLE
        # Non-Interactive Install
        .\install-calculator-provisioning.ps1 -Action install -NonInteractive -Force -Verbose

    .EXAMPLE
        # Nur Status ausgeben
        .\install-calculator-provisioning.ps1 -Action status -NonInteractive

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.0
        Created on:    07.02.2026
        Last Modified: 07.02.2026

    .CHANGELOG
        Version 1.0 - 07.02.2026
        - Initial script created (Orchestrator-compatible skeleton)

    .REQUIREMENTS
        - PowerShell 5.1 or newer
        - Administrative permissions (für systemweite Änderungen)
        - Optional: BITS / Internetzugang (je nach Use-Case)
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigDir,
    [string]$LogDir,

    # install | update | remove | status | menu
    [ValidateSet("status","install","update","remove","menu")]
    [string]$Action = "menu",

    [switch]$NonInteractive,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Config (App-spezifisch)
# -----------------------------
$AppDisplayName = "Microsoft.WindowsCalculator"

# Download-URIs
$CalcUri   = "http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/ea3bc611-fa15-49e6-b10a-23b0769c6a7e?P1=1770402309&P2=404&P3=2&P4=lHkpsZpZ5VI7Ns4yL2cZklgTQvou9GSaK26rJOc2Sy%2fbhSoPxN3CG85gMGQ3zyQlcM5RrPm8WXu2MqYeWmw9YA%3d%3d"
$VCLibsUri = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"

# Dateinamen
$CalcFileName   = "WindowsCalculator.msixbundle"
$VCLibsFileName = "Microsoft.VCLibs.x64.appx"

# -----------------------------
# Resolve Paths (Subscript-friendly)
# -----------------------------
function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# Defaults, falls Orchestrator nichts übergibt:
if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot "..\..\config" }
if (-not $LogDir)    { $LogDir    = Join-Path $ConfigDir "logs" }

Ensure-Dir $ConfigDir
Ensure-Dir $LogDir

# App-Arbeitsordner in config (damit alles “bei euch” bleibt)
$BasePath = Join-Path $ConfigDir "packages\Calculator"
Ensure-Dir $BasePath

$CalcFile   = Join-Path $BasePath $CalcFileName
$VCLibsFile = Join-Path $BasePath $VCLibsFileName

# Logfile pro Script/Tag
$LogFile = Join-Path $LogDir ("calculator-provisioning-{0}.log" -f (Get-Date -Format "yyyyMMdd"))

# -----------------------------
# Helpers
# -----------------------------
function Set-CodepageUtf8 {
    try { chcp 65001 | Out-Null } catch {}
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $script:OutputEncoding = [Text.Encoding]::UTF8
    } catch {}
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","OK")][string]$Level="INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    $line | Tee-Object -FilePath $LogFile -Append | Out-Host
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Dieses Skript muss als Administrator ausgeführt werden." "ERROR"
        exit 1
    }
}

function Enable-Tls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

function Download-File {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Enable-Tls12
    Ensure-Dir (Split-Path $OutFile -Parent)

    if ($PSCmdlet.ShouldProcess($OutFile, "Download from $Uri")) {
        # Erst BITS (robust), fallback IWR
        try {
            Write-Log "Download (BITS): $Uri -> $OutFile" "INFO"
            Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
            return
        } catch {
            Write-Log "BITS fehlgeschlagen, fallback Invoke-WebRequest: $($_.Exception.Message)" "WARN"
        }

        Write-Log "Download (IWR): $Uri -> $OutFile" "INFO"
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
}

function Get-ProvisionedCalc {
    try {
        Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $AppDisplayName }
    } catch {
        $null
    }
}

function Get-InstalledCalcForAnyUser {
    try {
        Get-AppxPackage -AllUsers -Name $AppDisplayName -ErrorAction SilentlyContinue
    } catch {
        $null
    }
}

function Show-Status {
    $prov = Get-ProvisionedCalc
    $inst = Get-InstalledCalcForAnyUser

    Write-Host ""
    Write-Host "=== STATUS: Windows Calculator (RDS zentral) ===" -ForegroundColor Cyan

    if ($prov) {
        Write-Host ("Provisioniert: JA | Version: {0} | PackageName: {1}" -f $prov.Version, $prov.PackageName) -ForegroundColor Green
    } else {
        Write-Host "Provisioniert: NEIN" -ForegroundColor Yellow
    }

    if ($inst) {
        $top = $inst | Sort-Object Version -Descending | Select-Object -First 1
        Write-Host ("Installiert (AllUsers): JA | Höchste Version: {0} | Publisher: {1}" -f $top.Version, $top.Publisher) -ForegroundColor Green
    } else {
        Write-Host "Installiert (AllUsers): (keine Treffer oder Abfrage nicht verfügbar)" -ForegroundColor DarkYellow
    }

    Write-Host ("Arbeitsordner: {0}" -f $BasePath)
    Write-Host ("Dateien: CalculatorBundle={0}, VCLibs={1}" -f (Test-Path $CalcFile), (Test-Path $VCLibsFile))
    Write-Host ("Log: {0}" -f $LogFile)
    Write-Host ""
}

function Provision-Calc {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [switch]$ForceReprovision
    )

    $prov = Get-ProvisionedCalc

    if ($prov -and -not $ForceReprovision) {
        Write-Log "Bereits provisioniert (Version $($prov.Version)). Kein Install notwendig." "OK"
        return
    }

    if ($ForceReprovision -and $prov) {
        if ($PSCmdlet.ShouldProcess($prov.PackageName, "Remove existing provisioning")) {
            Write-Log "ForceReprovision: Entferne bestehendes Provisioning ($($prov.PackageName))..." "WARN"
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            Write-Log "Provisioning entfernt." "OK"
        }
    }

    # Downloads (immer frisch bei Install/Update, damit Update wirklich zieht)
    Download-File -Uri $VCLibsUri -OutFile $VCLibsFile
    Download-File -Uri $CalcUri   -OutFile $CalcFile

    # Provisioning VCLibs
    try {
        if ($PSCmdlet.ShouldProcess("Online Image", "Add provisioned package: VCLibs")) {
            Write-Log "Provisioniere Abhängigkeit (VCLibs)..." "INFO"
            Add-AppxProvisionedPackage -Online -PackagePath $VCLibsFile -SkipLicense -ErrorAction Stop | Out-Null
            Write-Log "VCLibs provisioniert." "OK"
        }
    } catch {
        # Oft schon vorhanden -> Warn statt Abbruch
        Write-Log "VCLibs Provisioning: $($_.Exception.Message)" "WARN"
    }

    # Provisioning Calculator
    if ($PSCmdlet.ShouldProcess("Online Image", "Add provisioned package: Windows Calculator")) {
        Write-Log "Provisioniere Windows Calculator..." "INFO"
        Add-AppxProvisionedPackage -Online -PackagePath $CalcFile -SkipLicense -ErrorAction Stop | Out-Null
        Write-Log "Windows Calculator provisioniert." "OK"
        Write-Log "Hinweis: Neue Benutzerprofile erhalten den Rechner automatisch. Bestehende User: einmal ab-/anmelden." "OK"
    }
}

function Remove-CalcProvisioning {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $prov = Get-ProvisionedCalc
    if (-not $prov) {
        Write-Log "Kein Provisioning gefunden - nichts zu entfernen." "WARN"
        return
    }

    if ($PSCmdlet.ShouldProcess($prov.PackageName, "Remove provisioned package")) {
        Write-Log "Entferne Provisioning ($($prov.PackageName))..." "INFO"
        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
        Write-Log "Provisioning entfernt." "OK"
        Write-Log "Hinweis: Falls der Calculator bereits in Benutzerprofilen installiert war, kann er dort weiterhin vorhanden sein." "WARN"
    }
}

function Pause-Continue {
    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "Enter drücken zum Fortfahren" | Out-Null
    }
}

function Is-InteractiveSession {
    # Wenn explizit NonInteractive -> false
    if ($NonInteractive) { return $false }
    # Heuristik: Console vorhanden + nicht in reinem CI
    try { return [Environment]::UserInteractive } catch { return $true }
}

# -----------------------------
# Main
# -----------------------------
Set-CodepageUtf8
Assert-Admin
Write-Log "=== Start | Action=$Action | Force=$Force | WhatIf=$WhatIfPreference | Verbose=$($PSBoundParameters.ContainsKey('Verbose')) | NonInteractive=$NonInteractive ===" "INFO"

try {
    # NonInteractive: Action muss sinnvoll sein (menu ist dann Quatsch)
    if ($NonInteractive -and $Action -eq "menu") {
        $Action = "status"
    }

    switch ($Action) {
        "status" {
            Show-Status
            exit 0
        }

        "install" {
            # install = provision wenn fehlt; Force kann hier “reinstall” sein, wenn gewünscht:
            if ($Force) { Provision-Calc -ForceReprovision } else { Provision-Calc }
            Show-Status
            exit 0
        }

        "update" {
            # update = immer reprovision (wie vorher Menüpunkt 3)
            Provision-Calc -ForceReprovision
            Show-Status
            exit 0
        }

        "remove" {
            Remove-CalcProvisioning
            Show-Status
            exit 0
        }

        "menu" {
            if (-not (Is-InteractiveSession)) {
                Show-Status
                exit 0
            }

            # Menü wie vorher, aber sauber und ohne Clear-Host-Loop-Zwang
            while ($true) {
                Show-Status

                Write-Host "=== MENÜ ===" -ForegroundColor Cyan
                Write-Host "1) Status anzeigen"
                Write-Host "2) Install / Repair"
                Write-Host "3) Update (Reprovision)"
                Write-Host "4) Remove (Provisioning entfernen)"
                Write-Host "5) Log anzeigen (letzte 40 Zeilen)"
                Write-Host "0) Beenden"
                Write-Host ""

                $choice = Read-Host "Auswahl"
                switch ($choice) {
                    "1" { Show-Status; Pause-Continue }
                    "2" { if ($Force) { Provision-Calc -ForceReprovision } else { Provision-Calc }; Pause-Continue }
                    "3" { Provision-Calc -ForceReprovision; Pause-Continue }
                    "4" { Remove-CalcProvisioning; Pause-Continue }
                    "5" {
                        if (Test-Path $LogFile) {
                            Write-Host ""
                            Write-Host "=== LOG (letzte 40 Zeilen) ===" -ForegroundColor Cyan
                            Get-Content $LogFile -Tail 40 | Out-Host
                        } else {
                            Write-Host "Kein Log gefunden." -ForegroundColor Yellow
                        }
                        Pause-Continue
                    }
                    "0" { Write-Log "=== Ende (User Exit) ===" "INFO"; exit 0 }
                    default { Write-Host "Ungültige Auswahl." -ForegroundColor Yellow }
                }

                try { Clear-Host } catch {}
            }
        }
    }
}
catch {
    Write-Log "Fehler: $($_.Exception.Message)" "ERROR"
    exit 1
}
finally {
    Write-Log "=== Ende ===" "INFO"
}
