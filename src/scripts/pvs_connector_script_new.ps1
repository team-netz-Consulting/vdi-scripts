<#
    .SYNOPSIS
        Dieses Skript verarbeitet Parameter aus einem Citrix App Layering Connector 
        und erstellt daraus eine strukturierte Jobdatei für die nachgelagerte Verarbeitung 
        durch ein separates Importskript.

    .DESCRIPTION
        1. **Parameterübernahme**: Übernimmt Werte wie ImageName, OSType und DiskLocatorId vom App Layering Connector.
        2. **Jobdatei-Erstellung**: Erstellt im definierten Arbeitsverzeichnis (`$ScriptFolder`) eine `.job`-Datei mit diesen Informationen.
        3. **Logging**: Protokolliert die übernommenen Daten und ggf. aufgetretene Fehler zur Fehleranalyse.

        Die erzeugte Jobdatei dient als Input für das Skript `pvs_import_jobfile.ps1`, das die eigentliche vDisk-Integration durchführt.

    .EXAMPLE
        Dieses Skript wird automatisch durch den App Layering Connector ausgelöst und erfordert keine manuelle Ausführung.

    .NOTES
        Author:        team-netz Consulting
        Version:       1.1
        Created on:    05.10.2017
        Last Modified: 23.06.2025

    .REQUIREMENTS
        - PowerShell 5.0 oder neuer
        - Wird vom Citrix App Layering Connector aufgerufen
        - Schreibberechtigung im angegebenen `$ScriptFolder`
#>


#==========================================================
#Constants
$LOCATION_STACK_NAME = "pvs_connector_script"
$scriptversion = "1.1"
#==========================================================
#Settings to Configure

#1-Folder for script
$ScriptFolder = "C:\scripts\pvs-connector"

#Log File Name
$LOG_FILE  = "$ScriptFolder\pvs_connector_script.log"
#==========================================================


function Log 
{
    param([string]$Message)
    (Get-Date -Format "[yyyy-MM-dd HH:mm:ss] ") + $Message | Out-File -FilePath $LOG_FILE -Append -Force
}

Function FormatErrors()
{
	$NumToProcess = $Error.Count - 1
	For ($i = $NumToProcess; $i -gt -1; $i-- )
	{
		If (!($Error[$i].Contains("disklocatorTest")))
		{
			Log "========================================================================" 
			$MyError = "Error: " + $Error[$i].InvocationInfo.PositionMessage + "Exception: " + $Error[$i]
			Log $MyError
		}
	}
	$Error.Clear()
}

Log "========================================================================"
Log "           Running Script For Image - $imageName"
Log "========================================================================"
Log "Script Version: $scriptversion" 
Log "--- Variables Passed From Connector ---"
Log "ConnectorCfgName: '$connectorCfgName'"
Log "ImageName: '$imageName'"
Log "OSType: '$osType'"
Log "DiskLocatorId: '$diskLocatorId'"
Log ""

Set-Location -Path $ScriptFolder

Log "$(Get-Location)"

$global:FormatedErrors = ""

try
{
    #WriteJobFile
    $JobFile="$ScriptFolder\$diskLocatorId.job"
    New-Item $JobFile -ItemType File
 
    Add-Content $JobFile "ConnectorCfgName=$connectorCfgName"
    Add-Content $JobFile "ImageName=$imageName"
    Add-Content $JobFile "OSType=$osType"
    Add-Content $JobFile "DiskLocatorId=$diskLocatorId"
}
catch
{
  Log "An error occurred:"
  Log "$_"
}