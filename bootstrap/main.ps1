# bootstrap\main.ps1
<#
.SYNOPSIS
  Bootstrapper: lädt/aktualisiert das Repo und startet das Entry-Skript.

USAGE:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1
#>

[CmdletBinding()]
param(
    [switch]$NoUpdate,
    [ValidateSet("BranchZip","Release")]
    [string]$UpdateMode = "BranchZip",
    [string]$Branch = "main",

    # Ziel: Program Files\TeamNetz\vdi-scripts
    [string]$InstallRoot = (Join-Path $env:ProgramFiles "TeamNetz\vdi-scripts"),

    [string]$EntryScript = "src\run.ps1"   # relativ zum InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Repo-Informationen
$RepoOwner = "team-netz-Consulting"
$RepoName  = "vdi-scripts"

# Pfade
$CurrentDir = $InstallRoot
$ConfigDir  = Join-Path $CurrentDir "config"
$LogDir     = Join-Path $ConfigDir "logs"
$TempDir    = Join-Path $env:TEMP ("vdi-scripts-update-" + [guid]::NewGuid())

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Download-BranchZip {
    param([string]$BranchName)
    $zipUrl = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$BranchName.zip"
    $zipPath = Join-Path $TempDir "$RepoName-$BranchName.zip"
    Write-Verbose "Downloading $zipUrl -> $zipPath"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    return $zipPath
}

function Download-LatestReleaseZip {
    $apiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
    Write-Verbose "Querying releases: $apiUrl"
    $resp = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "PowerShell" }
    $tag = $resp.tag_name
    $zipUrl = $resp.zipball_url
    $zipPath = Join-Path $TempDir "$RepoName-$tag.zip"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -Headers @{ "User-Agent" = "PowerShell" }
    return @{ ZipPath = $zipPath; Version = $tag }
}

function Expand-ZipToStaging {
    param([string]$ZipPath)
    Ensure-Dir $TempDir
    $staging = Join-Path $TempDir "staging"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
    Ensure-Dir $staging
    Expand-Archive -Path $ZipPath -DestinationPath $staging -Force

    $root = Get-ChildItem $staging | Where-Object { $_.PSIsContainer } | Select-Object -First 1
    if (-not $root) { throw "ZIP staging root folder not found." }
    return $root.FullName
}

function Sync-Folder {
    param([string]$SourceDir, [string]$TargetDir)
    Ensure-Dir $TargetDir

    # Robocopy mirror (robust). /NFL /NDL to reduce output
    $robo = @($SourceDir, $TargetDir, "/MIR", "/R:1", "/W:1", "/NFL", "/NDL", "/NP", "/NJH", "/NJS")
    $rc = & robocopy @robo
    # robocopy gibt verschiedene ExitCodes; wir behandeln nur 1..7 als normal (siehe robocopy docs)
    return $LASTEXITCODE
}

function Update-Scripts {
    Ensure-Dir $CurrentDir
    Ensure-Dir $TempDir

    if ($UpdateMode -eq "Release") {
        $dl = Download-LatestReleaseZip
        $root = Expand-ZipToStaging -ZipPath $dl.ZipPath
        Sync-Folder -SourceDir $root -TargetDir $CurrentDir | Out-Null
        # Schreibe Version
        $dl.Version | Out-File -FilePath (Join-Path $CurrentDir "VERSION.txt") -Encoding UTF8
        return
    }

    $zip = Download-BranchZip -BranchName $Branch
    $root = Expand-ZipToStaging -ZipPath $zip
    Sync-Folder -SourceDir $root -TargetDir $CurrentDir | Out-Null
    (Get-Date -Format "yyyyMMdd-HHmmss") | Out-File -FilePath (Join-Path $CurrentDir "VERSION.txt") -Encoding UTF8
}

