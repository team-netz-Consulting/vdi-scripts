#requires -version 5.1
<#
    .SYNOPSIS
        Windows Server / VDI / RDS – Generic Store/AppX/MSIX Provisioning
        Zentrale Bereitstellung (Provisioning) inkl. Status / Install / Update / Remove

        Dieses Skript ist ein generischer Provisioning-Wrapper für AppX/MSIX/MSIXBUNDLE Pakete.
        Es ist kompatibel zum Orchestrator (src/run.ps1) und unterstützt NonInteractive,
        Logging, WhatIf/Verbose und einheitliche ExitCodes.

    .DESCRIPTION
        provisioning-storeapp.ps1 provisioniert eine Store-/AppX-/MSIX-Anwendung zentral (Online Image),
        optional inkl. Abhängigkeiten (Dependencies).

        Die Paketdateien können entweder:
        1) direkt als Parameter übergeben werden (AppPackagePath / DependencyPackagePaths)
        2) aus der config (settings.json) gelesen werden, wenn ActionKey angegeben wird
           und der entsprechende Item-Block eine storeApp.packages Struktur enthält.

        Standard-Ablage der Pakete ist unterhalb von:
            <scriptRoot>/packages/<id>/

        Das Skript eignet sich für:
        - Offline-Installationen
        - AppX/MSIX-Provisioning
        - Golden Image Build / RDS / VDI

    .EXAMPLE
        # Install mit Parametern
        .\provisioning-storeapp.ps1 -Action install -NonInteractive `
          -DisplayName Microsoft.WindowsCalculator `
          -AppPackagePath "C:\...\WindowsCalculator.msixbundle" `
          -DependencyPackagePaths "C:\...\Microsoft.VCLibs.x64.14.00.Desktop.appx"

    .EXAMPLE
        # Install über Config Item (ActionKey)
        .\provisioning-storeapp.ps1 -Action install -NonInteractive -ActionKey "Calculator.CalcInstall"

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.0
        Created on:    07.02.2026
        Last Modified: 07.02.2026

    .REQUIREMENTS
        - PowerShell 5.1 or newer
        - Administrative permissions
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigDir,
    [string]$LogDir,

    # status | install | update | remove | menu
    [ValidateSet("status","install","update","remove","menu")]
    [string]$Action = "menu",

    [switch]$NonInteractive,
    [switch]$Force,

    # --- Option 1: Direkte Übergabe ---
    [string]$DisplayName,
    [string]$AppPackagePath,
    [string[]]$DependencyPackagePaths,

    # --- Option 2: Automatisch über settings.json ---
    # Vollqualifizierter Key wie "Calculator.CalcInstall"
    [string]$ActionKey
)

try {
    chcp 65001 | Out-Null
    [Console]::InputEncoding  = [Text.Encoding]::UTF8
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding           = [Text.Encoding]::UTF8
} catch {}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# Defaults wie im Orchestrator
if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot "..\..\config" }
if (-not $LogDir)    { $LogDir    = Join-Path $ConfigDir "logs" }
Ensure-Dir $ConfigDir
Ensure-Dir $LogDir

# Logfile pro Tag
$LogFile = Join-Path $LogDir ("storeapp-provisioning-{0}.log" -f (Get-Date -Format "yyyyMMdd"))

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

function Resolve-RepoRoots {
    # settings.json liegt in $ConfigDir
    $settingsFile = Join-Path $ConfigDir "settings.json"
    if (-not (Test-Path $settingsFile)) { throw "settings.json nicht gefunden: $settingsFile" }

    $settings = (Get-Content $settingsFile -Raw) | ConvertFrom-Json

    $scriptRootRel = $settings.scriptRoot
    if (-not $scriptRootRel) { $scriptRootRel = "src/scripts" }

    # configDir ist <repoRoot>\config, daher repoRoot = parent(configDir)
    $repoRoot = (Resolve-Path (Join-Path $ConfigDir "..")).Path
    $scriptRootPath = (Resolve-Path (Join-Path $repoRoot $scriptRootRel)).Path

    return @{
        Settings = $settings
        RepoRoot = $repoRoot
        ScriptRoot = $scriptRootPath
    }
}

function Load-From-ConfigByActionKey {
    param([Parameter(Mandatory)][string]$Key)

    $ctx = Resolve-RepoRoots
    $settings = $ctx.Settings
    $scriptRootPath = $ctx.ScriptRoot
    $repoRoot = $ctx.RepoRoot

    # ActionKey "Category.Item"
    $parts = $Key.Split('.', 2)
    if ($parts.Count -ne 2) { throw "Ungültiger ActionKey '$Key'. Erwartet: Category.Item" }

    $catKey = $parts[0]
    $itemKey = $parts[1]

    $cat = $settings.categories | Where-Object { $_.key -eq $catKey } | Select-Object -First 1
    if (-not $cat) { throw "Kategorie nicht gefunden: $catKey" }

    $item = $cat.items | Where-Object { $_.key -eq $itemKey } | Select-Object -First 1
    if (-not $item) { throw "Item nicht gefunden: $Key" }

    if (-not $item.storeApp) { throw "settings.json: Item '$Key' hat keinen 'storeApp' Block." }

    $sa = $item.storeApp

    if (-not $sa.displayName) { throw "settings.json: storeApp.displayName fehlt in '$Key'." }

    $depPaths = @()
    $appPath  = $null

    if ($sa.packages) {
        if ($sa.packages.dependencies) {
            foreach ($d in @($sa.packages.dependencies)) {
                if ($d.path) { $depPaths += (Resolve-Path (Join-Path $repoRoot $d.path)).Path }
            }
        }
        if ($sa.packages.app -and $sa.packages.app.path) {
            $appPath = (Resolve-Path (Join-Path $repoRoot $sa.packages.app.path)).Path
        }
    }

    return @{
        DisplayName = [string]$sa.displayName
        DependencyPackagePaths = $depPaths
        AppPackagePath = $appPath
        ScriptRoot = $scriptRootPath
        RawItem = $item
    }
}

function Get-ProvisionedPackage([string]$name) {
    try { Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $name } } catch { $null }
}

function Get-InstalledPackageAllUsers([string]$name) {
    try { Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue } catch { $null }
}

function Show-Status([string]$name, [string]$appPath, [string[]]$depPaths) {
    $prov = Get-ProvisionedPackage $name
    $inst = Get-InstalledPackageAllUsers $name

    Write-Host ""
    Write-Host "=== STATUS: $name (RDS/VDI zentral) ===" -ForegroundColor Cyan

    if ($prov) {
        Write-Host ("Provisioniert: JA | Version: {0} | PackageName: {1}" -f $prov.Version, $prov.PackageName) -ForegroundColor Green
    } else {
        Write-Host "Provisioniert: NEIN" -ForegroundColor Yellow
    }

    if ($inst) {
        $top = $inst | Sort-Object Version -Descending | Select-Object -First 1
        Write-Host ("Installiert (AllUsers): JA | Höchste Version: {0} | Publisher: {1}" -f $top.Version, $top.Publisher) -ForegroundColor Green
    } else {
        Write-Host "Installiert (AllUsers): (keine Treffer oder Abfrage nicht verfügbar)" -ForegroundColor DarkYellow
    }

    if ($appPath) {
        Write-Host ("AppPackage: {0} | Exists={1}" -f $appPath, (Test-Path $appPath))
    } else {
        Write-Host "AppPackage: (nicht gesetzt)" -ForegroundColor Yellow
    }

    if (@($depPaths).Count -gt 0) {
        Write-Host "Dependencies:"
        foreach ($p in $depPaths) {
            Write-Host (" - {0} | Exists={1}" -f $p, (Test-Path $p))
        }
    } else {
        Write-Host "Dependencies: (keine)" -ForegroundColor DarkYellow
    }

    Write-Host ("Log: {0}" -f $LogFile)
    Write-Host ""
}

function Provision-StoreApp {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$AppPath,
        [string[]]$DepPaths,
        [switch]$ForceReprovision
    )

    if (-not (Test-Path $AppPath)) { throw "AppPackage nicht gefunden: $AppPath" }

    if ($DepPaths) {
        foreach ($dp in $DepPaths) {
            if (-not (Test-Path $dp)) { throw "Dependency-Paket nicht gefunden: $dp" }
        }
    }

    $prov = Get-ProvisionedPackage $Name

    if ($prov -and -not $ForceReprovision) {
        Write-Log "Bereits provisioniert (Version $($prov.Version)). Kein Install notwendig." "OK"
        return
    }

    if ($ForceReprovision -and $prov) {
        if ($PSCmdlet.ShouldProcess($prov.PackageName, "Remove existing provisioning")) {
            Write-Log "ForceReprovision: Entferne bestehendes Provisioning ($($prov.PackageName))..." "WARN"
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            Write-Log "Provisioning entfernt." "OK"
        }
    }

    # Dependencies zuerst
    if (@($DepPaths).Count -gt 0) {
        foreach ($dp in $DepPaths) {
            try {
                if ($PSCmdlet.ShouldProcess("Online Image", "Add provisioned dependency: $([IO.Path]::GetFileName($dp))")) {
                    Write-Log "Provisioniere Abhängigkeit: $dp" "INFO"
                    Add-AppxProvisionedPackage -Online -PackagePath $dp -SkipLicense -ErrorAction Stop | Out-Null
                    Write-Log "Dependency provisioniert: $([IO.Path]::GetFileName($dp))" "OK"
                }
            } catch {
                Write-Log "Dependency Provisioning: $($_.Exception.Message)" "WARN"
            }
        }
    }

    # App
    if ($PSCmdlet.ShouldProcess("Online Image", "Add provisioned package: $Name")) {
        Write-Log "Provisioniere App: $Name | PackagePath=$AppPath" "INFO"
        Add-AppxProvisionedPackage -Online -PackagePath $AppPath -SkipLicense -ErrorAction Stop | Out-Null
        Write-Log "App provisioniert: $Name" "OK"
        Write-Log "Hinweis: Neue Benutzerprofile erhalten die App automatisch. Bestehende User: einmal ab-/anmelden." "OK"
    }
}

function Remove-StoreAppProvisioning {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Name)

    $prov = Get-ProvisionedPackage $Name
    if (-not $prov) {
        Write-Log "Kein Provisioning gefunden - nichts zu entfernen." "WARN"
        return
    }

    if ($PSCmdlet.ShouldProcess($prov.PackageName, "Remove provisioned package")) {
        Write-Log "Entferne Provisioning ($($prov.PackageName))..." "INFO"
        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
        Write-Log "Provisioning entfernt." "OK"
        Write-Log "Hinweis: Falls die App bereits in Benutzerprofilen installiert war, kann sie dort weiterhin vorhanden sein." "WARN"
    }
}

function Pause-Continue {
    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "Enter drücken zum Fortfahren" | Out-Null
    }
}

function Is-InteractiveSession {
    if ($NonInteractive) { return $false }
    try { return [Environment]::UserInteractive } catch { return $true }
}

# -----------------------------
# MAIN
# -----------------------------
Assert-Admin
Write-Log "=== Start | Action=$Action | Force=$Force | WhatIf=$WhatIfPreference | Verbose=$($PSBoundParameters.ContainsKey('Verbose')) | NonInteractive=$NonInteractive | ActionKey=$ActionKey ===" "INFO"

try {
    # NonInteractive: menu ist sinnlos
    if ($NonInteractive -and $Action -eq "menu") { $Action = "status" }

    # Falls keine direkten Parameter: aus Config laden
    if (-not $DisplayName -and $ActionKey) {
        $cfg = Load-From-ConfigByActionKey -Key $ActionKey
        $DisplayName = $cfg.DisplayName
        if (-not $DependencyPackagePaths) { $DependencyPackagePaths = $cfg.DependencyPackagePaths }
        if (-not $AppPackagePath) { $AppPackagePath = $cfg.AppPackagePath }
    }

    if (-not $DisplayName) { throw "DisplayName fehlt. Nutze -DisplayName oder -ActionKey (Config storeApp.displayName)." }

    switch ($Action) {
        "status" {
            Show-Status -name $DisplayName -appPath $AppPackagePath -depPaths $DependencyPackagePaths
            exit 0
        }

        "install" {
            if (-not $AppPackagePath) { throw "AppPackagePath fehlt. (Config storeApp.packages.app.path oder Parameter -AppPackagePath)" }
            if ($Force) { Provision-StoreApp -Name $DisplayName -AppPath $AppPackagePath -DepPaths $DependencyPackagePaths -ForceReprovision }
            else        { Provision-StoreApp -Name $DisplayName -AppPath $AppPackagePath -DepPaths $DependencyPackagePaths }
            Show-Status -name $DisplayName -appPath $AppPackagePath -depPaths $DependencyPackagePaths
            exit 0
        }

        "update" {
            if (-not $AppPackagePath) { throw "AppPackagePath fehlt. (Config storeApp.packages.app.path oder Parameter -AppPackagePath)" }
            Provision-StoreApp -Name $DisplayName -AppPath $AppPackagePath -DepPaths $DependencyPackagePaths -ForceReprovision
            Show-Status -name $DisplayName -appPath $AppPackagePath -depPaths $DependencyPackagePaths
            exit 0
        }

        "remove" {
            Remove-StoreAppProvisioning -Name $DisplayName
            Show-Status -name $DisplayName -appPath $AppPackagePath -depPaths $DependencyPackagePaths
            exit 0
        }

        "menu" {
            if (-not (Is-InteractiveSession)) {
                Show-Status -name $DisplayName -appPath $AppPackagePath -depPaths $DependencyPackagePaths
                exit 0
            }

            while ($true) {
                Show-Status -name $DisplayName -appPath $AppPackagePath -depPaths $DependencyPackagePaths

                Write-Host "=== MENÜ ===" -ForegroundColor Cyan
                Write-Host "1) Status anzeigen"
                Write-Host "2) Install / Repair"
                Write-Host "3) Update (Reprovision)"
                Write-Host "4) Remove (Provisioning entfernen)"
                Write-Host "5) Log anzeigen (letzte 40 Zeilen)"
                Write-Host "0) Beenden"
                Write-Host ""

                $choice = Read-Host "Auswahl"
                switch ($choice) {
                    "1" { Show-Status -name $DisplayName -appPath $AppPackagePath -depPaths $DependencyPackagePaths; Pause-Continue }
                    "2" { if ($Force) { Provision-StoreApp -Name $DisplayName -AppPath $AppPackagePath -DepPaths $DependencyPackagePaths -ForceReprovision } else { Provision-StoreApp -Name $DisplayName -AppPath $AppPackagePath -DepPaths $DependencyPackagePaths }; Pause-Continue }
                    "3" { Provision-StoreApp -Name $DisplayName -AppPath $AppPackagePath -DepPaths $DependencyPackagePaths -ForceReprovision; Pause-Continue }
                    "4" { Remove-StoreAppProvisioning -Name $DisplayName; Pause-Continue }
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
                    "0" { Write-Log "=== Ende (User Exit) ===" "INFO"; exit 0 }
                    default { Write-Host "Ungültige Auswahl." -ForegroundColor Yellow }
                }

                try { Clear-Host } catch {}
            }
        }
    }
}
catch {
    Write-Log "Fehler: $($_.Exception.Message)" "ERROR"
    exit 1
}
finally {
    Write-Log "=== Ende ===" "INFO"
}
