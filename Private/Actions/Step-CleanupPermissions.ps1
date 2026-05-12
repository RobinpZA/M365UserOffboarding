function Step-CleanupPermissions {
    <#
    .SYNOPSIS
        Removes the user from all admin roles, security groups, and Microsoft 365 groups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'CleanupPermissions'
        StepLabel = 'Clean Up Admin Roles & Groups'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $rolesRemoved   = [System.Collections.Generic.List[string]]::new()
    $groupsRemoved  = [System.Collections.Generic.List[string]]::new()
    $errors         = [System.Collections.Generic.List[string]]::new()
    $manualActions  = [System.Collections.Generic.List[string]]::new()

    # ── Get all memberships ───────────────────────────────────────────────────
    $memberships = @()
    try {
        $memUri  = '/v1.0/users/' + $UserId + '/memberOf?$select=id,displayName,resourceProvisioningOptions&$top=100'
        $memResp = Invoke-MgGraphRequest -Method GET -Uri $memUri -ErrorAction Stop
        $memberships = @($memResp.value)
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to retrieve memberships: $_"
        return $result
    }

    # ── Remove from directory roles ───────────────────────────────────────────
    $roles = @($memberships | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.directoryRole' })
    foreach ($role in $roles) {
        try {
            Invoke-MgGraphRequest -Method DELETE `
                -Uri ('/v1.0/directoryRoles/' + $role.id + '/members/' + $UserId + '/$ref') `
                -ErrorAction Stop
            $rolesRemoved.Add($role.displayName)
        }
        catch {
            $errors.Add("Role '$($role.displayName)': $_")
        }
    }

    # ── Remove from groups (security, M365, mail-enabled) ─────────────────────
    # Skip Teams-connected groups — those are handled by Step-RemoveTeamsAndDLs
    # which uses the proper Teams API and preserves conversation history correctly.
    $groups = @($memberships | Where-Object {
        $_.'@odata.type' -eq '#microsoft.graph.group' -and
        ($_.resourceProvisioningOptions -notcontains 'Team')
    })
    foreach ($grp in $groups) {
        try {
            Invoke-MgGraphRequest -Method DELETE `
                -Uri ('/v1.0/groups/' + $grp.id + '/members/' + $UserId + '/$ref') `
                -ErrorAction Stop
            $groupsRemoved.Add($grp.displayName)
        }
        catch {
            # Combine exception message and HTTP response body (Graph error code is in the response body)
            $errFull = $_.Exception.Message + ' ' + ($_.ErrorDetails?.Message ?? '')
            # Dynamic groups and some system groups cannot have members removed via API
            if ($errFull -match 'dynamicMembership|ReadOnlyViolation|unsupported') {
                # Skip with note rather than treating as error
            }
            elseif ($errFull -match 'Authorization_RequestDenied') {
                # Role-assignable and distribution groups cannot have members removed via the Graph groups API.
                # Record as a manual action item — does not count as a failure.
                $manualActions.Add("'$($grp.displayName)' (cannot remove via Graph API — remove manually in Entra ID or Exchange admin)")
            }
            else {
                $errors.Add("Group '$($grp.displayName)': $_")
            }
        }
    }

    $summary = @()
    if ($rolesRemoved.Count -gt 0)   { $summary += "$($rolesRemoved.Count) role(s) removed: $($rolesRemoved -join ', ')" }
    if ($groupsRemoved.Count -gt 0)  { $summary += "$($groupsRemoved.Count) group(s) removed" }
    if ($manualActions.Count -gt 0)  { $summary += "Manual removal required in Entra ID: $($manualActions -join '; ')" }

    $anyWork = $rolesRemoved.Count -gt 0 -or $groupsRemoved.Count -gt 0 -or $manualActions.Count -gt 0 -or $errors.Count -gt 0
    if (-not $anyWork) {
        $result.Status  = 'Skipped'
        $result.Message = 'User had no admin roles or group memberships'
        return $result
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = $summary -join '; '
    }
    else {
        $result.Status  = 'Error'
        $summary += 'ERRORS: ' + ($errors -join '; ')
        $result.Message = $summary -join '; '
    }

    return $result
}
