#requires -version 5.1
<#
    .SYNOPSIS
        Azure Arc Setup – Install/Remove (VDI/RDS Subscript)

        Installiert oder entfernt das Windows Server 2025 Feature-on-Demand
        "Azure Arc Setup".

    .DESCRIPTION
        Dieses Skript integriert Azure Arc Setup in das standardisierte
        VDI/RDS Subscript-Framework.

        Funktionen:
        - Statusprüfung von Azure Arc Setup
        - Installation von Azure Arc Setup
        - Entfernen von Azure Arc Setup
        - Reapply / Update

        Unterstützt:
        - NonInteractive (Automation / Orchestrator)
        - Logging
        - WhatIf / Verbose
        - Einheitliche ExitCodes

        Hinweis:
        Dieses Skript entfernt ausschließlich das Feature "Azure Arc Setup"
        auf Windows Server 2025 und höher.

        Das Entfernen von Azure Arc Setup deinstalliert NICHT automatisch den
        Azure Connected Machine Agent. Falls der Server vollständig aus Azure Arc
        entfernt werden soll, müssen zusätzlich:
        - VM Extensions entfernt,
        - der Server per azcmagent getrennt,
        - und der Agent separat deinstalliert werden.

    .EXAMPLE
        # Azure Arc Setup entfernen
        .\azurearcsetup.ps1 -Action remove -NonInteractive -Verbose

    .EXAMPLE
        # Status prüfen
        .\azurearcsetup.ps1 -Action status -NonInteractive

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.0
        Created on:    01.04.2026
        Last Modified: 01.04.2026

    .CHANGELOG
        Version 1.0 - 01.04.2026
        - Initiale Implementierung für Windows Server 2025 Azure Arc Setup
        - Status / Install / Update / Remove integriert

    .REQUIREMENTS
        - PowerShell 5.1 or newer
        - Administrative permissions
        - Windows Server 2025 oder höher
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Wird vom Orchestrator übergeben
    [string]$ConfigDir,
    [string]$LogDir,

    # Einheitlicher Action-Mechanismus:
    # status  = nur Status ausgeben
    # install = installieren / reparieren
    # update  = update (häufig: reinstall/reprovision)
    # remove  = entfernen / cleanup
    # menu    = interaktives Menü
    [ValidateSet("status","install","update","remove","menu")]
    [string]$Action = "menu",

    # Option 7 (Orchestrator Standard):
    [switch]$NonInteractive,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Region: Script-spezifische Config
# -----------------------------
$ScriptKeyName = "AzureArcSetup"
$WorkSubDir    = "packages\$ScriptKeyName"

$CapabilityName = "AzureArcSetup~~~~"

# -----------------------------
# Region: Path-Setup (Subscript-friendly)
# -----------------------------
function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# Defaults, falls Orchestrator nichts übergibt
if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot "..\..\config" }
if (-not $LogDir)    { $LogDir    = Join-Path $ConfigDir "logs" }

Ensure-Dir $ConfigDir
Ensure-Dir $LogDir

# Einheitlicher Arbeitsordner in config (keine harten C:\Support Pfade)
$BasePath = Join-Path $ConfigDir $WorkSubDir
Ensure-Dir $BasePath

# Logfile pro Script/Tag
$LogFile = Join-Path $LogDir ("{0}-{1}.log" -f $ScriptKeyName.ToLower(), (Get-Date -Format "yyyyMMdd"))

# -----------------------------
# Region: Helper
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

function Is-InteractiveSession {
    if ($NonInteractive) { return $false }
    try { return [Environment]::UserInteractive } catch { return $true }
}

function Pause-Continue {
    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "Enter drücken zum Fortfahren" | Out-Null
    }
}

function Get-AzureArcSetupCapability {
    try {
        $cap = Get-WindowsCapability -Online -Name $CapabilityName -ErrorAction Stop
        return $cap
    }
    catch {
        throw "Azure Arc Setup Capability '$CapabilityName' konnte nicht abgefragt werden. Läuft das Skript auf Windows Server 2025 oder höher?"
    }
}

# -----------------------------
# Region: Domain Functions
# -----------------------------
function Get-Status {
    $cap = Get-AzureArcSetupCapability

    Write-Host ""
    Write-Host "=== STATUS: $ScriptKeyName ===" -ForegroundColor Cyan
    Write-Host ("Arbeitsordner: {0}" -f $BasePath)
    Write-Host ("Log:          {0}" -f $LogFile)
    Write-Host ("Capability:   {0}" -f $CapabilityName)
    Write-Host ("State:        {0}" -f $cap.State)

    switch ($cap.State) {
        "Installed" {
            Write-Host "Status: Azure Arc Setup IST INSTALLIERT" -ForegroundColor Green
        }
        "NotPresent" {
            Write-Host "Status: Azure Arc Setup IST NICHT INSTALLIERT" -ForegroundColor Yellow
        }
        default {
            Write-Host ("Status: Unbekannter/abweichender Zustand: {0}" -f $cap.State) -ForegroundColor Yellow
        }
    }

    Write-Host ""
}

