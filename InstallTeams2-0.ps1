<#
    .SYNOPSIS
        Dieses Skript automatisiert die Installation von Microsoft Teams 2.0 und des zugehörigen Meeting Add-ins für eine Citrix VDI-Umgebung (Windows Server 2022). Es führt folgende Schritte aus:


    .DESCRIPTION
        1. **Überprüfen einer vorhandenen Installation**: Das Skript überprüft, ob bereits eine Installation von Microsoft Teams vorhanden ist. Falls eine alte Version gefunden wird, wird diese deinstalliert, bevor mit der Installation fortgefahren wird.
        2. **Herunterladen der Teams MSIX-Datei**: Das Skript lädt die aktuelle Microsoft Teams 2.0 MSIX-Installationsdatei herunter und speichert sie in einem temporären Verzeichnis.
        3. **Installation von Microsoft Teams 2.0**: Die Teams 2.0 Anwendung wird über `Add-AppxProvisionedPackage` installiert, um die App im VDI-Modus bereitzustellen, der für Citrix VDI-Umgebungen optimiert ist.
        4. **AutoUpdate deaktivieren**: Um automatische Updates zu verhindern (was in VDI-Umgebungen oft unerwünscht ist), wird ein Registrierungseintrag erstellt, der die AutoUpdate-Funktion deaktiviert.
        5. **Installation des Teams Meeting Add-ins**: Das Skript sucht das Installationsverzeichnis von Teams und verwendet den Installer für das Meeting Add-in, um sicherzustellen, dass das Add-in in Outlook zur Verfügung steht.
        6. **Aufräumen der Installationsdateien**: Nach Abschluss der Installation werden die temporär heruntergeladenen Installationsdateien gelöscht.


    .EXAMPLE

    .NOTES
        Author:        team-netz Consulting GmbH
        Version:       1.0
        Created on:    25.09.2024
        Last Modified: 15.10.2024
        
    .CHANGELOG
        Version 1.0 - 25.09.2024
        - Initial version created to install Teams 2.0.
        - 

    .REQUIREMENTS
        - PowerShell 5.0 or newer
        - Appropriate permissions
#>


