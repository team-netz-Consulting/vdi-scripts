<#
    .SYNOPSIS
        Dieses Skript verarbeitet die durch den Citrix App Layering Connector erstellten Jobdateien 
        zur finalen Integration von vDisks in Citrix Provisioning Services (PVS). 
        Es ermöglicht optional die Konvertierung zu VHDX sowie die Nutzung von PVS-Versionierung.

    .DESCRIPTION
        1. **Initialisierung der Umgebung**: Prüft und lädt das Citrix PVS PowerShell Snap-in, das für die Automatisierung erforderlich ist.
        2. **Verarbeitung von Jobdateien**: Liest alle im Skriptverzeichnis vorhandenen `.job`-Dateien ein, die durch das pvs_connector_script.ps1 generiert wurden.
        3. **vDisk-Verwaltung**: Identifiziert und verarbeitet vDisks (inkl. Validierung und Speicherortprüfung), um sie entweder direkt zu übernehmen oder als neue Version einzubinden.
        4. **VHDX-Konvertierung (optional)**: Unterstützt die Umbenennung und Konvertierung von VHD zu VHDX, wenn aktiviert.
        5. **PVS-Versionierung (optional)**: Falls aktiviert, wird entweder eine neue vDisk angelegt oder eine neue Version zur bestehenden vDisk hinzugefügt. Einstellungen wie WriteCache, Lizenzmodus etc. werden übernommen.
        6. **Aufräumen**: Entfernt verarbeitete Jobdateien und temporäre Dateien, um eine saubere Umgebung zu gewährleisten.
        7. **Wiederholung**: Das Skript läuft kontinuierlich in einer Schleife und prüft regelmäßig auf neue Jobdateien.

    .EXAMPLE
        Dieses Skript wird im Hintergrund auf einem Management-Server ausgeführt, der Zugriff auf den PVS Store hat.
        Es wird automatisch auf neue `.job`-Dateien reagieren und entsprechende Aktionen durchführen.

    .NOTES
        Author:        team-netz Consulting
        Version:       1.1
        Created on:    10.05.2017
        Last Modified: 23.06.2025

    .REQUIREMENTS
        - Citrix Provisioning Services 7.7 oder neuer
        - PowerShell 5.0 oder neuer
        - Ausreichende Berechtigungen auf dem PVS Store
        - `qemu-img.exe` bei aktivierter VHDX-Konvertierung
        - Das pvs_connector_script.ps1 muss zuvor eine gültige `.job`-Datei erstellt haben
#>

#==========================================================
#Constants
# $MCLI_SNAPIN_NAME = "McliPSSnapIn"
$PVS_SNAPIN_NAME = "Citrix.PVS.SnapIn"
$LOCATION_STACK_NAME = "pvs_connector_script"
$scriptversion = "1.1"
#==========================================================
#Settings to Configure

#1-Folder for script
$ScriptFolder = "C:\scripts\pvs-connector"

#2-Enable Convert to VHDX
$bConvertToVHDX = $true
#Enable a check for space in the store before converting to VHDX
$bCheckForSpace = $true
#Path to qemu-img.exe
$QEMUPATH = "C:\scripts\pvs-connector\qemu-img.exe"
#Format of VHDX file used in QEMU-IMG
$VHDXSubformat="dynamic"

#3-Enable PVS Versioning
$bUSE_Versioning = $true
#To use ImageName as the vDisk name Set this to $True
$bUseImageNameAsvDiskName = $true

$SleepSeconds=60

#Log File Name
$LOG_FILE  = "$ScriptFolder\pvs_import_jobfile.log"
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
		Log "========================================================================" 
		$MyError = "Error: " + $Error[$i].InvocationInfo.PositionMessage + "Exception: " + $Error[$i]
		Log $MyError
	}
	$Error.Clear()
}

Log "========================================================================"
Log "           Starting Script For Image - Import"
Log "========================================================================"

$global:FormatedErrors = ""

$registeredSnapins = Get-PSSnapin -Registered

