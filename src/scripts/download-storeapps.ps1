<#
    .SYNOPSIS
        Windows Server / VDI / RDS – Download von Microsoft Store Apps via winget
        Zentrale Paketbeschaffung für Offline-Installation und Provisioning


        Dieses Skript dient als zentrales Download-Modul für Microsoft-Store-Apps.
        Es liest die zu ladenden Pakete aus der zentralen settings.json und speichert
        die Artefakte standardisiert unterhalb von <scriptRoot>/packages/<PackageId>/.

        Das Skript ist Orchestrator-kompatibel (src/run.ps1) und kann interaktiv oder
        non-interaktiv ausgeführt werden.

    .DESCRIPTION
        Das Skript download-storeapp.ps1 lädt Microsoft-Store-Applikationen mithilfe
        von winget (Source: msstore) lokal herunter, ohne sie zu installieren.

        Die zu ladenden Pakete werden in der Datei:
            ../../config/settings.json

        im Abschnitt "storePackages" definiert.

        Für jedes aktivierte Paket wird ein eigener Ordner erzeugt:
            <scriptRoot>/packages/<StorePackageId>/

        Der Download erfolgt reproduzierbar und eignet sich für:
        - Offline-Installationen
        - AppX/MSIX-Provisioning
        - Image-Build-Pipelines (Golden Image)
        - RDS / VDI / Server Core Szenarien

    .EXAMPLE
        # Alle in der settings.json aktivierten Store-Pakete herunterladen
        .\download-storeapps.ps1

    .EXAMPLE
        # Nur ein bestimmtes Store-Paket herunterladen
        .\download-storeapps.ps1 -Ids 9NKSQGP7F2NH

    .EXAMPLE
        # Zielordner vor dem Download bereinigen
        .\download-storeapps.ps1 -Clean

    .EXAMPLE
        # Fehler bei einem Paket ignorieren und mit dem nächsten fortfahren
        .\download-storeapps.ps1 -ContinueOnError

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.0
        Created on:    07.02.2026
        Last Modified: 07.02.2026

    .CHANGELOG
        Version 1.0 - 07.02.2026
        - Initial script created
        - Unterstützung für winget download (msstore)
        - Zentrale Steuerung über settings.json
        - Standardisierte Paketablage unter scriptRoot/packages/

    .REQUIREMENTS
        - PowerShell 5.1 or newer
        - winget (App Installer) >= 1.8
        - Internetzugang für den Download
        - Optional: Microsoft Store / Entra ID Authentifizierung
#>


[CmdletBinding()]
param(
    # Nur bestimmte IDs laden (wenn leer: alle enabled aus config)
    [string[]]$Ids,

    # Zielordner pro Paket vor Download leeren
    [switch]$Clean,

    # Wenn gesetzt: Fehler bei einem Paket bricht nicht alles ab
    [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR")][string]$Level = "INFO"
    )
    $prefix = switch ($Level) {
        "OK"    { "[+]" }
        "WARN"  { "[!]" }
        "ERROR" { "[x]" }
        default { "[i]" }
    }
    Write-Host "$prefix $Message"
}