function Do-Install {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $cap = Get-AzureArcSetupCapability

    if ($Force) {
        Write-Log "Force ist gesetzt: Azure Arc Setup wird erneut angewendet, sofern möglich." "WARN"
    }

    if ($cap.State -eq "Installed" -and -not $Force) {
        Write-Log "Azure Arc Setup ist bereits installiert. Keine Aktion erforderlich." "INFO"
        return
    }

    if ($PSCmdlet.ShouldProcess("System", "Install $ScriptKeyName")) {

        Write-Log "Installiere Azure Arc Setup Capability (PowerShell)..." "INFO"

        try {
            Add-WindowsCapability `
                -Online `
                -Name $CapabilityName `
                -ErrorAction Stop | Out-Null
        }
        catch {
            throw "Add-WindowsCapability fehlgeschlagen: $($_.Exception.Message)"
        }

        Write-Log "Azure Arc Setup wurde installiert." "OK"
    }
}
function Do-Update {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($PSCmdlet.ShouldProcess("System", "Update $ScriptKeyName")) {
        Write-Log "Update entspricht Reapply (Remove + Install)." "INFO"
        Do-Remove
        Do-Install
        Write-Log "Update abgeschlossen." "OK"
    }
}

function Do-Remove {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $cap = Get-AzureArcSetupCapability

    if ($cap.State -eq "NotPresent") {
        Write-Log "Azure Arc Setup ist bereits entfernt. Keine Aktion erforderlich." "INFO"
        return
    }

    if ($PSCmdlet.ShouldProcess("System", "Remove $ScriptKeyName")) {

        Write-Log "Entferne Azure Arc Setup Capability..." "INFO"

        try {
            Remove-WindowsCapability `
                -Name $CapabilityName `
                -Online `
                -ErrorAction Stop | Out-Null
        }
        catch {
            throw "Remove-WindowsCapability fehlgeschlagen: $($_.Exception.Message)"
        }

        Write-Log "Azure Arc Setup wurde entfernt." "OK"
    }
}

function Show-Menu {
    if (-not (Is-InteractiveSession)) {
        # In nicht-interaktiven Sessions nur Status ausgeben
        Get-Status
        return
    }

    while ($true) {
        Get-Status

        Write-Host "=== MENÜ ($ScriptKeyName) ===" -ForegroundColor Cyan
        Write-Host "1) Status anzeigen"
        Write-Host "2) Install / Repair"
        Write-Host "3) Update"
        Write-Host "4) Remove"
        Write-Host "5) Log anzeigen (letzte 40 Zeilen)"
        Write-Host "0) Beenden"
        Write-Host ""

        $choice = Read-Host "Auswahl"
        switch ($choice) {
            "1" { Get-Status; Pause-Continue }
            "2" { Do-Install; Get-Status; Pause-Continue }
            "3" { Do-Update;  Get-Status; Pause-Continue }
            "4" { Do-Remove;  Get-Status; Pause-Continue }
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
            "0" { Write-Log "=== Ende (User Exit) ===" "INFO"; break }
            default { Write-Host "Ungültige Auswahl." -ForegroundColor Yellow }
        }

        try { Clear-Host } catch {}
        if ($choice -eq "0") { break }
    }
}

# -----------------------------
# Region: Main
# -----------------------------
Set-CodepageUtf8
Assert-Admin

Write-Log "=== Start | Script=$ScriptKeyName | Action=$Action | Force=$Force | WhatIf=$WhatIfPreference | Verbose=$($PSBoundParameters.ContainsKey('Verbose')) | NonInteractive=$NonInteractive ===" "INFO"

try {
    if ($NonInteractive -and $Action -eq "menu") {
        # Bei Automatisierung ist menu nicht sinnvoll – fallback status
        $Action = "status"
    }

    switch ($Action) {
        "status"  { Get-Status; exit 0 }
        "install" { Do-Install; Get-Status; exit 0 }
        "update"  { Do-Update;  Get-Status; exit 0 }
        "remove"  { Do-Remove;  Get-Status; exit 0 }
        "menu"    { Show-Menu;  exit 0 }
        default   { Write-Log "Ungültige Action: $Action" "ERROR"; exit 2 }
    }
}
catch {
    Write-Log ("Fehler: {0}" -f $_.Exception.Message) "ERROR"
    exit 1
}
finally {
    Write-Log "=== Ende ===" "INFO"
}