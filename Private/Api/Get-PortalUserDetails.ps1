function Get-PortalUserDetails {
    <#
    .SYNOPSIS
        Returns rich detail for a single user: licences, groups, admin roles, and managed devices.
    .PARAMETER UserId
        The Azure AD Object ID or UPN of the user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserId
    )

    $result = @{
        id                = $UserId
        displayName       = ''
        userPrincipalName = ''
        jobTitle          = ''
        department        = ''
        accountEnabled    = $true
        mail              = ''
        manager           = $null
        licenses          = @()
        groups            = @()
        roles             = @()
        devices           = @()
    }

    # ── Basic user info ───────────────────────────────────────────────────────
    try {
        $uri  = '/v1.0/users/' + $UserId + '?$select=id,displayName,userPrincipalName,department,jobTitle,accountEnabled,mail'
        $user = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        $result.id                = $user.id
        $result.displayName       = $user.displayName
        $result.userPrincipalName = $user.userPrincipalName
        $result.jobTitle          = $user.jobTitle
        $result.department        = $user.department
        $result.accountEnabled    = $user.accountEnabled
        $result.mail              = $user.mail
    }
    catch {
        Write-Warning "Get-PortalUserDetails: failed to get user info for $UserId — $_"
        return $result
    }

    # ── Manager ───────────────────────────────────────────────────────────────
    try {
        $mgrUri = '/v1.0/users/' + $UserId + '/manager?$select=displayName,userPrincipalName,id'
        $mgr    = Invoke-MgGraphRequest -Method GET -Uri $mgrUri -ErrorAction SilentlyContinue
        if ($mgr) {
            $result.manager = @{
                id                = $mgr.id
                displayName       = $mgr.displayName
                userPrincipalName = $mgr.userPrincipalName
            }
        }
    }
    catch {
        Write-Verbose "Get-PortalUserDetails: manager lookup suppressed for $UserId — $_"
    }

    # ── Licences ──────────────────────────────────────────────────────────────
    try {
        $licUri  = '/v1.0/users/' + $UserId + '/licenseDetails'
        $licResp = Invoke-MgGraphRequest -Method GET -Uri $licUri -ErrorAction SilentlyContinue
        $result.licenses = @($licResp.value | ForEach-Object { $_.skuPartNumber } | Where-Object { $_ })
    }
    catch {
        Write-Verbose "Get-PortalUserDetails: licence lookup suppressed for $UserId — $_"
    }

    # ── Group and role memberships ─────────────────────────────────────────────
    try {
        $memUri  = '/v1.0/users/' + $UserId + '/memberOf?$select=id,displayName,@odata.type&$top=100'
        $memResp = Invoke-MgGraphRequest -Method GET -Uri $memUri -ErrorAction SilentlyContinue
        foreach ($m in $memResp.value) {
            if ($m.'@odata.type' -eq '#microsoft.graph.group') {
                $result.groups += $m.displayName
            }
            elseif ($m.'@odata.type' -eq '#microsoft.graph.directoryRole') {
                $result.roles += $m.displayName
            }
        }
    }
    catch {
        Write-Verbose "Get-PortalUserDetails: membership lookup suppressed for $UserId — $_"
    }

    # ── Managed devices (Intune) ──────────────────────────────────────────────
    try {
        $devUri  = '/v1.0/deviceManagement/managedDevices?$filter=userId eq ''' + $UserId + '''&$select=deviceName,operatingSystem,deviceEnrollmentType,managedDeviceOwnerType,id'
        $devResp = Invoke-MgGraphRequest -Method GET -Uri $devUri -ErrorAction SilentlyContinue
        $result.devices = @($devResp.value | ForEach-Object {
            @{
                id         = $_.id
                name       = $_.deviceName
                os         = $_.operatingSystem
                enrollment = $_.deviceEnrollmentType
                ownerType  = $_.managedDeviceOwnerType
            }
        })
    }
    catch {
        Write-Verbose "Get-PortalUserDetails: device lookup suppressed for $UserId — $_"
    }

    return $result
}
