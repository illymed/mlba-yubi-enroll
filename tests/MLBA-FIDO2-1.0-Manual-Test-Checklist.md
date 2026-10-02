# MLBA-FIDO2 1.0 Manual Test Checklist

## Safety and test setup

- [ ] Use a dedicated test tenant and test accounts; do not use production users.
- [ ] Use a dedicated YubiKey whose existing credentials may be erased. The selected YubiEnroll profile may factory-reset or configure the key.
- [ ] Confirm the active YubiEnroll provider, tenant, and profile before each enrollment.
- [ ] Use `-YubiEnrollProfile <name>` when testing a non-default profile.
- [ ] Confirm run reports and the persistent enrollment log are being written to approved test locations.
- [ ] Confirm the test operator knows how to stop the process if the tenant, provider, profile, or physical key is incorrect.

## Start-up and input selection

- [ ] **Prerequisites:** Run where `yubienroll` and `ykman` are available. Confirm the script reaches its prompts and identifies that it uses the existing provider session.
- [ ] **Provider/profile preflight:** Confirm startup displays the result of `yubienroll status`, the active provider configuration, available profile settings, and any script profile override. Check the provider name, tenant, authenticated account, and profile/reset settings; verify secret-like values are redacted. Enter `N` and confirm the script stops before run metadata, report-directory creation, key inspection, or enrollment. Repeat and enter `Y` only when the displayed context is correct.
- [ ] **Missing command:** In a controlled test environment, run with an invalid `-YubiEnrollCommand` or `-YkmanCommand`. Confirm the error and retry/abort choice appear; abort without enrolling.
- [ ] **Manual input:** Run without `-i`; enter an invalid menu selection, then `1`. Confirm it repeats the menu, prompts for one UPN, and normalizes the UPN to lowercase.
- [ ] **CSV menu input:** Run without `-i`; enter an invalid selection, then `2`. Confirm it prompts for a CSV path.
- [ ] **Explicit CSV input:** Run with `-i <path>`. Confirm the input-mode menu is bypassed.
- [ ] **Headered CSV:** Load a file with `UserPrincipalName`, `TicketId`, and `OperatorNote`. Confirm values are preserved in the processed row.
- [ ] **Headerless CSV:** Load a one-column list of UPNs without a header. Confirm each UPN is accepted.
- [ ] **Duplicate UPNs:** Try duplicates differing only by case or surrounding whitespace. Confirm validation stops before enrollment.
- [ ] **Blank UPN:** Try a row with an empty UPN. Confirm validation stops before enrollment.
- [ ] **Empty/header-only CSV:** Confirm an empty file and a header-only file are rejected before enrollment.
- [ ] **Cancel run:** At `Continue with enrollment? (Y/N)`, enter `N`. Confirm no key inspection or enrollment starts and the resulting run report contains no enrolled users.

## Successful enrollment

- [ ] Use one approved test account and the dedicated key. Confirm the provider, tenant, and profile before proceeding.
- [ ] Enter `Y` at the run confirmation prompt.
- [ ] At the per-user prompt, insert the intended key and press Enter.
- [ ] Confirm `ykman` inspection does not print parsed device details to the terminal, while YubiEnroll's interactive prompts remain visible and usable.
- [ ] Complete enrollment with the intended test profile.
- [ ] After enrollment completes and before the next key prompt, confirm `ykman list --serials` runs while the enrolled key remains connected.
- [ ] With a key that reports a serial, confirm the same serial appears in the run JSON, CSV, and persistent enrollment log.
- [ ] With a Security Key series key that returns no serial, confirm `No Serial Number Detected` is recorded and enrollment remains successful.
- [ ] If multiple keys are connected or serial lookup fails, confirm the script warns and uses `No Serial Number Detected` rather than assigning an ambiguous/wrong serial or changing the enrollment outcome.
- [ ] Confirm YubiEnroll's printed temporary PIN is captured automatically without an additional operator PIN-entry prompt.
- [ ] Confirm the user is reported as `Succeeded`.
- [ ] Confirm JSON and CSV reports are created under `run-reports/<run-id>/`.
- [ ] Confirm reports contain the user, status, selected key details, completion time, and the PIN entered or confirmed (if any).
- [ ] Confirm the persistent enrollment log contains the next asset ID, expected user, serial number or fallback marker, key details, tenant label, operator details, and captured temporary PIN.
- [ ] Confirm the input CSV was not modified.

## Per-user and failure handling

- [ ] **Skip before inspection:** At a user's key prompt, enter `S`. Confirm the row is `Skipped`, no inspection/enrollment occurs for that user, and the next user is offered.
- [ ] **Inspection failure:** Disconnect the test key and press Enter. Confirm the inspection error and retry/skip/abort prompt appear. Skip the row; confirm it is reported as `Failed` with the inspection stage and no enrollment exit code.
- [ ] **Enrollment failure and continue:** If a predictable, safe test-provider rejection is available, trigger it with a test account. Choose to skip after failure; confirm the row is `Failed`, the exit code is recorded when available, and the next row proceeds.
- [ ] **Abort:** On a controlled failure, choose abort. Confirm the failure row is written to the report before the run stops.
- [ ] **Retry:** On a recoverable failure, choose retry after correcting the cause. Confirm the same user is retried and appears only once in the final report.
- [ ] **No PIN:** If a successful test flow generates no PIN, leave the PIN prompt blank. Confirm the report PIN field is empty.

## Reports and inventory

- [ ] For a multi-user run, confirm there is one result per processed row and that `TicketId`, `OperatorNote`, status, stage, message, exit code, serial number/fallback, and key details are correct.
- [ ] Open the CSV report in spreadsheet software and confirm it is a readable CSV. Do not expect an `.xlsx` workbook.
- [ ] With a disposable test log, confirm a missing log starts at `YK-0001` and an existing highest asset ID increments by one. Do not alter the production enrollment log for this test.
- [ ] Confirm the report's operator field identifies the Windows account, and tenant/enroller details are recorded in the persistent log rather than assumed to be in each run report.
- [ ] Confirm PIN-bearing run reports and the persistent enrollment log are restricted, protected at rest, and covered by approved PIN delivery, retention, and secure deletion procedures. Do not share the original files.

## PowerShell compatibility

- [ ] Run the non-destructive checks under Windows PowerShell 5.1.
- [ ] Run the same checks under the supported PowerShell 7.x version, if applicable.
- [ ] Confirm prompting, CSV handling, native command interaction, and report writing work in each host.
- [ ] Keep automated tests mocked; they do not replace the live test-tenant and dedicated-key smoke test.

## 1.0 release gate

- [ ] A real test-tenant enrollment completed successfully and its report and inventory-log entry were reviewed.
- [ ] Skip, failure, retry, abort, and cancellation behavior matched expectations.
- [ ] Temporary PINs were captured automatically and appear in both run reports and the persistent enrollment log; both stores are access-restricted and protected.
- [ ] The required PowerShell host(s) passed the checks above.
- [ ] Successful registration was independently verified through the normal Entra administrative process; the script itself does not verify registration in Entra.