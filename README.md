# M365 User Offboarding

A PowerShell module that launches an interactive local web portal for offboarding Microsoft 365 users. Administrators can search and select users, configure each step, run the full workflow in one click, and export a styled audit report.

![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-blue?logo=powershell)
![Version](https://img.shields.io/badge/version-1.1.0-informational)

---

## Features

- **Browser-based portal** — served locally at `http://127.0.0.1:8080`, no external hosting required
- **10-step offboarding workflow** — each step can be individually enabled, disabled, or configured before running
- **What-If preview mode** — run a full dry-run from the portal to see exactly what each step *would* do without applying any changes
- **Bulk offboarding** — select multiple users and run all steps in a single operation
- **Conditional steps** — Intune device actions are automatically skipped when the tenant has no Intune licence
- **Audit log** — every step result is recorded and exportable as both CSV and a styled HTML report

---

## Offboarding Steps

| # | Step | Description |
|---|------|-------------|
| 1 | **Clean Up Admin Roles & Groups** | Removes active and PIM-eligible Entra ID roles (including roles scoped to an administrative unit) and group memberships |
| 2 | **Block Sign-In & Revoke Sessions** | Disables the account and revokes all active refresh tokens. For accounts synced from on-premises AD, it revokes sessions and tells you to disable the account on-premises |
| 3 | **Convert to Shared Mailbox** | Converts the mailbox to shared and optionally grants a delegate FullAccess + SendAs |
| 4 | **Set Out of Office** | Enables auto-reply with configurable internal and external messages |
| 5 | **Secure Device (Intune)** | Personal (BYOD) devices are always retired; company-owned devices are retired or factory-wiped (your choice) — skipped if no Intune licence |
| 6 | **Remove All Licences** | Removes every assigned licence in one Graph call. Not run if the mailbox conversion failed, or if the mailbox still needs a licence (over 50 GB, archive active, or on hold). If Convert to Shared Mailbox is off, it runs with a warning: the mailbox is permanently deleted 30 days later |
| 7 | **Transfer OneDrive to Manager** | Grants the user's manager write access to their OneDrive for data retrieval |
| 8 | **Remove from Teams & Distribution Lists** | Removes membership from all Teams and mail-enabled distribution groups |
| 9 | **Remove Delegated Mailbox Access** | Revokes FullAccess, SendAs and Send on Behalf this user holds on other mailboxes. FullAccess is checked mailbox by mailbox, so allow 1–2 minutes per 500 mailboxes |
| 10 | **Disable / Reset MFA Methods** | Clears all registered authentication methods |

---

## Requirements

- **PowerShell 7.2** or later
- **Microsoft.Graph.Authentication** >= 2.0.0
- **ExchangeOnlineManagement** >= 3.0.0
- **DLLPickle** >= 1.0.0 _(auto-installed on first run if missing — prevents MSAL DLL conflicts between the two modules above)_

### Microsoft Graph permissions

The connecting account needs the following delegated Graph scopes (you will be prompted to consent on first run):

| Scope | Used for |
|-------|----------|
| `User.ReadWrite.All` | Read & update user accounts |
| `Directory.ReadWrite.All` | Remove role assignments and group memberships |
| `Group.ReadWrite.All` | Remove Teams / group membership |
| `RoleManagement.ReadWrite.Directory` | Remove active and PIM-eligible Entra ID roles (the signed-in admin also needs Privileged Role Administrator) |
| `DeviceManagementManagedDevices.ReadWrite.All` | Retire / wipe Intune devices |
| `UserAuthenticationMethod.ReadWrite.All` | Reset MFA methods |
| `Files.ReadWrite.All` | Transfer OneDrive access (only works on drives the signed-in admin can open) |
| `MailboxSettings.ReadWrite` | Set out-of-office auto-reply |
| `TeamMember.ReadWrite.All` | Remove Teams memberships |
| `Organization.Read.All` | Read tenant details at startup |

---

## Installation

### From source

```powershell
# Clone the repository
git clone https://github.com/RobinpZA/M365UserOffboarding.git
cd M365UserOffboarding

# Install runtime dependencies (also run by build.ps1 automatically)
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
Install-Module ExchangeOnlineManagement       -Scope CurrentUser -Force
Install-Module DLLPickle                      -Scope CurrentUser -Force

# Import the module
Import-Module .\M365UserOffboarding.psd1
```

### Using the build script

```powershell
# Bootstrap all build and runtime dependencies
.\build.ps1

# Run linter
.\build.ps1 Analyze

# Run tests
.\build.ps1 Test

# Produce a deployable build under .\build\M365UserOffboarding\
.\build.ps1 Build

# Run the full CI pipeline (Analyze → Test → Build)
.\build.ps1 CI
```

---

## Usage

```powershell
# Start the portal on the default port (8080)
Start-M365UserOffboarding

# Start the portal on a custom port
Start-M365UserOffboarding -Port 9090

# Pin sign-in to one tenant (recommended for MSP use)
Start-M365UserOffboarding -TenantId 00000000-0000-0000-0000-000000000000
```

### Safety checks

- Graph and Exchange Online must sign in to the same tenant, or the portal refuses to connect. With `-TenantId`, both must also match that tenant.
- The tenant is checked again right before every run.
- A live run asks you to type **OFFBOARD** first. What-If preview does not.
- The local server only answers requests addressed to `127.0.0.1` or `localhost` on its own port, which blocks DNS-rebinding attacks from other websites.

On launch the module will:

1. Open `http://127.0.0.1:<port>/` in your default browser automatically
2. Wait for you to click **Connect to Microsoft 365** in the portal, then sign in to **Microsoft Graph** and **Exchange Online**
3. Display tenant and connection details in the console
4. Block until you click **✕ Close** in the portal
5. Offer to generate the HTML audit report (the CSV is already saved)

> [!NOTE]
> If the port is already in use, the module tries the next 9 ports (8081–8089 by default). If all 10 are taken, it stops with an error.

---

## Portal walkthrough

| View | Description |
|------|-------------|
| **Users** | Search and paginate all users in the tenant. Select one or more to offboard. |
| **Offboard** | Review selected users, toggle individual steps on/off, supply configuration (delegate UPN, OOO message, device action), run **Preview (What-If)** for a dry-run, or run the live workflow. |
| **Audit Log** | Live view of all step results from the current session, with per-user and per-step status badges. |

### What-If preview

Use **Preview (What-If)** on the **Offboard** view to execute the full workflow in simulation mode.

- All enabled steps are evaluated in normal order
- No write operations are performed against Microsoft 365, Entra, Exchange, Intune, OneDrive, or SharePoint
- Step results are returned with status **WhatIf** so you can review expected impact before running live
- A preview banner is shown in the results panel to make it clear no changes were made

---

## Audit log output

Audit logs go to `~\M365UserOffboarding\Output\AuditLogs\` by default. Change it with `-OutputPath`. The default is outside OneDrive on purpose, because the logs contain tenant data; the portal warns you if you point it at a OneDrive folder.

| File | Format |
|------|--------|
| `OffboardingAudit_<timestamp>.csv` | Written as each step finishes, so nothing is lost if the console closes. Suitable for Excel or a SIEM |
| `OffboardingAudit_<timestamp>.html` | Styled report with success/error/skipped counts, generated on request or when the portal closes |

Both formats include **WhatIf** status rows when preview mode is used.

---

## Project structure

```
M365UserOffboarding.psd1          # Module manifest
M365UserOffboarding.psm1          # Root module (dot-sources Private + Public)
build.ps1                         # Build / CI script
PSScriptAnalyzerSettings.psd1     # Linter configuration

Public/
  Start-M365UserOffboarding.ps1   # The single exported function

Private/
  Auth/
    Connect-OffboardingServices.ps1
  Server/
    Start-HttpListener.ps1        # Blocking HTTP server loop
    Invoke-RequestRouter.ps1      # Routes requests to API handlers
    Write-HttpResponse.ps1        # Response helpers
  Api/
    Get-PortalUserList.ps1        # Paginated user search via Graph
    Get-PortalUserDetails.ps1     # Single-user detail lookup
    Invoke-OffboardUsers.ps1      # Orchestrates the step pipeline
  Actions/
    Step-BlockSignIn.ps1
    Step-CleanupPermissions.ps1
    Step-ConvertSharedMailbox.ps1
    Step-DisableMfa.ps1
    Step-RemoveDelegatedAccess.ps1
    Step-RemoveLicenses.ps1
    Step-RemoveTeamsAndDLs.ps1
    Step-SecureDevice.ps1
    Step-SetOutOfOffice.ps1
    Step-TransferOneDrive.ps1
  Logging/
    Write-AuditEntry.ps1
    Export-AuditLog.ps1

Assets/portal/                    # Embedded web portal (HTML / CSS / JS)
Tests/
  M365UserOffboarding.Tests.ps1   # Pester 5 test suite
Output/AuditLogs/                 # Old default audit location (git-ignored; logs now default to ~\M365UserOffboarding)
```

---

## Development

```powershell
# Lint
.\build.ps1 Analyze

# Test (requires Pester >= 5.0)
.\build.ps1 Test

# Clean build artefacts
.\build.ps1 Clean
```

Tests cover module manifest validity, import correctness, private function isolation, PSScriptAnalyzer compliance, and the step result contract.
