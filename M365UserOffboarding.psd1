@{
    RootModule        = 'M365UserOffboarding.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7f3a1d2-4e5c-4a8b-9c6d-2f1e3d5a7b9c'
    Author            = 'Robin Pieterse'
    CompanyName       = 'Turrito'
    Copyright         = '(c) 2026 Turrito. All rights reserved.'
    Description       = 'Interactive Microsoft 365 user offboarding portal. Launches a local web portal for managing the complete offboarding workflow: sign-in block, session revocation, shared mailbox conversion, out-of-office, Intune device wipe, licence removal, permissions cleanup, OneDrive transfer, Teams/DL removal, SharePoint access removal, and MFA reset.'
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
            ReleaseNotes = 'Initial release — 11-step interactive offboarding portal with full audit log.'
        }
    }
}
