#requires -version 5.1
<#
    .SYNOPSIS
        Windows Photo Viewer – Enable/Disable (VDI/RDS Subscript)

        Aktiviert oder deaktiviert die klassische Windows Photoanzeige
        über Registry-Anpassungen (maschinenweit).

    .DESCRIPTION
        Dieses Skript integriert die Windows Photo Viewer Aktivierung
        in das standardisierte VDI/RDS Subscript-Framework.

        Funktionen:
        - Aktivieren des Windows Photo Viewers (Registry Restore)
        - Entfernen der Registrierung (Cleanup)
        - Statusprüfung
        - Reapply (Update)

        Unterstützt:
        - NonInteractive (Automation / Orchestrator)
        - Logging
        - WhatIf / Verbose
        - Einheitliche ExitCodes

        Hinweis:
        Das Skript setzt KEINE Default-App-Zuordnung für Benutzer.
        Dies muss separat (GPO / DISM / XML) erfolgen.

    .EXAMPLE
        # Aktivieren (Automation)
        .\windowsphotoviewer.ps1 -Action install -NonInteractive -Force -Verbose

    .EXAMPLE
        # Status prüfen
        .\windowsphotoviewer.ps1 -Action status -NonInteractive

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.1
        Created on:    07.02.2026
        Last Modified: 01.04.2026

    .CHANGELOG
        Version 1.1 - 01.04.2026
        - Implementierung Windows Photo Viewer Enable/Disable
        - Registry Handling integriert

        Version 1.0 - 07.02.2026
        - Initial template created

    .REQUIREMENTS
        - PowerShell 5.1 or newer
        - Administrative permissions
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigDir,
    [string]$LogDir,

    [ValidateSet("status","install","update","remove","menu")]
    [string]$Action = "menu",

    [switch]$NonInteractive,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Region: Script-spezifische Config
# -----------------------------
$ScriptKeyName = "WindowsPhotoViewer"
$WorkSubDir    = "packages\$ScriptKeyName"

$RegBase = "HKLM:\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations"

$FileTypes = @(
    ".jpg",".jpeg",".png",".bmp",".gif",".tif",".tiff",".ico",".jfif"
)

# -----------------------------
# Region: Path-Setup
# -----------------------------
function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot "..\..\config" }
if (-not $LogDir)    { $LogDir    = Join-Path $ConfigDir "logs" }

Ensure-Dir $ConfigDir
Ensure-Dir $LogDir

$BasePath = Join-Path $ConfigDir $WorkSubDir
Ensure-Dir $BasePath

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

# -----------------------------
# Region: Domain Functions
# -----------------------------
function Get-Status {
    Write-Host ""
    Write-Host "=== STATUS: $ScriptKeyName ===" -ForegroundColor Cyan
    Write-Host ("Arbeitsordner: {0}" -f $BasePath)
    Write-Host ("Log:          {0}" -f $LogFile)

    if (Test-Path $RegBase) {
        Write-Host "Status: AKTIVIERT" -ForegroundColor Green
    } else {
        Write-Host "Status: DEAKTIVIERT" -ForegroundColor Yellow
    }
}

function Do-Install {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($Force) {
        Write-Log "Force aktiv → Reapply wird durchgeführt." "WARN"
    }

    if ($PSCmdlet.ShouldProcess("Registry", "Enable Windows Photo Viewer")) {

        Write-Log "Aktiviere Windows Photo Viewer..." "INFO"

        New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows Photo Viewer" -Force | Out-Null
        New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities" -Force | Out-Null
        New-Item -Path $RegBase -Force | Out-Null

        foreach ($ext in $FileTypes) {
            New-ItemProperty -Path $RegBase -Name $ext -Value "PhotoViewer.FileAssoc.Tiff" -PropertyType String -Force | Out-Null
        }

        New-ItemProperty `
            -Path "HKLM:\SOFTWARE\RegisteredApplications" `
            -Name "Windows Photo Viewer" `
            -Value "SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities" `
            -PropertyType String `
            -Force | Out-Null

        Write-Log "Windows Photo Viewer aktiviert." "OK"
    }
}

function Do-Update {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($PSCmdlet.ShouldProcess("System", "Update $ScriptKeyName")) {
        Write-Log "Reapply wird ausgeführt..." "INFO"
        Do-Install
        Write-Log "Update abgeschlossen." "OK"
    }
}

function Do-Remove {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($PSCmdlet.ShouldProcess("Registry", "Disable Windows Photo Viewer")) {

        Write-Log "Deaktiviere Windows Photo Viewer..." "INFO"

        Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows Photo Viewer" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "Windows Photo Viewer" -ErrorAction SilentlyContinue

        Write-Log "Windows Photo Viewer deaktiviert." "OK"
    }
}

function Show-Menu {
    if (-not (Is-InteractiveSession)) {
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
        Write-Host "5) Log anzeigen"
        Write-Host "0) Beenden"

        $choice = Read-Host "Auswahl"
        switch ($choice) {
            "1" { Get-Status; Pause-Continue }
            "2" { Do-Install; Pause-Continue }
            "3" { Do-Update;  Pause-Continue }
            "4" { Do-Remove;  Pause-Continue }
            "5" { Get-Content $LogFile -Tail 40; Pause-Continue }
            "0" { break }
        }
        Clear-Host
    }
}

# -----------------------------
# Region: Main
# -----------------------------
Set-CodepageUtf8
Assert-Admin

Write-Log "Start: $ScriptKeyName | Action=$Action" "INFO"

try {
    if ($NonInteractive -and $Action -eq "menu") { $Action = "status" }

    switch ($Action) {
        "status"  { Get-Status; exit 0 }
        "install" { Do-Install; exit 0 }
        "update"  { Do-Update;  exit 0 }
        "remove"  { Do-Remove;  exit 0 }
        "menu"    { Show-Menu;  exit 0 }
        default   { Write-Log "Ungültige Action" "ERROR"; exit 2 }
    }
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 1
}
finally {
    Write-Log "Ende" "INFO"
}