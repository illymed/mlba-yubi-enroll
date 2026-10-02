# FIDO2 Security Key Pre-Provisioning
## Purpose
This document outlines the process of pre-provisioning a FIDO2 YubiKey as an authentication method for a chosen Microsoft 365 account using the YubiEnroll command line application. This article outlines the usage of the MLBA-FIDO2.ps1 PowerShell script for bulk preprovisioning keys for users.

## Functionality
This script will:

- Take User Principal Names as input; When run without `-i`/`-InputCsv`, the script will prompt for input mode.
- Interactively go through the process of enrolling the keys, one after another
- Collect and log identifying and operationally relevant information for each enrolled security key.
- Record each run in run reports and each successful enrollment in a persistent enrollment log (see [Reporting](#reporting)).

### Reporting
The script produces two kinds of output.

#### Run reports
Each run writes a JSON and a CSV report to `<script-root>\run-reports\<run-id>\` (override the parent folder with `-OutputDirectory`). The run ID is the UTC start time, e.g. `20261002-143015Z`. Reports are written even if the run is aborted, as long as the run folder was created (after preflight and input validation).

- `run-report.json`: run metadata (run ID, operator `DOMAIN\user`, start/completion time in UTC, input CSV path) and a detailed result for each user.
- `run-report.csv`: a flattened per-user summary for review.

Each result contains:

- User principal name, ticket ID, and operator note
- Status: `Succeeded`, `Failed`, or `Skipped` (a user skipped after a failed attempt is reported as `Failed`)
- Stage reached and a message
- `yubienroll` exit code (when enrollment ran)
- Key details from `ykman`: device type, serial number, firmware, form factor, USB interfaces, NFC state, and FIDO2 availability
- Enrollment profile used
- Temporary PIN
- Completion time in UTC

Full `yubienroll` output is not captured; only the temporary PIN line is saved.

#### Persistent enrollment log
The script maintains a persistent local enrollment log (`fido2-enrollment-log.csv` in the script root, or the path given with `-EnrollmentLogPath`) used for inventory tracking and asset identifier generation. It is appended to across runs and only successful enrollments are recorded. Each row stores:

- Timestamp (UTC)
- Asset identifier (`YK-0001`, `YK-0002`, ...; the next number after the highest existing one). If the log does not exist, it is created and numbering starts at `YK-0001`.
- User principal name
- Serial number (or `No Serial Number Detected` when none, an error, or multiple keys are detected)
- Device type, firmware version, form factor, enabled USB interfaces, and FIDO2 USB/NFC state
- Temporary PIN
- Tenant, enrolled-by name, and enrolled-by email
- Enrollment profile used

If the log cannot be updated after a successful enrollment, the script offers to retry, continue without logging, or abort. Updates are written atomically, so a failed write does not corrupt the existing log.

#### Handling
The run reports and the enrollment log contain plaintext temporary PINs and must be treated as credential-bearing files:

- Restrict access, protect them at rest, and apply a retention and deletion policy.
- Do not attach them to tickets or send them through ordinary email; if sharing is needed, create a copy with the PIN columns removed.
- Deliver PINs to users through the approved secure process, and do not copy them into ticket notes.
- The reports are not proof of registration; confirm registered methods in Entra ID.

### Enrollment profiles
No YubiEnroll profile is needed. After inspecting each key with `ykman info`, the script picks a built-in profile by device type and passes its settings to `yubienroll credentials add` as flags. The profile used is recorded in the reports and log.

| Profile | Matches | Always-UV | Min PIN | Force PIN change | Reset | Random PIN |
|---|---|---|---|---|---|---|
| YubiKey Security Key Line | `Security Key*` | On | 4 | Yes | Yes | Yes (4) |
| YubiKey 5 Nano | `YubiKey 5 Nano` | Off | 4 | No | Yes | Yes (4) |

Other models stop with a "no profile" error for that user. Add a profile to `$script:EnrollmentProfiles` at the top of the script to support them, or use `-YubiEnrollProfile` to apply one YubiEnroll profile to every key.

### CSV Input
Preferred format, with a header row (`TicketId` and `OperatorNote` are optional and appear in the reports):

```csv
UserPrincipalName,TicketId,OperatorNote
user1@contoso.com,SEC-1001,Initial enrollment
user2@contoso.com,SEC-1002,
```

Also supported: a headerless file with one UPN per line in column A.

UPNs are trimmed and lowercased. Blank or duplicate UPNs stop the run before any enrollment.

## Prerequisites
Before you can run the script to enroll keys for users, ensure that you meet the following prerequisites:
### Local Prerequisites

- `YubiEnroll` CLI app installed on local machine
- `YubiKey Manager` CLI app installed on local machine
- Windows PowerShell 5.1+ 
- CSV file containing the list of users to enroll (optional; a single user can be entered manually)
### Microsoft Prerequisites
- Access to a Microsoft 365 account with permissions in the target tenant meeting or exceeding:
  - Privileged Authentication Administrator
  - Cloud Application Administrator
- MLBA FIDO2 Enrollment App Registration is present in target tenant.
  - If the app registration is not present, it can be created using the template present in CIPP.


## Installing YubiEnroll

1. Download the YubiEnroll installer MSI from the Yubico Website
   - link: https://downloads.yubico.com/support/yubienroll-1.2.0-win64.msi

2. Run the MSI as an Administrator.
3. To verify installation was successful: Open a PowerShell window and type `yubienroll`
   - the help screen for `yubienroll` will be displayed, showing commands and usage instructions.

## Installing YubiKey Manager

1. Download the YubiKey Manager installer MSI from the Yubico Website.
   - link: https://developers.yubico.com/yubikey-manager/Releases/

2. Run the MSI as an Administrator.
3. To verify installation was successful: Open a PowerShell Window and type `ykman`
    - the help screen for `ykman` will be displayed, showing commands and usage instructions.



# Enrolling Security Keys for users
## Configuring YubiEnroll

1. Add a Provider to YubiEnroll
   - Run in Administrator PowerShell: `yubienroll providers add <TENANT-NAME>`

2. Select `[1] ENTRA`
3. Enter the App Registration information:
   - Client Id: `<app-registration-client-id>`
   - Redirect Uri: http://localhost/yubienroll-redirect
   - Microsoft Entra Tenant Id: `<target-tenant-id>`
   - Microsoft Entra ID base URL:
     - Commercial and GCC Microsoft 365 tenants: `https://login.microsoftonline.com`
     - GCC High Microsoft 365 tenants: `https://login.microsoft.us`
     - DoD Microsoft 365 tenants: `https://login.microsoftonline.us`
   - Microsoft Graph base URL:
     - Commercial and GCC Microsoft 365 tenants: https://graph.microsoft.com
     - GCC High Microsoft 365 tenants: https://graph.microsoft.us
     - DoD Microsoft 365 tenants: https://dod-graph.microsoft.us
4. If prompted to create a profile, select No. The script supplies enrollment settings per key model (see [Enrollment profiles](#enrollment-profiles)).
5. If prompted to activate the created provider, select Yes.
6. Enter `yubienroll login` and follow the prompts to sign in with the enrolling admin account.
7. If prompted via Windows to "allow network access" select Yes.

## Running the Script
Once YubiEnroll has been set up, you can begin enrolling users.
1. Place the script inside its own folder.
2. Open PowerShell and run the script. The following flags are supported:
   - `-i <file-path>` / `-InputCsv <file-path>` allows a CSV file to be input before run; defaults to interactive input prompt.
   - `-OutputDirectory <chosen-path>` specifies the parent folder for run reports (each run gets its own `<run-id>` subfolder); defaults to `<script-root>\run-reports`
   - `-EnrollmentLogPath <file-path>` specifies the target path for the persistent enrollment log; defaults to the script root.  
   - `-YubiEnrollCommand <chosen-command>` specifies a custom command for YubiEnroll; defaults to `yubienroll` via `PATH`
   - `-YkmanCommand <chosen-command>` specifies a custom command for YubiKey Manager; defaults to `ykman` via `PATH`
   - `-YubiEnrollProfile <profile-name>` overrides the built-in model profiles and uses this YubiEnroll profile for every key in the run.
3. The active YubiEnroll provider and the built-in profile table will be displayed. If correct, select `Y`
4. Enter the following information when prompted:
    
        note: this information is only run metadata and will not be used to validate the operator or tenant in script logic.

- `Target Tenant Name`
- `Enrolled-by Name`
- `Enrolled-by Email`

5.   Follow the prompts onscreen to enroll security keys for each account included in the CSV file.
6. When the script finishes, a run report will be generated that contains a record of each enrollment operation. The report will be generated at `<OutputDirectory>\<your-run's-id>\` (default `<script-root>\run-reports\<your-run's-id>\`).


# Supporting Documentation to Write
- How to add the MLBA FIDO2 Enrollment App Registration to a Tenant via CIPP
