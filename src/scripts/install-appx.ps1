<# 
Windows Server 2025 RDS – Windows Calculator (Microsoft.WindowsCalculator)
Zentrale Bereitstellung (Provisioning) inkl. Menü: Status / Install / Update / Remove

Hinweise:
- Als Administrator ausführen
- Desktop Experience erforderlich
- Provisioning wirkt automatisch für NEUE Benutzerprofile; bestehende User müssen i.d.R. einmal ab-/anmelden
#>

#region Config
$AppDisplayName = "Microsoft.WindowsCalculator"
$BasePath       = "C:\Support\Appx\Calculator"
$CalcUri        = "http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/ea3bc611-fa15-49e6-b10a-23b0769c6a7e?P1=1770402309&P2=404&P3=2&P4=lHkpsZpZ5VI7Ns4yL2cZklgTQvou9GSaK26rJOc2Sy%2fbhSoPxN3CG85gMGQ3zyQlcM5RrPm8WXu2MqYeWmw9YA%3d%3d"
$VCLibsUri      = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"

$CalcFile       = Join-Path $BasePath "WindowsCalculator.msixbundle"
$VCLibsFile     = Join-Path $BasePath "Microsoft.VCLibs.x64.appx"
$LogFile        = Join-Path $BasePath "install.log"
#endregion Config

#region Helpers

function set-codepage {
    # --- Console & Script Encoding ---
    chcp 65001 | Out-Null
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
}
function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR","OK")] [string]$Level="INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    $line | Tee-Object -FilePath $LogFile -Append | Out-Host
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Dieses Skript muss als Administrator ausgeführt werden." -ForegroundColor Red
        exit 1
    }
}

function Ensure-Folder {
    if (-not (Test-Path $BasePath)) {
        New-Item -ItemType Directory -Path $BasePath -Force | Out-Null
    }
    if (-not (Test-Path $LogFile)) {
        New-Item -ItemType File -Path $LogFile -Force | Out-Null
    }
}

