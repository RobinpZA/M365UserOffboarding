function Start-M365UserOffboarding {
    <#
    .SYNOPSIS
        Launches the M365 User Offboarding portal.
    .DESCRIPTION
        Starts a local HTTP portal on 127.0.0.1 (default port 8080). Authentication
        to Microsoft Graph and Exchange Online is performed interactively from within
        the portal — click "Connect to Microsoft 365" on the landing screen.
    .PARAMETER TenantId
        Tenant ID (GUID) to connect to. When set, sign-in is pinned to this tenant
        and the portal refuses to connect if Graph or Exchange land anywhere else.
    .PARAMETER OutputPath
        Folder for audit logs. Defaults to ~\M365UserOffboarding\Output\AuditLogs, which
        is outside OneDrive so tenant data is not synced. Every step result is appended to
        a CSV here as it happens; an HTML report can be generated when the portal closes.
    .PARAMETER Port
        Starting port for the portal server. Tries 8080–8089 if the preferred port
        is already in use.
    .EXAMPLE
        Start-M365UserOffboarding
    .EXAMPLE
        Start-M365UserOffboarding -Port 9090
    .EXAMPLE
        Start-M365UserOffboarding -TenantId 00000000-0000-0000-0000-000000000000
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId = '',

        [string]$OutputPath = (Join-Path $HOME 'M365UserOffboarding' 'Output' 'AuditLogs'),

        [ValidateRange(1024, 65535)]
        [int]$Port = 8080
    )

    # ── Banner ────────────────────────────────────────────────────────────
    $moduleVersion = $MyInvocation.MyCommand.Module.Version
    Write-Host ''
    Write-Host '  ╔═════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '  ║   M365 User Offboarding Portal          ║' -ForegroundColor Cyan
    Write-Host "  ║   Module version $moduleVersion$((' ' * [Math]::Max(0, 22 - "$moduleVersion".Length))) ║" -ForegroundColor Cyan
    Write-Host '  ╚═════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''

    # ── Reset session state ───────────────────────────────────────────────
    Write-Host '[1/2] Initialising session…' -ForegroundColor Yellow
    $script:AuditLog         = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:ServerStop       = $false
    $script:Connected        = $false
    $script:TenantName       = ''
    $script:TenantId         = ''
    $script:ExpectedTenantId = $TenantId
    $script:AuditDir         = $OutputPath
    $script:AuditStamp       = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $script:ConnectedAs      = ''
    $script:HasIntuneLicense = $false
    $script:CsrfToken        = [System.Convert]::ToBase64String(
                                   [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    Write-Host "  Audit log : $(Join-Path $OutputPath "OffboardingAudit_$($script:AuditStamp).csv")" -ForegroundColor DarkCyan
    $oneDriveRoots = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) | Where-Object { $_ } | Select-Object -Unique
    $fullOutput    = [System.IO.Path]::GetFullPath($OutputPath)
    if ($oneDriveRoots | Where-Object { $fullOutput.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }) {
        Write-Warning 'The audit log folder is inside OneDrive, so tenant data will be synced to the cloud. Use -OutputPath to choose another folder.'
    }
    Write-Host ''

    # ── Launch portal ─────────────────────────────────────────────────────
    Write-Host '[2/2] Starting portal server…' -ForegroundColor Yellow

    # Start-OffboardingServer is blocking — returns only when the user clicks Close.
    # Browser launch happens inside Start-OffboardingServer once the actual bound port
    # is known, preventing the browser from opening on the wrong port when fallback
    # binding is used.
    Start-OffboardingServer -PreferredPort $Port

    Write-Host ''
    Write-Host 'Portal closed.' -ForegroundColor Cyan

    # ── Prompt to export audit ─────────────────────────────────────────────
    if ($script:AuditLog.Count -gt 0) {
        Write-Host "$($script:AuditLog.Count) audit entries recorded." -ForegroundColor Yellow
        Write-Host "CSV already saved to $(Join-Path $script:AuditDir "OffboardingAudit_$($script:AuditStamp).csv")" -ForegroundColor DarkCyan
        $choice = Read-Host 'Also generate the HTML report? [Y/n]'
        if ($choice -ne 'n' -and $choice -ne 'N') {
            $null = Export-AuditLog   # Export-AuditLog prints the saved paths itself
        }
    }

    Write-Host 'Done.' -ForegroundColor Cyan
}
