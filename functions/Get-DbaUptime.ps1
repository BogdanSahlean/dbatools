function Get-DbaUptime {
	<#
		.SYNOPSIS
			Returns the uptime of the SQL Server instance, and if required the hosting windows server
			
		.DESCRIPTION
			By default, this command returns for each SQL Server instance passed in:
			SQL Instance last startup time, Uptime as a PS TimeSpan, Uptime as a formatted string
			Hosting Windows server last startup time, Uptime as a PS TimeSpan, Uptime as a formatted string
			
		.PARAMETER SqlInstance
			The SQL Server instance that you're connecting to.

		.PARAMETER SqlCredential
			Allows you to login to servers using SQL Logins instead of Windows Authentication (AKA Integrated or Trusted). To use:

			$scred = Get-Credential, then pass $scred object to the -SqlCredential parameter.
			
			Windows Authentication will be used if SqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials.
			
			To connect to SQL Server as a different Windows user, run PowerShell as that user.

		.PARAMETER WindowsCredential
			Allows you to authenticate to Windows servers using alternate credentials.

			$wincred = Get-Credential, then pass $wincred object to the -WindowsCredential parameter.
			
		.PARAMETER Silent
			If this switch is enabled, the internal messaging functions will be silenced.

		.NOTES
			Tags: CIM
			Original Author: Stuart Moore (@napalmgram), stuart-moore.com
			
			dbatools PowerShell module (https://dbatools.io, clemaire@gmail.com)
			Copyright (C) 2016 Chrissy LeMaire
			License: GNU GPL v3 https://opensource.org/licenses/GPL-3.0

		.LINK
			https://dbatools.io/Get-DbaUptime

		.EXAMPLE
			Get-DbaUptime -SqlInstance SqlBox1\Instance2

			Returns an object with SQL Server start time, uptime as TimeSpan object, uptime as a string, and Windows host boot time, host uptime as TimeSpan objects and host uptime as a string for the sqlexpress instance on winserver

		.EXAMPLE
			Get-DbaUptime -SqlInstance winserver\sqlexpress, sql2016

			Returns an object with SQL Server start time, uptime as TimeSpan object, uptime as a string, and Windows host boot time, host uptime as TimeSpan objects and host uptime as a string for the sqlexpress instance on host winserver  and the default instance on host sql2016
			
		.EXAMPLE   
			Get-DbaUptime -SqlInstance sqlserver2014a, sql2016 -SqlOnly

			Returns an object with SQL Server start time, uptime as TimeSpan object, uptime as a string for the sqlexpress instance on host winserver  and the default instance on host sql2016

		.EXAMPLE   
			Get-DbaRegisteredServerName -SqlInstance sql2014 | Get-DbaUptime 

			Returns an object with SQL Server start time, uptime as TimeSpan object, uptime as a string, and Windows host boot time, host uptime as TimeSpan objects and host uptime as a string for every server listed in the Central Management Server on sql2014
			
	#>
	[CmdletBinding(DefaultParameterSetName = "Default")]
	Param (
		[parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[Alias("ServerInstance", "SqlServer", "ComputerName")]
		[DbaInstanceParameter[]]$SqlInstance,
		[Alias("Credential")]
		[PSCredential]$SqlCredential,
		[PSCredential]$WindowsCredential,
		[switch]$Silent
	)
	
	begin {
		$nowutc = (Get-Date).ToUniversalTime()
	}
	process {
		foreach ($instance in $SqlInstance) {
            $SqlOnly = $false;
			if ($instance.Gettype().FullName -eq [System.Management.Automation.PSCustomObject] ) {
				$servername = $instance.SqlInstance
			}
			elseif ($instance.Gettype().FullName -eq [Microsoft.SqlServer.Management.Smo.Server]) {
				$servername = $instance.NetName
			}
			else {
				$servername = $instance.ComputerName;
			}

			try {
				Write-Message -Level Verbose -Message "Connecting to $instance"
				$server = Connect-SqlInstance -SqlInstance $instance -SqlCredential $sqlcredential
			}
			catch {
				Stop-Function -Message "Failure" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
			}
			Write-Message -Level Verbose -Message "Getting start times for $servername"
			#Get tempdb creation date
			$SQLStartTime = $server.Databases["tempdb"].CreateDate
			$SQLUptime = New-TimeSpan -Start $SQLStartTime.ToUniversalTime() -End $nowutc
			$SQLUptimeString = "{0} days {1} hours {2} minutes {3} seconds" -f $($SQLUptime.Days), $($SQLUptime.Hours), $($SQLUptime.Minutes), $($SQLUptime.Seconds)
			
			$WindowsServerName = (Resolve-DbaNetworkName $servername -Credential $WindowsCredential).FullComputerName

			try {
				Write-Message -Level Verbose -Message "Getting WinBootTime via CimInstance for $servername"
				$WinBootTime = (Get-DbaOperatingSystem -ComputerName $windowsServerName -Credential $WindowsCredential -ErrorAction SilentlyContinue).LastBootTime
				$WindowsUptime = New-TimeSpan -start $WinBootTime.ToUniversalTime() -end $nowutc
				$WindowsUptimeString = "{0} days {1} hours {2} minutes {3} seconds" -f $($WindowsUptime.Days), $($WindowsUptime.Hours), $($WindowsUptime.Minutes), $($WindowsUptime.Seconds)
			}
			catch {
				try {
					Write-Message -Level Verbose -Message "Getting WinBootTime via CimInstance DCOM"
					$CimOption = New-CimSessionOption -Protocol DCOM
					$CimSession = New-CimSession -Credential:$WindowsCredential -ComputerName $WindowsServerName -SessionOption $CimOption
					$WinBootTime = ($CimSession | Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
					$WindowsUptime = New-TimeSpan -start $WinBootTime.ToUniversalTime() -end $nowutc
					$WindowsUptimeString = "{0} days {1} hours {2} minutes {3} seconds" -f $($WindowsUptime.Days), $($WindowsUptime.Hours), $($WindowsUptime.Minutes), $($WindowsUptime.Seconds)
				}
				catch {
					$SqlOnly = $true;
					Stop-Function -Message "Failure getting WinBootTime" -ErrorRecord $_ -Target $instance -Continue
				}
			}
				
			$rtn = [PSCustomObject]@{
				ComputerName     = $WindowsServerName
				InstanceName     = $server.ServiceName
				SqlServer        = $server.Name
				SqlUptime        = $SQLUptime
				WindowsUptime    = $WindowsUptime
				SqlStartTime     = $SQLStartTime
				WindowsBootTime  = $WinBootTime
				SinceSqlStart    = $SQLUptimeString
				SinceWindowsBoot = $WindowsUptimeString
			}

			if ($SqlOnly) {
				Select-DefaultView -InputObject $rtn -ExcludeProperty WindowsBootTime,WindowsUptime,SinceWindowsBoot
			}
			else {
				Select-DefaultView -InputObject $rtn -Property ($rtn|get-member -MemberType NoteProperty|select-object -ExpandProperty name)
			}
		}
	}
}