function Get-ScriptRootPath {
    # robust, auch wenn über dot-sourcing oder anderen Host
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-WinGetVersion {
    try {
        $raw = & winget --version 2>$null
        $raw = $raw.Trim().TrimStart('v','V')
        return [version]$raw
    } catch {
        throw "winget ist nicht verfügbar. Stelle sicher, dass App Installer / WinGet installiert ist."
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Load-Config {
    param([Parameter(Mandatory)][string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        throw "Config nicht gefunden: $ConfigPath"
    }
    $json = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return $json
}

function Invoke-WinGetDownload {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DownloadDir
    )

    Ensure-Directory -Path $DownloadDir

    $args = @(
        "download",
        "--id", $Id,
        "--source", $Source,
        "--exact",
        "--download-directory", $DownloadDir,
        "--accept-source-agreements",
        "--accept-package-agreements"
    )

    # winget schreibt oft gemischt in stdout/stderr -> alles einsammeln
    $out = & winget @args 2>&1 | Out-String

    # Suche nach heruntergeladenen Artefakten (MSIX/APPX/Bundle)
    $files = Get-ChildItem -Path $DownloadDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(msix|msixbundle|appx|appxbundle)$' } |
        Sort-Object LastWriteTime -Descending

    if (-not $files) {
        $msg = @(
            "winget download hat keine MSIX/APPX-Dateien erzeugt.",
            "winget-Ausgabe:",
            $out.Trim()
        ) -join "`n"
        throw $msg
    }

    return $files
}

# ----------------- MAIN -----------------

$scriptDir = Get-ScriptRootPath
$configPath = Join-Path $scriptDir "..\..\config\settings.json"
$configPath = (Resolve-Path $configPath).Path

$config = Load-Config -ConfigPath $configPath

if (-not $config.scriptRoot) {
    throw "Config-Fehler: 'scriptRoot' fehlt."
}

# ScriptRoot in config ist relativ zum Repo-Root; wir leiten Repo-Root aus config location ab:
# config liegt in <repoRoot>\config\settings.json
$repoRoot = Split-Path -Parent (Split-Path -Parent $configPath)
$scriptRootPath = Join-Path $repoRoot $config.scriptRoot
$scriptRootPath = (Resolve-Path $scriptRootPath).Path

$packagesRoot = Join-Path $scriptRootPath "packages"
Ensure-Directory -Path $packagesRoot

# winget Mindestversion (download ist erst in neueren Versionen zuverlässig)
$min = [version]"1.8.0"
$ver = Get-WinGetVersion
if ($ver -lt $min) {
    throw "winget $ver ist zu alt. Bitte auf >= $min aktualisieren (App Installer)."
}

if (-not $config.storePackages) {
    Write-Log "Keine 'storePackages' in config gefunden - nichts zu tun." "WARN"
    exit 0
}

$pkgs = @($config.storePackages) | Where-Object { $_.enabled -ne $false }

if ($Ids -and $Ids.Count -gt 0) {
    $pkgs = $pkgs | Where-Object { $Ids -contains $_.id }
}

if (-not $pkgs -or $pkgs.Count -eq 0) {
    Write-Log "Keine passenden/enabled Store-Pakete gefunden." "WARN"
    exit 0
}

Write-Log "RepoRoot: $repoRoot" "INFO"
Write-Log "ScriptRoot (aus config): $scriptRootPath" "INFO"
Write-Log "PackagesRoot: $packagesRoot" "INFO"
Write-Log "winget version: $ver" "INFO"

$errors = @()

foreach ($p in $pkgs) {
    $id = [string]$p.id
    $name = if ($p.name) { [string]$p.name } else { $id }
    $source = if ($p.source) { [string]$p.source } else { "msstore" }

    $targetDir = Join-Path $packagesRoot $id
    try {
        Write-Log "Download: $name ($id) source=$source -> $targetDir" "INFO"

        if ($Clean -and (Test-Path $targetDir)) {
            Write-Log "Clean: Lösche vorhandene Dateien in $targetDir" "WARN"
            Get-ChildItem -Path $targetDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }

        $files = Invoke-WinGetDownload -Id $id -Source $source -DownloadDir $targetDir

        $fileList = $files | Select-Object -First 5 | ForEach-Object { $_.Name } | Sort-Object
        Write-Log "OK: Download abgeschlossen. Dateien: $($fileList -join ', ')" "OK"
    } catch {
        $msg = "FEHLER bei $name ($id): $($_.Exception.Message)"
        Write-Log $msg "ERROR"
        $errors += $msg
        if (-not $ContinueOnError) { break }
    }
}

if ($errors.Count -gt 0) {
    throw ("Ein oder mehrere Downloads sind fehlgeschlagen:`n- " + ($errors -join "`n- "))
}

Write-Log "Alle Downloads abgeschlossen." "OK"
