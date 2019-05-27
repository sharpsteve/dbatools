function Export-DbaLinkedServer {
    <#
    .SYNOPSIS
        Exports linked servers INCLUDING PASSWORDS, unless specified otherwise, to sql file.

    .DESCRIPTION
        Exports linked servers INCLUDING PASSWORDS, unless specified otherwise, to sql file.

        Requires remote Windows access if exporting the password.

    .PARAMETER SqlInstance
        Source SQL Server. You must have sysadmin access and server version must be SQL Server version 2005 or higher.

    .PARAMETER SqlCredential
        Login to the target instance using alternative linked servers. Windows and SQL Authentication supported. Accepts credential objects (Get-Credential)

    .PARAMETER Credential
        Login to the target OS using alternative linked servers. Accepts credential objects (Get-Credential)

    .PARAMETER Path
        The path to the directory that will contain exported sql file.

    .PARAMETER FilePath
       The specific path to a file which will contain the output.

    .PARAMETER LinkedServer
        The linked server(s) to export. If unspecified, all linked servers will be processed.

    .PARAMETER InputObject
        Allow credentials to be piped in from Get-DbaLinkedServer

    .PARAMETER ExcludePassword
        Exports the linked server without any sensitive information.

    .PARAMETER Append
        Append to Path

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: LinkedServer
        Author: Chrissy LeMaire (@cl), netnerds.net

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .EXAMPLE
        PS C:\> Export-DbaLinkedServer -SqlInstance sql2017 -Path C:\temp\ls.sql

        Exports the linked servers, including passwords, from sql2017 to the file C:\temp\ls.sql

    .EXAMPLE
        PS C:\> Export-DbaLinkedServer -SqlInstance sql2017 -Path C:\temp\ls.sql -ExcludePassword

        Exports the linked servers, without passwords, from sql2017 to the file C:\temp\ls.sql

    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [DbaInstanceParameter[]]$SqlInstance,
        [string[]]$LinkedServer,
        [PSCredential]$SqlCredential,
        [PSCredential]$Credential,
        [string]$Path = (Get-DbatoolsConfigValue -FullName 'Path.DbatoolsExport'),
        [string]$FilePath,
        [switch]$ExcludePassword,
        [switch]$Append,
        [Microsoft.SqlServer.Management.Smo.LinkedServer[]]$InputObject,
        [switch]$EnableException
    )
    process {
        foreach ($instance in $SqlInstance) {
            try {
                $server = Connect-SqlInstance -SqlInstance $instance -SqlCredential $sqlcredential -MinimumVersion 9
                $InputObject += $server.LinkedServers
            } catch {
                Stop-Function -Message "Error occurred while establishing connection to $instance" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }

            if ($LinkedServer) {
                $InputObject = $InputObject | Where-Object Name -in $LinkedServer
            }

            if (-not $InputObject) {
                Write-Message -Level Verbose -Message "Nothing to export"
                continue
            }

            if (!(Test-SqlSa -SqlInstance $instance -SqlCredential $sqlcredential)) {
                Stop-Function -Message "Not a sysadmin on $instance. Quitting." -Target $instance -Continue
            }

            Write-Message -Level Verbose -Message "Getting NetBios name for $instance."
            $sourceNetBios = Resolve-NetBiosName $server

            Write-Message -Level Verbose -Message "Checking if Remote Registry is enabled on $instance."
            try {
                Invoke-Command2 -Raw -Credential $Credential -ComputerName $sourceNetBios -ScriptBlock { Get-ItemProperty -Path "HKLM:\SOFTWARE\" } -ErrorAction Stop
            } catch {
                Stop-Function -Message "Can't connect to registry on $instance." -Target $sourceNetBios -ErrorRecord $_
                return
            }

            $timenow = (Get-Date -uformat "%m%d%Y%H%M%S")
            if (-not $FilePath) {
                $FilePath = Join-DbaPath -Path $Path -Child "$($server.name.replace('\', '$'))-$timenow-linkedservers.sql"
            }

            if (Test-Path $Path -PathType Container) {
                $timenow = (Get-Date -uformat "%m%d%Y%H%M%S")
                $filepath = Join-Path -Path $Path -ChildPath "$($server.name.replace('\', '$'))-$timenow-linkedservers.sql"
            } elseif (Test-Path $Path -PathType Leaf) {
                if ($SqlInstance.Count -gt 1) {
                    $timenow = (Get-Date -uformat "%m%d%Y%H%M%S")
                    $PathData = Get-ChildItem $Path
                    $filepath = "$($PathData.DirectoryName)\$($server.name.replace('\', '$'))-$timenow-$($PathData.Name)"
                } else {
                    $filepath = $Path
                }
            }
            $sql = @()

            if ($ExcludePassword) {
                $sql += $InputObject.Script()
            } else {
                try {
                    $decrypted = Get-DecryptedObject -SqlInstance $server -Type LinkedServer
                } catch {
                    Stop-Function -Continue -Message "Failure" -ErrorRecord $_
                }

                foreach ($ls in $InputObject) {
                    $currentls = $decrypted | Where-Object Name -eq $ls.Name
                    if ($currentls.Password) {
                        $tempsql = $ls.Script()
                        foreach ($map in $currentls) {
                            $rmtuser = $map.Identity.Replace("'", "''")
                            $password = $map.Password.Replace("'", "''")
                            $tempsql = $tempsql.Replace(' /* For security reasons the linked server remote logins password is changed with ######## */', '')
                            $tempsql = $tempsql.Replace("rmtuser=N'$rmtuser',@rmtpassword='########'", "rmtuser=N'$rmtuser',@rmtpassword='$password'")
                        }
                        $sql += $tempsql
                    } else {
                        $sql += $ls.Script()
                    }
                }
            }
            try {
                if ($Append) {
                    Add-Content -Path $FilePath -Value $sql
                } else {
                    Set-Content -Path $FilePath -Value $sql
                }
                Get-ChildItem -Path $FilePath
            } catch {
                Stop-Function -Message "Can't write to $FilePath" -ErrorRecord $_ -Continue
            }
        }
    }
}