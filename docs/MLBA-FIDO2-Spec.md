# MLBA-FIDO2 Specification

Source of truth for `src/MLBA-FIDO2.ps1`. Edit this document, then ask for the script (and tests) to be updated to match. Each requirement has a stable ID (e.g. `FLOW-3`) so edits can reference it. Sections marked **[Current]** describe present behavior; change them to change the script.

## 1. Purpose and Scope

Bulk pre-provision FIDO2 YubiKeys for Microsoft 365 users by driving the locally installed `yubienroll` and `ykman` CLIs, one key at a time, with an operator at the workstation.

In scope:
- Collect users (single or CSV), run metadata, and operator confirmations.
- Preflight display of the YubiEnroll provider and the script's built-in enrollment profile table for operator review.
- Inspect each key with `ykman`, enroll with `yubienroll`, record serial and temporary PIN.
- Produce per-run JSON/CSV reports and a persistent inventory log.

Out of scope (the script must not):
- Use Microsoft Graph, authenticate to YubiEnroll, create/switch providers, or create app registrations.
- Change tenant FIDO2 policy or verify registration in Entra ID.
- Issue its own factory-reset command (the YubiEnroll profile may reset the key).
- Run unattended, or offer a dry-run/test mode.
- Validate UPNs against Entra ID.
- Record AAGUIDs.

## 2. Environment and Dependencies

- ENV-1 Windows PowerShell 5.1+ (`#requires -Version 5.1`); PowerShell 7 also supported.
- ENV-2 `yubienroll` on `PATH` or supplied via `-YubiEnrollCommand`.
- ENV-3 `ykman` on `PATH` or supplied via `-YkmanCommand`.
- ENV-4 YubiEnroll provider already configured and logged in by the operator. No YubiEnroll profile is required; the script supplies settings per key (section 7.4).
- ENV-5 Tenant FIDO2 policy already allows the key's AAGUID.
- ENV-6 One tenant per run (tenant is free-text metadata only; not validated).
- ENV-7 Strict mode on (`Set-StrictMode -Version Latest`), `$ErrorActionPreference = 'Stop'`.
- ENV-8 `Invoke-Main` runs only when the script is invoked, not dot-sourced (so tests can load functions).

## 3. Parameters **[Current]**

| Parameter | Alias | Type | Default | Notes |
|---|---|---|---|---|
| `-InputCsv` | `-i`, `-Input` | string | none | Must be an existing file if provided. If omitted, the input-mode menu is shown. |
| `-OutputDirectory` | | string | `<script-root>\run-reports` | Parent of per-run folders. |
| `-EnrollmentLogPath` | | string | `<script-root>\fido2-enrollment-log.csv` | Persistent inventory log. |
| `-YubiEnrollCommand` | | string | `yubienroll` | Name or full path. |
| `-YkmanCommand` | | string | `ykman` | Name or full path. |
| `-YubiEnrollProfile` | | string | none | Override: use this YubiEnroll-side profile (`--profile <name> --force`) for every key instead of the built-in model profiles. |

## 4. Run Flow **[Current]**

```text
Start
 -> FLOW-1  Generate Run ID (UTC yyyyMMdd-HHmmssZ), compute run directory
 -> FLOW-2  Prerequisite check (both commands resolvable)            [retry/abort]
 -> FLOW-3  YubiEnroll preflight + confirmation (Y/N)                 N => exit, nothing created
 -> FLOW-4  Collect run metadata (tenant, enrolled-by name, email)    [retry/abort]
 -> FLOW-5  Collect input rows (menu / CSV)                           [retry/abort]
 -> FLOW-6  Create run directory                                      [retry/abort]
 -> FLOW-7  Show queued users, "Continue with enrollment? (Y/N)"      N => exit
 -> FLOW-8  Per-user loop (section 5)
 -> FLOW-9  Always (finally): if run directory exists, write reports  [retry/abort]
```

- FLOW-2 Missing command throws; operator chooses `R` retry or `A` abort.
- FLOW-3 Runs read-only: `yubienroll status` and `yubienroll providers show <active-provider>`, then prints the built-in profile table (or the `-YubiEnrollProfile` override notice). Active provider is parsed from the status line `Active provider set to '<name>'`. If it cannot be parsed, the run stops with output shown. Output lines matching secret-like keys (`client_secret`, `secret`, `access_token`, `refresh_token`, `password`, `private_key`) are redacted. Prompt: `Does this provider and profile configuration look OK? (Y/N)`. `N` stops before metadata, report directory creation, key inspection, or enrollment.
- FLOW-4 All three metadata values are required and trimmed. This data is not used to validate the operator or tenant.
- FLOW-7 Accepts only `Y` or `N` (case-insensitive).
- FLOW-9 Reports are written even when the run is aborted or fails after the run directory was created.
- FLOW-10 Any unhandled error prints `Run stopped: <message>`; remaining users are not processed.

## 5. Per-User Flow **[Current]**

For each input row, in order:

