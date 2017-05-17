$config = Import-PowerShellDataFile -Path "$PSScriptRoot\Configuration.psd1"
$Defaults = $config.Defaults
$AdToCsvFieldMap = $config.FieldMap

## Load the System.Web type to generate random password
Add-Type -AssemblyName 'System.Web'

function Get-CompanyAdUser
{
	[OutputType([Microsoft.ActiveDirectory.Management.ADUser])]
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$All,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[pscredential]$Credential = $Defaults.Credential,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$DomainController = $Defaults.DomainController,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string[]]$Properties = '*'
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
		Write-Verbose -Message "Finding all enabled AD users in domain with field(s) used: $($Defaults.FieldMatchIds.AD -join ',')"
	}
	process
	{
		try
		{
			## Find all users that have the unique AD ID and are enabled
			$params = @{
				Properties = $Properties
			}
			if ($Credential)
			{
				$params.Credential = $Credential
			}

			if ($DomainController) {
				$params.Server = $DomainController
			}

			if ($All.IsPresent) {
				$params.Filter = '*'
				Get-AdUser @params
			} else {
				$Defaults.FieldMatchIds.AD | foreach {
					$params.LDAPFilter = "(&($($_)=*)(!userAccountControl:1.2.840.113556.1.4.803:=2))"
					Get-AdUser @params
				}
			}
		}
		catch
		{
			Write-Error -Message "Function: $($MyInvocation.MyCommand.Name) Error: $($_.Exception.Message)"
		}
	}
}

function GetCsvColumnHeaders
{
	[OutputType([string])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$CsvFilePath
	)
	
	(Get-Content -Path $CsvFilePath | Select-Object -First 1).Split(',') -replace '"'
}

function TestCsvHeaderExists
{
	[OutputType([bool])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$CsvFilePath = $Defaults.InputCsvFilePath,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string[]]$Header
	)

	$csvHeaders = GetCsvColumnHeaders -CsvFilePath $CsvFilePath
	if (Compare-Object -ReferenceObject $csvHeaders -DifferenceObject $Header) {
		$false
	} else {
		$true
	}
}

function Get-CompanyCsvUser
{
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateScript({Test-Path -Path $_ -PathType Leaf})]
		[string]$CsvFilePath = $Defaults.InputCsvFilePath,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[hashtable]$Exclude
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
		Write-Verbose -Message "Enumerating all users in CSV file [$($CsvFilePath)]"
	}
	process
	{
		try
		{
			$whereFilter = { '*' }
			if ($PSBoundParameters.ContainsKey('Exclude'))
			{
				$conditions = $Exclude.GetEnumerator() | foreach { "(`$_.$($_.Key) -ne '$($_.Value)')" }
				$whereFilter = [scriptblock]::Create($conditions -join ' -and ')
			}
			@(Import-Csv -Path $CsvFilePath).where($whereFilter)
		}
		catch
		{
			Write-Error -Message "Function: $($MyInvocation.MyCommand.Name) Error: $($_.Exception.Message)"
		}
	}
}

function CompareCompanyUser
{
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object[]]$AdUsers,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscustomobject[]]$CsvUsers
	)

	$ErrorActionPreference = 'Stop'
	Write-Verbose -Message "Beginning Company AD <--> CSV compare..."
	Write-Verbose -Message "Found [$(@($AdUsers).Count)] enabled AD users."
	Write-Verbose -Message "Found [$(@($csvUsers).Count)] users in CSV."
	
	@($csvUsers).foreach({
		$output = @{
			CsvUser = $_
			AdUser = $null
			IdMatchedOn = $null
			Match = $false
		}
		if ($adUserMatch = FindUserMatch -AdUsers $AdUsers -CsvUser $_) {
			$output.AdUser = $adUserMatch.MatchedAdUser
			$output.IdMatchedOn = $adUserMatch.IdMatchedOn
			$output.Match = $true 
		}
		[pscustomobject]$output
	})
}

