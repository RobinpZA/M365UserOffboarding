@{
    RootModule        = 'M365UserOffboarding.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'b7f3a1d2-4e5c-4a8b-9c6d-2f1e3d5a7b9c'
    Author            = 'Robin Pieterse'
    CompanyName       = 'Turrito Networks'
    Copyright         = '(c) 2026 Robin Pieterse · Turrito. Licensed under the MIT License.'
    Description       = 'Interactive Microsoft 365 user offboarding portal. Launches a local web portal for managing the complete offboarding workflow: sign-in block, session revocation, shared mailbox conversion, out-of-office, Intune device wipe, licence removal, permissions cleanup, OneDrive transfer, Teams/DL removal, delegated mailbox access removal, and MFA reset.'
    PowerShellVersion = '7.2'

    RequiredModules   = @(
        'Microsoft.Graph.Authentication',
        'ExchangeOnlineManagement'
    )

    FunctionsToExport = @('Start-M365UserOffboarding')
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('M365', 'Microsoft365', 'Offboarding', 'EntraID', 'Exchange', 'Intune', 'Graph', 'Portal')
            ProjectUri   = 'https://github.com/RobinpZA/M365UserOffboarding'
            LicenseUri   = 'https://github.com/RobinpZA/M365UserOffboarding/blob/main/LICENSE'
            ReleaseNotes = '1.1.0 — Safety guards (licence/mailbox checks, per-ownership device actions, tenant pinning and matching, DNS-rebinding protection, typed confirmation). PIM-eligible and scoped role removal; full delegated-access scan incl. Send on Behalf; synced-user handling; audit CSV written live outside OneDrive (-OutputPath). Removed the SharePoint step, which only saw app permissions.'
        }
    }
}
