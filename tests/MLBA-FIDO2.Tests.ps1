# Pester 3.4-compatible tests. These tests mock all external enrollment/device commands.

$scriptUnderTest = Join-Path $PSScriptRoot 'MLBA-FIDO2.ps1'
. $scriptUnderTest

$global:Fido2TestReadHostResponses = @()
$global:Fido2TestYkmanCalls = @()
function global:Read-Host {
	param([string]$Prompt)
	if ($global:Fido2TestReadHostResponses.Count -eq 0) {
		throw "Unexpected Read-Host prompt: $Prompt"
	}
	$response = [string]$global:Fido2TestReadHostResponses[0]
	if ($global:Fido2TestReadHostResponses.Count -gt 1) {
		$global:Fido2TestReadHostResponses = @($global:Fido2TestReadHostResponses | Select-Object -Skip 1)
	} else {
		$global:Fido2TestReadHostResponses = @()
	}
	return $response
}

function global:Write-TestYkmanInfo {
	param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
	$global:LASTEXITCODE = 0
	$global:Fido2TestYkmanCalls += ,(@($Arguments))
	if ($Arguments.Count -gt 0 -and $Arguments[0] -eq 'list') {
		if ($global:Fido2TestYkmanSerialExitCode -ne 0) {
			$global:LASTEXITCODE = $global:Fido2TestYkmanSerialExitCode
			return $global:Fido2TestYkmanSerialOutput
		}
		return $global:Fido2TestYkmanSerialOutput
	}
	@(
		'Device type: Security Key NFC'
		'Firmware version: 5.8.0'
		'Form factor: Keychain (USB-A)'
		'Enabled USB interfaces: FIDO, CCID'
		'NFC transport is enabled'
		'FIDO2 Enabled Enabled'
	)
}

$global:Fido2TestYkmanSerialOutput = @('7654321')
$global:Fido2TestYkmanSerialExitCode = 0

function global:Invoke-TestEnrollment {
	$global:LASTEXITCODE = 0
}

function global:Invoke-TestYubiEnroll {
	param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
	$global:LASTEXITCODE = 0
	$global:Fido2TestYubiEnrollCalls += ,(@($Arguments))
	switch ($Arguments[0]) {
		'status' {
			@(
				"Active provider set to 'Test Provider' using Microsoft Entra ID."
				'Authenticated as test-operator@example.com.'
			)
		}
		'providers' {
			if ($Arguments[1] -eq 'show') {
				@('Provider: Test Provider', 'Tenant ID: 00000000-0000-0000-0000-000000000001', 'Profile: Test Profile', 'Client secret: should-be-redacted')
			} else {
				@('Name Active Provider', 'Test Provider True ENTRA')
			}
		}
		'profiles' { @('Profile Minimum PIN Always UV Reset Random PIN', 'Test Profile 6 True False True') }
		default { throw "Unexpected YubiEnroll read-only command: $($Arguments -join ' ')" }
	}
}

