# src\run.ps1
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$LogDir,

    # Action Key aus settings.json
    [string]$Action,

    # Option 7: Non-Interactive/Verbose/Force/WhatIf
    [switch]$NonInteractive,
    [switch]$Force
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
# JSON mit optionalen Kommentaren (// ... und /* ... */) tolerant einlesen
$jsonRaw = Get-Content $settingsFile -Raw

# Block-Kommentare entfernen: /* ... */
$jsonRaw = [regex]::Replace($jsonRaw, '/\*.*?\*/', '', 'Singleline')

# Zeilen-Kommentare entfernen: // ...
$jsonRaw = [regex]::Replace($jsonRaw, '^\s*//.*$', '', 'Multiline')

# Trailing commas entfernen (optional, falls vorhanden)
$jsonRaw = [regex]::Replace($jsonRaw, ',(\s*[}\]])', '$1')

$settings = $jsonRaw | ConvertFrom-Json


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
    $list = @(
        "-ConfigDir", $ConfigDir,
        "-LogDir", $LogDir
    )

    if ($Force) { $list += "-Force" }
    if ($NonInteractive) { $list += "-NonInteractive"; $list += "-Confirm:$false" }

    # Common Parameter korrekt “durchreichen”
    if ($PSBoundParameters.ContainsKey('Verbose')) { $list += "-Verbose" }
    if ($WhatIfPreference) { $list += "-WhatIf" }

    return $list
}


function Run-Action([string]$key) {
    if (-not $actionMap.ContainsKey($key)) { throw "Unbekannte Aktion: $key" }

    $a = $actionMap[$key]
    $scriptPath = Resolve-ScriptPath $a.script
    if (-not (Test-Path $scriptPath)) { throw "Script nicht gefunden: $scriptPath" }

    $common = Build-CommonArgs
    $extra  = @()
    if ($a.args) { $extra = @($a.args) }

    # Argumente als echtes Array (wichtig für Pfade mit Leerzeichen)
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath
    ) + $common + $extra

    # Debug-Ausgabe (hilft beim Nachvollziehen)
    $pretty = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    Write-Host "Starte Action '$key' -> $scriptPath"
    Write-Host "CMD: powershell.exe $pretty"

    # Direkt ausführen: Output/Fehler sichtbar, ExitCode über $LASTEXITCODE
    & powershell.exe @argList
    $code = $LASTEXITCODE

    if ($code -ne 0) { Write-Warning "Action '$key' ExitCode=$code" }
    return $code
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
