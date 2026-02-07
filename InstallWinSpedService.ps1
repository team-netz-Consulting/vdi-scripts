<#
    .SYNOPSIS
        Prüft WinSped und installiert/aktiviert den RabbitMQ-Dienst.

    .DESCRIPTION
        Das Skript prüft, ob WinSped installiert ist. Falls ja, wird im
        RabbitMQ-Verzeichnis der Dienst installiert und gestartet.

    .EXAMPLE
        Run as Administrator in einer Umgebung mit WinSped.

    .INPUTS
    .OUTPUTS

    .NOTES
        Author: Felix Schwenke
        Company: team-netz Consulting

    .HISTORY
        Last Change: 17.09.2025 FELSWE: Script created
#>

Begin {
    $Script_Path = $MyInvocation.MyCommand.Path
    $Script_Dir  = Split-Path -Parent $Script_Path
    $Script_Name = [System.IO.Path]::GetFileName($Script_Path)

    # Pfad zur WinSped-Installation (Beispiel, ggf. anpassen)
    $WinSpedPath = "C:\Program Files\LIS\WinSpedClient\WinSped\Bin"

    # Pfad zum RabbitMQ sbin-Verzeichnis
    $RabbitMQPath = "C:\Program Files\RabbitMQ Server\rabbitmq_server-4.1.0\sbin"
}

Process {
    ####################################################################
    ####### Funktionen #####
    ####################################################################

    function Test-WinSpedInstalled {
        param (
            [string]$Path
        )
        if (Test-Path $Path) {
            Write-BISFLog -Msg "WinSped gefunden unter: $Path"
            return $true
        }
        else {
            Write-BISFLog -Msg "WinSped wurde nicht gefunden." -Type W
            return $false
        }
    }

    function Install-RabbitMQService {
        param (
            [string]$SbinPath
        )

        $installBat = Join-Path $SbinPath "rabbitmq-service.bat"

        if (Test-Path $installBat) {
            try {
                Write-BISFLog -Msg "Installiere RabbitMQ-Dienst..."
                Start-Process -FilePath $installBat -ArgumentList "install" -Wait -NoNewWindow
                Write-BISFLog -Msg "RabbitMQ-Dienst erfolgreich installiert."

                Write-BISFLog -Msg "Starte RabbitMQ-Dienst..."
                Start-Process -FilePath $installBat -ArgumentList "start" -Wait -NoNewWindow
                Write-BISFLog -Msg "RabbitMQ-Dienst erfolgreich gestartet."
            }
            catch {
                Write-BISFLog -Msg "Fehler bei der RabbitMQ-Installation: $_" -Type E
            }
        }
        else {
            Write-BISFLog -Msg "rabbitmq-service.bat nicht gefunden unter: $SbinPath" -Type E
        }
    }

    ####################################################################
    ####### Main Execution #####
    ####################################################################

    Write-BISFLog -Msg "Starte Prüfung auf WinSped..."

    if (Test-WinSpedInstalled -Path $WinSpedPath) {
        Install-RabbitMQService -SbinPath $RabbitMQPath
    }

    Write-BISFLog -Msg "Skript abgeschlossen."
}

End {
    Add-BISFFinishLine
}
