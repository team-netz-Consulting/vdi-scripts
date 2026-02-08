#requires -version 5.1
<#
    .SYNOPSIS
        Ermittelt Download-URLs für Microsoft Store APPX/MSIX Pakete.

    .DESCRIPTION
        Dieses Skript nutzt den inoffiziellen Store-Endpunkt (rg-adguard),
        um direkte Download-URLs für APPX/MSIX/MSIXBUNDLE-Pakete zu ermitteln.

        Es lädt **keine Dateien herunter**, sondern:
        - gibt URLs in der Konsole aus
        - schreibt URLs ins Logfile
        - optional: Export in eine Textdatei

        Optimiert als Sub-Skript für den VDI/RDS Orchestrator.

    .EXAMPLE
        get-appx-url.ps1 -StoreUrl "https://apps.microsoft.com/detail/9wzdncrfhvn5" -NonInteractive

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.0
        Created on:    07.02.2026

    .REQUIREMENTS
        - PowerShell 5.1+
        - Internetzugang
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Orchestrator Standard
    [string]$ConfigDir,
    [string]$LogDir,

    # Store URL oder ID
    [Parameter(Mandatory)]
    [string]$StoreUrl,

    # Optionaler Export
    [string]$ExportFile,

    # Option 7
    [switch]$NonInteractive,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Region: Config
# ------------------------------------------------------------
$ScriptKeyName = "GET-APPX-URL"

# ------------------------------------------------------------
# Region: Paths
# ------------------------------------------------------------
function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot "..\..\config" }
if (-not $LogDir)    { $LogDir    = Join-Path $ConfigDir "logs" }

Ensure-Dir $ConfigDir
Ensure-Dir $LogDir

$BasePath = Join-Path $ConfigDir "tools\get-appx-url"
Ensure-Dir $BasePath

if (-not $ExportFile) {
    $ExportFile = Join-Path $BasePath ("appx-urls-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

$LogFile = Join-Path $LogDir ("get-appx-url-{0}.log" -f (Get-Date -Format "yyyyMMdd"))

# ------------------------------------------------------------
# Region: Helper
# ------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","OK")][string]$Level="INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    $line | Tee-Object -FilePath $LogFile -Append | Out-Host
}

function Enable-Tls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

# ------------------------------------------------------------
# Region: Core Function
# ------------------------------------------------------------
function Get-AppxDownloadUrls {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Uri
    )

    Enable-Tls12

    Write-Log "Ermittle APPX/MSIX URLs für: $Uri"

    if (-not $PSCmdlet.ShouldProcess($Uri, "Query Store download URLs")) {
        return @()
    }

    $arch = $env:PROCESSOR_ARCHITECTURE.Replace("AMD","X").Replace("IA","X")

    $response = Invoke-WebRequest `
        -UseBasicParsing `
        -Method POST `
        -Uri "https://store.rg-adguard.net/api/GetFiles" `
        -Body "type=url&url=$Uri&ring=Retail" `
        -ContentType "application/x-www-form-urlencoded"

    $links = $response.Links |
        Where-Object {
            $_ -match '\.(appx|appxbundle|msix|msixbundle)' -and
            ($_ -match '_neutral_' -or $_ -match "_${arch}_")
        } |
        Select-String -Pattern '(?<=a href=").+(?=" r)' |
        ForEach-Object { $_.Matches.Value } |
        Sort-Object -Unique

    return $links
}

function Download-AppxPackage {
[CmdletBinding()]
param (
  [string]$Uri,
  [string]$Path = "."
)
   
  process {
    $Path = (Resolve-Path $Path).Path
    #Get Urls to download
    $WebResponse = Invoke-WebRequest -UseBasicParsing -Method 'POST' -Uri 'https://store.rg-adguard.net/api/GetFiles' -Body "type=url&url=$Uri&ring=Retail" -ContentType 'application/x-www-form-urlencoded'
    $LinksMatch = $WebResponse.Links | where {$_ -like '*.appx*' -or $_ -like '*.appxbundle*' -or $_ -like '*.msix*' -or $_ -like '*.msixbundle*'} | where {$_ -like '*_neutral_*' -or $_ -like "*_"+$env:PROCESSOR_ARCHITECTURE.Replace("AMD","X").Replace("IA","X")+"_*"} | Select-String -Pattern '(?<=a href=").+(?=" r)'
    $DownloadLinks = $LinksMatch.matches.value 

    function Resolve-NameConflict{
    #Accepts Path to a FILE and changes it so there are no name conflicts
    param(
    [string]$Path
    )
        $newPath = $Path
        if(Test-Path $Path){
            $i = 0;
            $item = (Get-Item $Path)
            while(Test-Path $newPath){
                $i += 1;
                $newPath = Join-Path $item.DirectoryName ($item.BaseName+"($i)"+$item.Extension)
            }
        }
        return $newPath
    }
    #Download Urls
    foreach($url in $DownloadLinks){
        Write-Host $url
    }
  }
}

# ------------------------------------------------------------
# Region: Main
# ------------------------------------------------------------
Write-Log "=== Start | Script=$ScriptKeyName | StoreUrl=$StoreUrl ==="

try {

    Download-AppxPackage -Uri "https://apps.microsoft.com/detail/9wzdncrfhvn5"
  <#   $urls = Get-AppxDownloadUrls -Uri $StoreUrl

    if (-not $urls -or $urls.Count -eq 0) {
        Write-Log "Keine Download-URLs gefunden." "WARN"
        exit 0
    }

    Write-Host ""
    Write-Host "=== GEFUNDENE DOWNLOAD-URLS ===" -ForegroundColor Cyan

    foreach ($url in $urls) {
        Write-Host $url
        Write-Log $url
    }

    if ($ExportFile) {
        $urls | Out-File -FilePath $ExportFile -Encoding UTF8 -Force
        Write-Log "URLs exportiert nach: $ExportFile" "OK"
    } #>

    exit 0
}
catch {
    Write-Log ("Fehler: {0}" -f $_.Exception.Message) "ERROR"
    exit 1
}
finally {
    Write-Log "=== Ende ===" "INFO"
}
