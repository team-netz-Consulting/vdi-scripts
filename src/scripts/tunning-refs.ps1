[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue' # Wichtig: Verhindert sofortigen Abbruch bei kleinerem Fehler

# ------------------------------------------------------------
# Konfiguration
# ------------------------------------------------------------

$BackupFolder = Join-Path $env:ProgramData 'RefsTuningTool'
$BackupFile   = Join-Path $BackupFolder 'registry-backup.json'

# Hier die gewünschten Zielwerte eintragen
$DesiredValues = @(
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        Name  = 'RefsEnableLargeWorkingSetTrim'
        Type  = 'DWord'
        Value = 1
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        Name  = 'RefsNumberOfChunksToTrim'
        Type  = 'DWord'
        Value = 4
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        Name  = 'RefsDisableCachedPins'
        Type  = 'DWord'
        Value = 1
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        Name  = 'RefsProcessedDeleteQueueEntryCountThreshold'
        Type  = 'DWord'
        Value = 2048
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        Name  = 'RefsEnableInlineTrim'
        Type  = 'DWord'
        Value = 1
    },
    @{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Disk'
        Name  = 'TimeOutValue'
        Type  = 'DWord'
        Value = 200
    },
    @{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Microsoft Data Protection Manager\Configuration\DiskStorage'
        Name  = 'DuplicateExtentBatchSizeinMB'
        Type  = 'DWord'
        Value = 64
    }
)

# ------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------

function Ensure-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Dieses Skript muss als Administrator ausgeführt werden.' -ForegroundColor Red
        Write-Host 'Bitte starten Sie PowerShell als Admin und laden Sie das Skript neu.' -ForegroundColor Yellow
        Read-Host 'ENTER drücken zum Beenden'
        exit 1
    }
    Write-Host 'Administrator-Rechte bestätigt.' -ForegroundColor Green
}

function Ensure-BackupFolder {
    try {
        if (-not (Test-Path $BackupFolder)) {
            Write-Host "Erstelle Verzeichnis: $BackupFolder" -ForegroundColor Cyan
            New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null
        }
    }
    catch {
        Write-Host "Fehler beim Erstellen des Backup-Verzeichnisses: $_" -ForegroundColor Red
        throw
    }
}

function Get-RegistryValueSafe {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $exists = Test-Path $Path
    if (-not $exists) {
        return [PSCustomObject]@{
            Path        = $Path
            Name        = $Name
            Exists      = $false
            ValueExists = $false
            Value       = $null
        }
    }

    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return [PSCustomObject]@{
            Path        = $Path
            Name        = $Name
            Exists      = $true
            ValueExists = $true
            Value       = $item.$Name
        }
    }
    catch {
        return [PSCustomObject]@{
            Path        = $Path
            Name        = $Name
            Exists      = $true
            ValueExists = $false
            Value       = $null
        }
    }
}

function Show-CurrentValues {
    Write-Host ''
    Write-Host 'Aktuelle Registry-Werte' -ForegroundColor Cyan
    Write-Host ('-' * 90)

    $rows = foreach ($entry in $DesiredValues) {
        $current = Get-RegistryValueSafe -Path $entry.Path -Name $entry.Name

        [PSCustomObject]@{
            Pfad         = $entry.Path
            Name         = $entry.Name
            Vorhanden    = if ($current.ValueExists) { 'Ja' } else { 'Nein' }
            AktuellerWert = if ($current.ValueExists) { $current.Value } else { '<nicht gesetzt>' }
            Zielwert     = $entry.Value
        }
    }

    $rows | Format-Table -AutoSize
    Write-Host ''
}

