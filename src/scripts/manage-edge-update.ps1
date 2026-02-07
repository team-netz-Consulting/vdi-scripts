<#
.SYNOPSIS
    Edge Update Manager – findet Microsoft Edge/Update-Komponenten und kann sie per Umbenennen deaktivieren/aktivieren.

.DESCRIPTION
    Dieses Skript durchsucht vordefinierte Verzeichnisse nach Update-Executables (z. B. "update", "elevation_service")
    und bietet ein Menü zum:
      1) Beenden laufender Update-Prozesse (sofern erkannt)
      2) Deaktivieren durch Umbenennen der .exe (Suffix "_disabled")
      3) Aktivieren durch Entfernen des Suffix "_disabled"
      4) Anzeigen des Status

    Hinweis: Das Skript verändert Dateinamen (Rename-Item). Dafür sind i. d. R. Administratorrechte nötig.
    Das Deaktivieren von Updaten kann Sicherheitsrisiken verursachen und ist in Unternehmensumgebungen ggf. policy-widrig.

.PARAMETER None
    Keine Parameter – Bedienung erfolgt über ein interaktives Menü.

.NOTES
    Autor:      team-netz Consulting GmbH
    Version:    1.0.0
    Datum:      2026-02-07
    Benötigt:   Windows PowerShell 5.1+ / PowerShell 7+, passende Berechtigungen (ggf. "Als Administrator ausführen")
    Pfade:      $env:SystemDrive\Program Files (x86)\Microsoft
                $env:LOCALAPPDATA\Microsoft\EdgeUpdate

.EXAMPLE
    PS> .\EdgeUpdateManager.ps1
    Startet das Menü und erlaubt Deaktivieren/Aktivieren/Status.

.LINK
    (optional) Interne Doku/Repo-Link
#>
function Get-UpdateProgramPaths {
    return @(
        "$env:SystemDrive\Program Files (x86)\Microsoft",
        "$env:LOCALAPPDATA\Microsoft\EdgeUpdate"
    )
}

function Is-UpdateProgram($file) {
    $fileName = Split-Path -Leaf $file
    $name, $ext = $fileName -split '\.', 2
    if ($ext -ieq 'exe') {
        return $name -match "update|elevation_service"
    }
    return $false
}

function Get-UpdatePrograms($path) {
    $updatePrograms = @()
    if (-not (Test-Path $path)) {
        return @()
    }
    if (Test-Path $path -PathType Leaf) {
        if (Is-UpdateProgram $path) {
            $updatePrograms += $path
        }
    } else {
        foreach ($subfile in Get-ChildItem -Path $path -Recurse) {
            $updatePrograms += Get-UpdatePrograms -Path $subfile.FullName
        }
    }
    return $updatePrograms
}

function Get-NewFileName($file, $disabledSuffix) {
    $path = Split-Path -Parent $file
    $fileName = Split-Path -Leaf $file
    $name, $ext = $fileName -split '\.', 2
    if ($name -like "*$disabledSuffix") {
        $newName = $name -replace "$disabledSuffix$", ''
    } else {
        $newName = "$name$disabledSuffix"
    }
    return Join-Path -Path $path -ChildPath "$newName.$ext"
}

function Terminate-UpdatePrograms {
    $terminated = @()
    Get-Process | ForEach-Object {
        try {
            if (Is-UpdateProgram $_.Path) {
                Stop-Process -Id $_.Id -Force
                $terminated += $_.Path
            }
        } catch {
            Write-Host "Failed to terminate process: $($_.Name)" -ForegroundColor Yellow
        }
    }
    return $terminated
}

function Disable-Update {
    $disabledFiles = @()
    $updateProgramPaths = Get-UpdateProgramPaths
    foreach ($path in $updateProgramPaths) {
        $updatePrograms = Get-UpdatePrograms -Path $path
        foreach ($file in $updatePrograms) {
            $disabledFile = Get-NewFileName -File $file -DisabledSuffix "_disabled"
            if (-not (Test-Path $disabledFile)) {
                Rename-Item -Path $file -NewName $disabledFile
                $disabledFiles += [PSCustomObject]@{
                    OriginalFile = $file
                    NewFile      = $disabledFile
                }
            }
        }
    }
    return $disabledFiles
}

function Enable-Update {
    $enabledFiles = @()
    $updateProgramPaths = Get-UpdateProgramPaths
    foreach ($path in $updateProgramPaths) {
        $updatePrograms = Get-UpdatePrograms -Path $path
        foreach ($file in $updatePrograms) {
            if ($file -like "*_disabled*") {
                $enabledFile = Get-NewFileName -File $file -DisabledSuffix "_disabled"
                Rename-Item -Path $file -NewName $enabledFile
                $enabledFiles += [PSCustomObject]@{
                    OriginalFile = $file
                    NewFile      = $enabledFile
                }
            }
        }
    }
    return $enabledFiles
}

function Check-Status {
    $updateProgramPaths = Get-UpdateProgramPaths
    $status = @()
    foreach ($path in $updateProgramPaths) {
        $updatePrograms = Get-UpdatePrograms -Path $path
        foreach ($file in $updatePrograms) {
            $status += [PSCustomObject]@{
                File  = $file
                State = if ($file -like "*_disabled*") { "Disabled" } else { "Enabled" }
            }
        }
    }
    return $status
}

function Show-Menu {
    Clear-Host
    Write-Host "===== Edge Update Manager =====" -ForegroundColor Cyan
    Write-Host "1. Disable Update"
    Write-Host "2. Enable Update"
    Write-Host "3. Status"
    Write-Host "4. Exit"
}

function Manage-EdgeUpdates {
    while ($true) {
        Show-Menu
        $choice = Read-Host "Please select an option"
        switch ($choice) {
            "1" {
                $terminated = Terminate-UpdatePrograms
                if ($terminated.Count -gt 0) {
                    Write-Host "Terminated the following update programs:" -ForegroundColor Green
                    $terminated | ForEach-Object { Write-Host $_ }
                }
                $disabled = Disable-Update
                if ($disabled.Count -gt 0) {
                    Write-Host "Disabled the following update programs:" -ForegroundColor Green
                    $disabled | ForEach-Object { Write-Host "$($_.OriginalFile) -> $($_.NewFile)" }
                } else {
                    Write-Host "No update programs found to disable." -ForegroundColor Yellow
                }
            }
            "2" {
                $enabled = Enable-Update
                if ($enabled.Count -gt 0) {
                    Write-Host "Enabled the following update programs:" -ForegroundColor Green
                    $enabled | ForEach-Object { Write-Host "$($_.OriginalFile) -> $($_.NewFile)" }
                } else {
                    Write-Host "No update programs found to enable." -ForegroundColor Yellow
                }
            }
            "3" {
                $status = Check-Status
                if ($status.Count -gt 0) {
                    Write-Host "Current status of update programs:" -ForegroundColor Cyan
                    $status | ForEach-Object { Write-Host "$($_.File): $($_.State)" }
                } else {
                    Write-Host "No update programs found." -ForegroundColor Yellow
                }
            }
            "4" {
                Write-Host "Exiting Edge Update Manager." -ForegroundColor Cyan
                exit
                break
            }
            default {
                Write-Host "Invalid option. Please try again." -ForegroundColor Red
            }
        }
        Pause
    }
}

# Script entry point
Manage-EdgeUpdates
