# bootstrap\main.ps1
<#
.SYNOPSIS
  Bootstrapper: lädt/aktualisiert das Repo und startet das Entry-Skript.

USAGE:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1
#>

[CmdletBinding()]
param(
    [switch]$NoUpdate,
    [ValidateSet("BranchZip","Release")]
    [string]$UpdateMode = "BranchZip",
    [string]$Branch = "main",

    # Ziel: Program Files\TeamNetz\vdi-scripts
    [string]$InstallRoot = (Join-Path $env:ProgramFiles "TeamNetz\vdi-scripts"),

    [string]$EntryScript = "src\run.ps1"   # relativ zum InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
chcp 65001 | Out-Null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

# Repo-Informationen
$RepoOwner = "team-netz-Consulting"
$RepoName  = "vdi-scripts"

# Pfade
$CurrentDir = $InstallRoot
$ConfigDir  = Join-Path $CurrentDir "config"
$LogDir     = Join-Path $ConfigDir "logs"
$TempDir    = Join-Path $env:TEMP ("vdi-scripts-update-" + [guid]::NewGuid())

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Download-BranchZip {
    param([string]$BranchName)
    $zipUrl = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$BranchName.zip"
    $zipPath = Join-Path $TempDir "$RepoName-$BranchName.zip"
    Write-Verbose "Downloading $zipUrl -> $zipPath"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    return $zipPath
}

function Download-LatestReleaseZip {
    $apiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
    Write-Verbose "Querying releases: $apiUrl"
    $resp = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "PowerShell" }
    $tag = $resp.tag_name
    $zipUrl = $resp.zipball_url
    $zipPath = Join-Path $TempDir "$RepoName-$tag.zip"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -Headers @{ "User-Agent" = "PowerShell" }
    return @{ ZipPath = $zipPath; Version = $tag }
}

function Expand-ZipToStaging {
    param([string]$ZipPath)
    Ensure-Dir $TempDir
    $staging = Join-Path $TempDir "staging"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
    Ensure-Dir $staging
    Expand-Archive -Path $ZipPath -DestinationPath $staging -Force

    $root = Get-ChildItem $staging | Where-Object { $_.PSIsContainer } | Select-Object -First 1
    if (-not $root) { throw "ZIP staging root folder not found." }
    return $root.FullName
}

function Sync-Folder {
    param([string]$SourceDir, [string]$TargetDir)
    Ensure-Dir $TargetDir

    # Robocopy mirror (robust). /NFL /NDL to reduce output
    $robo = @($SourceDir, $TargetDir, "/MIR", "/R:1", "/W:1", "/NFL", "/NDL", "/NP", "/NJH", "/NJS")
    $rc = & robocopy @robo
    # robocopy gibt verschiedene ExitCodes; wir behandeln nur 1..7 als normal (siehe robocopy docs)
    return $LASTEXITCODE
}

function Update-Scripts {
    Ensure-Dir $CurrentDir
    Ensure-Dir $TempDir

    if ($UpdateMode -eq "Release") {
        $dl = Download-LatestReleaseZip
        $root = Expand-ZipToStaging -ZipPath $dl.ZipPath
        Sync-Folder -SourceDir $root -TargetDir $CurrentDir | Out-Null
        # Schreibe Version
        $dl.Version | Out-File -FilePath (Join-Path $CurrentDir "VERSION.txt") -Encoding UTF8
        return
    }

    $zip = Download-BranchZip -BranchName $Branch
    $root = Expand-ZipToStaging -ZipPath $zip
    Sync-Folder -SourceDir $root -TargetDir $CurrentDir | Out-Null
    (Get-Date -Format "yyyyMMdd-HHmmss") | Out-File -FilePath (Join-Path $CurrentDir "VERSION.txt") -Encoding UTF8
}

try {
    # Ensure base dirs
    Ensure-Dir $CurrentDir
    Ensure-Dir $ConfigDir
    Ensure-Dir $LogDir

    if (-not $NoUpdate) {
        Write-Host "Prüfe / führe Update durch..."
        Update-Scripts
    }
    else {
        Write-Host "Update übersprungen (NoUpdate)."
    }

    $entryPath = Join-Path $CurrentDir $EntryScript
    if (-not (Test-Path $entryPath)) {
        throw "Entry script nicht gefunden: $entryPath"
    }

    # Start Entry Script mit Übergabe der Config-/Log-Pfade
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $entryPath,
        "-ConfigDir", "`"$ConfigDir`"",
        "-LogDir", "`"$LogDir`""
    )
    Write-Host "Starte: powershell.exe $EntryScript"
    & powershell.exe @argList
}
catch {
    Write-Error "Fehler im Bootstrapper: $_"
    exit 1
}
finally {
    if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}
