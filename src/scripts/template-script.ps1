#requires -version 5.1
<#
    .SYNOPSIS
        TEMPLATE – VDI/RDS Subscript (Standard-Gerüst)

        Dieses Skript dient als Vorlage für Automatisierungs-Skripte in VDI-/RDS-Umgebungen.
        Es ist kompatibel zum Orchestrator (src/run.ps1) und unterstützt NonInteractive,
        Logging, WhatIf/Verbose und einheitliche ExitCodes.

    .DESCRIPTION
        Dieses Template bildet das gemeinsame Grundgerüst für alle Sub-Skripte in diesem Repository.

        Enthaltene Bausteine:
        1. Standardparameter (ConfigDir/LogDir/Action/NonInteractive/Force/WhatIf/Verbose)
        2. Zentralisiertes Logging (config/logs)
        3. Admin-Check
        4. Strukturierte Actions: status/install/update/remove/menu
        5. SupportsShouldProcess für -WhatIf
        6. Einheitliche ExitCodes (0 OK, 1 Fehler, 2 ungültige Action)
        7. Optionaler interaktiver Menümodus

        Das eigentliche „Fach-Handling“ (Install/Update/Remove) wird in den jeweiligen
        Funktionen implementiert.

    .EXAMPLE
        # Non-Interactive Install
        .\template-subscript.ps1 -Action install -NonInteractive -Force -Verbose

    .EXAMPLE
        # Nur Status ausgeben
        .\template-subscript.ps1 -Action status -NonInteractive

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.0
        Created on:    07.02.2026
        Last Modified: 07.02.2026

    .CHANGELOG
        Version 1.0 - 07.02.2026
        - Initial template created (Orchestrator-compatible skeleton)

    .REQUIREMENTS
        - PowerShell 5.1 or newer
        - Administrative permissions (für systemweite Änderungen)
        - Optional: BITS / Internetzugang (je nach Use-Case)
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
# TODO: Script-spezifische Namen/URLs/IDs hier definieren
$ScriptKeyName = "TEMPLATE"
$WorkSubDir    = "packages\$ScriptKeyName"  # wird unter config\packages\... angelegt

# Optional: feste Download-URIs etc.
# $DownloadUri = "https://example.com/file.msi"
# $OutFileName = "example.msi"

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

# -----------------------------
# Region: Domain Functions (TODO)
# -----------------------------
function Get-Status {
    <#
      TODO: Rückgabe / Ausgabe eines Status (z.B. Version, installed/provisioned etc.)
      Empfehlung:
      - gebe rein informativ aus (keine Änderungen)
    #>
    Write-Host ""
    Write-Host "=== STATUS: $ScriptKeyName ===" -ForegroundColor Cyan
    Write-Host ("Arbeitsordner: {0}" -f $BasePath)
    Write-Host ("Log:          {0}" -f $LogFile)
    Write-Host ""
}

function Do-Install {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    <#
      TODO: Installation / Repair implementieren
      - Nutze $Force für „reinstall/reprovision/repair erzwingen“
      - Nutze ShouldProcess für Änderungen (damit -WhatIf sinnvoll ist)
    #>

    if ($Force) {
        Write-Log "Force ist gesetzt: Install wird als Repair/Reinstall ausgeführt." "WARN"
    }

    if ($PSCmdlet.ShouldProcess("System", "Install $ScriptKeyName")) {
        Write-Log "TODO: Implementiere Installationslogik." "INFO"
        # Beispiel:
        # Download-File -Uri $DownloadUri -OutFile (Join-Path $BasePath $OutFileName)
        # Start-Process msiexec.exe -ArgumentList "/i ... /qn" -Wait
        Write-Log "Install (Template) abgeschlossen." "OK"
    }
}

function Do-Update {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    <#
      TODO: Update implementieren (häufig: Download neu + reinstall/reprovision)
    #>

    if ($PSCmdlet.ShouldProcess("System", "Update $ScriptKeyName")) {
        Write-Log "TODO: Implementiere Update-Logik." "INFO"
        Write-Log "Update (Template) abgeschlossen." "OK"
    }
}

function Do-Remove {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    <#
      TODO: Entfernen/Cleanup implementieren
    #>

    if ($PSCmdlet.ShouldProcess("System", "Remove $ScriptKeyName")) {
        Write-Log "TODO: Implementiere Remove-Logik." "INFO"
        Write-Log "Remove (Template) abgeschlossen." "OK"
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