function FindUserMatch
{
	[OutputType()]
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[object[]]$AdUsers,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[object]$CsvUser
	)
	$ErrorActionPreference = 'Stop'

	$Defaults.FieldMatchIds | foreach {
		$adMatchField = $_.AD
		$csvMatchField = $_.CSV
		if ($csvMatchVal = $CsvUser.$csvMatchField) {
			Write-Debug -Message "CsvFieldMatchValue is [$($csvMatchVal)]"
			Write-Debug -Message "AD field match value is $($adMatchField)"
			if ($matchedAdUser = @($AdUsers).where({ $_.$adMatchField -eq $csvMatchVal })) {
				Write-Debug -Message "Found AD match for CSV user [$csvMatchVal]: [$($matchedAdUser.($adMatchField))]"
				[pscustomobject]@{
					MatchedAdUser = $matchedAdUser
					IdMatchedOn = $csvMatchField
				}
				break
			} else {
				Write-Debug -Message "No user match found for CSV user [$csvMatchVal]"
			}
		}
	}
}

function FindAttributeMismatch
{
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[Microsoft.ActiveDirectory.Management.ADUser]$AdUser,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[pscustomobject]$CsvUser
	)

	$ErrorActionPreference = 'Stop'

	Write-Debug "AD-CSV field map values are [$($AdToCsvFieldMap.Values | Out-String)]"
	$csvPropertyNames = $CsvUser.PSObject.Properties.Name
	$AdPropertyNames = $AdUser.PSObject.Properties.Name
	Write-Debug "CSV properties are: [$csvPropertyNames]"
	Write-Debug "ADUser props: [$($AdPropertyNames)]"
	foreach ($csvProp in ($csvPropertyNames | Where { ($_ -in @($AdToCsvFieldMap.Values)) })) {
		
		## Ensure we're going to be checking the value on the correct CSV property and AD attribute
		$matchingAdAttribName = ($AdToCsvFieldMap.GetEnumerator() | where { $_.Value -eq $csvProp }).Name
		Write-Debug -Message "Matching AD attrib name is: [$($matchingAdAttribName)]"
		if ($adAttribMatch = $AdPropertyNames | where { $_ -eq $matchingAdAttribName }) {
			Write-Debug -Message "ADAttribMatch: [$($adAttribMatch)]"
			if (-not $AdUser.$adAttribMatch) {
				$AdUser.$adAttribMatch = ''
			}
			if (-not $CsvUser.$csvProp) {
				$CsvUser.$csvProp = ''
			}
			if ($AdUser.$adAttribMatch -ne $CsvUser.$csvProp) {
				[pscustomobject]@{
					CSVAttributeName = $csvProp
					CSVAttributeValue = $CsvUser.$csvProp
					ADAttributeName = $adAttribMatch
					ADAttributeValue = $AdUser.$adAttribMatch
				}
				Write-Debug -Message "AD attribute mismatch found on CSV property: [$($csvProp)]. Value is [$($AdUser.$adAttribMatch)] and should be [$($CsvUser.$csvProp)]"
			}
		}
	}
}

function SyncCompanyUser
{
	[OutputType()]
	[CmdletBinding(SupportsShouldProcess,ConfirmImpact = 'High')]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[Microsoft.ActiveDirectory.Management.ADUser]$AdUser,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscustomobject]$CsvUser,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscustomobject[]]$Attributes,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Identifier,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[pscredential]$Credential = $Defaults.Credential,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$DomainController = $Defaults.DomainController
	)

	$ErrorActionPreference = 'Stop'

	$replaceHt = @{}
	foreach ($obj in $Attributes) {
		$replaceHt.($obj.ADAttributeName) = $obj.CSVAttributeValue
	}

	$adIdentity = $AdUser.$Identifier

	$params = @{
		Identity = $adIdentity
		Replace = $replaceHt
	}
	if ($Credential) {
		$params.Credential = $Credential
	}
	if ($DomainController) {
		$params.Server = $DomainController
	}
	if ($PSCmdlet.ShouldProcess("User: [$Identifier] AD attribs: $($replaceHt.Keys -join ',')",'Set AD attributes'))
	{
		Write-Debug -Message "Setting the following AD attributes for user [$Identifier]: $($replaceHt | Out-String)"
		Set-AdUser @params	
	}
}

