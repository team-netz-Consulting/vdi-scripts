#requires -version 5.1
<#
    .SYNOPSIS
        VDI Server 2025 Tunning – Startmenü Prelaunch Fix für Windows Server 2025 RDSH/VDI

        Dieses Skript setzt/verwaltet den Microsoft-dokumentierten Registry-Fix gegen
        verzögertes erstes Öffnen des Startmenüs in Windows Server 2025 Remote Desktop
        Session Host / VDI-Umgebungen.

    .DESCRIPTION
        Windows Server 2025 startet StartMenuExperienceHost.exe, SearchHost.exe und
        ähnliche Startmenü-/Suchprozesse standardmäßig nicht mehr direkt beim Benutzer-Logon.
        Dadurch kann das erste Öffnen des Startmenüs in RDSH-/VDI-Sessions mehrere Sekunden
        verzögert sein.

        Der Fix setzt:
            HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StartMenu
            PrelaunchOverride = 1 (REG_DWORD)

        Wirkung:
            0 / nicht vorhanden = neues Standardverhalten, Prelaunch deaktiviert
            1                 = vorheriges Verhalten, Prelaunch beim Benutzer-Logon aktiviert

        Hinweis:
            Microsoft empfiehlt die Änderung nur, wenn Benutzer tatsächlich eine spürbare
            Verzögerung beim ersten Öffnen des Startmenüs bemerken. Bei vielen gleichzeitigen
            Logons kann Prelaunch höhere CPU-Last und längere Anmeldezeiten verursachen.

        Enthaltene Bausteine:
        1. Standardparameter (ConfigDir/LogDir/Action/NonInteractive/Force/WhatIf/Verbose)
        2. Zentralisiertes Logging (config/logs)
        3. Admin-Check
        4. Strukturierte Actions: status/install/update/remove/menu
        5. SupportsShouldProcess für -WhatIf
        6. Einheitliche ExitCodes (0 OK, 1 Fehler, 2 ungültige Action)
        7. Optionaler interaktiver Menümodus

    .EXAMPLE
        .\vdi-server2025-tunning.ps1 -Action install -NonInteractive -Force -Verbose

    .EXAMPLE
        .\vdi-server2025-tunning.ps1 -Action status -NonInteractive

    .EXAMPLE
        .\vdi-server2025-tunning.ps1 -Action remove -WhatIf

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.0
        Created on:    30.04.2026
        Last Modified: 30.04.2026

    .CHANGELOG
        Version 1.0 - 30.04.2026
        - Initial version for Windows Server 2025 Start menu PrelaunchOverride tuning

    .REQUIREMENTS
        - PowerShell 5.1 or newer
        - Administrative permissions
        - Windows Server 2025 RDSH/VDI empfohlen; Registry-Wert wird technisch auch auf
          anderen Windows-Versionen gesetzt, sofern -Force oder manuelle Ausführung erfolgt.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Wird vom Orchestrator übergeben
    [string]$ConfigDir,
    [string]$LogDir,

    # Einheitlicher Action-Mechanismus:
    # status  = nur Status ausgeben
    # install = Registry-Fix setzen / reparieren
    # update  = Registry-Fix erneut setzen
    # remove  = Registry-Fix entfernen / Default wiederherstellen
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
$ScriptKeyName = "VDI-SERVER2025-TUNNING"
$WorkSubDir    = "packages\$ScriptKeyName"

$RegPath       = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StartMenu"
$RegName       = "PrelaunchOverride"
$RegType       = "DWord"
$DesiredValue  = 1

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

