# src\run.ps1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$ConfigDir,
    [string]$LogDir,

    # Vollqualifizierter Action-Key: "Category.Item"
    [string]$Action,

    [switch]$NonInteractive,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# Defaults, falls nicht vom Bootstrapper übergeben
if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot "..\config" }
if (-not $LogDir)    { $LogDir    = Join-Path $ConfigDir "logs" }
Ensure-Dir $ConfigDir
Ensure-Dir $LogDir

$settingsFile = Join-Path $ConfigDir "settings.json"
if (-not (Test-Path $settingsFile)) { throw "settings.json nicht gefunden: $settingsFile" }

# JSON laden (ohne Kommentare!)
$settings = (Get-Content $settingsFile -Raw) | ConvertFrom-Json

# scriptRoot bestimmen
$scriptRootRel = $settings.scriptRoot
if (-not $scriptRootRel) { $scriptRootRel = "src/scripts" }

# InstallRoot ermitteln (run.ps1 liegt unter ...\src)
$installRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path  # ...\vdi-scripts
$scriptRoot  = (Resolve-Path (Join-Path $installRoot $scriptRootRel)).Path

function Resolve-ScriptPath([string]$scriptValue) {
    # wenn Pfad Trenner vorhanden, relativ zu InstallRoot
    if ($scriptValue -match '[\\/]' ) {
        $p = Join-Path $installRoot $scriptValue
        return (Resolve-Path $p).Path
    }
    $p2 = Join-Path $scriptRoot $scriptValue
    return (Resolve-Path $p2).Path
}

function Build-CommonArgs {
    $list = @(
        "-ConfigDir", $ConfigDir,
        "-LogDir", $LogDir
    )

    if ($Force) { $list += "-Force" }
    if ($NonInteractive) {
        $list += "-NonInteractive"
        $list += "-Confirm:$false"
    }

    # Common Parameters korrekt durchreichen
    if ($PSBoundParameters.ContainsKey('Verbose')) { $list += "-Verbose" }
    if ($WhatIfPreference) { $list += "-WhatIf" }

    return $list
}

function Script-SupportsActionKeyParam {
    param([Parameter(Mandatory)][string]$ScriptPath)

    try {
        # Lightweight Check: suchen nach "ActionKey" im param()-Block
        $txt = Get-Content -Path $ScriptPath -Raw -ErrorAction Stop
        if ($txt -match '(?is)\bparam\s*\(.*?\bActionKey\b') { return $true }
        return $false
    } catch {
        # Wenn nicht prüfbar: lieber nichts injizieren
        return $false
    }
}

# Actions-Lookup aufbauen: "Category.Item" -> actionObject
$actionMap = @{}
$categories = @()

if ($settings.categories) {
    foreach ($cat in $settings.categories) {
        if (-not $cat.key) { continue }
        $categories += $cat

        if ($cat.items) {
            foreach ($it in $cat.items) {
                if (-not $it.key -or -not $it.script) { continue }
                $fullKey = "{0}.{1}" -f $cat.key, $it.key
                $actionMap[$fullKey] = $it | Add-Member -NotePropertyName "__categoryKey" -NotePropertyValue $cat.key -PassThru
            }
        }
    }
} else {
    throw "settings.json: 'categories' fehlt."
}

function Run-ActionByKey([string]$fullKey) {
    if (-not $actionMap.ContainsKey($fullKey)) { throw "Unbekannte Action: $fullKey" }

    $a = $actionMap[$fullKey]
    $scriptPath = Resolve-ScriptPath $a.script
    if (-not (Test-Path $scriptPath)) { throw "Script nicht gefunden: $scriptPath" }

    $common = Build-CommonArgs
    $extra  = @()
    if ($a.args) { $extra = @($a.args) }

    # NEW: ActionKey automatisch mitsenden, aber nur wenn Script es unterstützt
    $injectActionKey = Script-SupportsActionKeyParam -ScriptPath $scriptPath
    if ($injectActionKey) {
        $common += @("-ActionKey", $fullKey)
    }

    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath
    ) + $common + $extra

    $pretty = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    Write-Host "Starte Action '$fullKey' -> $scriptPath"
    Write-Host "CMD: powershell.exe $pretty"

<#     & powershell.exe @argList
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Warning "Action '$fullKey' ExitCode=$code" }
    return $code #>
    # Subprozess im gleichen Fenster ausführen (Output zuverlässig sichtbar)

    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -NoNewWindow -Wait -PassThru
    $code = $p.ExitCode
    if ($code -ne 0) { Write-Warning "Action '$fullKey' ExitCode=$code" }
    return $code
}

function Show-Menu($title, $items) {
    Write-Host ""
    Write-Host $title -ForegroundColor Cyan

    for ($i=0; $i -lt $items.Count; $i++) {
        Write-Host ("[{0}] {1}" -f ($i+1), $items[$i].Display)
    }
    Write-Host "[Q] Zurück/Beenden"

    $sel = Read-Host "Nummer"
    if ($sel -match '^[Qq]') { return $null }

    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $items.Count) { return $items[$idx] }
    }

    Write-Host "Ungültige Auswahl." -ForegroundColor Yellow
    return $null
}

# Non-Interactive: wenn keine Action angegeben -> defaultAction
if ($NonInteractive -and -not $Action) {
    if ($settings.defaultAction) { $Action = $settings.defaultAction }
    else { throw "NonInteractive gesetzt, aber keine -Action und keine defaultAction in settings.json." }
}

if ($Action) {
    $code = Run-ActionByKey $Action
    exit $code
}

# ---------------------------
# Interaktives Hauptmenü
# ---------------------------

while ($true) {
    $catItems = @()
    foreach ($c in $categories) {
        $catItems += [pscustomobject]@{
            Key     = $c.key
            Display = $c.name
            Raw     = $c
        }
    }

    $pickedCat = Show-Menu "VDI Scripts - Auswahl" $catItems
    if (-not $pickedCat) { exit 0 }

    $cat = $pickedCat.Raw
    $subItems = @()

    foreach ($it in $cat.items) {
        if (-not $it.key) { continue }
        $fullKey = "{0}.{1}" -f $cat.key, $it.key

        $subItems += [pscustomobject]@{
            Key     = $fullKey
            Display = $it.name
        }
    }

    while ($true) {
        $pickedAction = Show-Menu ("{0} - Aktionen" -f $cat.name) $subItems
        if (-not $pickedAction) { break }

        $code = Run-ActionByKey $pickedAction.Key
        Read-Host "Press Enter to return" | Out-Null
    }
}