function NewRandomPassword
{
	[CmdletBinding()]
	[OutputType([System.Security.SecureString])]
	param
	(
		[Parameter()]
		[ValidateRange(8, 64)]
		[uint32]$Length = (Get-Random -Minimum 20 -Maximum 32),

		[Parameter()]
		[ValidateRange(0, 8)]
		[uint32]$Complexity = 3
	)

	try
	{
		$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop;

		# Generate a password with the specified length and complexity.
		$password = [System.Web.Security.Membership]::GeneratePassword($Length, $Complexity);

		# Remove any restricted characters that makes the password unfriendly to XML.
		@('"', "'", '<', '>', '&', '/') | ForEach-Object {
			$password = $password.Replace($_, '');
		}

		# Convert the password to a secure string so we don't put plain text passwords on the pipeline.
		[pscustomobject]@{
			SecurePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
			PlainTextPassword = $password
		}
	}
	catch
	{
		Write-Error -Message $_.Exception.Message
	}
}

function WriteLog
{
	[OutputType([void])]
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$FilePath = "$PSScriptRoot\CsvToActiveDirectorySync.log",

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Identifier,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscustomobject[]]$Attributes
	)
	
	$ErrorActionPreference = 'Stop'
	
	$time = Get-Date -Format 'g'
	$Attributes | foreach {
		$_ | Add-Member -MemberType NoteProperty -Name 'Identifier' -Force -Value $Identifier
		$_ | Add-Member -MemberType NoteProperty -Name 'Time' -Force -Value $time
	}
	
	$Attributes | Export-Csv -Path $FilePath -Append -NoTypeInformation

}

function TestNullCsvIdField
{
	[OutputType([bool])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$CsvUser
	)


	if (-not ($Defaults.FieldMatchIds.CSV | where { $CSVUser.$_ })) {
		$false
	} else {
		$true
	}
}

function Invoke-AdSync
{
	[OutputType()]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$CsvFilePath = $Defaults.InputCsvFilePath,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$ReportOnly,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[hashtable]$Exclude
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			$getCsvParams = @{
				CsvFilePath = $CsvFilePath
			}
			if ($PSBoundParameters.ContainsKey('Exclude'))
			{
				if (-not (TestCsvHeaderExists -CsvFilePath $CsvFilePath -Header [array]$Exclude.Keys)) {
					throw 'One or more CSV headers excluded with -Exclude do not exist in the CSV file.'
				}
				$getCsvParams.Exclude = $Exclude
			}
			
			$compParams = @{
				CsvUsers = Get-CompanyCsvUser @getCsvParams
				AdUsers = Get-CompanyAdUser -Properties ([array]$AdToCsvFieldMap.Keys)
			}
			if (-not ($userCompareResults = CompareCompanyUser @compParams)) {
				Write-Warning -Message 'No user compare results returned.'
			} else {
				foreach ($user in $userCompareResults) {
					if ($user.Match) {
						$id = $user.CsvUser.($user.IdMatchedOn)
						Write-Verbose -Message "Match found for user [$(id)]"
						$attribMismatches = FindAttributeMismatch -AdUser $user.ADUser -CsvUser $user.CSVUser
						if ($attribMismatches) {
							$logAttribs = $attribMismatches
							if (-not $ReportOnly.IsPresent) {
								SyncCompanyUser -AdUser $user.ADUser -CsvUser $user.CSVUser -Attributes $attribMismatches -Identifier $user.IdMatchedOn
							}
						} else {
							Write-Verbose -Message "No attributes found to be mismatched between CSV and AD user account for user [$id]"
							$logAttribs = [pscustomobject]@{
								CSVAttributeName = 'AlreadyInSync'
								CSVAttributeValue = 'AlreadyInSync'
								ADAttributeName = 'AlreadyInSync'
								ADAttributeValue = 'AlreadyInSync'
							}
						}
					} else {
						if (-not (TestNullCsvIdField -CsvUser $user.CsvUser)) {
							Write-Warning -Message 'The CSV user identifier field could not be found!'
						} else {
							$ids = $Defaults.FieldMatchIds.CSV | foreach { $user.CSVUser.$_ }
							$id = $ids -join ','
							$logAttribs = ([pscustomobject]@{
								CSVAttributeName = 'NoMatch'
								CSVAttributeValue = 'NoMatch'
								ADAttributeName = 'NoMatch'
								ADAttributeValue = 'NoMatch'
							})
						}
					}
					WriteLog -Identifier $id -Attributes $logAttribs
				}
			}
		}
		catch
		{
			Write-Error -Message "Function: $($MyInvocation.MyCommand.Name) Error: $($_.Exception.Message)"
		}
	}
}