function Get-OsInfoSafe {
    try {
        return Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-PrelaunchOverrideState {
    $exists = Test-Path $RegPath
    $valueExists = $false
    $value = $null

    if ($exists) {
        try {
            $props = Get-ItemProperty -Path $RegPath -ErrorAction Stop
            if ($null -ne $props.PSObject.Properties[$RegName]) {
                $valueExists = $true
                $value = [int]($props.$RegName)
            }
        } catch {
            Write-Log "Registry-Status konnte nicht vollständig gelesen werden: $($_.Exception.Message)" "WARN"
        }
    }

    [pscustomobject]@{
        RegistryPath = $RegPath
        Name         = $RegName
        PathExists   = $exists
        ValueExists  = $valueExists
        Value        = $value
        IsCompliant  = ($valueExists -and $value -eq $DesiredValue)
    }
}

function Test-IsLikelyServer2025 {
    $os = Get-OsInfoSafe
    if ($null -eq $os) { return $false }

    # Windows Server 2025 ist Build 26100.x. Caption ist je nach Sprache/Edition unterschiedlich.
    $caption = [string]$os.Caption
    $build   = 0
    [void][int]::TryParse([string]$os.BuildNumber, [ref]$build)

    return (($caption -match "Server") -and ($caption -match "2025" -or $build -ge 26100))
}

# -----------------------------
# Region: Domain Functions
# -----------------------------
function Get-Status {
    $state = Get-PrelaunchOverrideState
    $os = Get-OsInfoSafe

    Write-Host ""
    Write-Host "=== STATUS: $ScriptKeyName ===" -ForegroundColor Cyan
    Write-Host ("Arbeitsordner: {0}" -f $BasePath)
    Write-Host ("Log:          {0}" -f $LogFile)
    Write-Host ("Registry:     {0}" -f $RegPath)
    Write-Host ("Wert:         {0}" -f $RegName)

    if ($null -ne $os) {
        Write-Host ("OS:           {0} | Build {1}" -f $os.Caption, $os.BuildNumber)
    }

    if (-not $state.PathExists) {
        Write-Host "Status:       Registry-Pfad fehlt; Fix ist nicht gesetzt." -ForegroundColor Yellow
    } elseif (-not $state.ValueExists) {
        Write-Host "Status:       Registry-Wert fehlt; Windows-Default aktiv." -ForegroundColor Yellow
    } elseif ($state.IsCompliant) {
        Write-Host ("Status:       OK - {0}={1}" -f $RegName, $state.Value) -ForegroundColor Green
    } else {
        Write-Host ("Status:       Abweichend - {0}={1}, erwartet={2}" -f $RegName, $state.Value, $DesiredValue) -ForegroundColor Yellow
    }

    Write-Host ""
}

function Do-Install {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (-not (Test-IsLikelyServer2025) -and -not $Force) {
        Write-Log "Dieses System wirkt nicht wie Windows Server 2025. Mit -Force kann der Fix trotzdem gesetzt werden." "WARN"
    }

    $state = Get-PrelaunchOverrideState
    if ($state.IsCompliant -and -not $Force) {
        Write-Log "Registry-Fix ist bereits gesetzt: $RegPath\$RegName=$DesiredValue" "OK"
        return
    }

    if ($Force) {
        Write-Log "Force ist gesetzt: Registry-Fix wird erneut gesetzt." "WARN"
    }

    if ($PSCmdlet.ShouldProcess("$RegPath\$RegName", "Set REG_DWORD $DesiredValue")) {
        if (-not (Test-Path $RegPath)) {
            Write-Log "Erstelle Registry-Pfad: $RegPath" "INFO"
            New-Item -Path $RegPath -Force | Out-Null
        }

        Write-Log "Setze Registry-Wert: $RegPath\$RegName=$DesiredValue ($RegType)" "INFO"
        New-ItemProperty -Path $RegPath -Name $RegName -Value $DesiredValue -PropertyType $RegType -Force | Out-Null
        Write-Log "Windows Server 2025 Startmenü PrelaunchOverride wurde aktiviert." "OK"
    }
}

function Do-Update {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($PSCmdlet.ShouldProcess("$RegPath\$RegName", "Update/Reapply REG_DWORD $DesiredValue")) {
        Do-Install
        Write-Log "Update/Reapply abgeschlossen." "OK"
    }
}

function Do-Remove {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $state = Get-PrelaunchOverrideState
    if (-not $state.ValueExists) {
        Write-Log "Registry-Wert ist nicht vorhanden; keine Änderung erforderlich." "OK"
        return
    }

    if ($PSCmdlet.ShouldProcess("$RegPath\$RegName", "Remove registry value and restore Windows default behavior")) {
        Remove-ItemProperty -Path $RegPath -Name $RegName -Force -ErrorAction Stop
        Write-Log "Registry-Wert entfernt. Windows-Default ist wieder aktiv." "OK"
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
        Write-Host "2) Install / Repair - PrelaunchOverride aktivieren"
        Write-Host "3) Update - Fix erneut setzen"
        Write-Host "4) Remove - PrelaunchOverride entfernen"
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