function Backup-CurrentValues {
    Ensure-BackupFolder # Nur Fehler abfangen, nicht throwen hier, um Script flow nicht zu blocken bei Schreibfehlern

    # Prüfen ob Backup-Datei existiert
    if (Test-Path $BackupFile) {
        Write-Host "Backup-Datei existiert bereits: $BackupFile" -ForegroundColor Yellow
        Write-Host 'Kein neues Backup erstellt.' -ForegroundColor Gray
        return
    }

    $backup = foreach ($entry in $DesiredValues) {
        $current = Get-RegistryValueSafe -Path $entry.Path -Name $entry.Name

        [PSCustomObject]@{
            Path        = $entry.Path
            Name        = $entry.Name
            ValueExists = $current.ValueExists
            Value       = $current.Value
        }
    }

    try {
        $jsonContent = $backup | ConvertTo-Json -Depth 5
        Set-Content -Path $BackupFile -Value $jsonContent -Encoding UTF8 -ErrorAction Stop
        Write-Host "Backup erfolgreich erstellt: $BackupFile" -ForegroundColor Green
    }
    catch {
        Write-Host "Fehler beim Speichern des Backup in $BackupFile: $_" -ForegroundColor Red
        throw
    }
}

function Set-RegistryValueSafe {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string]$Type,

        [Parameter(Mandatory)]
        $Value
    )

    # Key-Path prüfen
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    try {
        # Wert setzen
        New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
        
        # Debug-Check ob wirklich geschrieben wurde (manchmal sehr wichtig bei HKLM)
        # Wenn Write-Host hier nicht steht, ist der Fehler oft unsichtbar
        # Wir lassen den Fehler hier durch, damit das Hauptskript ihn fängt
        
        return $true
    }
    catch {
        # Fehler zurückgeben statt auszuwerfen
        return $false
    }
}

function Apply-DesiredValues {
    Write-Host ''
    Write-Host 'Setze gewünschte Werte ...' -ForegroundColor Cyan
    Write-Host 'Dies kann einige Sekunden dauern, wenn das Backup erstellt wird.'

    try {
        Backup-CurrentValues
    }
    catch {
        Write-Host 'Fehler während des Backups: $_' -ForegroundColor Red
        Write-Host 'Die Werte werden NICHT gesetzt.' -ForegroundColor Red
        return
    }

    $setCount = 0
    $failCount = 0

    foreach ($entry in $DesiredValues) {
        $success = Set-RegistryValueSafe -Path $entry.Path -Name $entry.Name -Type $entry.Type -Value $entry.Value

        if ($success) {
            Write-Host ("Gesetzt: {0} -> {1}\{2}" -f $entry.Value, $entry.Path, $entry.Name) -ForegroundColor Green
            $setCount++
        }
        else {
            # Fehlermeldung für den fehlgeschlagenen Eintrag
            Write-Host ("FEHLER: Konnte Wert {0} nicht setzen." -f $entry.Name) -ForegroundColor Red
            Write-Host "   Pfad: $Path" -ForegroundColor DarkYellow
            Write-Host "   Grund: Es gibt eine Berechtigung oder einen Schreibfehler." -ForegroundColor DarkYellow
            $failCount++
        }
    }

    Write-Host ''
    Write-Host 'Zusammenfassung:' -ForegroundColor Cyan
    Write-Host '   Erfolgreich: {0} Werte' -ForegroundColor Green -f $setCount
    if ($failCount -gt 0) {
        Write-Host '   Fehlerhaft: {0} Werte' -ForegroundColor Red -f $failCount
    }
    Write-Host 'Ein Neustart wird empfohlen, aber NICHT automatisch ausgeführt.' -ForegroundColor Yellow
    Write-Host ''
}