Describe 'MLBA FIDO2 script behavior' {
	It 'shows the numbered menu, retries invalid input, and normalizes manual UPNs' {
		$script:InputCsv = $null
		$global:Fido2TestReadHostResponses = @('invalid', '1', ' Person@Example.COM ')
		$rows = @(Get-InputRows)
		$rows.Count | Should Be 1
		$rows[0].UserPrincipalName | Should Be 'person@example.com'
		$rows[0].OperatorNote | Should Be 'Interactive single-user enrollment'
		$summary = @(Get-QueuedUserSummary -InputRows $rows)
		$summary.Count | Should Be 1
		$summary[0] | Should Be '1. person@example.com'
	}

	It 'loads a headered CSV and preserves ticket and operator notes' {
		$path = Join-Path $TestDrive 'headered.csv'
		@(
			'UserPrincipalName,TicketId,OperatorNote'
			' Person@Example.com ,INC-123,Reviewed'
		) | Set-Content -LiteralPath $path -Encoding UTF8
		$script:InputCsv = $path
		$rows = @(Get-InputRows)
		$rows.Count | Should Be 1
		$rows[0].UserPrincipalName | Should Be 'person@example.com'
		$rows[0].TicketId | Should Be 'INC-123'
		$rows[0].OperatorNote | Should Be 'Reviewed'
		$summary = @(Get-QueuedUserSummary -InputRows $rows)
		$summary[0] | Should Be '1. person@example.com'
	}

	It 'accepts a headerless single-column CSV through menu option 2' {
		$path = Join-Path $TestDrive 'headerless.csv'
		'test@example.com' | Set-Content -LiteralPath $path -Encoding UTF8
		$script:InputCsv = $null
		$global:Fido2TestReadHostResponses = @('invalid', '2', $path)
		$rows = @(Get-InputRows)
		$rows.Count | Should Be 1
		$rows[0].UserPrincipalName | Should Be 'test@example.com'
	}

	It 'lists every CSV user in queue order' {
		$inputRows = @(
			[pscustomobject]@{ UserPrincipalName = 'first@example.com' }
			[pscustomobject]@{ UserPrincipalName = 'second@example.com' }
	)
		$summary = @(Get-QueuedUserSummary -InputRows $inputRows)
		$summary.Count | Should Be 2
		$summary[0] | Should Be '1. first@example.com'
		$summary[1] | Should Be '2. second@example.com'
	}

	It 'rejects duplicate normalized UPNs' {
		$path = Join-Path $TestDrive 'duplicates.csv'
		@(
			'UserPrincipalName'
			'Test@example.com'
			' test@EXAMPLE.com '
		) | Set-Content -LiteralPath $path -Encoding UTF8
		$script:InputCsv = $path
		$threw = $false
		try { Get-InputRows | Out-Null } catch { $threw = $true }
		$threw | Should Be $true
	}

	It 'rejects empty and header-only CSV files' {
		$emptyPath = Join-Path $TestDrive 'empty.csv'
		'' | Set-Content -LiteralPath $emptyPath -Encoding UTF8
		$script:InputCsv = $emptyPath
		$threw = $false
		try { Get-InputRows | Out-Null } catch { $threw = $true }
		$threw | Should Be $true

		$headerPath = Join-Path $TestDrive 'header-only.csv'
		'UserPrincipalName,TicketId' | Set-Content -LiteralPath $headerPath -Encoding UTF8
		$script:InputCsv = $headerPath
		$threw = $false
		try { Get-InputRows | Out-Null } catch { $threw = $true }
		$threw | Should Be $true
	}

	It 'extracts the selected YubiKey fields without writing inspection output' {
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$info = Invoke-YkmanInfo
		$info.DeviceType | Should Be 'Security Key NFC'
		$info.FirmwareVersion | Should Be '5.8.0'
		$info.FormFactor | Should Be 'Keychain (USB-A)'
		$info.NfcTransportEnabled | Should Be $true
		$info.Fido2Usb | Should Be 'Enabled'
		$info.Fido2Nfc | Should Be 'Enabled'
	}

	It 'rejects ykman output that does not contain the expected fields' {
		function global:Write-TestBadYkmanInfo {
			$global:LASTEXITCODE = 0
			'Unexpected output'
		}
		$script:YkmanCommand = 'Write-TestBadYkmanInfo'
		$threw = $false
		try { Invoke-YkmanInfo | Out-Null } catch { $threw = $true }
		$threw | Should Be $true
		$script:YkmanCommand = 'Write-TestYkmanInfo'
	}

	It 'captures one serial number from ykman list --serials' {
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$global:Fido2TestYkmanCalls = @()
		$global:Fido2TestYkmanSerialOutput = @('  7654321  ')
		$global:Fido2TestYkmanSerialExitCode = 0
		Get-YubiKeySerialNumber | Should Be '7654321'
		($global:Fido2TestYkmanCalls[0] -join ' ') | Should Be 'list --serials'
	}

	It 'records the explicit no-serial marker when ykman returns no output' {
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$global:Fido2TestYkmanSerialOutput = @()
		$global:Fido2TestYkmanSerialExitCode = 0
		Get-YubiKeySerialNumber | Should Be 'No Serial Number Detected'
	}

	It 'does not treat unexpected text as a serial number' {
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$global:Fido2TestYkmanSerialOutput = @('No devices found')
		$global:Fido2TestYkmanSerialExitCode = 0
		Get-YubiKeySerialNumber | Should Be 'No Serial Number Detected'
	}

	It 'does not assign a serial when ykman returns multiple keys' {
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$global:Fido2TestYkmanSerialOutput = @('1111111', '2222222')
		$global:Fido2TestYkmanSerialExitCode = 0
		Get-YubiKeySerialNumber | Should Be 'No Serial Number Detected'
	}

	It 'keeps enrollment successful when the serial lookup command fails' {
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$global:Fido2TestYkmanSerialOutput = @('serial listing unavailable')
		$global:Fido2TestYkmanSerialExitCode = 1
		Get-YubiKeySerialNumber | Should Be 'No Serial Number Detected'
	}

	It 'captures the PIN from native YubiEnroll output without prompting the operator' {
		$commandPath = Join-Path $TestDrive 'mock-yubienroll.cmd'
		@(
			'@echo off'
			'echo YubiEnroll prompt on stderr>&2'
			'echo YubiKey configuration summary:'
			'echo Temporary PIN: CAPTURED-5678'
			'exit /b 0'
		) | Set-Content -LiteralPath $commandPath -Encoding ASCII
		$script:YubiEnrollCommand = $commandPath
		$script:YubiEnrollProfile = $null
		Invoke-YubiEnroll -UserPrincipalName 'capture@example.com'
		$script:LastYubiEnrollTemporaryPin | Should Be 'CAPTURED-5678'
	}

	It 'shows active YubiEnroll status and configuration, then honors a no confirmation' {
		$script:YubiEnrollCommand = 'Invoke-TestYubiEnroll'
		$global:Fido2TestYubiEnrollCalls = @()
		$global:Fido2TestReadHostResponses = @('N')
		$confirmed = Confirm-YubiEnrollContext
		$confirmed | Should Be $false
		$global:Fido2TestYubiEnrollCalls.Count | Should Be 3
		($global:Fido2TestYubiEnrollCalls[0] -join ' ') | Should Be 'status'
		($global:Fido2TestYubiEnrollCalls[1] -join ' ') | Should Be 'providers show Test Provider'
		($global:Fido2TestYubiEnrollCalls[2] -join ' ') | Should Be 'profiles list'
	}

	It 'stops before metadata and report setup when provider preflight is declined' {
		$script:YubiEnrollCommand = 'Invoke-TestYubiEnroll'
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$script:InputCsv = $null
		$script:OutputDirectory = Join-Path $TestDrive 'declined-preflight-reports'
		$global:Fido2TestYubiEnrollCalls = @()
		$global:Fido2TestReadHostResponses = @('N')
		Invoke-Main
		Test-Path -LiteralPath $script:OutputDirectory | Should Be $false
		$global:Fido2TestYubiEnrollCalls.Count | Should Be 3
	}

	It 'writes temporary PINs and operator notes to run reports' {
		$script:InputCsv = $null
		$script:LastYubiEnrollTemporaryPin = 'TEST-PIN-1234'
		$inputRow = [pscustomobject]@{
			UserPrincipalName = 'test@example.com'
			TicketId = 'INC-9'
			OperatorNote = 'Reviewed'
		}
		$rows = New-Object 'System.Collections.Generic.List[object]'
		$rows.Add((New-ReportRow -InputRow $inputRow -Status 'Succeeded' -Stage 'Registration' -Message 'ok' -ExitCode 0))
		$runDirectory = Join-Path $TestDrive 'reports'
		New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
		Write-RunReport -RunDirectory $runDirectory -RunId 'test-run' -StartedUtc (Get-Date).ToUniversalTime() -ReportRows $rows
		$json = Get-Content -LiteralPath (Join-Path $runDirectory 'run-report.json') -Raw
		$csv = Get-Content -LiteralPath (Join-Path $runDirectory 'run-report.csv') -Raw
		$json | Should Match 'TEST-PIN-1234'
		$csv | Should Match 'TEST-PIN-1234'
		$csv | Should Match 'OperatorNote'
		$csv | Should Match 'Reviewed'
	}

	It 'increments the asset sequence and persists the captured PIN' {
		$path = Join-Path $TestDrive 'enrollment-log.csv'
		@(
			'AssetName'
			'YK-0014'
		) | Set-Content -LiteralPath $path -Encoding UTF8
		$script:EnrollmentLogPath = $path
		$inputRow = [pscustomobject]@{ UserPrincipalName = 'test@example.com' }
		$metadata = [pscustomobject]@{ Tenant = 'Tenant'; EnrolledByName = 'Operator'; EnrolledByEmail = 'operator@example.com' }
		$keyInfo = [pscustomobject]@{
			SerialNumber = '7654321'
			DeviceType = 'Security Key NFC'
			FirmwareVersion = '5.8.0'
			FormFactor = 'Keychain (USB-A)'
			EnabledUsbInterfaces = 'FIDO, CCID'
			Fido2Usb = 'Enabled'
			Fido2Nfc = 'Enabled'
		}
		$script:LastYubiEnrollTemporaryPin = 'PIN-TO-PERSIST-3499'
		Add-SuccessfulEnrollment -InputRow $inputRow -Metadata $metadata -YubiKeyInfo $keyInfo -TemporaryPin $script:LastYubiEnrollTemporaryPin
		$log = Get-Content -LiteralPath $path -Raw
		$log | Should Match 'YK-0015'
		$log | Should Match 'TemporaryPin'
		$log | Should Match 'PIN-TO-PERSIST-3499'
		$log | Should Match 'SerialNumber'
		$log | Should Match '7654321'
	}

	It 'reports a failed enrollment exit code and continues to the next user' {
		$inputPath = Join-Path $TestDrive 'integration-users.csv'
		@(
			'UserPrincipalName,TicketId,OperatorNote'
			'first@example.com,INC-1,First row'
			'second@example.com,INC-2,Second row'
		) | Set-Content -LiteralPath $inputPath -Encoding UTF8
		$script:InputCsv = $inputPath
		$script:YubiEnrollCommand = 'Invoke-TestYubiEnroll'
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$script:OutputDirectory = Join-Path $TestDrive 'integration-reports'
		$script:EnrollmentLogPath = Join-Path $TestDrive 'integration-log.csv'
		$global:Fido2TestYkmanSerialOutput = @('1234567')
		$global:Fido2TestYkmanSerialExitCode = 0
		$global:Fido2TestReadHostResponses = @('Y', 'Test Tenant', 'Operator', 'operator@example.com', 'Y', '', 'S', '')
		$global:Fido2TestEnrollCount = 0
		$originalYubiEnroll = (Get-Command Invoke-YubiEnroll -CommandType Function).ScriptBlock
		Set-Item -Path Function:\Invoke-YubiEnroll -Value {
			$global:Fido2TestEnrollCount++
			if ($global:Fido2TestEnrollCount -eq 1) {
				$script:LastYubiEnrollExitCode = 23
				throw 'Mock enrollment failure'
			}
			$script:LastYubiEnrollExitCode = 0
			$script:LastYubiEnrollTemporaryPin = 'AUTO-CAPTURED-PIN'
		}
		Invoke-Main
		Set-Item -Path Function:\Invoke-YubiEnroll -Value $originalYubiEnroll

		$runDirectory = Get-ChildItem -LiteralPath $script:OutputDirectory -Directory | Select-Object -First 1
		$report = Get-Content -LiteralPath (Join-Path $runDirectory.FullName 'run-report.json') -Raw | ConvertFrom-Json
		$report.Results.Count | Should Be 2
		$report.Results[0].Status | Should Be 'Failed'
		$report.Results[0].ExitCode | Should Be 23
		$report.Results[1].Status | Should Be 'Succeeded'
		$report.Results[1].TemporaryPin | Should Be 'AUTO-CAPTURED-PIN'
		$report.Results[1].YubiKeyInfo.SerialNumber | Should Be '1234567'
		$log = Get-Content -LiteralPath $script:EnrollmentLogPath -Raw
		$log | Should Match 'AUTO-CAPTURED-PIN'
		$log | Should Match '1234567'
		$csv = Get-Content -LiteralPath (Join-Path $runDirectory.FullName 'run-report.csv') -Raw
		$csv | Should Match 'SerialNumber'
		$csv | Should Match '1234567'
	}

	It 'records the failed row and exit code when the operator aborts' {
		$inputPath = Join-Path $TestDrive 'abort-user.csv'
		@('UserPrincipalName', 'abort@example.com') | Set-Content -LiteralPath $inputPath -Encoding UTF8
		$script:InputCsv = $inputPath
		$script:YubiEnrollCommand = 'Invoke-TestYubiEnroll'
		$script:YkmanCommand = 'Write-TestYkmanInfo'
		$script:OutputDirectory = Join-Path $TestDrive 'abort-reports'
		$script:EnrollmentLogPath = Join-Path $TestDrive 'abort-log.csv'
		$global:Fido2TestReadHostResponses = @('Y', 'Test Tenant', 'Operator', 'operator@example.com', 'Y', '', 'A')
		Set-Item -Path Function:\Invoke-YubiEnroll -Value {
			$script:LastYubiEnrollExitCode = 42
			throw 'Mock enrollment failure'
		}
		Invoke-Main

		$runDirectory = Get-ChildItem -LiteralPath $script:OutputDirectory -Directory | Select-Object -First 1
		$report = Get-Content -LiteralPath (Join-Path $runDirectory.FullName 'run-report.json') -Raw | ConvertFrom-Json
		$report.Results.Count | Should Be 1
		$report.Results[0].Status | Should Be 'Failed'
		$report.Results[0].ExitCode | Should Be 42
		$report.Results[0].UserPrincipalName | Should Be 'abort@example.com'
	}
}
