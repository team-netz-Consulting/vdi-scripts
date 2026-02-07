# src\run.ps1
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$LogDir,

    # Action Key aus settings.json
    [string]$Action,

    # Option 7: Non-Interactive/Verbose/Force/WhatIf
    [switch]$NonInteractive,
    [switch]$Force,
    [switch]$WhatIf,
    [switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# Default-Pfade, falls nicht vom Bootstrapper übergeben
if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot "..\config" }
if (-not $LogDir)    { $LogDir    = Join-Path $ConfigDir "logs" }

Ensure-Dir $ConfigDir
Ensure-Dir $LogDir

$settingsFile = Join-Path $ConfigDir "settings.json"
if (-not (Test-Path $settingsFile)) {
    throw "settings.json nicht gefunden: $settingsFile"
}

# JSON laden
$settings = Get-Content $settingsFile -Raw | ConvertFrom-Json

# scriptRoot bestimmen
$scriptRootRel = $settings.scriptRoot
if (-not $scriptRootRel) { $scriptRootRel = "src/scripts" }

# Absoluter Pfad zu scriptRoot
# run.ps1 liegt in ...\src\run.ps1; InstallRoot ist zwei Ebenen höher als scriptsRootRel, kann aber auch direkt relativ funktionieren.
$installRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
$scriptRoot = Resolve-Path (Join-Path $installRoot "..\$scriptRootRel") -ErrorAction SilentlyContinue
if (-not $scriptRoot) {
    # fallback: relativ zu InstallRoot (also Parent von src)
    $installRoot2 = Resolve-Path (Join-Path $PSScriptRoot "..\..") | Select-Object -ExpandProperty Path
    $scriptRoot = Resolve-Path (Join-Path $installRoot2 $scriptRootRel)
}
$scriptRoot = $scriptRoot.Path

# Actions aus config
if (-not $settings.actions) { throw "settings.json: 'actions' fehlt." }

# In eine Lookup-Tabelle: key -> actionObject
$actionMap = @{}
foreach ($a in $settings.actions) {
    if (-not $a.key -or -not $a.script) { continue }
    $actionMap[$a.key] = $a
}

function Resolve-ScriptPath([string]$scriptValue) {
    # Wenn scriptValue bereits ein Pfad mit \ oder / enthält, behandeln wir ihn als relativ zum InstallRoot
    if ($scriptValue -match '[\\/]' ) {
        $p = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path $scriptValue
        return (Resolve-Path $p).Path
    }
    # sonst relativ zu scriptRoot
    $p2 = Join-Path $scriptRoot $scriptValue
    return (Resolve-Path $p2).Path
}

function Build-CommonArgs {
    # Option 7: Standard-Parameter, die wir an Unter-Skripte weiterreichen
    # Voraussetzung: Unter-Skripte akzeptieren diese Parameter (oder du ignorierst unbekannte mit param(...) / [CmdletBinding()] + $PSBoundParameters)
    $list = @(
        "-ConfigDir", $ConfigDir,
        "-LogDir", $LogDir
    )

    if ($Force)      { $list += "-Force" }
    if ($WhatIf)     { $list += "-WhatIf" }
    if ($Verbose)    { $list += "-Verbose" }
    if ($NonInteractive) {
        $list += "-NonInteractive"
        # Optional: viele Cmdlets respektieren -Confirm:$false, wenn Script mit SupportsShouldProcess arbeitet
        $list += "-Confirm:$false"
    }

    return $list
}

function Run-Action([string]$key) {
    if (-not $actionMap.ContainsKey($key)) { throw "Unbekannte Aktion: $key" }

    $a = $actionMap[$key]
    $scriptPath = Resolve-ScriptPath $a.script

    if (-not (Test-Path $scriptPath)) { throw "Script nicht gefunden: $scriptPath" }

    $common = Build-CommonArgs

    # Zusätzliche Args aus config
    $extra = @()
    if ($a.args) { $extra = @($a.args) }

    # Start in eigener PowerShell, damit ExitCodes sauber sind
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath
    ) + $common + $extra

    Write-Host "Starte Action '$key' -> $scriptPath"
    if ($extra.Count -gt 0) { Write-Host ("Extra args: " + ($extra -join " ")) }

    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Wait -PassThru
    return $p.ExitCode
}

# Non-Interactive: Wenn keine Action angegeben, versuche defaultAction
if ($NonInteractive -and -not $Action) {
    if ($settings.defaultAction) { $Action = $settings.defaultAction }
    else { throw "NonInteractive gesetzt, aber keine -Action und keine defaultAction in settings.json." }
}

if ($Action) {
    $code = Run-Action $Action
    exit $code
}

# Interaktives Menü
Write-Host "VDI Scripts - Auswahl" -ForegroundColor Cyan

$keys = @($actionMap.Keys) | Sort-Object
for ($i = 0; $i -lt $keys.Count; $i++) {
    $k = $keys[$i]
    $name = $actionMap[$k].name
    if (-not $name) { $name = $k }
    Write-Host ("[{0}] {1} ({2})" -f ($i+1), $name, $k)
}
Write-Host "[Q] Beenden"

$sel = Read-Host "Nummer oder Key"
if ($sel -match '^[Qq]') { exit 0 }

if ($sel -match '^\d+$') {
    $idx = [int]$sel - 1
    if ($idx -ge 0 -and $idx -lt $keys.Count) {
        $Action = $keys[$idx]
    } else {
        Write-Host "Ungültige Auswahl."
        exit 0
    }
} else {
    $Action = $sel
}

$code = Run-Action $Action
exit $code