function Restore-FromBackup {
    Write-Host ''

    if (-not (Test-Path $BackupFile)) {
        Write-Host "Keine Backup-Datei gefunden: $BackupFile" -ForegroundColor Red
        Write-Host 'Rückgängig machen ist daher nicht möglich.' -ForegroundColor Red
        Write-Host ''
        return
    }

    try {
        Write-Host 'Stelle Werte aus dem Backup wieder her ...' -ForegroundColor Cyan

        $backupEntries = Get-Content -Path $BackupFile -Raw | ConvertFrom-Json

        foreach ($entry in $backupEntries) {
            if ($entry.ValueExists -eq $true) {
                if (-not (Test-Path $entry.Path)) {
                    New-Item -Path $entry.Path -Force | Out-Null
                }

                $type = 'DWord'
                $originalDesired = $DesiredValues | Where-Object { $_.Path -eq $entry.Path -and $_.Name -eq $entry.Name } | Select-Object -First 1
                if ($null -ne $originalDesired) {
                    $type = $originalDesired.Type
                }

                New-ItemProperty -Path $entry.Path -Name $entry.Name -PropertyType $type -Value $entry.Value -Force | Out-Null
                Write-Host ("Wiederhergestellt: {0} -> {1}\{2}" -f $entry.Value, $entry.Path, $entry.Name) -ForegroundColor Green
            }
            else {
                if (Test-Path $entry.Path) {
                    try {
                        Remove-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction Stop
                        Write-Host ("Entfernt: {0}\{1}" -f $entry.Path, $entry.Name) -ForegroundColor Yellow
                    }
                    catch {
                        Write-Host ("Konnte nicht entfernen: {0}\{1}" -f $entry.Path, $entry.Name) -ForegroundColor Red
                    }
                }
            }
        }

        Write-Host ''
        Write-Host 'Die ursprünglichen Werte wurden aus dem Backup wiederhergestellt.' -ForegroundColor Green
        Write-Host 'Ein Neustart wird empfohlen, aber NICHT automatisch ausgeführt.' -ForegroundColor Yellow
        Write-Host ''
    }
    catch {
        Write-Host "Fehler bei der Wiederherstellung: $_" -ForegroundColor Red
    }
}

function Show-TargetValues {
    # Fix für das Ausblendungsproblem
    Write-Host ''
    Write-Host 'Konfigurierte Zielwerte' -ForegroundColor Cyan
    Write-Host ('-' * 90) -ForegroundColor Gray
    Write-Host ''

    if ($DesiredValues.Count -eq 0) {
        Write-Host 'Keine Zielwerte konfiguriert!' -ForegroundColor Red
        return
    }

    # Explizite Ausgabe der Tabelle
    $DesiredValues | Format-Table -AutoSize -Wrap | Out-String | Write-Host

    Write-Host ''
}

function Pause-Menu {
    Read-Host 'ENTER drücken, um zum Menü zurückzukehren'
}

function Show-Menu {
    Clear-Host
    Write-Host '==============================================='
    Write-Host ' ReFS / Disk / DPM Registry Tool'
    Write-Host '==============================================='
    Write-Host '1 - Aktuelle Werte anzeigen'
    Write-Host '2 - Konfigurierte Zielwerte anzeigen'
    Write-Host '3 - Werte setzen'
    Write-Host '4 - Änderungen rückgängig machen'
    Write-Host '5 - Backup-Datei anzeigen'
    Write-Host '0 - Beenden'
    Write-Host '==============================================='
    Write-Host ''
}

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------

Ensure-Admin

do {
    Show-Menu
    $choice = Read-Host 'Bitte Auswahl eingeben'

    switch ($choice) {
        '1' {
            Show-CurrentValues
            Pause-Menu
        }
        '2' {
            Show-TargetValues
            Pause-Menu
        }
        '3' {
            Apply-DesiredValues
            Pause-Menu
        }
        '4' {
            Restore-FromBackup
            Pause-Menu
        }
        '5' {
            Write-Host ''
            Write-Host "Backup-Datei: $BackupFile" -ForegroundColor Cyan
            if (Test-Path $BackupFile) {
                Get-Content -Path $BackupFile
            }
            else {
                Write-Host 'Noch keine Backup-Datei vorhanden.' -ForegroundColor Yellow
            }
            Write-Host ''
            Pause-Menu
        }
        '0' {
            Write-Host ''
            Write-Host 'Skript beendet.'
            Write-Host ''
        }
        default {
            Write-Host ''
            Write-Host 'Ungültige Auswahl.' -ForegroundColor Red
            Write-Host ''
            Pause-Menu
        }
    }
}
while ($choice -ne '0')