$snapin = $registeredSnapins | Where Name -EQ $PVS_SNAPIN_NAME


if ($snapin -eq $null) {
    Log "Error: No PVS console PowerShell snapin found."
    Log "========================================================================"

	Exit 1
}

Log "User Defined Settings"
Log "============================================"
if ($bUSE_Versioning)
{
	Log "Versioning is enabled"
	if ($bUseImageNameAsvDiskName){Log "Use Image Name as vDIsk Name is enabled"} else {Log "Use Image Name as vDIsk Name is disabled"}
} 
else 
{
	Log "Versioning is disabled"
	}
if ($bConvertToVHDX)
{
	Log "Convert to VHDX is enabled"
	if ($bCheckForSpace){Log "Check for Space is enabled"} else {Log "Check for Space is disabled"}
} 
else 
{
	Log "Convert to VHDX is disabled"
}
Log "============================================"
Log ""

Log "Using PVS snapin $($snapin.Name) at version $($snapin.Version)"
Add-PSSnapin -Name $snapin.Name 


#Loop
DO
{
  $tmpLoop=$true
        $Jobs=Get-Item -path "$ScriptFolder\*.job"

        foreach ($job in $jobs)
        {

            Log "Read Jobfile: $job.FullName"
        
            $JobProperties = convertfrom-stringdata (get-content $job.FullName -raw)
            
            $connectorCfgName=$JobProperties.'ConnectorCfgName'
            $imageName=$JobProperties.'ImageName'
            $osType=$JobProperties.'OSType'
            $diskLocatorId=$JobProperties.'DiskLocatorId'
            $global:FormatedErrors = ""
            $MyVHDDiskLocator=$null
            $storePath=$null
            $MyPVSDisk=$null
            $MyVHDXPath=$null
            $MyVHDpath=$null
            $siteId = $null
            $storeID = $null
            $disklocatorTest=$null
            $existingDiskVersions = $null
            $nextVersionNum =$null
			$bRebaseVersion = $false

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

            #Get the path to the vhd we just imported in case we need it for the copy to other servers
            Log "Getting the path to the VHD we imported"
            #Get the disk locator so we can see how big the disk is
            $MyVHDDiskLocator = Get-PVSDisklocator -DiskLocatorId $diskLocatorId
	
            $storePath = (Get-PvsStore -StoreId $MyVHDDiskLocator.StoreId).Path
            Log "The Store Path was found to be:$storePath"
            $MyPVSDisk = Get-PvsDisk -DiskLocatorId $diskLocatorId
            if (!($?))
            {
	            Log "We were not able to find the imported vDisk for disklocatorId [$diskLocatorId]  -- exiting script"
	            FormatErrors
	            Exit
            }

            $MyVHDXPath = $MyPVSDisk.OriginalFile
            $MyVHDpath = $MyPVSDisk.OriginalFile
            Log "VHD Path for the original vDisk is [$MyVHDpath]"
            if ($MyVHDpath -eq $null)
            {
	            Log "We were not able to find the imported vDisk -- exiting script"
	            Log "========================================================================"
	            FormatErrors
	            Log "========================================================================"
	            Exit
            }
            if (!($MyVHDpath.Contains(".")))
            {
	            Log "We could nto decipher the vDisk filename.  It might be too long for teh Citrix PowerShell to handle.  Max length of the file path is 127 characters -- exiting script"
	            Log "========================================================================"
	            FormatErrors
	            Log "========================================================================"
	            Exit
            }

            #Get the vDisk Settings
            $VD_ActivationEnabled = $MyPVSDisk.ActivationDateEnabled
            $VD_ADPasswordEnabled = $MyPVSDisk.AdPasswordEnabled
            $VD_HAEnabled = $MyPVSDisk.HaEnabled
            $VD_PrinterManagementEnabled = $MyPVSDisk.PrinterManagementEnabled
            $VD_WritecacheType = $MyPVSDisk.WriteCacheType
            $VD_WriteCacheSize = $MyPVSDisk.WriteCacheSize
            $VD_LicenseMode = $MyPVSDisk.LicenseMode            

            If ($bUSE_Versioning)
	            {
		            Log "Using vDisk Versioning"
		            Log "Searching for new disk locator with Id $diskLocatorId"
	                $VHDX_DiskLocator = Get-PvsDiskLocator -DiskLocatorId $diskLocatorId
		
	                Log "Changing to directory: $storePath"
	                Push-Location $storePath -StackName $LOCATION_STACK_NAME
		
		
					if($bUseImageNameAsvDiskName)
		            {					
		
			            #First lets see if there is a vDisk disklocator with our image name already
			            $siteId = $VHDX_DiskLocator.SiteId
					
			            $storeID = $VHDX_DiskLocator.StoreId
			            $disklocatorTest = Get-PvsDiskLocator -DiskLocatorName "$imageName" -SiteId $siteId -StoreId $storeID -ErrorAction:Continue
						
			            if ($disklocatorTest -eq $null)
			            {							
                            # Clear Error from Get-PvsDiskLocator because its the first disk
                            $Error.Clear()
				            Log "No vDisk found matching our image name [$imageName].  This will be the first version."
				            #Now need to remove the vDisk, rename the vhd and add it back in to PVS.
				            # $bRebaseVersion = $false
				
				            Log "Getting Disk Locator for the original VHD"
			                $VHD_DiskLocator = Get-PvsDiskLocator -DiskLocatorId $diskLocatorId
				
				            $dl_Name = $imageName 
				            $dl_Site = $VHD_DiskLocator.SiteName
				            $dl_Store = $VHD_DiskLocator.StoreName
				            $dl_Description = $VHD_DiskLocator.Description
				            $dl_MenuText = $VHD_DiskLocator.MenuText
				            $dl_ServerName = $VHD_DiskLocator.ServerName
				            $dl_RebalanceEnabled = $VHD_DiskLocator.RebalanceEnabled
				            $dl_RebalanceEnabledPercent = $VHD_DiskLocator.RebalanceTriggerPercent
				            $dl_SubnetAffinity = $VHD_DiskLocator.SubnetAffinity
				
				            #Delete the original disklocator
				            Log "Removing the Disk Locator with ID $diskLocatorId"
				            Remove-PvsDiskLocator -DiskLocatorId $diskLocatorId -Confirm:$false
				
				            #Delete the PVP and lok files
				            $delFileBase = $VHD_DiskLocator.DiskLocatorName
				            Log "Removing $storePath\$delFileBase.lok"
				            Remove-Item "$storePath\$delFileBase.lok"
				            Log "Removing $storePath\$delFileBase.pvp"
				            Remove-Item "$storePath\$delFileBase.pvp"
				
				            #Now rename the vhd file to imagename.vhd or imagename.vhdx
			                Log "Changing to directory: $storePath"
							Log "before push"
			                Push-Location $storePath -StackName $LOCATION_STACK_NAME
							Log "after push"
				            if ($bConvertToVHDX){$VHDEXT = "vhdx"}else{$VHDEXT = "vhd"}
							Log "nach zuweisimg"
                            # $VHDEXT = "vhdx"
				            $MyNewDiskPath = "$storePath\$imageName.$VHDEXT"
							Log "vor if"
				            if ($bConvertToVHDX)
				            {
					            Log "Renaming the disk file from [$MyVHDXpath] to [$MyNewDiskPath]"
					            ren $MyVHDXpath $MyNewDiskPath
				            }
				            else
				            {
					            Log "Renaming the disk file from [$MyVHDpath] to [$MyNewDiskPath]"
					            ren $MyVHDpath $MyNewDiskPath
				            }
				            #Make sure the rename worked
				            if (!(Test-Path $MyNewDiskPath))
				            {
					            Log "***Warning the rename failed.  Exiting Script"
					            Log "Try manually impporting the vDisk"
					            Log "========================================================================"
					            FormatErrors
					            Log "========================================================================"

					            Exit
				            }
				
				            #Now  add the new one
				            Log "Creating a disk locator for our VHD/VHDX file"

				            if ($dl_MenuText -eq $null){$dl_MenuText=""}
				            if ($dl_Description -eq $null){$dl_Description=""}
				            if ($dl_ServerName -eq $null){$dl_ServerName=""}
				            if ($bConvertToVHDX)
				            {
					            if ($dl_ServerName -eq "")
					            {
						            New-PvsDiskLocator `
						            -DiskLocatorName "$dl_Name" `
						            -SiteName "$dl_Site" `
						            -StoreName "$dl_Store" `
						            -VHDX 
						            $VHDEXT = "vhdx"
					            }
					            else
					            {
						            New-PvsDiskLocator `
						            -DiskLocatorName "$dl_Name" `
						            -SiteName "$dl_Site" `
						            -StoreName "$dl_Store" `
						            -ServerName "$dl_ServerName" `
						            -VHDX 
						            $VHDEXT = "vhdx"
					            }
				            }
				            else
				            {
				            New-PvsDiskLocator `
					            -DiskLocatorName "$dl_Name" `
					            -SiteName "$dl_Site" `
					            -StoreName "$dl_Store" `
					            -ServerName "$dl_ServerName" 
					            $VHDEXT = "vhdx"
				            }
				            if (!($?))
				            {
					            Log "***Warning the new disk created for our image was could not be added as a vDisk.  Exiting Script"
					            Log "using settings dl_name:$dl_Name dl_site:$dl_Site dl_store:$dl_store dl_server:$dl_ServerName"
					
					            Log "Try manually impporting the vDisk"
					            Log "========================================================================"
					            FormatErrors
					            Log "========================================================================"

					            Exit
				            }
				
				            $NewDiskLocator = Get-PvsDiskLocator -DiskLocatorName $dl_Name -SiteName $dl_Site -StoreName $dl_Store
				            $newDiskLocatorId = $NewDiskLocator.DiskLocatorId
				            Log "The new DiskLocator Id for the renamed image [$imageName] is $newDiskLocatorId"
				            $storePath = (Get-PvsStore -StoreId $NewDiskLocator.StoreId).Path
				
				            $o = Get-PvsDisk -DiskLocatorId $newDiskLocatorId
				            $o.ActivationDateEnabled = $VD_ActivationEnabled 
				            $o.HaEnabled = $VD_HAEnabled 
				            $o.AdPasswordEnabled = $VD_ADPasswordEnabled 
				            $o.PrinterManagementEnabled = $VD_PrinterManagementEnabled 
				            $o.WriteCacheType = $VD_WritecacheType 
				            $o.WriteCacheSize = $VD_WriteCacheSize 
				            $o.LicenseMode = $VD_LicenseMode
							$o.VHDX = $bConvertToVHDX
				            
				
				            #get the vhd/vhdx path
				            $OriginalFileO = $o.OriginalFile
				            if ($OriginalFileO -eq $null){$OriginalFileO = ""}
				            if ($OriginalFileO.Contains("."))
				            {
					            $MyVHDXPath = $OriginalFileO
					            Log "The new VHDX path for our vDisk is [$MyVHDXPath]"
				            }
				            else
				            {
					            Log "We were not able to find the imported vDisk after the VHDX conversion -- 331 -- exiting script"
					            Log "========================================================================"
					            FormatErrors
					            Log "========================================================================"
					            Exit
				            }
				
				            Log "We will now update the vDisk settinsg to match previous settings"
				            #Change the disk to use the new disk locator
				            Set-PvsDisk $o 

							#NEU
							Log "Checking if file exists at path: $MyVHDXPath"
							if (-not (Test-Path -Path $MyVHDXPath)) {
								Log "vDisk file was not found at [$MyVHDXPath] -- exiting script"
								Log "========================================================================"
					            FormatErrors
					            Log "========================================================================"
								$tmpLoop = $false
								Exit
							}else{
								Log "Success - The new vDisk was imported as $ImageName."
							}
							#NEU-ENDE
			            }
			            else
			            {
				            $bRebaseVersion = $true
				
			            }
		            }
		            else
		            {
			            $bRebaseVersion = $true
		            }
		
		            if ($bRebaseVersion)
		            {
			            #We need to find the newest disk for our image
			            if ($bUseImageNameAsvDiskName)
			            {
				            $NewDiskBaseName = "$imageName"
				            $newestDisk = $NewDiskBaseName
			            }
			            else
			            {
				            $NewDiskBaseName = $VHDX_DiskLocator.Name
				            $latestTimeStamp = [DateTime]::MinValue
			                $newestDisk = $null

							$datePattern = "\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"
							$newDiskPrefix = $NewDiskBaseName -replace "_$datePattern$", ""

			                Log "Searching for the latest disk that begins with $newDiskPrefix."

			                ForEach ($file in (Get-ChildItem -Filter "*.vhd*")) {
			                    if ($file.BaseName -eq "$NewDiskBaseName") {
			                        Continue
			                    }

					            if ($file.BaseName -match "$($newDiskPrefix)$($dateTimeRegex)") {
			                        $timeStamp = [DateTime]::ParseExact($Matches[1], "yyyy-MM-dd_HH-mm-ss", $null)

			                        Log "Found '$($file.BaseName)'"

			                        if ($timeStamp -gt $latestTimeStamp) {
			                            $newestDisk = $file.BaseName
			                        }
			                    }
			                }
			            }
			
			            $existingDiskBaseName = $newestDisk
		                if ($existingDiskBaseName -eq $null) {
		                    Log "No existing vDisk with a name similar to $($VHDX_DiskLocator.Name) was found, so a new version will not be added."
				            Log "========================================================================"
				            FormatErrors
				            Log "========================================================================"

				            Exit
		                }
		    
			            Log "Will add version to vDisk: $existingDiskBaseName"

                        Log "CheckPath: $StorePath"

		                Export-PvsDisk -DiskLocatorId $VHDX_DiskLocator.DiskLocatorId

		                $existingDiskLoc = Get-PvsDiskLocator -SiteId $VHDX_DiskLocator.SiteId -StoreId $VHDX_DiskLocator.StoreId -DiskLocatorName $existingDiskBaseName
			
			            Log "Getting existing Disk Versions"
		                $existingDiskVersions = Get-PvsDiskVersion -DiskLocatorId $existingDiskLoc.DiskLocatorId
		                # $nextVersionNum = ($existingDiskVersions | Measure -Property Version -Maximum).Maximum + 1
						$maxVersion = ($existingDiskVersions | Measure-Object -Property Version -Maximum).Maximum
						$nextVersionNum = if ($maxVersion) { $maxVersion + 1 } else { 1 }

			            #Edit the disk manifest
						$manifestPath = Join-Path $StorePath "$($VHDX_DiskLocator.Name).xml"
			
		 	            Log "Editing disk manifest file '$manifestPath' to use version $NextVersionNum"

						if (-not (Test-Path $manifestPath)) {
							Log "Manifest file not found: $manifestPath"
							Exit
						}

		                [xml]$manifest = Get-Content $manifestPath

			            $newDesc = "Created from published disk $($manifest.versionManifest.version.diskFileName)"

		                $manifest.versionManifest.version.type = "4"        # Merged Base - necessary so previous versions can be deleted
		                $manifest.versionManifest.version.access = "7"      # Test - as opposed to Production (0) or Maintenance
		                $manifest.versionManifest.version.versionNumber = "$NextVersionNum"
		                if ($bConvertToVHDX)
			            {
				            $manifest.versionManifest.version.diskFileName = "$ExistingDiskBaseName.$NextVersionNum.vhdx"
		                }
			            else
			            {
		            		$manifest.versionManifest.version.diskFileName = "$ExistingDiskBaseName.$NextVersionNum.vhd"
		            	}
			            $manifest.versionManifest.version.description = "$newDesc"

		                ##$outPath = "$(Convert-Path -Path ".")\$ExistingDiskBaseName.xml"
                        $outPath = Join-Path $StorePath "$ExistingDiskBaseName.xml"
		                Log "Writing new disk manifest file '$outPath'"

		                $manifest.Save($outPath)
		    
		                # TODO copy load balancing settings over
		                $diskLocks = Get-PvsDiskLocatorLock -DiskLocatorId $existingDiskLoc.DiskLocatorId
		                if ($diskLocks.Length -le 0) {
		                    Log "Copying configuration settings to existing vDisk: $existingDiskBaseName"

		                    $newDisk = Get-PvsDisk -DiskLocatorId $VHDX_DiskLocator.DiskLocatorId
		                    $existingDisk = Get-PvsDisk -DiskLocatorId $existingDiskLoc.DiskLocatorId

		                    $existingDisk.PrinterManagementEnabled = $newDisk.PrinterManagementEnabled
		                    $existingDisk.AdPasswordEnabled = $newDisk.AdPasswordEnabled
		                    $existingDisk.WriteCacheType = $newDisk.WriteCacheType
		                    $existingDisk.LicenseMode = $newDisk.LicenseMode
				            $OriginalFileED = $existingDisk.OriginalFile
				            if ($OriginalFileED -eq $null){$OriginalFileED = $existingDisk.OriginalFile}
				            if ($OriginalFileED -eq $null){$OriginalFileED = ""}
				            
							if (-not (Test-Path -Path $OriginalFileED)) {
								Log "vDisk file [$OriginalFileED] not found -- exiting script"
								FormatErrors
								Exit
							}

							$existingDisk.VHDX = $OriginalFileED.ToLower().EndsWith(".vhdx")
							Set-PvsDisk $existingDisk
		                } else {
		                    Log "WARNING: vDisk '$existingDiskBaseName' is locked, configuration settings will not be changed!"
		                }
			
			            Log "Removing the disk locator with id [$($VHDX_DiskLocator.DiskLocatorId)]"
		                Remove-PvsDiskLocator -DiskLocatorId $VHDX_DiskLocator.DiskLocatorId

		                #Now lets rename the pvp and vhdx to our version numbering naming scheme
		                $NewDiskBaseName = $VHDX_DiskLocator.Name
		                Log "Renaming vDisk files to use version number $NextVersionNum"

		                Remove-Item "$StorePath\$NewDiskBaseName.lok"
		                Remove-Item "$StorePath\$NewDiskBaseName.xml"
		                Rename-Item "$NewDiskBaseName.pvp" "$ExistingDiskBaseName.$NextVersionNum.pvp"
		    
                        if ($bConvertToVHDX)
			            {
                            Log "Renaming $StorePath\$NewDiskBaseName.vhdx to $StorePath\$ExistingDiskBaseName.$NextVersionNum.vhdx"

				            Rename-Item "$StorePath\$NewDiskBaseName.vhdx" "$StorePath\$ExistingDiskBaseName.$NextVersionNum.vhdx"
			            }
			            else
			            {
				            Rename-Item "$NewDiskBaseName.vhd" "$ExistingDiskBaseName.$NextVersionNum.vhd"
			            }
					
			            Add-PvsDiskVersion -DiskLocatorId $existingDiskLoc.DiskLocatorId

		                Log "vDisk $($VHDX_DiskLocator.Name) successfully converted to version $nextVersionNum of vDisk $existingDiskBaseName"

		                Remove-Item "$StorePath\$existingDiskBaseName.xml" -ErrorAction Continue
		            }
	            }
	
	            FormatErrors
	            Log "========================================================================"
				if($Error.Count() > 0) {
					$tmpLoop = $false
					Log "Quit Loop due to Error"
				}

            #Remove Job File
            Remove-Item $Job.FullName -verbose
        }

  Log "Sleep $SleepSeconds Seconds."

  Start-Sleep -Seconds $SleepSeconds
} Until ($tmpLoop -eq $false)



Log "========================================================================"
Log "           Stopping Script For Image - Import"
Log "========================================================================"


