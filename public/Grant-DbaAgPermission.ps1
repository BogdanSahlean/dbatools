function Grant-DbaAgPermission {
    <#
    .SYNOPSIS
        Grants endpoint and availability group permissions to a login.

    .DESCRIPTION
        Grants endpoint and availability group permissions to a login. If the account is a Windows login and does not exist, it will be automatically added.

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Login
        The login or logins to modify.

    .PARAMETER AvailabilityGroup
        Only modify specific availability groups.

    .PARAMETER Type
        Specify type: Endpoint or AvailabilityGroup. Endpoint will modify the DatabaseMirror endpoint type.

    .PARAMETER Permission
        Grants one or more permissions:
            Alter
            Connect
            Control
            CreateSequence
            CreateAnyDatabase
            Delete
            Execute
            Impersonate
            Insert
            Receive
            References
            Select
            Send
            TakeOwnership
            Update
            ViewChangeTracking
            ViewDefinition

            CreateAnyDatabase

        Connect is default.

    .PARAMETER InputObject
        Enables piping from Get-DbaLogin.

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: AG, HA
        Author: Chrissy LeMaire (@cl), netnerds.net

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/Grant-DbaAgPermission

    .EXAMPLE
        PS C:\> Grant-DbaAgPermission -SqlInstance sql2017a -Type AvailabilityGroup -AvailabilityGroup SharePoint -Permission CreateAnyDatabase

        Adds CreateAnyDatabase permissions to the SharePoint availability group on sql2017a. Does not prompt for confirmation.

    .EXAMPLE
        PS C:\> Grant-DbaAgPermission -SqlInstance sql2017a -Type AvailabilityGroup -AvailabilityGroup ag1, ag2 -Permission CreateAnyDatabase -Confirm

        Adds CreateAnyDatabase permissions to the ag1 and ag2 availability groups on sql2017a. Prompts for confirmation.

    .EXAMPLE
        PS C:\> Get-DbaLogin -SqlInstance sql2017a | Out-GridView -Passthru | Grant-DbaAgPermission -Type EndPoint

        Grants the selected logins Connect permissions on the DatabaseMirroring endpoint for sql2017a
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param (
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$SqlCredential,
        [string[]]$Login,
        [string[]]$AvailabilityGroup,
        [parameter(Mandatory)]
        [ValidateSet('Endpoint', 'AvailabilityGroup')]
        [string[]]$Type,
        [ValidateSet('Alter', 'Connect', 'Control', 'CreateAnyDatabase', 'CreateSequence', 'Delete', 'Execute', 'Impersonate', 'Insert', 'Receive', 'References', 'Select', 'Send', 'TakeOwnership', 'Update', 'ViewChangeTracking', 'ViewDefinition')]
        [string[]]$Permission = "Connect",
        [parameter(ValueFromPipeline)]
        [Microsoft.SqlServer.Management.Smo.Login[]]$InputObject,
        [switch]$EnableException
    )
    process {
        if (Test-Bound -Not SqlInstance, InputObject) {
            Stop-Function -Message "You must supply either -SqlInstance or an Input Object"
            return
        }

        if ($Type -contains "Endpoint" -and $SqlInstance -and -not $Login) {
            Stop-Function -Message "You must specify one or more logins when using the Endpoint type together with the SqlInstance parameter."
            return
        }

        if ($Type -contains "AvailabilityGroup" -and -not $AvailabilityGroup) {
            Stop-Function -Message "You must specify at least one availability group when using the AvailabilityGroup type."
            return
        }

        foreach ($instance in $SqlInstance) {
            try {
                $server = Connect-DbaInstance -SqlInstance $instance -SqlCredential $SqlCredential
            } catch {
                Stop-Function -Message "Failure" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }
            if ($Permission -contains "CreateAnyDatabase") {
                foreach ($ag in $AvailabilityGroup) {
                    try {
                        $server.GrantAvailabilityGroupCreateDatabasePrivilege($ag)
                        $server.Alter()
                    } catch {
                        Stop-Function -Message "Failure executing GrantAvailabilityGroupCreateDatabasePrivilege for Availability Group $ag" -ErrorRecord $_ -Target $instance
                        return
                    }
                }
            }
            if ($Login) {
                $InputObject += Get-DbaLogin -SqlInstance $server -SqlCredential $SqlCredential -Login $Login
                foreach ($account in $Login) {
                    if ($account -notin $InputObject.Name) {
                        try {
                            $InputObject += New-DbaLogin -SqlInstance $server -Login $account -EnableException
                        } catch {
                            Stop-Function -Message "Failure creating login $account" -ErrorRecord $_ -Target $instance
                            return
                        }
                    }
                }
            }
        }

        foreach ($account in $InputObject) {
            $server = $account.Parent
            if ($Type -contains "Endpoint") {
                $server.Endpoints.Refresh()
                $endpoint = $server.Endpoints | Where-Object EndpointType -eq DatabaseMirroring

                if (-not $endpoint) {
                    Stop-Function -Message "DatabaseMirroring endpoint does not exist on $server" -Target $server -Continue
                }

                foreach ($perm in $Permission) {
                    if ($Pscmdlet.ShouldProcess($server.Name, "Granting $perm on $endpoint")) {
                        if ($perm -in 'CreateAnyDatabase') {
                            Stop-Function -Message "$perm not supported by endpoints" -Continue
                        }
                        try {
                            $bigperms = New-Object Microsoft.SqlServer.Management.Smo.ObjectPermissionSet([Microsoft.SqlServer.Management.Smo.ObjectPermission]::$perm)
                            $endpoint.Grant($bigperms, $account.Name)
                            [pscustomobject]@{
                                ComputerName = $account.ComputerName
                                InstanceName = $account.InstanceName
                                SqlInstance  = $account.SqlInstance
                                Name         = $account.Name
                                Permission   = $perm
                                Type         = "Grant"
                                Status       = "Success"
                            }
                        } catch {
                            Stop-Function -Message "Failure granting $perm on endpoint to $($account.Name)" -ErrorRecord $_ -Target $account -Continue
                        }
                    }
                }
            }

            if ($Type -contains "AvailabilityGroup") {
                $ags = Get-DbaAvailabilityGroup -SqlInstance $server -AvailabilityGroup $AvailabilityGroup
                foreach ($ag in $ags) {
                    foreach ($perm in $Permission) {
                        if ($perm -notin 'Alter', 'Control', 'TakeOwnership', 'ViewDefinition') {
                            Stop-Function -Message "$perm not supported by availability groups" -Continue
                        }
                        if ($Pscmdlet.ShouldProcess($server.Name, "Granting $perm on $ags")) {
                            try {
                                $bigperms = New-Object Microsoft.SqlServer.Management.Smo.ObjectPermissionSet([Microsoft.SqlServer.Management.Smo.ObjectPermission]::$perm)
                                $ag.Grant($bigperms, $account.Name)
                                [pscustomobject]@{
                                    ComputerName = $account.ComputerName
                                    InstanceName = $account.InstanceName
                                    SqlInstance  = $account.SqlInstance
                                    Name         = $account.Name
                                    Permission   = $perm
                                    Type         = "Grant"
                                    Status       = "Success"
                                }
                            } catch {
                                Stop-Function -Message "Failure granting $perm on availability group $($ag.Name) to $($account.Name)" -ErrorRecord $_ -Target $ag -Continue
                            }
                        }
                    }
                }
            }
        }
    }
}
