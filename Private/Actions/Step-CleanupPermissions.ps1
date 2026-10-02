function Step-CleanupPermissions {
    <#
    .SYNOPSIS
        Removes the user's admin roles (active and PIM-eligible) and group memberships.
    .NOTES
        Roles come from the unified role management API, so assignments scoped to an
        administrative unit and PIM-eligible assignments are included — memberOf only
        shows active tenant-wide roles. Removing roles needs Privileged Role Administrator.
        Teams-connected groups are left to Step-RemoveTeamsAndDLs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{},
        [switch]$WhatIf
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
    $memberships = [System.Collections.Generic.List[object]]::new()
    try {
        $memUri = '/v1.0/users/' + $UserId + '/memberOf?$select=id,displayName,resourceProvisioningOptions&$top=100'
        do {
            $memResp = Invoke-MgGraphRequest -Method GET -Uri $memUri -ErrorAction Stop
            $memberships.AddRange([object[]]@($memResp.value))
            $memUri = $memResp.'@odata.nextLink'
        } while ($memUri)
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to retrieve memberships: $_"
        return $result
    }

    # ── Get role assignments (active and PIM-eligible) ────────────────────────
    $roleFilter = '?$filter=principalId eq ''' + $UserId + '''&$expand=roleDefinition($select=displayName)'
    $activeRoles = @()
    try {
        $resp        = Invoke-MgGraphRequest -Method GET -Uri ('/v1.0/roleManagement/directory/roleAssignments' + $roleFilter) -ErrorAction Stop
        $activeRoles = @($resp.value)
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to retrieve role assignments: $_"
        return $result
    }

    $eligibleRoles = @()
    $pimNote       = ''
    try {
        $resp          = Invoke-MgGraphRequest -Method GET -Uri ('/v1.0/roleManagement/directory/roleEligibilitySchedules' + $roleFilter) -ErrorAction Stop
        $eligibleRoles = @($resp.value)
    }
    catch {
        $errFull = $_.Exception.Message + ' ' + ($_.ErrorDetails?.Message ?? '')
        # Tenants without Entra ID P2 have no PIM, so there is nothing eligible to remove.
        if ($errFull -notmatch 'AadPremiumLicenseRequired|PremiumLicense|P2') {
            $pimNote = "Could not check PIM-eligible roles: $_"
        }
    }

    $roleLabel = { param($r, $kind) "$($r.roleDefinition.displayName ?? $r.roleDefinitionId) ($kind$(if ($r.directoryScopeId -and $r.directoryScopeId -ne '/') { ', scoped' }))" }

    # ── What-If: describe changes without applying them ───────────────────────
    if ($WhatIf) {
        $rolesFound  = @($eligibleRoles | ForEach-Object { & $roleLabel $_ 'eligible' }) +
                       @($activeRoles   | ForEach-Object { & $roleLabel $_ 'active' })
        $groupsFound = @($memberships | Where-Object {
            $_.'@odata.type' -eq '#microsoft.graph.group' -and
            ($_.resourceProvisioningOptions -notcontains 'Team')
        })
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($rolesFound.Count -gt 0)  { $parts.Add("$($rolesFound.Count) admin role(s) to remove: $($rolesFound -join ', ')") }
        if ($groupsFound.Count -gt 0) { $parts.Add("$($groupsFound.Count) group(s) to remove") }
        if ($pimNote)                 { $parts.Add($pimNote) }
        if ($parts.Count -eq 0)       { $parts.Add('No admin roles or non-Teams group memberships found') }
        $result.Status  = 'WhatIf'
        $result.Message = $parts -join '; '
        return $result
    }

    if ($pimNote) { $errors.Add($pimNote) }

    # ── Remove PIM-eligible roles first, so they cannot be activated meanwhile ─
    foreach ($role in $eligibleRoles) {
        $label = & $roleLabel $role 'eligible'
        try {
            $body = @{
                action           = 'adminRemove'
                principalId      = $UserId
                roleDefinitionId = $role.roleDefinitionId
                directoryScopeId = $role.directoryScopeId ?? '/'
                justification    = 'User offboarding'
            } | ConvertTo-Json -Compress
            Invoke-MgGraphRequest -Method POST `
                -Uri '/v1.0/roleManagement/directory/roleEligibilityScheduleRequests' `
                -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $rolesRemoved.Add($label)
        }
        catch {
            $errors.Add("Role $label`: $_")
        }
    }

    # ── Remove active roles ───────────────────────────────────────────────────
    # Permanent assignments delete directly; PIM-activated or time-bound ones refuse
    # the DELETE and need an adminRemove schedule request instead.
    foreach ($role in $activeRoles) {
        $label = & $roleLabel $role 'active'
        try {
            Invoke-MgGraphRequest -Method DELETE `
                -Uri ('/v1.0/roleManagement/directory/roleAssignments/' + $role.id) `
                -ErrorAction Stop
            $rolesRemoved.Add($label)
        }
        catch {
            $deleteError = $_
            try {
                $body = @{
                    action           = 'adminRemove'
                    principalId      = $UserId
                    roleDefinitionId = $role.roleDefinitionId
                    directoryScopeId = $role.directoryScopeId ?? '/'
                    justification    = 'User offboarding'
                } | ConvertTo-Json -Compress
                Invoke-MgGraphRequest -Method POST `
                    -Uri '/v1.0/roleManagement/directory/roleAssignmentScheduleRequests' `
                    -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
                $rolesRemoved.Add($label)
            }
            catch {
                $errors.Add("Role $label`: $deleteError")
            }
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
        $result.Status  = if ($summary.Count -gt 0) { 'Warning' } else { 'Error' }
        $summary += 'ERRORS: ' + ($errors -join '; ')
        $result.Message = $summary -join '; '
    }

    return $result
}
