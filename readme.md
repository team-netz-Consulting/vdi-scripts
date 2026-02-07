# VDI-SCRIPTS – Automatisierung für VDI / RDS (mit Auto-Update)

Dieses Repository enthält PowerShell-Skripte zur **Automatisierung und Standardisierung** von Installations-, Update- und Konfigurationsaufgaben in **VDI- und RDS-Umgebungen** (z. B. Windows Server 2025 RDS, Citrix / AVD, Golden Images, Session Hosts).

Ziel ist es, Umgebungen schnell, reproduzierbar und zentral steuerbar zu **„betanken“**, inklusive einer **Auto-Update-Funktion** über GitHub.

---

## Features

- Zentrales Bootstrap-Skript mit Auto-Update
- Steuerung aller Tasks über einen Orchestrator
- Konfiguration über JSON (keine harte Logik im Code)
- Non-Interactive & CI/Image-Build-tauglich
- Zentrales Logging
- Erweiterbar ohne Code-Anpassung
- Geeignet für VDI, RDS, Golden Images, Session Hosts

---

## Repository-Struktur

```
vdi-scripts/
├─ bootstrap/
│  └─ main.ps1
├─ config/
│  ├─ settings.json
│  └─ logs/
└─ src/
   ├─ run.ps1
   └─ scripts/
      ├─ install-appx.ps1
      ├─ InstallTeams2-0.ps1
      ├─ installVda2507.ps1
      ├─ InstallWinSpedService.ps1
      └─ install-calculator-provisioning.ps1
```

---

## Architektur / Ablauf

### 1. Bootstrapper (`bootstrap/main.ps1`)
- Wird initial gestartet (manuell oder per Deployment)
- Lädt/aktualisiert das Repository automatisch
- Installationsziel (Standard):
  ```
  C:\Program Files\TeamNetz\vdi-scripts
  ```
- Erstellt `config/` und `config/logs/`
- Startet anschließend den Orchestrator

---

### 2. Orchestrator (`src/run.ps1`)
- Liest alle verfügbaren Actions aus `config/settings.json`
- Optional interaktives Menü
- Oder Non-Interactive-Ausführung für Automatisierung
- Übergibt Standardparameter an Sub-Skripte:
  - `-ConfigDir`
  - `-LogDir`
  - `-NonInteractive`
  - `-Force`
  - `-WhatIf`
  - `-Verbose`

---

### 3. Sub-Skripte (`src/scripts`)
- Verantwortlich für konkrete Aufgaben (Install, Update, Remove)
- Sollten idempotent sein
- Logging erfolgt zentral im `config/logs`-Verzeichnis
- Unterstützen idealerweise `SupportsShouldProcess` für `-WhatIf`

Minimaler empfohlener Header:

```powershell
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$ConfigDir,
  [string]$LogDir,
  [switch]$NonInteractive,
  [switch]$Force
)
```

---

## Konfiguration (`config/settings.json`)

Beispiel:

```json
{
  "defaultAction": "InstallVDA",
  "scriptRoot": "src/scripts",
  "actions": [
    {
      "key": "InstallVDA",
      "name": "Install VDA 2507",
      "script": "installVda2507.ps1",
      "args": []
    },
    {
      "key": "CalcUpdate",
      "name": "Calculator Update",
      "script": "install-calculator-provisioning.ps1",
      "args": ["-Action","update","-NonInteractive"]
    }
  ]
}
```

---

## Nutzung

### Interaktiv
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap\main.ps1
```

### Non-Interactive
```powershell
& "C:\Program Files\TeamNetz\vdi-scripts\src\run.ps1" `
   -Action InstallVDA `
   -NonInteractive `
   -Force `
   -Verbose
```

---

## Auto-Update

Der Bootstrapper unterstützt:
- Branch-ZIP (immer aktueller Stand)
- GitHub Releases (empfohlen für produktive Umgebungen)

---

## Get-AppX-URL
Ermittelt Download-URLs für APPX/MSIX/MSIXBUNDLE aus dem Microsoft Store
Nutzung der Store-ID / Store-URL (apps.microsoft.com/detail/<ID>)
Kein Download, nur Auflisten / Logging / optional Export

.\get-appx-url.ps1 -StoreUrl "https://apps.microsoft.com/detail/9wzdncrfhvn5" -Verbose

## Logging

- Logs befinden sich unter:
  ```
  config\logs
  ```
- Empfohlen: ein Logfile pro Skript und Tag

---

## Bootstrapper herunterladen (wget)

Der Einstieg in die Automatisierung erfolgt über den **Bootstrapper (`main.ps1`)**.  
Er lädt und aktualisiert alle weiteren Skripte automatisch.

### Download mit `wget` (empfohlen)

```bash
wget https://raw.githubusercontent.com/team-netz-Consulting/vdi-scripts/refs/heads/master/bootstrap/main.ps1 -OutFile .\main.ps1 -UseBasicParsing
```

## Start des Bootstrappers
powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1

## Zielgruppe / Einsatz

- VDI / RDS Umgebungen
- Golden Image Builds
- Session Host Deployment
- Intune / SCCM / CI-Pipelines
- Wiederholbare, kontrollierte Systemkonfiguration

---

## Best Practices

- Skripte idempotent halten
- Keine interaktiven Prompts bei `-NonInteractive`
- Klare ExitCodes verwenden
- Änderungen sauber loggen

---

## Hinweis

Interne Automatisierungslösung. Nutzung auf eigene Verantwortung.
Lizenz kann bei Bedarf ergänzt werden.