1. USER-1 Prompt: insert the intended key, press Enter to continue or `S`/`SKIP` to skip. Any other text re-prompts.
2. USER-2 Skip => record `Skipped` / stage `OperatorConfirmation` / message `Operator skipped this user`; next user.
3. USER-3 Stage `YubiKeyInspection`: run `ykman info` (output captured, not shown). Failure => retry/abort prompt (`R`/`A`) around inspection.
4. USER-3a Stage `ProfileSelection` (skipped when `-YubiEnrollProfile` is set): choose the built-in profile for the detected device type (section 7.4). No match => failure handled per USER-8.
5. USER-4 Stage `YubiEnroll`: run `yubienroll credentials add <UPN>` with the profile's settings as flags plus `--force` (or `--profile <name> --force` for the override). Stdout is streamed live to the console; stderr is read concurrently and echoed afterwards. Both are scanned for a PIN line (`[Temporary|Random|New|Generated] PIN: <value>`, ANSI codes stripped). Non-zero exit code => failure. Missing PIN line on success => warning only.
6. USER-5 Immediately after success (key still connected) run `ykman list --serials` and attach the serial to the key info.
7. USER-6 Append to the persistent enrollment log (section 7). On failure, operator may `R` retry logging, `S` continue without logging, or `A` abort.
8. USER-7 Record `Succeeded` / stage `Registration` / message `yubienroll completed`.

Failure handling per user:
- USER-8 Any failure before enrollment success: warn, then prompt `R` retry this user, `S` skip, or `A` abort.
- USER-9 `S` after failure records `Failed` (not `Skipped`) with the failing stage, message, and exit code if any.
- USER-10 `A` records `Failed`, then aborts the run.
- USER-11 A failure after enrollment succeeded (e.g. serial lookup or logging abort) records `Succeeded` with a message noting the post-enrollment failure, and does not offer retry (avoids re-enrolling).
- USER-12 A failed user never stops later rows unless the operator chooses abort.

## 6. Input **[Current]**

- IN-1 If `-InputCsv` is omitted, show menu: `1` manual single user, `2` CSV. Repeat until `1` or `2`.
- IN-2 Manual mode: prompt for one UPN; trimmed, lowercased; blank is an error. Row gets `OperatorNote = 'Interactive single-user enrollment'`, empty `TicketId`.
- IN-3 CSV mode: if no `-InputCsv`, prompt for a full path (surrounding quotes stripped); file must exist.
- IN-4 CSV formats accepted: with header (`UserPrincipalName`, optional `TicketId`, `OperatorNote`), or headerless with one UPN in column A.
- IN-5 A header-only file or an empty file is an error.
- IN-6 UPNs are trimmed and lowercased. Blank UPN => error. Duplicate UPNs => error. All before any enrollment.
- IN-7 The input file is never modified. UPNs are not validated beyond the above.

## 7. Outputs **[Current]**

### 7.1 Run report

Location: `<OutputDirectory>\<run-id>\run-report.json` and `run-report.csv`.

- OUT-1 JSON: `RunId`, `Operator` (`DOMAIN\user`), `StartedUtc`, `CompletedUtc`, `InputCsv` (resolved path or null), `Results[]`.
- OUT-2 Result fields: `UserPrincipalName`, `TicketId`, `OperatorNote`, `Status` (`Succeeded`/`Failed`/`Skipped`), `Stage`, `Message`, `ExitCode`, `YubiKeyInfo`, `TemporaryPin`, `CompletedUtc`.
- OUT-3 CSV is flattened: the fields above plus `DeviceType`, `SerialNumber`, `FirmwareVersion`, `FormFactor`, `EnabledUsbInterfaces`, `NfcTransportEnabled`, `Fido2Usb`, `Fido2Nfc`, `EnrollmentProfile`, `TemporaryPin`. Encoding UTF-8.
- OUT-4 Full YubiEnroll output is not captured, only the temporary PIN line.

### 7.2 Persistent enrollment log

Location: `-EnrollmentLogPath`, CSV, appended across runs.

- LOG-1 Columns, in order: `TimestampUtc`, `AssetName`, `UserPrincipalName`, `SerialNumber`, `DeviceType`, `FirmwareVersion`, `FormFactor`, `EnabledUsbInterfaces`, `Fido2Usb`, `Fido2Nfc`, `TemporaryPin`, `Tenant`, `EnrolledByName`, `EnrolledByEmail`, `EnrollmentProfile`.
- LOG-2 Only successful enrollments are logged.
- LOG-3 `AssetName` is `YK-NNNN` (zero-padded to 4): max existing number + 1; `YK-0001` if the log is absent or has none.
- LOG-4 Write is atomic: whole log rewritten to a temp file in the same folder, then moved over the original; temp file removed on failure. Older rows missing newer columns are rewritten with blanks.
- LOG-5 The log directory is created if missing.

### 7.4 Enrollment profiles

