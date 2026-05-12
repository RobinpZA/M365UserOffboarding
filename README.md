# M365 User Offboarding

A PowerShell module that launches an interactive local web portal for offboarding Microsoft 365 users. Administrators can search and select users, configure each step, run the full workflow in one click, and export a styled audit report.

![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-blue?logo=powershell)
![Version](https://img.shields.io/badge/version-1.0.0-informational)

---

## Features

- **Browser-based portal** — served locally at `http://127.0.0.1:8080`, no external hosting required
- **11-step offboarding workflow** — each step can be individually enabled, disabled, or configured before running
- **Bulk offboarding** — select multiple users and run all steps in a single operation
- **Conditional steps** — Intune device actions are automatically skipped when the tenant has no Intune licence
- **Audit log** — every step result is recorded and exportable as both CSV and a styled HTML report

---

## Offboarding Steps

| # | Step | Description |
|---|------|-------------|
| 1 | **Clean Up Admin Roles & Groups** | Removes all Entra ID directory roles and group memberships |
| 2 | **Block Sign-In & Revoke Sessions** | Disables the account and revokes all active refresh tokens |
| 3 | **Convert to Shared Mailbox** | Converts the mailbox to shared and optionally grants a delegate FullAccess + SendAs |
| 4 | **Set Out of Office** | Enables auto-reply with configurable internal and external messages |
| 5 | **Secure Device (Intune)** | Retires (BYOD) or fully wipes company-managed devices — skipped if no Intune licence |
| 6 | **Remove All Licences** | Removes every assigned Microsoft 365 licence in a single Graph call |
| 7 | **Transfer OneDrive to Manager** | Grants the user's manager write access to their OneDrive for data retrieval |
| 8 | **Remove from Teams & Distribution Lists** | Removes membership from all Teams and mail-enabled distribution groups |
| 9 | **Remove Delegated Mailbox Access** | Revokes any delegated permissions this user holds on other mailboxes |
| 10 | **Remove SharePoint Memberships** | Removes the user from SharePoint site collections |
| 11 | **Disable / Reset MFA Methods** | Clears all registered authentication methods |

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
| `User.Read.All` / `User.ReadWrite.All` | Read & update user accounts |
| `Directory.ReadWrite.All` | Remove role assignments and group memberships |
| `Group.ReadWrite.All` | Remove Teams / group membership |
| `RoleManagement.ReadWrite.Directory` | Remove Entra ID directory roles |
| `DeviceManagementManagedDevices.ReadWrite.All` | Retire / wipe Intune devices |
| `UserAuthenticationMethod.ReadWrite.All` | Reset MFA methods |
| `Sites.FullControl.All` / `Files.ReadWrite.All` | Transfer OneDrive access |
| `MailboxSettings.ReadWrite` | Set out-of-office auto-reply |
| `TeamMember.ReadWrite.All` | Remove Teams memberships |
| `Organization.Read.All` | Read tenant details at startup |
| `AuditLog.Read.All` | (reserved for future audit queries) |

---

## Installation

### From source

```powershell
# Clone the repository
git clone https://github.com/your-org/M365UserOffboarding.git
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
```

On launch the module will:

1. Authenticate to **Microsoft Graph** (interactive browser sign-in) and **Exchange Online**
2. Display tenant and connection details in the console
3. Open `http://127.0.0.1:<port>/` in your default browser automatically
4. Block until you click **✕ Close** in the portal
5. Prompt you to export the audit log

> [!NOTE]
> If port 8080 is already in use, the module automatically tries ports 8081–8089 before falling back to the specified port.

---

## Portal walkthrough

| View | Description |
|------|-------------|
| **Users** | Search and paginate all users in the tenant. Select one or more to offboard. |
| **Offboard** | Review selected users, toggle individual steps on/off, supply configuration (delegate UPN, OOO message, device action), and run the workflow. |
| **Audit Log** | Live view of all step results from the current session, with per-user and per-step status badges. |

---

## Audit log output

After the portal is closed, results are saved to `Output\AuditLogs\`:

| File | Format |
|------|--------|
| `OffboardingAudit_<timestamp>.csv` | Machine-readable; suitable for import into Excel or SIEM |
| `OffboardingAudit_<timestamp>.html` | Styled report with success/error/skipped counts and colour-coded badges |

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
    Step-RemoveSharePointAccess.ps1
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
Output/AuditLogs/                 # Generated audit reports (git-ignored)
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