function Enable-Tls {
    try {
        # TLS 1.2 erzwingen (Server-Umgebungen)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Enable-Tls

    # Erst BITS (robust), fallback Invoke-WebRequest
    try {
        Write-Log "Download (BITS): $Uri -> $OutFile"
        Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
        return
    } catch {
        Write-Log "BITS fehlgeschlagen, fallback zu Invoke-WebRequest. Details: $($_.Exception.Message)" "WARN"
    }

    try {
        Write-Log "Download (IWR): $Uri -> $OutFile"
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "Download fehlgeschlagen: $Uri | $($_.Exception.Message)"
    }
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
<#         $FileRequest = Invoke-WebRequest -Uri $url -UseBasicParsing #-Method Head
        $FileName = ($FileRequest.Headers["Content-Disposition"] | Select-String -Pattern  '(?<=filename=).+').matches.value
        $FilePath = Join-Path $Path $FileName; $FilePath = Resolve-NameConflict($FilePath)
        [System.IO.File]::WriteAllBytes($FilePath, $FileRequest.content)
        echo $FilePath #>
        Write-Log $url
    }
  }
}
function Download-WingetApp {
    param(
        [Parameter(Mandatory)]
        [string]$AppId,                 # z.B. 9WZDNCRFHVN5

        [Parameter(Mandatory)]
        [string]$OutFile,        # z.B. C:\Support\Appx\Calculator

        [string]$Source = "msstore"
    )

   
    Write-Log "winget download gestartet (AppId=$AppId)..." "INFO"

    # --- winget prüfen ---
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget ist nicht verfügbar."
    }

    # --- Zielordner sicherstellen ---
    $destDir = Split-Path $OutFile -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # --- Downloadverzeichnis (temporär) ---
    $tempDir = Join-Path $env:TEMP "winget_$($AppId)"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    # --- winget download ---
    $args = @(
        "download",
        "--id", $AppId,
        "--source", "msstore",
        "--download-directory", $tempDir,
        "--accept-source-agreements",
        "--accept-package-agreements"
    )

    $proc = Start-Process -FilePath $winget.Source `
                          -ArgumentList $args `
                          -NoNewWindow `
                          -Wait `
                          -PassThru

    if ($proc.ExitCode -ne 0) {
        throw "winget download fehlgeschlagen (ExitCode=$($proc.ExitCode))."
    }

    # --- Paketdatei finden ---
    $package = Get-ChildItem -Path $tempDir -Recurse `
        -Include *.msixbundle,*.appxbundle,*.msix,*.appx `
        | Sort-Object LastWriteTime -Descending `
        | Select-Object -First 1

    if (-not $package) {
        throw "winget-Download erfolgreich, aber keine MSIX/APPX-Datei gefunden."
    }

    # --- Ziel ersetzen ---
    Copy-Item -Path $package.FullName -Destination $OutFile -Force

    Write-Log "winget-Download erfolgreich: $OutFile" "OK"

    # --- Cleanup ---
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}


function Get-ProvisionedCalc {
    try {
        return Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $AppDisplayName }
    } catch {
        return $null
    }
}

function Get-InstalledCalcForAnyUser {
    # zeigt, ob irgendwo (irgendein User) das Paket installiert ist (optional Info)
    try {
        return Get-AppxPackage -AllUsers -Name $AppDisplayName -ErrorAction SilentlyContinue
    } catch {
        return $null
    }
}

function Show-Status {
    Write-Host ""
    Write-Host "=== STATUS: Windows Calculator (RDS zentral) ===" -ForegroundColor Cyan

    $prov = Get-ProvisionedCalc
    $inst = Get-InstalledCalcForAnyUser

    if ($prov) {
        Write-Host ("Provisioniert: JA  | Version: {0} | PackageName: {1}" -f $prov.Version, $prov.PackageName) -ForegroundColor Green
    } else {
        Write-Host "Provisioniert: NEIN" -ForegroundColor Yellow
    }

    if ($inst) {
        # Es können mehrere Einträge vorkommen; zeige die höchste Version
        $top = $inst | Sort-Object Version -Descending | Select-Object -First 1
        Write-Host ("Installiert (AllUsers): JA | Höchste Version: {0} | Publisher: {1}" -f $top.Version, $top.Publisher) -ForegroundColor Green
    } else {
        Write-Host "Installiert (AllUsers): (keine Treffer oder Abfrage nicht verfügbar)" -ForegroundColor DarkYellow
    }

    Write-Host ("Downloadpfad: {0}" -f $BasePath)

    $f1 = Test-Path $CalcFile
    $f2 = Test-Path $VCLibsFile
    Write-Host ("Vorhandene Dateien: CalculatorBundle={0}, VCLibs={1}" -f $f1, $f2)

    if ($f1) { Write-Host (" - {0} ({1:N1} MB)" -f $CalcFile, ((Get-Item $CalcFile).Length/1MB)) }
    if ($f2) { Write-Host (" - {0} ({1:N1} MB)" -f $VCLibsFile, ((Get-Item $VCLibsFile).Length/1MB)) }

    Write-Host ("Log: {0}" -f $LogFile)
    Write-Host ""
}

function Provision-Calc {
    param(
        [switch]$ForceReprovision
    )

    Ensure-Folder

    $prov = Get-ProvisionedCalc
    if ($prov -and -not $ForceReprovision) {
        Write-Log "Bereits provisioniert (Version $($prov.Version)). Kein Install notwendig." "OK"
        return
    }

    if ($ForceReprovision -and $prov) {
        Write-Log "ForceReprovision: Entferne bestehendes Provisioning ($($prov.PackageName))..." "WARN"
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            Write-Log "Provisioning entfernt." "OK"
        } catch {
            throw "Konnte Provisioning nicht entfernen: $($_.Exception.Message)"
        }
    }

    # Download (immer frisch, damit Update wirklich zieht)
    try {
        Download-File -Uri $VCLibsUri -OutFile $VCLibsFile
        Download-File -Uri $CalcUri   -OutFile $CalcFile
        #Download-WingetApp -AppId "9WZDNCRFHVN5" -OutFile $CalcFile
        #Download-AppxPackage -Uri "https://apps.microsoft.com/detail/9wzdncrfhvn5" -Path $BasePath
    } catch {
        Write-Log $_ "ERROR"
        throw
    }

    # Provisioning
    try {
        Write-Log "Provisioniere Abhängigkeit (VCLibs)..." "INFO"
        Add-AppxProvisionedPackage -Online -PackagePath $VCLibsFile -SkipLicense -ErrorAction Stop | Out-Null
        Write-Log "VCLibs provisioniert." "OK"
    } catch {
        # Wenn schon da, ist das nicht zwingend fatal – aber wir loggen und machen weiter nur wenn es "already exists" ist.
        Write-Log "VCLibs Provisioning: $($_.Exception.Message)" "WARN"
    }

    try {
        Write-Log "Provisioniere Windows Calculator..." "INFO"
        Add-AppxProvisionedPackage -Online -PackagePath $CalcFile -SkipLicense -ErrorAction Stop | Out-Null
        Write-Log "Windows Calculator provisioniert." "OK"
    } catch {
        Write-Log "Calculator Provisioning fehlgeschlagen: $($_.Exception.Message)" "ERROR"
        throw
    }

    Write-Log "Fertig. Neue Benutzerprofile erhalten den Rechner automatisch. Bestehende User: einmal ab-/anmelden." "OK"
}

function Remove-CalcProvisioning {
    $prov = Get-ProvisionedCalc
    if (-not $prov) {
            Write-Log "Kein Provisioning gefunden - nichts zu entfernen" "WARN"
        return
    }

    Write-Log "Entferne Provisioning ($($prov.PackageName))..." "INFO"
    try {
        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
        Write-Log "Provisioning entfernt." "OK"
        Write-Log "Hinweis: Falls der Calculator bereits in Benutzerprofilen installiert war, kann er dort weiterhin vorhanden sein." "WARN"
    } catch {
        Write-Log "Entfernen fehlgeschlagen: $($_.Exception.Message)" "ERROR"
        throw
    } 
}

function Pause-Continue {
    Write-Host ""
    Read-Host "Enter drücken zum Fortfahren"
}
#endregion Helpers

#region Main
set-codepage

Assert-Admin
Ensure-Folder
Write-Log "=== Start ===" "INFO"

# Beim Start direkt Status anzeigen
Show-Status

while ($true) {
    Write-Host "=== MENÜ ===" -ForegroundColor Cyan
    Write-Host "1) Status anzeigen"
    Write-Host "2) Install / Repair (wenn fehlt, provisionieren)"
    Write-Host "3) Update (neu herunterladen + reprovisionieren)"
    Write-Host "4) Remove (Provisioning entfernen)"
    Write-Host "5) Log anzeigen (letzte 40 Zeilen)"
    Write-Host "0) Beenden"
    Write-Host ""

    $choice = Read-Host "Auswahl"
    switch ($choice) {
        "1" {
            Show-Status
            Pause-Continue
        }
        "2" {
            try {
                Provision-Calc
            } catch {
                Write-Host $_ -ForegroundColor Red
            }
            Show-Status
            Pause-Continue
        }
        "3" {
            try {
                Provision-Calc -ForceReprovision
            } catch {
                Write-Host $_ -ForegroundColor Red
            }
            Show-Status
            Pause-Continue
        }
        "4" {
            try {
                Remove-CalcProvisioning
            } catch {
                Write-Host $_ -ForegroundColor Red
            }
            Show-Status
            Pause-Continue
        }
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
        "0" {
            Write-Log "=== Ende (User Exit) ===" "INFO"
            exit
        }
        default {
            Write-Host "Ungültige Auswahl." -ForegroundColor Yellow
        }
    }

    Clear-Host
    Show-Status
}
#endregion Main