- PROF-1 Profiles live in `$script:EnrollmentProfiles` at the top of the script: `Name`, `DeviceTypePattern` (regex against `Device type`), `MinPinLength`, `RequireAlwaysUv`, `RequireEa`, `ForcePinChange`, `Reset`, `RandomPin`, `RandomPinLength`. First match wins.
- PROF-2 Shipped profiles: `YubiKey Security Key Line` (`^Security Key`; always-UV on, force PIN change on) and `YubiKey 5 Nano` (`^YubiKey 5 Nano`; always-UV off, force PIN change off). Both: min PIN 4, no EA, reset on, random PIN length 4. Other models fail with a no-match error until a profile is added.
- PROF-3 Settings are passed as explicit flags (`--no-...` for false values), so no YubiEnroll-side profile needs to exist.
- PROF-4 The profile name used is recorded in `EnrollmentProfile` in both reports and the log.

### 7.3 Key information (`ykman info` parsing)

- KEY-1 Parsed fields: `Device type`, `Firmware version`, `Form factor`, `Enabled USB interfaces`, `NFC transport is enabled`, and the `FIDO2` line (USB/NFC: `Enabled` or `Not available`).
- KEY-2 Device type, firmware version, and the FIDO2 line are required; if missing, inspection fails.
- KEY-3 Serial from `ykman list --serials`: exactly one numeric line => that serial. Otherwise (command error, no output, non-numeric output, multiple serials) => `No Serial Number Detected`, with a warning when anomalous.
- KEY-4 Not parsed or enforced: AAGUID, PIN state, credential capacity, model/firmware allow-list.

## 8. Security and Data Handling **[Current]**

- SEC-1 Temporary PINs are stored in plaintext in both the run reports and the enrollment log. Both are credential-bearing: restrict access, protect at rest, apply retention/deletion, never attach to tickets or send by ordinary email.
- SEC-2 Secret-like fields in displayed provider configuration are redacted at display time.
- SEC-3 PINs are delivered to users through the organization's approved secure process, recorded separately from tickets.
- SEC-4 Entra ID is the authoritative record of registered credentials, not these files.
- SEC-5 No passwords, client secrets, or tokens are stored by the script.

## 9. Error and Retry Model **[Current]**

| Scope | Prompt | Choices |
|---|---|---|
| Prerequisites, metadata, input, run dir, report write, key inspection | Retry/abort | `R`, `A` |
| Per-user failure | Retry/skip/abort | `R`, `S`, `A` |
| Enrollment log write failure | Retry/continue/abort | `R`, `S`, `A` |
| Preflight, start confirmation | Yes/no | `Y`, `N` |

All prompts re-ask until given a valid choice. Choices are case-insensitive and trimmed.

## 10. Code Architecture **[Current]**

Single file, `src/MLBA-FIDO2.ps1`: parameters, helper functions, then `Invoke-Main` guarded by `$MyInvocation.InvocationName -ne '.'`.

| Function | Responsibility |
|---|---|
| `New-RunId` | UTC run identifier |
| `Write-OperatorMessage` | Colored console messages |
| `Read-Choice` | Validated prompt loop |
| `Invoke-WithRetryChoice` | Wrap an action with retry/abort |
| `Invoke-YubiEnrollReadOnlyCommand` | Run read-only yubienroll commands, throw on non-zero |
| `Write-SafeConfigurationOutput` | Print lines with secret redaction |
| `Confirm-YubiEnrollContext` | Preflight display and Y/N |
| `Test-LocalPrerequisites` | Check both executables exist |
| `Get-RunMetadata` | Tenant and operator prompts |
| `Get-InputRows` | Menu, manual entry, CSV parsing and validation |
| `Get-QueuedUserSummary` | Numbered user list |
| `Invoke-YkmanInfo` | Run and parse `ykman info` |
| `Invoke-YubiEnroll` | Run enrollment, stream output, capture PIN and exit code |
| `Get-YubiKeySerialNumber` | Serial lookup with sentinel fallback |
| `Get-NextAssetName` | Next `YK-NNNN` |
| `Add-SuccessfulEnrollment` | Atomic append to inventory log |
| `New-ReportRow` | Build a result record |
| `Write-RunReport` | Write JSON and CSV |
| `Invoke-Main` | Orchestration (sections 4 and 5) |

Script-scoped state: `LastYubiEnrollTemporaryPin`, `LastYubiEnrollExitCode`.

Tests: `MLBA-FIDO2.Tests.ps1` (Pester) must mock `yubienroll` and `ykman` and never enroll a real credential. Manual live testing: `MLBA-FIDO2-1.0-Manual-Test-Checklist.md`.

## 11. Known Limitations **[Current]**

- No dry-run mode; passing the final confirmation can modify a physical key.
- Provider session is not independently verified; the operator reviews the preflight display.
- No AAGUID allow-list check, model/firmware enforcement, or capacity check.
- No separate delete or factory-reset command.
- Every user requires operator interaction.
- A failed registration is not re-verified in Entra ID; verify the key with `ykman` and Entra before retrying. Do not auto-reset a key after an error.

## 12. Operator Checklist

Before: confirm UPN list (de-duplicated), provider and profile, tenant FIDO2 policy and AAGUID, key availability and capacity, restricted report location.
After: review reports and log (contain PINs), confirm registrations in Entra ID, deliver PINs securely, investigate failures before retrying, apply retention policy.

## 13. Open Decisions / Planned Changes

_Add desired changes here in plain language, then request that the script be updated to match._

-
