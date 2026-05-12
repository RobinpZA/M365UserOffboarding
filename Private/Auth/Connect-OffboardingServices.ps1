function Connect-OffboardingServices {
    <#
    .SYNOPSIS
        Authenticates to Microsoft Graph and Exchange Online for offboarding operations.
    .OUTPUTS
        [hashtable] with keys: Graph ($true/$false), Exchange ($true/$false),
        TenantName, TenantId, ConnectedAs, HasIntuneLicense
    #>
    [CmdletBinding()]
    param()

    # ── DLL Pickle — preload MSAL assemblies to avoid version conflicts ─────────
    # When Microsoft.Graph.Authentication and ExchangeOnlineManagement are both
    # loaded they can conflict over different Microsoft.Identity.Client.dll versions.
    # DLLPickle resolves this by loading the newest version first.
    if (Get-Module -ListAvailable -Name DLLPickle) {
        Import-Module DLLPickle -ErrorAction SilentlyContinue
        Import-DPLibrary -ErrorAction SilentlyContinue
    }
    else {
        Write-Host '  [WARN] DLLPickle not installed — installing to prevent MSAL DLL conflicts...' -ForegroundColor Yellow
        try {
            Install-Module DLLPickle -Scope CurrentUser -Force -ErrorAction Stop
            Import-Module DLLPickle -ErrorAction Stop
            Import-DPLibrary -ErrorAction Stop
            Write-Host '  [OK] DLLPickle installed and loaded' -ForegroundColor Green
        }
        catch {
            Write-Host '  [WARN] Could not install DLLPickle. Exchange Online may fail due to MSAL DLL conflicts.' -ForegroundColor Yellow
            Write-Host '         Run: Install-Module DLLPickle -Scope CurrentUser' -ForegroundColor DarkYellow
        }
    }

    $status = @{
        Graph           = $false
        Exchange        = $false
        TenantName      = ''
        TenantId        = ''
        ConnectedAs     = ''
        HasIntuneLicense = $false
    }

    $requiredScopes = @(
        'User.Read.All'
        'User.ReadWrite.All'
        'Directory.ReadWrite.All'
        'Group.ReadWrite.All'
        'RoleManagement.ReadWrite.Directory'
        'DeviceManagementManagedDevices.ReadWrite.All'
        'UserAuthenticationMethod.ReadWrite.All'
        'Sites.FullControl.All'
        'Files.ReadWrite.All'
        'MailboxSettings.ReadWrite'
        'TeamMember.ReadWrite.All'
        'Organization.Read.All'
        'AuditLog.Read.All'
    )

    # ── Microsoft Graph ───────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Connecting to Microsoft Graph...' -ForegroundColor Cyan
    try {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop

        $org  = Invoke-MgGraphRequest -Method GET -Uri '/v1.0/organization?$select=displayName,id' -ErrorAction Stop
        $me   = Invoke-MgGraphRequest -Method GET -Uri '/v1.0/me?$select=userPrincipalName,displayName' -ErrorAction Stop

        $status.TenantName  = $org.value[0].displayName
        $status.TenantId    = $org.value[0].id
        $status.ConnectedAs = $me.userPrincipalName
        $status.Graph       = $true

        Write-Host "  [OK] Graph — Tenant: $($status.TenantName) | As: $($status.ConnectedAs)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [FAIL] Microsoft Graph: $_" -ForegroundColor Red
        return $status
    }

    # ── Check Intune licensing ─────────────────────────────────────────────
    try {
        $skus = Invoke-MgGraphRequest -Method GET -Uri '/v1.0/subscribedSkus?$select=skuPartNumber,servicePlans,capabilityStatus' -ErrorAction SilentlyContinue
        $status.HasIntuneLicense = [bool](
            $skus.value |
            Where-Object { $_.capabilityStatus -eq 'Enabled' } |
            ForEach-Object { $_.servicePlans } |
            Where-Object { $_.servicePlanName -like 'INTUNE*' -and $_.provisioningStatus -eq 'Success' }
        )
        $intuneLabel = if ($status.HasIntuneLicense) { 'Licensed' } else { 'Not licensed — device step will be skipped' }
        Write-Host "  [OK] Intune: $intuneLabel" -ForegroundColor $(if ($status.HasIntuneLicense) { 'Green' } else { 'Yellow' })
    }
    catch {
        Write-Host '  [WARN] Could not determine Intune licensing status.' -ForegroundColor Yellow
    }

    # ── Exchange Online ───────────────────────────────────────────────────────
    Write-Host '  Connecting to Exchange Online...' -ForegroundColor Cyan
    try {
        # Install module if needed
        if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
            Write-Host '  Installing ExchangeOnlineManagement...' -ForegroundColor Yellow
            Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module ExchangeOnlineManagement -ErrorAction Stop

        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        $status.Exchange = $true
        Write-Host '  [OK] Exchange Online' -ForegroundColor Green
    }
    catch {
        Write-Host "  [FAIL] Exchange Online: $_" -ForegroundColor Red
        Write-Host '         Exchange-dependent steps will be skipped.' -ForegroundColor DarkYellow
    }

    # ── Propagate to module-level variables ───────────────────────────────────
    $script:TenantName       = $status.TenantName
    $script:TenantId         = $status.TenantId
    $script:ConnectedAs      = $status.ConnectedAs
    $script:HasIntuneLicense = $status.HasIntuneLicense
    $script:Connected        = $status.Graph

    return $status
}