# Function to handle logging to console and/or logfile with optional text color for console output
function Write-Log {
    param (
        [string]$Message,                  
        [string]$LogFile = "$PWD\teams2.0.txt",  
        [switch]$NoConsole,                
        [switch]$DebugMode,                
        [string]$TextColor = "White"       
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $Message"

    if (-not $NoConsole) {
        Write-Host $logMessage -ForegroundColor $TextColor
    }

    Add-Content -Path $LogFile -Value $logMessage
}

function Manage-RegistryKeys {
    param (
        [Parameter(Mandatory = $true)]
        [array]$keys  # Array von Key-Definitionen, die verarbeitet werden sollen
    )

    foreach ($key in $keys) {
        # Extrahiere die Eigenschaften des jeweiligen Keys
        $registryPath = $key.Path
        $propertyName = $key.Name
        $propertyType = $key.Type
        $propertyValue = $key.Value
        $action = $key.Action  # Hinzufügen, Aktualisieren oder Löschen

        try {
            # Überprüfen, ob der Registry-Pfad existiert
            if (-not (Test-Path $registryPath)) {
                if ($action -eq "Add" -or $action -eq "Update") {
                    Write-Log -Message "Erstelle den Registry-Pfad $registryPath..."
                    New-Item -Path $registryPath -Force | Out-Null
                    Write-Log -Message "Registry-Pfad $registryPath wurde erfolgreich erstellt."
                } else {
                    Write-Log -Message "Pfad $registryPath existiert nicht, Aktion '$action' nicht möglich." -TextColor Yellow
                    continue
                }
            }

            switch ($action) {
                "Add" {
                    Write-Log -Message "Hinzufügen des Registry-Keys '$propertyName' mit Wert '$propertyValue'..."
                    New-ItemProperty -Path $registryPath -Name $propertyName -PropertyType $propertyType -Value $propertyValue -Force | Out-Null
                    Write-Log -Message "Registry-Key '$propertyName' wurde erfolgreich hinzugefügt." -TextColor Green
                }
                "Update" {
                    # Prüfen, ob der Registry-Key existiert
                    if (Test-Path "$registryPath\$propertyName") {
                        Write-Log -Message "Aktualisieren des vorhandenen Registry-Keys '$propertyName' mit Wert '$propertyValue'..."
                        Set-ItemProperty -Path $registryPath -Name $propertyName -Value $propertyValue -Force | Out-Null
                        Write-Log -Message "Registry-Key '$propertyName' wurde erfolgreich aktualisiert." -TextColor Green
                    } else {
                        Write-Log -Message "Registry-Key '$propertyName' existiert nicht. Führe Hinzufügen statt Aktualisieren durch..."
                        New-ItemProperty -Path $registryPath -Name $propertyName -PropertyType $propertyType -Value $propertyValue -Force | Out-Null
                        Write-Log -Message "Registry-Key '$propertyName' wurde erfolgreich hinzugefügt." -TextColor Green
                    }
                }
                "Remove" {
                    Write-Log -Message "Löschen des Registry-Keys '$propertyName'..."
                    Remove-ItemProperty -Path $registryPath -Name $propertyName -Force | Out-Null
                    Write-Log -Message "Registry-Key '$propertyName' wurde erfolgreich gelöscht." -TextColor Green
                }
                default {
                    Write-Log -Message "Ungültige Aktion '$action' für den Registry-Key '$propertyName'. Verwende 'Add', 'Update' oder 'Remove'." -TextColor Red
                }
            }
        } catch {
            Write-Log -Message "Fehler: Konnte den Registry-Key '$propertyName' im Pfad '$registryPath' nicht verarbeiten." -TextColor Red
        }
    }
}

# Funktion zum Aktivieren der Startart "Manuell" für den Dienst "App-Vorbereitung"
function Enable-AppPreparationService {
    $serviceName = "AppReadiness"  # Interner Name des Dienstes
    try {
        # Überprüfen, ob der Dienst vorhanden ist
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        Write-Log -Message "Aktivieren der Startart 'Manuell' für den Dienst 'App-Vorbereitung'..."
        
        # Setze den Dienst auf "Manuell"
        Set-Service -Name $serviceName -StartupType Manual
        
        Write-Log -Message "Der Dienst 'App-Vorbereitung' wurde erfolgreich auf 'Manuell' gesetzt." -TextColor Green

        # Überprüfen, ob der Dienst gestoppt ist, und ihn dann starten
        if ($service.Status -ne 'Running') {
            Write-Log -Message "Der Dienst 'App-Vorbereitung' ist derzeit gestoppt. Starten des Dienstes..."
            Start-Service -Name $serviceName
            Write-Log -Message "Der Dienst 'App-Vorbereitung' wurde erfolgreich gestartet." -TextColor Green
            
            # 20 Sekunden Pause mit Progress Bar
            Write-Log -Message "Warte 20 Sekunden..."
            for ($i = 0; $i -le 20; $i++) {
                $percentComplete = ($i / 20) * 100
                Write-Progress -Activity "Warte auf Dienststart" -Status "Bitte warten..." -PercentComplete $percentComplete
                Start-Sleep -Seconds 1
            }     
            
            # Fortschrittsanzeige leeren
            Write-Progress -Activity "Warte auf Dienststart" -Status "Fertig" -Completed            
        } else {
            Write-Log -Message "Der Dienst 'App-Vorbereitung' läuft bereits." -TextColor Yellow
        }     
        
    } catch {
        Write-Log -Message "Fehler: Der Dienst 'App-Vorbereitung' wurde nicht gefunden oder es trat ein Fehler auf." -TextColor Red
    }
}

# Funktion zum erstellen eines Teams 2.1 Shortcuts
function Create-TeamsShortcut {
    param (
        [string]$shortcutPath = "$env:USERPROFILE\Desktop\Teams.lnk"  # Standardpfad für den Shortcut (Desktop)
    )

    # Pfad zur ausführbaren Datei von Teams 2.1
    $teamsInstallDir = (Get-AppxPackage -Name "*Teams*" -AllUsers).InstallLocation
    if (-not $teamsInstallDir) {
        $teamsInstallDir = "C:\Program Files\Microsoft Teams"
    }

    $addinInstallerPath = "$teamsInstallDir\ms-teams.exe"
    if (Test-Path $addinInstallerPath) 
    {
        # Create WScript.Shell COM object
        $WScriptShell = New-Object -ComObject WScript.Shell

        # Erstelle die Verknüpfung
        $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $teamsExecutablePath
        $shortcut.WorkingDirectory = "C:\Program Files\Microsoft Teams"  # Arbeitsverzeichnis (anpassen, falls nötig)
        $shortcut.WindowStyle = 1  # Normales Fenster
        $shortcut.IconLocation = "$teamsExecutablePath, 0"  # Standard-Icon von Teams
        $shortcut.Save()
    }
    else {
        Write-Log -Message "Fehler: Die Teams 2.1 ausführbare Datei wurde nicht gefunden. Überprüfen Sie den Pfad." -TextColor Red
        return
    }  

    Write-Log -Message "Die Verknüpfung für Microsoft Teams 2.1 wurde erfolgreich erstellt: $shortcutPath" -TextColor Green
}

# Funktion zum Deaktivieren des Dienstes "App-Vorbereitung"
function Disable-AppPreparationService {
    $serviceName = "AppReadiness"  # Interner Name des Dienstes
    try {
        # Überprüfen, ob der Dienst vorhanden ist
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        Write-Log -Message "Deaktivieren des Dienstes 'App-Vorbereitung'..."
        
        # Setze den Dienst auf "Disabled"
        Set-Service -Name $serviceName -StartupType Disabled
        
        Write-Log -Message "Der Dienst 'App-Vorbereitung' wurde erfolgreich deaktiviert." -TextColor Green
    } catch {
        Write-Log -Message "Fehler: Der Dienst 'App-Vorbereitung' wurde nicht gefunden oder es trat ein Fehler auf." -TextColor Red
    }
}


# Function to install Microsoft Teams
function Install-Teams {
    Write-Log -Message "Überprüfen, ob bereits eine Teams-Installation vorhanden ist..."
    $existingTeams = Get-AppxPackage -Name "*Teams*" -AllUsers
    if ($existingTeams) {
        Write-Log -Message "Vorhandene Microsoft Teams Installation gefunden. Entferne diese..."
        Remove-AppxPackage -Package $existingTeams.PackageFullName -AllUsers
        if ($?) {
            Write-Log -Message "Vorherige Microsoft Teams Installation wurde erfolgreich entfernt."
        } else {
            Write-Log -Message "Fehler beim Entfernen der vorherigen Teams-Installation." -TextColor Red
            return
        }
    } else {
        Write-Log -Message "Keine vorhandene Teams-Installation gefunden."
    }

    Enable-AppPreparationService

    Write-Log -Message "Herunterladen des TeamsBootstrappers..."
    $bootstrapperUrl = "https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409"
    $bootstrapperPath = "$env:TEMP\Teamsbootstrapper.exe"    
    Invoke-WebRequest -Uri $bootstrapperUrl -OutFile $bootstrapperPath -UseBasicParsing

    Write-Log -Message "Herunterladen von Microsoft Teams 2.0 MSIX..."
    $teamsMsixUrl = "https://go.microsoft.com/fwlink/?linkid=2196106"
    $teamsMsixPath = "$env:TEMP\Teams_windows_x64.msix"
    Invoke-WebRequest -Uri $teamsMsixUrl -OutFile $teamsMsixPath -UseBasicParsing

    Write-Log -Message "Installieren von Microsoft Teams 2.0 im VDI-Modus auf Windows Server 2022..."
    Add-AppxProvisionedPackage -PackagePath $teamsMsixPath -Online -SkipLicense

    #Start-Process -FilePath $bootstrapperPath -ArgumentList "-p -o $teamsMsixPath" -NoNewWindow -Wait

    if (Get-Command -Name "*Teams" -ErrorAction SilentlyContinue) {
        Write-Log -Message "Microsoft Teams 2.0 wurde erfolgreich installiert."
    } else {
        Write-Log -Message "Fehler bei der Installation von Microsoft Teams 2.0." -TextColor Red
    }

    Write-Log -Message "Verarbeite Registry Keys..."

# Array von Registry-Keys, die hinzugefügt oder aktualisiert werden sollen
$keys = @(
    @{
        Path = "HKLM:\SOFTWARE\Microsoft\Teams"
        Name = "disableAutoUpdate"
        Type = "DWORD"
        Value = 1
        Action = "Update"
    },
    @{
        Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"
        Name = "AllowDevelopmentWithoutDevLicense"
        Type = "DWORD"
        Value = 1
        Action = "Update"
    },
    @{
        Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"
        Name = "AllowAllTrustedApps"
        Type = "DWORD"
        Value = 1
        Action = "Update"
    },
    @{
        Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"
        Name = "BlockNonAdminUserInstall"
        Type = "DWORD"
        Value = 0
        Action = "Update"
    }
) 

    # Aufrufen der Funktion Manage-RegistryKeys mit dem Array von Registry-Keys
    Manage-RegistryKeys -keys $keys

    #Disable-AppPreparationService
}

# Function to install the Meeting Add-in
function Install-AddIn {
    $teamsInstallDir = (Get-AppxPackage -Name "*Teams*" -AllUsers).InstallLocation
    if (-not $teamsInstallDir) {
        $teamsInstallDir = "C:\Program Files\Microsoft Teams"
    }

    $addinInstallerPath = "$teamsInstallDir\MICROSOFTTEAMSMEETINGADDININSTALLER.MSI"
    if (Test-Path $addinInstallerPath) {
        $installableversion = Get-AppLockerFileInformation -Path $addinInstallerPath | Select -ExpandProperty Publisher | select BinaryVersion
        $getversionnumber = $installableversion.BinaryVersion.toString()
        
        Write-Log -Message "Installieren des Microsoft Teams Meeting Add-ins..."
        $TeamsAddinInstall = start-process -filepath "C:\Windows\System32\msiexec.exe"-argumentList '/i MICROSOFTTEAMSMEETINGADDININSTALLER.MSI /qn ALLUSERS=1 /norestart TARGETDIR="C:\Program Files (x86)\Microsoft\TeamsMeetingAddin\',$getversionnumber,'"' -WorkingDirectory $teamsInstallDir -Passthru
        #Start-Process -FilePath $addinInstallerPath -ArgumentList "/quiet /norestart" -NoNewWindow -Wait
        $TeamsAddinInstall.WaitForExit()

        $addinKey = "HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect"
        if (Test-Path $addinKey) {
            Write-Log -Message "Das Microsoft Teams Meeting Add-in wurde erfolgreich installiert."
        } else {
            Write-Log -Message "Fehler bei der Installation des Microsoft Teams Meeting Add-ins." -TextColor Red
        }
    } else {
        Write-Log -Message "Teams Meeting Add-in Installer wurde nicht gefunden." -TextColor Red
    }
}

# Function to uninstall Microsoft Teams
function Uninstall-Teams {
    Write-Log -Message "Überprüfen, ob eine Teams-Installation vorhanden ist..."

    $teamsInstallDir = (Get-AppxPackage -Name "*Teams*" -AllUsers).InstallLocation
    if (-not $teamsInstallDir) {
        $teamsInstallDir = "C:\Program Files\Microsoft Teams"
    }

    $existingTeams = Get-AppxPackage -Name "*Teams*" -AllUsers
    if ($existingTeams) {
        Write-Log -Message "Vorhandene Microsoft Teams Installation gefunden. Entferne diese..."
        $addinInstallerPath = "$teamsInstallDir\MICROSOFTTEAMSMEETINGADDININSTALLER.MSI"
        
        $installableversion = Get-AppLockerFileInformation -Path $addinInstallerPath | Select -ExpandProperty Publisher | select BinaryVersion
        $getversionnumber = $installableversion.BinaryVersion.toString()
        
        Write-Log -Message "Deinstallieren des Microsoft Teams Meeting Add-ins..."
        $TeamsAddInUninstall = Start-Process -FilePath "C:\Windows\System32\msiexec.exe" -ArgumentList "-x MICROSOFTTEAMSMEETINGADDININSTALLER.MSI /qn" -WorkingDirectory $teamsInstallDir -Passthru
        $TeamsAddInUninstall.WaitForExit()
        Remove-Item -Path "C:\Program Files (x86)\Microsoft\TeamsMeetingAddin\" -Recurse -Force

        Write-Log -Message "Deinstallieren von Microsoft Teams..."
        Remove-AppxPackage -Package $existingTeams.PackageFullName -AllUsers
        if ($?) {
            Write-Log -Message "Vorherige Microsoft Teams Installation wurde erfolgreich entfernt."
        } else {
            Write-Log -Message "Fehler beim Entfernen der vorherigen Teams-Installation." -TextColor Red
        }
    } else {
        Write-Log -Message "Keine Teams-Installation gefunden."
    }
}

# Function to check the status of the installation
function Check-Status {
    Write-Log -Message "Überprüfen des Installationsstatus..."
    $existingTeams = Get-AppxPackage -Name "*Teams*" -AllUsers
    if ($existingTeams) {
        Write-Log -Message "Microsoft Teams ist installiert."
    } else {
        Write-Log -Message "Microsoft Teams ist nicht installiert."
    }
}

# Main menu
function Show-Menu {
    Clear-Host
    Write-Host "======================="
    Write-Host "  Teams 2.0 Installation"
    Write-Host "======================="
    Write-Host "1. Installation Komplett"
    Write-Host "2. Installation Teams"
    Write-Host "3. Installation AddIn"
    Write-Host "4. Deinstallation"
    Write-Host "5. Status prüfen und anzeigen"
    Write-Host "6. Beenden"
}

# Main program loop
while ($true) {
    Show-Menu
    $choice = Read-Host "Bitte wählen Sie eine Option (1-6)"
    switch ($choice) {
        1 {
            Write-Log -Message "Starte vollständige Installation."
            Install-Teams
            Install-AddIn
            Write-Log -Message "Vollständige Installation abgeschlossen."
            Write-Host "Drücken Sie eine beliebige Taste, um fortzufahren..."
Read-Host
        }
        2 {
            Write-Log -Message "Starte Teams-Installation."
            Install-Teams
            Write-Host "Drücken Sie eine beliebige Taste, um fortzufahren..."
            Read-Host
        }
        3 {
            Write-Log -Message "Starte AddIn-Installation."
            Install-AddIn
            Write-Host "Drücken Sie eine beliebige Taste, um fortzufahren..."
            Read-Host            
        }
        4 {
            Write-Log -Message "Starte Deinstallation."
            Uninstall-Teams
            Write-Host "Drücken Sie eine beliebige Taste, um fortzufahren..."
            Read-Host            
        }
        5 {
            Check-Status
            Write-Host "Drücken Sie eine beliebige Taste, um fortzufahren..."
            Read-Host            
        }
        6 {
            Write-Log -Message "Beenden ausgewählt. Das Programm wird beendet."
            exit
        }
        default {
            Write-Host "Ungültige Auswahl. Bitte wählen Sie eine Option zwischen 1 und 6." -ForegroundColor Red
        }
    }
}


