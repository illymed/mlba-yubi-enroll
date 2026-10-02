#requires -Version 5.1
# See MLBA-FIDO2-Usage.md for prerequisites, input CSV format, and report handling.

[CmdletBinding()]
param(
	[Alias('i', 'Input')]
	[ValidateScript({ [string]::IsNullOrWhiteSpace($_) -or (Test-Path -LiteralPath $_ -PathType Leaf) })]
	[string]$InputCsv,

	[string]$OutputDirectory = (Join-Path $PSScriptRoot 'run-reports'),

	[string]$EnrollmentLogPath = (Join-Path $PSScriptRoot 'fido2-enrollment-log.csv'),

	[string]$YubiEnrollCommand = 'yubienroll',

	[string]$YkmanCommand = 'ykman',

	[string]$YubiEnrollProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-RunId {
	return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssZ')
}

function Write-OperatorMessage {
	param(
		[Parameter(Mandatory)][string]$Message,
		[ConsoleColor]$Color = [ConsoleColor]::Cyan
	)

	Write-Host $Message -ForegroundColor $Color
}

function Read-Choice {
	param(
		[Parameter(Mandatory)][string]$Prompt,
		[Parameter(Mandatory)][string[]]$AllowedChoices
	)

	$choice = ''
	do {
		$choice = (Read-Host $Prompt).Trim().ToUpperInvariant()
	} while ($AllowedChoices -notcontains $choice)
	return $choice
}

function Invoke-WithRetryChoice {
	param(
		[Parameter(Mandatory)][string]$Operation,
		[Parameter(Mandatory)][scriptblock]$Action
	)

	while ($true) {
		try {
			return (& $Action)
		} catch {
			Write-Warning "$Operation failed: $($_.Exception.Message)"
			Write-OperatorMessage 'ACTION: choose whether to retry or abort.' -Color Yellow
			$choice = Read-Choice -Prompt 'Choose R to retry or A to abort' -AllowedChoices @('R', 'A')
			if ($choice -eq 'A') {
				throw
			}
		}
	}
}

function Invoke-YubiEnrollReadOnlyCommand {
	param(
		[Parameter(Mandatory)][string[]]$Arguments,
		[Parameter(Mandatory)][string]$Description
	)

	$output = @(& $YubiEnrollCommand @Arguments 2>&1 | ForEach-Object { [string]$_ })
	$exitCode = $LASTEXITCODE
	if ($exitCode -ne 0) {
		$details = $output -join [Environment]::NewLine
		throw "$Description failed with exit code $exitCode. $details"
	}

	return [pscustomobject]@{
		Output   = $output
		ExitCode = $exitCode
	}
}

function Write-SafeConfigurationOutput {
	param(
		[Parameter(Mandatory)][string[]]$Lines
	)

	foreach ($line in $Lines) {
		if ($line -match '(?i)^(\s*(?:client[_ -]?secret|secret|access[_ -]?token|refresh[_ -]?token|password|private[_ -]?key)\s*[:=]\s*).+$') {
			Write-Host ($Matches[1] + '[REDACTED]')
		} else {
			Write-Host $line
		}
	}
}

function Confirm-YubiEnrollContext {
	$status = Invoke-YubiEnrollReadOnlyCommand -Arguments @('status') -Description 'YubiEnroll status check'
	$activeProviderMatch = @($status.Output | Where-Object { $_ -match "Active provider set to '([^']+)'" } | Select-Object -First 1)
	if ($activeProviderMatch.Count -eq 0) {
		Write-OperatorMessage 'Could not identify the active provider from YubiEnroll status. Review the output and correct the provider before running enrollment.' -Color Red
		Write-SafeConfigurationOutput -Lines $status.Output
		throw 'The active YubiEnroll provider could not be determined; enrollment was not started.'
	}
	$activeProviderName = [regex]::Match([string]$activeProviderMatch[0], "Active provider set to '([^']+)'").Groups[1].Value

	$providerConfiguration = Invoke-YubiEnrollReadOnlyCommand -Arguments @('providers', 'show', $activeProviderName) -Description "Active provider configuration for '$activeProviderName'"
	$profileConfiguration = Invoke-YubiEnrollReadOnlyCommand -Arguments @('profiles', 'list') -Description 'YubiEnroll profile listing'

	Write-OperatorMessage 'YUBIENROLL PREFLIGHT: status' -Color Yellow
	Write-SafeConfigurationOutput -Lines $status.Output
	Write-OperatorMessage "YUBIENROLL PREFLIGHT: active provider configuration ($activeProviderName)" -Color Yellow
	Write-SafeConfigurationOutput -Lines $providerConfiguration.Output
	Write-OperatorMessage 'YUBIENROLL PREFLIGHT: available profile configuration' -Color Yellow
	Write-SafeConfigurationOutput -Lines $profileConfiguration.Output
	if (-not [string]::IsNullOrWhiteSpace($YubiEnrollProfile)) {
		Write-OperatorMessage "Enrollment profile override requested by this script: $YubiEnrollProfile" -Color Cyan
	} else {
		Write-OperatorMessage 'No -YubiEnrollProfile override supplied; YubiEnroll will use the profile assigned to the active provider, or its interactive defaults.' -Color Cyan
	}
	Write-OperatorMessage 'ACTION: verify the active provider, tenant, authentication status, and effective profile before continuing.' -Color Yellow

	return (Read-Choice -Prompt 'Does this provider and profile configuration look OK? (Y/N)' -AllowedChoices @('Y', 'N')) -eq 'Y'
}

function Write-RunReport {
	param(
		[Parameter(Mandatory)][string]$RunDirectory,
		[Parameter(Mandatory)][string]$RunId,
		[Parameter(Mandatory)][datetime]$StartedUtc,
		[Parameter(Mandatory)]$ReportRows
	)

	$jsonPath = Join-Path $RunDirectory 'run-report.json'
	$csvPath = Join-Path $RunDirectory 'run-report.csv'
	$reportItems = @($ReportRows.ToArray())
	@{
		RunId          = $RunId
		Operator       = "$env:USERDOMAIN\$env:USERNAME"
		StartedUtc     = $StartedUtc.ToString('o')
		CompletedUtc   = (Get-Date).ToUniversalTime().ToString('o')
		InputCsv       = if ([string]::IsNullOrWhiteSpace($InputCsv)) { $null } else { (Resolve-Path -LiteralPath $InputCsv).Path }
		Results        = $reportItems
	} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding utf8

	$csvProperties = @(
		'UserPrincipalName'
		'TicketId'
		'OperatorNote'
		'Status'
		'Stage'
		'Message'
		'ExitCode'
		'CompletedUtc'
		@{ Name = 'DeviceType'; Expression = { if ($null -eq $_.YubiKeyInfo) { '' } else { $_.YubiKeyInfo.DeviceType } } }
		@{ Name = 'SerialNumber'; Expression = { if ($null -eq $_.YubiKeyInfo) { '' } else { $_.YubiKeyInfo.SerialNumber } } }
		@{ Name = 'FirmwareVersion'; Expression = { if ($null -eq $_.YubiKeyInfo) { '' } else { $_.YubiKeyInfo.FirmwareVersion } } }
		@{ Name = 'FormFactor'; Expression = { if ($null -eq $_.YubiKeyInfo) { '' } else { $_.YubiKeyInfo.FormFactor } } }
		@{ Name = 'EnabledUsbInterfaces'; Expression = { if ($null -eq $_.YubiKeyInfo) { '' } else { $_.YubiKeyInfo.EnabledUsbInterfaces } } }
		@{ Name = 'NfcTransportEnabled'; Expression = { if ($null -eq $_.YubiKeyInfo) { '' } else { $_.YubiKeyInfo.NfcTransportEnabled } } }
		@{ Name = 'Fido2Usb'; Expression = { if ($null -eq $_.YubiKeyInfo) { '' } else { $_.YubiKeyInfo.Fido2Usb } } }
		@{ Name = 'Fido2Nfc'; Expression = { if ($null -eq $_.YubiKeyInfo) { '' } else { $_.YubiKeyInfo.Fido2Nfc } } }
		@{ Name = 'TemporaryPin'; Expression = { $_.TemporaryPin } }
	)
	$reportItems | Select-Object -Property $csvProperties |
		Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

	Write-OperatorMessage "Run complete. JSON report: $jsonPath" -Color Green
	Write-OperatorMessage "CSV report: $csvPath" -Color Green
}

function Test-LocalPrerequisites {
	foreach ($commandName in @($YubiEnrollCommand, $YkmanCommand)) {
		$command = Get-Command -Name $commandName -ErrorAction SilentlyContinue
		if ($null -eq $command) {
			throw "Required command was not found: $commandName"
		}
	}

	Write-OperatorMessage 'Required local commands are available. The script will not authenticate or create providers.' -Color Cyan
}

function Get-InputRows {
	$inputMode = ''
	if ([string]::IsNullOrWhiteSpace($InputCsv)) {
		while ($inputMode -notin @('1', '2')) {
			Write-OperatorMessage 'Select input mode:' -Color Yellow
			Write-Host '  1 - Manual single user'
			Write-Host '  2 - CSV user list'
			$inputMode = (Read-Host 'Enter 1 or 2').Trim()
		}
	}

	if ($inputMode -eq '1') {
		$upn = (Read-Host 'Enter the target user principal name (UPN)').Trim().ToLowerInvariant()
		if ([string]::IsNullOrWhiteSpace($upn)) {
			throw 'A user principal name is required when -InputCsv is not provided.'
		}

		return @([pscustomobject]@{
			UserPrincipalName = $upn
			TicketId          = ''
			OperatorNote      = 'Interactive single-user enrollment'
		})
	}
	if ([string]::IsNullOrWhiteSpace($InputCsv)) {
		$script:InputCsv = (Read-Host 'Enter the full path to the CSV file').Trim().Trim('"')
	}
	if (-not (Test-Path -LiteralPath $InputCsv -PathType Leaf)) {
		throw "The input CSV was not found: $InputCsv"
	}

	$rows = @(Import-Csv -LiteralPath $InputCsv)
	if ($rows.Count -eq 0) {
		$firstLine = Get-Content -LiteralPath $InputCsv -TotalCount 1
		if ([string]::IsNullOrWhiteSpace([string]$firstLine)) {
			throw 'The input CSV does not contain any users.'
		}
		if ([string]$firstLine -match '(?i)(^|,)\s*"?UserPrincipalName"?\s*(,|$)') {
			throw 'The input CSV contains a header but no user rows.'
		}
		$rows = @(Import-Csv -LiteralPath $InputCsv -Header UserPrincipalName)
	}
	if ($rows[0].PSObject.Properties.Name -notcontains 'UserPrincipalName') {
		$rows = @(Import-Csv -LiteralPath $InputCsv -Header UserPrincipalName)
	}

	$validRows = foreach ($row in $rows) {
		$upn = ([string]$row.UserPrincipalName).Trim().ToLowerInvariant()
		if ([string]::IsNullOrWhiteSpace($upn)) {
			throw 'Every input row must contain UserPrincipalName.'
		}
		$ticketId = if ($null -ne $row.PSObject.Properties['TicketId']) { ([string]$row.TicketId).Trim() } else { '' }
		$operatorNote = if ($null -ne $row.PSObject.Properties['OperatorNote']) { ([string]$row.OperatorNote).Trim() } else { '' }

		[pscustomobject]@{
			UserPrincipalName = $upn
			TicketId          = $ticketId
			OperatorNote      = $operatorNote
		}
	}

	$duplicates = @($validRows | Group-Object -Property UserPrincipalName | Where-Object Count -gt 1)
	if ($duplicates.Count -gt 0) {
		$names = ($duplicates.Name -join ', ')
		throw "The input CSV contains duplicate users: $names"
	}

	return $validRows
}

function Get-RunMetadata {
	$tenant = (Read-Host 'Enter the tenant').Trim()
	$enrolledByName = (Read-Host 'Enter enrolled-by name').Trim()
	$enrolledByEmail = (Read-Host 'Enter enrolled-by email address').Trim()

	if ([string]::IsNullOrWhiteSpace($tenant) -or [string]::IsNullOrWhiteSpace($enrolledByName) -or [string]::IsNullOrWhiteSpace($enrolledByEmail)) {
		throw 'Tenant, enrolled-by name, and enrolled-by email address are required.'
	}

	[pscustomobject]@{
		Tenant          = $tenant
		EnrolledByName  = $enrolledByName
		EnrolledByEmail = $enrolledByEmail
	}
}

function Get-NextAssetName {
	if (-not (Test-Path -LiteralPath $EnrollmentLogPath -PathType Leaf)) {
		return 'YK-0001'
	}

	$assetNumbers = @(Import-Csv -LiteralPath $EnrollmentLogPath | ForEach-Object {
		if ([string]$_.AssetName -match '^YK-(\d+)$') {
			[int]$Matches[1]
		}
	})
	$maximumAssetNumber = if ($assetNumbers.Count -eq 0) { 0 } else { [int](($assetNumbers | Measure-Object -Maximum).Maximum) }
	$nextNumber = $maximumAssetNumber + 1
	$nextNumberText = ([string]$nextNumber).PadLeft(4, '0')
	return 'YK-' + $nextNumberText
}

function Add-SuccessfulEnrollment {
	param(
		[Parameter(Mandatory)]$InputRow,
		[Parameter(Mandatory)]$Metadata,
		[Parameter(Mandatory)]$YubiKeyInfo,
		[string]$TemporaryPin
	)

	$logDirectory = Split-Path -Parent $EnrollmentLogPath
	if (-not [string]::IsNullOrWhiteSpace($logDirectory)) {
		New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
	}

	$record = [pscustomobject]@{
		TimestampUtc       = (Get-Date).ToUniversalTime().ToString('o')
		AssetName          = Get-NextAssetName
		UserPrincipalName  = $InputRow.UserPrincipalName
		SerialNumber       = $YubiKeyInfo.SerialNumber
		DeviceType         = $YubiKeyInfo.DeviceType
		FirmwareVersion    = $YubiKeyInfo.FirmwareVersion
		FormFactor         = $YubiKeyInfo.FormFactor
		EnabledUsbInterfaces = $YubiKeyInfo.EnabledUsbInterfaces
		Fido2Usb           = $YubiKeyInfo.Fido2Usb
		Fido2Nfc           = $YubiKeyInfo.Fido2Nfc
		TemporaryPin       = $TemporaryPin
		Tenant             = $Metadata.Tenant
		EnrolledByName     = $Metadata.EnrolledByName
		EnrolledByEmail    = $Metadata.EnrolledByEmail
	}

	$logColumns = @(
		'TimestampUtc'
		'AssetName'
		'UserPrincipalName'
		'SerialNumber'
		'DeviceType'
		'FirmwareVersion'
		'FormFactor'
		'EnabledUsbInterfaces'
		'Fido2Usb'
		'Fido2Nfc'
		'TemporaryPin'
		'Tenant'
		'EnrolledByName'
		'EnrolledByEmail'
	)
	$allRecords = @()
	if (Test-Path -LiteralPath $EnrollmentLogPath -PathType Leaf) {
		$allRecords += @(Import-Csv -LiteralPath $EnrollmentLogPath -ErrorAction Stop)
	}
	$allRecords += $record
	$tempLogPath = "$EnrollmentLogPath.$([guid]::NewGuid().ToString('N')).tmp"
	try {
		$allRecords | Select-Object -Property $logColumns | Export-Csv -LiteralPath $tempLogPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
		Move-Item -LiteralPath $tempLogPath -Destination $EnrollmentLogPath -Force -ErrorAction Stop
	} finally {
		if (Test-Path -LiteralPath $tempLogPath -PathType Leaf) {
			Remove-Item -LiteralPath $tempLogPath -Force -ErrorAction SilentlyContinue
		}
	}
	Write-OperatorMessage "Enrollment logged as $($record.AssetName)." -Color Green
}

function Invoke-YubiEnroll {
	param(
		[Parameter(Mandatory)][string]$UserPrincipalName
	)

	$arguments = @('credentials', 'add', $UserPrincipalName)
	if (-not [string]::IsNullOrWhiteSpace($YubiEnrollProfile)) {
		$arguments += @('--profile', $YubiEnrollProfile)
	}

	# Capture stdout line-by-line for the generated PIN while echoing it so the
	# operator still sees YubiEnroll's interactive output. Stderr remains attached.
	$script:LastYubiEnrollTemporaryPin = $null
	$script:LastYubiEnrollExitCode = $null
	& $YubiEnrollCommand @arguments | ForEach-Object {
		$line = [string]$_
		Write-Host $line
		$pinMatch = [regex]::Match($line, '^Temporary PIN:\s*(.+)$')
		if ($pinMatch.Success) {
			$script:LastYubiEnrollTemporaryPin = $pinMatch.Groups[1].Value.Trim()
		}
	}
	$exitCode = $LASTEXITCODE
	$script:LastYubiEnrollExitCode = $exitCode
	if ($exitCode -ne 0) {
		throw "yubienroll returned exit code $exitCode. Review the native command output displayed above."
	}
	if ([string]::IsNullOrWhiteSpace($script:LastYubiEnrollTemporaryPin)) {
		Write-Warning 'Enrollment succeeded, but YubiEnroll output did not contain a recognizable Temporary PIN line; the PIN could not be saved to the inventory or run report.'
	}
}

function Invoke-YkmanInfo {
	$output = @(& $YkmanCommand info 2>&1 | ForEach-Object { [string]$_ })
	$exitCode = $LASTEXITCODE
	if ($exitCode -ne 0) {
		$details = $output -join [Environment]::NewLine
		throw "ykman info failed with exit code $exitCode. $details"
	}

	$deviceType = ''
	$firmwareVersion = ''
	$formFactor = ''
	$enabledUsbInterfaces = ''
	$nfcTransportEnabled = $false
	$fido2Usb = ''
	$fido2Nfc = ''
	$deviceTypeFound = $false
	$firmwareVersionFound = $false
	$fido2InfoFound = $false
	foreach ($line in $output) {
		if ($line -match '^Device type:\s*(.+)$') { $deviceType = $Matches[1].Trim(); $deviceTypeFound = $true }
		elseif ($line -match '^Firmware version:\s*(.+)$') { $firmwareVersion = $Matches[1].Trim(); $firmwareVersionFound = $true }
		elseif ($line -match '^Form factor:\s*(.+)$') { $formFactor = $Matches[1].Trim() }
		elseif ($line -match '^Enabled USB interfaces:\s*(.+)$') { $enabledUsbInterfaces = $Matches[1].Trim() }
		elseif ($line -match '^NFC transport is enabled\s*$') { $nfcTransportEnabled = $true }
		elseif ($line -match '^FIDO2\s+(Enabled|Not available)\s+(Enabled|Not available)\s*$') {
			$fido2Usb = $Matches[1]
			$fido2Nfc = $Matches[2]
			$fido2InfoFound = $true
		}
	}
	if (-not $deviceTypeFound -or -not $firmwareVersionFound -or -not $fido2InfoFound) {
		throw 'ykman info output did not include the expected device type, firmware version, and FIDO2 details.'
	}

	return [pscustomobject]@{
		DeviceType           = $deviceType
		FirmwareVersion      = $firmwareVersion
		FormFactor           = $formFactor
		EnabledUsbInterfaces = $enabledUsbInterfaces
		NfcTransportEnabled  = $nfcTransportEnabled
		Fido2Usb             = $fido2Usb
		Fido2Nfc             = $fido2Nfc
	}
}

function Get-YubiKeySerialNumber {
	$noSerialNumber = 'No Serial Number Detected'
	try {
		$output = @(& $YkmanCommand list --serials 2>&1 | ForEach-Object { [string]$_ })
		$exitCode = $LASTEXITCODE
		if ($exitCode -ne 0) {
			$details = ($output -join [Environment]::NewLine).Trim()
			if ([string]::IsNullOrWhiteSpace($details)) {
				Write-Warning "ykman list --serials failed with exit code $exitCode; serial number was not recorded."
			} else {
				Write-Warning "ykman list --serials failed with exit code ${exitCode}: $details"
			}
			return $noSerialNumber
		}

		$serialNumbers = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^\d+$' })
		if ($serialNumbers.Count -eq 0) {
			if ($output.Count -gt 0) {
				Write-Warning 'ykman list --serials returned output that did not contain a serial number.'
			}
			return $noSerialNumber
		}
		if ($serialNumbers.Count -gt 1) {
			Write-Warning "ykman list --serials returned multiple serial numbers; unable to determine which key was just enrolled. Connect only the intended key to associate a serial."
			return $noSerialNumber
		}

		return $serialNumbers[0]
	} catch {
		Write-Warning "Unable to read the YubiKey serial number: $($_.Exception.Message)"
		return $noSerialNumber
	}
}

function New-ReportRow {
	param(
		[Parameter(Mandatory)]$InputRow,
		[string]$Status,
		[string]$Stage,
		[string]$Message,
		$ExitCode = $null,
		$YubiKeyInfo = $null
	)

	[pscustomobject]@{
		UserPrincipalName = $InputRow.UserPrincipalName
		TicketId          = $InputRow.TicketId
		OperatorNote      = $InputRow.OperatorNote
		Status            = $Status
		Stage             = $Stage
		Message           = $Message
		ExitCode          = $ExitCode
		YubiKeyInfo       = $YubiKeyInfo
		TemporaryPin      = $script:LastYubiEnrollTemporaryPin
		CompletedUtc      = (Get-Date).ToUniversalTime().ToString('o')
	}
}

function Get-QueuedUserSummary {
	param(
		[Parameter(Mandatory)][object[]]$InputRows
	)

	$index = 0
	foreach ($row in $InputRows) {
		$index++
		'{0}. {1}' -f $index, $row.UserPrincipalName
	}
}

function Invoke-Main {
$startedUtc = (Get-Date).ToUniversalTime()
$runId = New-RunId
$runDirectory = Join-Path $OutputDirectory $runId
$reportRows = New-Object 'System.Collections.Generic.List[object]'
$script:LastYubiEnrollTemporaryPin = $null
$script:LastYubiEnrollExitCode = $null

try {
	Invoke-WithRetryChoice -Operation 'Prerequisite validation' -Action { Test-LocalPrerequisites } | Out-Null
	if (-not (Confirm-YubiEnrollContext)) {
		Write-OperatorMessage 'Preflight declined. No enrollment was started.' -Color Red
		return
	}
	$metadata = Invoke-WithRetryChoice -Operation 'Run metadata collection' -Action { Get-RunMetadata }
	$inputRows = @(Invoke-WithRetryChoice -Operation 'Input CSV collection' -Action { Get-InputRows })
	Invoke-WithRetryChoice -Operation 'Run directory creation' -Action { New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null } | Out-Null

	Write-OperatorMessage "Validated $($inputRows.Count) input users. Run ID: $runId" -Color Green
	Write-Host 'Users queued for enrollment:'
	foreach ($queuedUser in @(Get-QueuedUserSummary -InputRows $inputRows)) {
		Write-Host "  $queuedUser"
	}
	Write-OperatorMessage 'ACTION: confirm whether to begin enrollment.' -Color Yellow
	$confirmation = Read-Choice -Prompt 'Continue with enrollment? (Y/N)' -AllowedChoices @('Y', 'N')
	if ($confirmation -eq 'N') {
			Write-OperatorMessage 'Run cancelled before enrollment.' -Color Red
		return
	}

	foreach ($inputRow in $inputRows) {
		$userFinished = $false
		while (-not $userFinished) {
			$stage = 'OperatorConfirmation'
			$ykmanInfo = $null
			$enrollmentSucceeded = $false
			$script:LastYubiEnrollExitCode = $null
			$script:LastYubiEnrollTemporaryPin = $null
			try {
				$confirmation = ''
				$skipUser = $false
				Write-OperatorMessage "ACTION: insert the intended key, then press Enter to inspect and enroll $($inputRow.UserPrincipalName). Type S to skip." -Color Cyan
				do {
					$confirmation = (Read-Host 'Press Enter to continue, or type S').Trim()
					$skipUser = $confirmation -match '^(?i:S|SKIP)$'
					if (-not $skipUser -and -not [string]::IsNullOrWhiteSpace($confirmation)) {
						Write-OperatorMessage 'Press Enter to continue, or type S to skip this user.' -Color Yellow
					}
				} while (-not $skipUser -and -not [string]::IsNullOrWhiteSpace($confirmation))
				if ($skipUser) {
					$reportRows.Add((New-ReportRow -InputRow $inputRow -Status 'Skipped' -Stage 'OperatorConfirmation' -Message 'Operator skipped this user'))
					$userFinished = $true
					continue
				}

				$stage = 'YubiKeyInspection'
				$ykmanInfo = Invoke-WithRetryChoice -Operation "YubiKey inspection for $($inputRow.UserPrincipalName)" -Action { Invoke-YkmanInfo }

				$stage = 'YubiEnroll'
				$script:LastYubiEnrollTemporaryPin = $null
				Invoke-YubiEnroll -UserPrincipalName $inputRow.UserPrincipalName
				$ykmanInfo | Add-Member -NotePropertyName SerialNumber -NotePropertyValue (Get-YubiKeySerialNumber) -Force
				$enrollmentSucceeded = $true
				$exitCode = 0
				$message = 'yubienroll completed'
				$logSaved = $false
				while (-not $logSaved) {
					try {
						Add-SuccessfulEnrollment -InputRow $inputRow -Metadata $metadata -YubiKeyInfo $ykmanInfo -TemporaryPin $script:LastYubiEnrollTemporaryPin
						$logSaved = $true
					} catch {
						$logError = $_.Exception.Message
						Write-Warning "Enrollment succeeded, but the enrollment log could not be updated: $logError"
						Write-OperatorMessage 'ACTION: choose retry logging, continue without logging, or abort.' -Color Yellow
						$logChoice = Read-Choice -Prompt 'Choose R to retry logging, S to continue without logging, or A to abort' -AllowedChoices @('R', 'S', 'A')
						if ($logChoice -eq 'S') {
							$message = "yubienroll completed, but the enrollment log could not be updated: $logError"
							$logSaved = $true
						} elseif ($logChoice -eq 'A') {
							throw
						}
					}
				}
				$reportRows.Add((New-ReportRow -InputRow $inputRow -Status 'Succeeded' -Stage 'Registration' -Message $message -ExitCode $exitCode -YubiKeyInfo $ykmanInfo))
				$userFinished = $true
			} catch {
				if ($enrollmentSucceeded) {
					$postEnrollmentError = $_.Exception.Message
					Write-Warning "Enrollment succeeded for $($inputRow.UserPrincipalName), but a post-enrollment step failed: $postEnrollmentError"
					$reportRows.Add((New-ReportRow -InputRow $inputRow -Status 'Succeeded' -Stage 'Registration' -Message "Enrollment succeeded; post-enrollment step failed: $postEnrollmentError" -ExitCode 0 -YubiKeyInfo $ykmanInfo))
					$userFinished = $true
					continue
				}
				Write-Warning "Failed for $($inputRow.UserPrincipalName): $($_.Exception.Message)"
				Write-OperatorMessage 'ACTION: choose retry, skip, or abort for this user.' -Color Yellow
				$choice = Read-Choice -Prompt 'Choose R to retry this user, S to skip this user, or A to abort' -AllowedChoices @('R', 'S', 'A')
				if ($choice -eq 'S') {
					$reportRows.Add((New-ReportRow -InputRow $inputRow -Status 'Failed' -Stage $stage -Message $_.Exception.Message -ExitCode $script:LastYubiEnrollExitCode -YubiKeyInfo $ykmanInfo))
					$userFinished = $true
				} elseif ($choice -eq 'A') {
					$reportRows.Add((New-ReportRow -InputRow $inputRow -Status 'Failed' -Stage $stage -Message $_.Exception.Message -ExitCode $script:LastYubiEnrollExitCode -YubiKeyInfo $ykmanInfo))
					throw
				}
			}
		}
	}
}
catch {
	Write-Warning "Run stopped: $($_.Exception.Message)"
	Write-OperatorMessage 'Run stopped. Review the report if it was created.' -Color Red
}
finally {
	if (Test-Path -LiteralPath $runDirectory -PathType Container) {
		try {
			Invoke-WithRetryChoice -Operation 'Run report writing' -Action { Write-RunReport -RunDirectory $runDirectory -RunId $runId -StartedUtc $startedUtc -ReportRows $reportRows } | Out-Null
		} catch {
			Write-Error "Could not write the run report: $($_.Exception.Message)"
		}
	}
}

}

if ($MyInvocation.InvocationName -ne '.') {
	Invoke-Main
}






