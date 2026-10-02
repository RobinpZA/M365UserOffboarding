function Connect-OffboardingServices {
    <#
    .SYNOPSIS
        Authenticates to Microsoft Graph and Exchange Online for offboarding operations.
    .OUTPUTS
        [hashtable] with keys: Graph ($true/$false), Exchange ($true/$false),
        TenantName, TenantId, ConnectedAs, HasIntuneLicense, Error
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
        Error            = ''
    }

    $requiredScopes = @(
        'User.ReadWrite.All'
        'Directory.ReadWrite.All'
        'Group.ReadWrite.All'
        'RoleManagement.ReadWrite.Directory'
        'DeviceManagementManagedDevices.ReadWrite.All'
        'UserAuthenticationMethod.ReadWrite.All'
        'Files.ReadWrite.All'
        'MailboxSettings.ReadWrite'
        'TeamMember.ReadWrite.All'
        'Organization.Read.All'
    )

    # ── Microsoft Graph ───────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Connecting to Microsoft Graph...' -ForegroundColor Cyan
    try {
        $mgParams = @{ Scopes = $requiredScopes; NoWelcome = $true; ErrorAction = 'Stop' }
        if ($script:ExpectedTenantId) { $mgParams.TenantId = $script:ExpectedTenantId }
        Connect-MgGraph @mgParams

        $org  = Invoke-MgGraphRequest -Method GET -Uri '/v1.0/organization?$select=displayName,id' -ErrorAction Stop
        $me   = Invoke-MgGraphRequest -Method GET -Uri '/v1.0/me?$select=userPrincipalName,displayName' -ErrorAction Stop

        # Connect-MgGraph can reuse a cached context for another tenant, so check
        # where the token actually points before anything is allowed to write.
        $ctxTenant = (Get-MgContext).TenantId
        if ($ctxTenant -ne $org.value[0].id) {
            throw "Graph context tenant ($ctxTenant) does not match organisation ($($org.value[0].id))."
        }
        if ($script:ExpectedTenantId -and $ctxTenant -ne $script:ExpectedTenantId) {
            throw "Signed in to tenant $ctxTenant, but -TenantId $($script:ExpectedTenantId) was requested."
        }

        $status.TenantName  = $org.value[0].displayName
        $status.TenantId    = $org.value[0].id
        $status.ConnectedAs = $me.userPrincipalName
        $status.Graph       = $true

        Write-Host "  [OK] Graph — Tenant: $($status.TenantName) | As: $($status.ConnectedAs)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [FAIL] Microsoft Graph: $_" -ForegroundColor Red
        try { $null = Disconnect-MgGraph -ErrorAction Stop } catch { Write-Verbose "Graph disconnect suppressed: $_" }
        $status.Graph = $false
        $status.Error = "Microsoft Graph: $_"
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
        Import-Module ExchangeOnlineManagement -ErrorAction Stop

        # Hint the same account so Exchange signs in where Graph did.
        Connect-ExchangeOnline -UserPrincipalName $status.ConnectedAs -ShowBanner:$false -ErrorAction Stop

        $exo = Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' } | Select-Object -Last 1
        if (-not $exo -or $exo.TenantID -ne $status.TenantId) {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
            $msg = "Exchange Online connected to tenant '$($exo.TenantID)', but Graph is on '$($status.TenantId)'. Both connections closed — sign in with one account for one tenant."
            Write-Host "  [FAIL] $msg" -ForegroundColor Red
            $status.Graph = $false
            $status.Error = $msg
            return $status
        }

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