try {
    # Ensure base dirs
    Ensure-Dir $CurrentDir
    Ensure-Dir $ConfigDir
    Ensure-Dir $LogDir

    if (-not $NoUpdate) {
        Write-Host "Prüfe / führe Update durch..."
        Update-Scripts
    }
    else {
        Write-Host "Update übersprungen (NoUpdate)."
    }

    $entryPath = Join-Path $CurrentDir $EntryScript
    if (-not (Test-Path $entryPath)) {
        throw "Entry script nicht gefunden: $entryPath"
    }

    # Start Entry Script mit Übergabe der Config-/Log-Pfade
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $entryPath,
        "-ConfigDir", "`"$ConfigDir`"",
        "-LogDir", "`"$LogDir`""
    )
    Write-Host "Starte: powershell.exe $EntryScript"
    & powershell.exe @argList
}
catch {
    Write-Error "Fehler im Bootstrapper: $_"
    exit 1
}
finally {
    if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# SIG # Begin signature block
# MIIoFgYJKoZIhvcNAQcCoIIoBzCCKAMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDMqQZ81H5QN9Gn
# R7g1cOmpzk3CGMZ+ccE6qyPY+ySQxKCCISowggYUMIID/KADAgECAhB6I67aU2mW
# D5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYDVQQK
# Ew9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRpbWUg
# U3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5
# WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSwwKgYD
# VQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIwDQYJ
# KoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPvIhKA
# VD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlBnwDE
# JuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv2eNm
# GiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7CQKf
# OUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLgzb1g
# bL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ1AzC
# s1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwUtrYE
# 2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYadtn03
# 4ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0jBBgw
# FoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1SgLqz
# YZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBDMEGg
# P6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3Rh
# bXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKGO2h0
# dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGluZ1Jv
# b3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTAN
# BgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVUacah
# RoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQUn73
# 3qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M/SFj
# eCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7KyUJ
# Go1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/mSiSU
# ice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ1c6F
# ibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALOz1Uj
# b0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7HpNi/
# KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUufrV64
# EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ7l93
# 9bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5vVye
# fQIwggZiMIIEyqADAgECAhEApCk7bh7d16c0CIetek63JDANBgkqhkiG9w0BAQwF
# ADBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSwwKgYD
# VQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0yNTAz
# MjcwMDAwMDBaFw0zNjAzMjEyMzU5NTlaMHIxCzAJBgNVBAYTAkdCMRcwFQYDVQQI
# Ew5XZXN0IFlvcmtzaGlyZTEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTAwLgYD
# VQQDEydTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFNpZ25lciBSMzYwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDThJX0bqRTePI9EEt4Egc83JSB
# U2dhrJ+wY7JgReuff5KQNhMuzVytzD+iXazATVPMHZpH/kkiMo1/vlAGFrYN2P7g
# 0Q8oPEcR3h0SftFNYxxMh+bj3ZNbbYjwt8f4DsSHPT+xp9zoFuw0HOMdO3sWeA1+
# F8mhg6uS6BJpPwXQjNSHpVTCgd1gOmKWf12HSfSbnjl3kDm0kP3aIUAhsodBYZsJ
# A1imWqkAVqwcGfvs6pbfs/0GE4BJ2aOnciKNiIV1wDRZAh7rS/O+uTQcb6JVzBVm
# PP63k5xcZNzGo4DOTV+sM1nVrDycWEYS8bSS0lCSeclkTcPjQah9Xs7xbOBoCdma
# hSfg8Km8ffq8PhdoAXYKOI+wlaJj+PbEuwm6rHcm24jhqQfQyYbOUFTKWFe901Vd
# yMC4gRwRAq04FH2VTjBdCkhKts5Py7H73obMGrxN1uGgVyZho4FkqXA8/uk6nkzP
# H9QyHIED3c9CGIJ098hU4Ig2xRjhTbengoncXUeo/cfpKXDeUcAKcuKUYRNdGDlf
# 8WnwbyqUblj4zj1kQZSnZud5EtmjIdPLKce8UhKl5+EEJXQp1Fkc9y5Ivk4AZacG
# MCVG0e+wwGsjcAADRO7Wga89r/jJ56IDK773LdIsL3yANVvJKdeeS6OOEiH6hpq2
# yT+jJ/lHa9zEdqFqMwIDAQABo4IBjjCCAYowHwYDVR0jBBgwFoAUX1jtTDF6omFC
# jVKAurNhlxmiMpswHQYDVR0OBBYEFIhhjKEqN2SBKGChmzHQjP0sAs5PMA4GA1Ud
# DwEB/wQEAwIGwDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MEoGA1UdIARDMEEwNQYMKwYBBAGyMQECAQMIMCUwIwYIKwYBBQUHAgEWF2h0dHBz
# Oi8vc2VjdGlnby5jb20vQ1BTMAgGBmeBDAEEAjBKBgNVHR8EQzBBMD+gPaA7hjlo
# dHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdD
# QVIzNi5jcmwwegYIKwYBBQUHAQEEbjBsMEUGCCsGAQUFBzAChjlodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdDQVIzNi5jcnQw
# IwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMA0GCSqGSIb3DQEB
# DAUAA4IBgQACgT6khnJRIfllqS49Uorh5ZvMSxNEk4SNsi7qvu+bNdcuknHgXIaZ
# yqcVmhrV3PHcmtQKt0blv/8t8DE4bL0+H0m2tgKElpUeu6wOH02BjCIYM6HLInbN
# HLf6R2qHC1SUsJ02MWNqRNIT6GQL0Xm3LW7E6hDZmR8jlYzhZcDdkdw0cHhXjbOL
# smTeS0SeRJ1WJXEzqt25dbSOaaK7vVmkEVkOHsp16ez49Bc+Ayq/Oh2BAkSTFog4
# 3ldEKgHEDBbCIyba2E8O5lPNan+BQXOLuLMKYS3ikTcp/Qw63dxyDCfgqXYUhxBp
# XnmeSO/WA4NwdwP35lWNhmjIpNVZvhWoxDL+PxDdpph3+M5DroWGTc1ZuDa1iXmO
# FAK4iwTnlWDg3QNRsRa9cnG3FBBpVHnHOEQj4GMkrOHdNDTbonEeGvZ+4nSZXrwC
# W4Wv2qyGDBLlKk3kUW1pIScDCpm/chL6aUbnSsrtbepdtbCLiGanKVR/KC1gsR0t
# C6Q0RfWOI4owggaCMIIEaqADAgECAhA2wrC9fBs656Oz3TbLyXVoMA0GCSqGSIb3
# DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEplcnNleTEUMBIG
# A1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJVU1QgTmV0d29y
# azEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0
# eTAeFw0yMTAzMjIwMDAwMDBaFw0zODAxMTgyMzU5NTlaMFcxCzAJBgNVBAYTAkdC
# MRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVi
# bGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCIndi5RWedHd3ouSaBmlRUwHxJBZvMWhUP2ZQQRLRBQIF3FJmp
# 1OR2LMgIU14g0JIlL6VXWKmdbmKGRDILRxEtZdQnOh2qmcxGzjqemIk8et8sE6J+
# N+Gl1cnZocew8eCAawKLu4TRrCoqCAT8uRjDeypoGJrruH/drCio28aqIVEn45NZ
# iZQI7YYBex48eL78lQ0BrHeSmqy1uXe9xN04aG0pKG9ki+PC6VEfzutu6Q3IcZZf
# m00r9YAEp/4aeiLhyaKxLuhKKaAdQjRaf/h6U13jQEV1JnUTCm511n5avv4N+jSV
# wd+Wb8UMOs4netapq5Q/yGyiQOgjsP/JRUj0MAT9YrcmXcLgsrAimfWY3MzKm1HC
# xcquinTqbs1Q0d2VMMQyi9cAgMYC9jKc+3mW62/yVl4jnDcw6ULJsBkOkrcPLUwq
# j7poS0T2+2JMzPP+jZ1h90/QpZnBkhdtixMiWDVgh60KmLmzXiqJc6lGwqoUqpq/
# 1HVHm+Pc2B6+wCy/GwCcjw5rmzajLbmqGygEgaj/OLoanEWP6Y52Hflef3XLvYnh
# EY4kSirMQhtberRvaI+5YsD3XVxHGBjlIli5u+NrLedIxsE88WzKXqZjj9Zi5ybJ
# L2WjeXuOTbswB7XjkZbErg7ebeAQUQiS/uRGZ58NHs57ZPUfECcgJC+v2wIDAQAB
# o4IBFjCCARIwHwYDVR0jBBgwFoAUU3m/WqorSs9UgOHYm8Cd8rIDZsswHQYDVR0O
# BBYEFPZ3at0//QET/xahbIICL9AKPRQlMA4GA1UdDwEB/wQEAwIBhjAPBgNVHRMB
# Af8EBTADAQH/MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0g
# ADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20vVVNF
# UlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUHAQEE
# KTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMA0GCSqG
# SIb3DQEBDAUAA4ICAQAOvmVB7WhEuOWhxdQRh+S3OyWM637ayBeR7djxQ8SihTnL
# f2sABFoB0DFR6JfWS0snf6WDG2gtCGflwVvcYXZJJlFfym1Doi+4PfDP8s0cqlDm
# dfyGOwMtGGzJ4iImyaz3IBae91g50QyrVbrUoT0mUGQHbRcF57olpfHhQEStz5i6
# hJvVLFV/ueQ21SM99zG4W2tB1ExGL98idX8ChsTwbD/zIExAopoe3l6JrzJtPxj8
# V9rocAnLP2C8Q5wXVVZcbw4x4ztXLsGzqZIiRh5i111TW7HV1AtsQa6vXy633vCA
# bAOIaKcLAo/IU7sClyZUk62XD0VUnHD+YvVNvIGezjM6CRpcWed/ODiptK+evDKP
# U2K6synimYBaNH49v9Ih24+eYXNtI38byt5kIvh+8aW88WThRpv8lUJKaPn37+YH
# Yafob9Rg7LyTrSYpyZoBmwRWSE4W6iPjB7wJjJpH29308ZkpKKdpkiS9WNsf/eeU
# tvRrtIEiSJHN899L1P4l6zKVsdrUu1FX1T/ubSrsxrYJD+3f3aKg6yxdbugot06Y
# wGXXiy5UUGZvOu3lXlxA+fC13dQ5OlL2gIb5lmF6Ii8+CQOYDwXM+yd9dbmocQsH
# jcRPsccUd5E9FiswEqORvz8g3s+jR3SFCgXhN4wz7NgAnOgpCdUo4uDyllU9PzCC
# BuYwggTOoAMCAQICEHe9DgOhtwj4VKsGchDZBEcwDQYJKoZIhvcNAQELBQAwUzEL
# MAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMT
# IEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcyODAwMDAw
# MFoXDTMwMDcyODAwMDAwMFowWTELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2Jh
# bFNpZ24gbnYtc2ExLzAtBgNVBAMTJkdsb2JhbFNpZ24gR0NDIFI0NSBDb2RlU2ln
# bmluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA1kJN
# +eNPxiP0bB2BpjD3SD3P0OWN5SAilgdENV0Gzw8dcGDmJlT6UyNgAqhfAgL3jslu
# Pal4Bb2O9U8ZJJl8zxEWmx97a9Kje2hld6vYsSw/03IGMlxbrFBnLCVNVgY2/MFi
# TH19hhaVml1UulDQsH+iRBnp1m5sPhPCnxHUXzRbUWgxYwr4W9DeullfMa+JaDhA
# PgjoU2dOY7Yhju/djYVBVZ4cvDfclaDEcacfG6VJbgogWX6Jo1gVlwAlad/ewmpQ
# ZU5T+2uhnxgeig5fVF694FvP8gwE0t4IoRAm97Lzei7CjpbBP86l2vRZKIw3ZaEx
# lguOpHZ3FUmEZoIl50MKd1KxmVFC/6Gy3ZzS3BjZwYapQB1Bl2KGvKj/osdjFwb9
# Zno2lAEgiXgfkPR7qVJOak9UBiqAr57HUEL6ZQrjAfSxbqwOqOOBGag4yJ4DKIak
# dKdHlX5yWip7FWocxGnmsL5AGZnL0n1VTiKcEOChW8OzLnqLxN7xSx+MKHkwRX9s
# E7Y9LP8tSooq7CgPLcrUnJiKSm1aNiwv37rL4kFKCHcYiK01YZQS86Ry6+42nqdR
# J5E896IazPyH5ZfhUYdp6SLMg8C3D0VsB+FDT9SMSs7PY7G1pBB6+Q0MKLBrNP4h
# aCdv7Pj6JoRbdULNiSZ5WZ1rq2NxYpAlDQgg8f8CAwEAAaOCAa4wggGqMA4GA1Ud
# DwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzASBgNVHRMBAf8ECDAGAQH/
# AgEAMB0GA1UdDgQWBBTas43AJJCja3fTDKBZ3SFnZHYLeDAfBgNVHSMEGDAWgBQf
# AL9GgAr8eDm3pbRD2VZQu86WOzCBkwYIKwYBBQUHAQEEgYYwgYMwOQYIKwYBBQUH
# MAGGLWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0
# NTBGBggrBgEFBQcwAoY6aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNl
# cnQvY29kZXNpZ25pbmdyb290cjQ1LmNydDBBBgNVHR8EOjA4MDagNKAyhjBodHRw
# Oi8vY3JsLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0NS5jcmwwVgYD
# VR0gBE8wTTBBBgkrBgEEAaAyATIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cu
# Z2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wCAYGZ4EMAQQBMA0GCSqGSIb3DQEB
# CwUAA4ICAQAIiHImxq/6rF8GwKqMkNrQssCil/9uEzIWVP0+9DARn4+Y+ZtS3fKi
# Fu7ZeJWmmnxhuAS1+OvL9GERM/ZlJbcRQovYaW7H/5W0gUOpfq6/gtZNzBGjg3Fq
# EF4ZBafnbH9W9Khcw04JrVlruPl+pS64/N4OwqD7sATUExvHJ6m5qi0xO89GTJ3r
# TOy8Lpzxh6N/OGlfQUBn9lN96kHvjj37qdQROEbfPOv2zSK9E83w4eblM6C+POR4
# 1RvMIPIwc7AiHPaE1ptcAALhKFJL/xJLQOrusBoGBp6E5ufw24RG+3PZK0K2yVc0
# xxbApushuaoO9/7byuu8F8u4Z+vjPk/bqZSGZFXJCQrA2QRxShFLWmTDvHh4rUxH
# JmUHmdXNNmChM1Oz9nsq1YlAPHGlq/iZWf3jm5JL3QW9Cwx4BivPU9i9EppbJ4aF
# P5G+4HiAc1Tfpx1nK2q2rk2JgCQIUnBQ8wH/RK4vmuDhSQjh4VvXONGeCoqdlCeb
# yqO52+I2auNvuVhi4DZ4NgH6waeJeiZTo1y70rLristjCC/+HvNWKeI1m9j/6aW9
# bUtZLIksL1K7tSmQ2kNHvHLdvNm/gMHcsKu0Sx1YNjdk65vhhReaKaL95gjSkv+g
# +Hzh6afRMI5fJlArx6Lil3eK79hNPibrmUBg8zxnDLYIcik1U4E03DCCBzgwggUg
# oAMCAQICDCrufjO3cNcZQRz+KTANBgkqhkiG9w0BAQsFADBZMQswCQYDVQQGEwJC
# RTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEvMC0GA1UEAxMmR2xvYmFsU2ln
# biBHQ0MgUjQ1IENvZGVTaWduaW5nIENBIDIwMjAwHhcNMjMwOTEyMTEwNDEzWhcN
# MjYwOTEyMTEwNDEzWjCBpTELMAkGA1UEBhMCREUxDzANBgNVBAgTBkJheWVybjEV
# MBMGA1UEBwwMVm9oZW5zdHJhdcOfMR0wGwYDVQQKExRtYWtlaG9zdGluZzR5b3Ug
# R21iSDEdMBsGA1UEAxMUbWFrZWhvc3Rpbmc0eW91IEdtYkgxMDAuBgkqhkiG9w0B
# CQEWIUFkbWluaXN0cmF0b3JAbWFrZWhvc3Rpbmc0eW91LmNvbTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBALtTMrUtKKOqUlTOA1Misb5+Kt805fhmqHpg
# dTexof6WrEwbquwPO4oQTWHwyYsRpeOl/Ok3yjKOS0O6/kuXUSsKbPcSYqpwa3kz
# Ki16cW76WQL21N8uAKsx3PT/0n31Mh2NIOSHI+XhbDfsOpNXNM0x8eeCZUZZz7/h
# 3+rbyPMOECmQ7hRZL/ACeRd5NfnB5c/rbdTmbpxKg4olCHL95QEEBvOuxbnsvl9G
# Ky7KVEzTf7UEAYZw0Rdb9h+Lnj37IEqT67AhLMtalEi//EgAiCBlbz9PsvBp4Ru0
# hH6i1Qtxx3jC6eFRwTdyMoNSAsgWuWyVREvm0VR6PDA6VPeFLnvIhEVFCU7Hg4Jf
# CD9a2tViZWArTXt70Bj/RU5GkdVdV7NQbbUNh3zC98Pd3GvXFdHjIGtxw9qQc77J
# XXYWE1LDaI3EvIA1L6QHjXCfcWra9L0M6BO6WSrLQ1MRrzSUMOfaUsYxhI1sXVgl
# WLK4zvoMCkbmYFum4xUTC8ZDopVKlJEU9TAnOtUakCN58ARjlxR9tTwsywFgN1ta
# KQGg0YWU4qpe1qSQ2DLaTAJuCx99Y4eZb/2rwQp66tgCS0K/iPB1ewFYC3LD8qVA
# U91lc0MgxcuXeo2Ku9Y9iGV1Od4T73qDCj3bCABWJ1AmLUrWn0jr7j018Q+h3YDX
# 0JIzyE2RAgMBAAGjggGxMIIBrTAOBgNVHQ8BAf8EBAMCB4AwgZsGCCsGAQUFBwEB
# BIGOMIGLMEoGCCsGAQUFBzAChj5odHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29t
# L2NhY2VydC9nc2djY3I0NWNvZGVzaWduY2EyMDIwLmNydDA9BggrBgEFBQcwAYYx
# aHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVjb2Rlc2lnbmNhMjAy
# MDBWBgNVHSAETzBNMEEGCSsGAQQBoDIBMjA0MDIGCCsGAQUFBwIBFiZodHRwczov
# L3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAIBgZngQwBBAEwCQYDVR0T
# BAIwADBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29t
# L2dzZ2NjcjQ1Y29kZXNpZ25jYTIwMjAuY3JsMBMGA1UdJQQMMAoGCCsGAQUFBwMD
# MB8GA1UdIwQYMBaAFNqzjcAkkKNrd9MMoFndIWdkdgt4MB0GA1UdDgQWBBRwk4UI
# QFC79x5gWgRRZF6ZLt8UhDANBgkqhkiG9w0BAQsFAAOCAgEAdqY37kVk9o/Kb5gs
# c9GqQk3qm8rF/MEyt/0hp93gD6vN7b4zHdrwfh5YV6vP/htWlUaewILYOJTMifAY
# 9E5YKDlVvdaycWPS5Nu6Z+RXN8U/NRmNN83ZI8jt9hzRU8Hyy9fbHwlTciYjUvHw
# L5FLuT/VDX2kfkK9++WYWY7EYLBm2USfM5vqKhLta8vV90pvA+dNdrd3eYPCZg/n
# h/PZkpnuc2weO7STQ1eFQx/os7rPMesX9qm7w2Ukf9EFbE3NXn+zS4DtuHH2R9g7
# 9tvgFJsT88Y7wt31KBr7FA9Zv+seSp8c58+RLWSnn8Gciq9ypLFY2GKIL/zHqyDf
# cuWE/BFEkkSn6zxhBIM5MO+B9mWYHBi6DN/JNQOWCi1fUOvKcyTKVb8i0KDuV2+M
# T6Vt64H7go40oqpcZhAx8C3iTAYSPWzlt+CgO8Iq/lNbT/SEKfCOPvCe1Ko60XTh
# pFoW2hsVOm4dcBZ68V4MQzWXv+jGoQwmpy3vu93LavxOs/sqyUEaedyPgbA03leX
# K4Co0FUjg04phk8hYjLQaA/z30Cub/E3I9HJnjEZYAMfT7ByOXK9erSus0AT774p
# oaI3mEXRBX6vPjG0K46rMajJZeGinHHV4UNULCLR6Rtcg6WDnwokftj0yEbVNCwY
# 3hCn3VjDhfiKgwt8KG0dCx41YhwxggZCMIIGPgIBATBpMFkxCzAJBgNVBAYTAkJF
# MRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMS8wLQYDVQQDEyZHbG9iYWxTaWdu
# IEdDQyBSNDUgQ29kZVNpZ25pbmcgQ0EgMjAyMAIMKu5+M7dw1xlBHP4pMA0GCWCG
# SAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcN
# AQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUw
# LwYJKoZIhvcNAQkEMSIEIInv/cn9SvrmCrhzJWfXPOECMW8ZixZscFr4ezO8nxwE
# MA0GCSqGSIb3DQEBAQUABIICADKo0zmGyFayVnkzaJ3Gj9qQdqNYP/Ka5kVdnz2+
# 30oGWxFCL3bNJWArsNwMKIkybP/8Jllw0xzgCVwMnwsOUElg95SzoG/4FpkmdKLS
# 5NrZy5KgiV8f0IcWMMMUQ1atyvd6xlGNHKABxfE2PHzwwIabMuLBiaQeYTvTPco4
# nozUD0cMo2K/KPC3cQeYIpaQ3mWxCr8Hmat3EGze/acIQPpmGddA8qX7b6MkMBWJ
# r4iba5qoKj41F3KqVRHQStNIxBiGLqlNAaRZfJR3ofrNivZgNqVZlZs0mS97O87K
# jvqHZwp8NgIhm4JljMebWBlWAZZgBvjRZhGu0VY8GcSxnFCox7XKYe+9IryYYSgq
# 6EqFqFZm+LaReTY/oUEJz7kqC8X1GHN7LntdtdwtQIXyW9vt9j0NvRzynbsBlUyU
# OYNi3MhZY2Fmzp9adCG8AauPSp7wLcQXHeR5kG6WOfALlBRAbLq/yFrcHtdYl/je
# faD/lxvfOr5vAgA0OpvdfDl7FVzVibscZi5cNJDW7A7nXCL2OHw4LsivJZv9X65T
# LWUEDH/JWp03O5ekcbnj814qq8RGpW27KuSuXQmi9ZIrqAHA58iIV8Naq58JtoZ7
# 0i76sU6oF16cWPVbrk/HxPdlJDc1KMXJLN1YutuwDO/XIGGzge1X4foDx+PuyRkl
# iYRXoYIDIzCCAx8GCSqGSIb3DQEJBjGCAxAwggMMAgEBMGowVTELMAkGA1UEBhMC
# R0IxGDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDEsMCoGA1UEAxMjU2VjdGlnbyBQ
# dWJsaWMgVGltZSBTdGFtcGluZyBDQSBSMzYCEQCkKTtuHt3XpzQIh616TrckMA0G
# CWCGSAFlAwQCAgUAoHkwGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG
# 9w0BCQUxDxcNMjYwMjA3MTI0NTIzWjA/BgkqhkiG9w0BCQQxMgQwgBmCFfjvB9Nr
# sSUexUmZiTj1Vatc6/vQDqRW8pJO7riYjFJoWC8nYhpDG6mpQXRQMA0GCSqGSIb3
# DQEBAQUABIICADiuJANSKTCEIBzuAtdX9bQJ6JN5SsaqVTBkuDkSwGEa0MI/TAzc
# MhNrH4E0Dj94BYynUfVtQFV1W7maGRSRqaGidB52XjXKcRyDJ9mJQvNxnc809/Va
# VRtMrq+GN9CeMLcOXJGIYZiMNFk8fPiY4peJhRIKpUGVHRgKITFL2SekqvJDtxOm
# ZCNrmNJHTja8yChz25e4A0NGecGwBaGwEtaPGAK92w4Any116qjngYm+BRPT6ZjG
# 9AtqzYTloCwSPQxcF0QB2U1+KwXvGEGRmoVYvp4ZaBTYMBlk88mOT7YmIuVW6UvW
# n74QEgFwDpU5AL5HKITyiO+cicn/9sbfF3e6BMiOJvoxWurEdt8vm2x4N6g2qml7
# HshkWypfoth+WwDC7jkevLLKaySOtjX9WCB4LRY0/t1KjrHZHtwdmC4gz78AeUHZ
# mEkiTl9BuBbBMCz54smCiUWf9lo81zMMUqEECsdEebvaFUI5wuoNIrqXsFfIjlDu
# qJAHP7SjAmiD+ndWtLxrYCTYjrg9P4gUP3EKYdpYNKaGhlGa/kwM07EFLDfD1LlH
# ACZ6dHTZCfiCYXF/zplalwFJrNPNmBdFsArdBn9B17na3d3tnClo8w7YbKPEV0SL
# xfEYSSCqTRmxNiJ6M+9kok5e5VWtRYmZkTwWlnhnTnwuqz/nSMvQ7LkJ
# SIG # End signature block
