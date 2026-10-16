#requires -version 5.1
<#
.SYNOPSIS
    Deaktiviert automatische Windows-Updates per Maschinenrichtlinie.
.DESCRIPTION
    Erstellt HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
    und setzt NoAutoUpdate auf 1 (REG_DWORD). Manuelle Updates bleiben moeglich.
    Benoetigt Administratorrechte. Unterstuetzt -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigDir,
    [string]$LogDir,
    [switch]$NonInteractive,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfigDir) { $ConfigDir = Join-Path $PSScriptRoot '..\..\config' }
if (-not $LogDir) { $LogDir = Join-Path $ConfigDir 'logs' }
$logFile = Join-Path $LogDir ('disable-windows-update-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
$regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

try {
    if ($PSCmdlet.ShouldProcess("$regPath\NoAutoUpdate", 'Set REG_DWORD 1 (automatische Windows-Updates deaktivieren)')) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Dieses Skript muss als Administrator ausgefuehrt werden.'
        }

        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        if (-not (Test-Path -LiteralPath $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        New-ItemProperty -Path $regPath -Name 'NoAutoUpdate' -Value 1 -PropertyType DWord -Force | Out-Null

        $key = Get-Item -LiteralPath $regPath
        if ($key.GetValue('NoAutoUpdate') -ne 1 -or $key.GetValueKind('NoAutoUpdate') -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
            throw 'Der Registry-Eintrag konnte nicht verifiziert werden.'
        }
        $message = '[{0}] OK: {1}\NoAutoUpdate=1 (REG_DWORD). Automatische Windows-Updates deaktiviert.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $regPath
        $message | Tee-Object -FilePath $logFile -Append | Out-Host
    }
    exit 0
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
