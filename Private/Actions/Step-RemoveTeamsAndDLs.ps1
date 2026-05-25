function Step-RemoveTeamsAndDLs {
    <#
    .SYNOPSIS
        Removes the user from all Microsoft Teams they are a member of, and from Exchange distribution lists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{},
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        Step      = 'RemoveTeamsAndDLs'
        StepLabel = 'Remove from Teams & Distribution Lists'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    $errors  = [System.Collections.Generic.List[string]]::new()

    # ── What-If: describe changes without applying them ───────────────────────
    if ($WhatIf) {
        $teamsFound = [System.Collections.Generic.List[string]]::new()
        $dlsFound   = [System.Collections.Generic.List[string]]::new()

        try {
            $memUri  = '/v1.0/users/' + $UserId + '/memberOf?$select=id,displayName,resourceProvisioningOptions&$top=100'
            $memResp = Invoke-MgGraphRequest -Method GET -Uri $memUri -ErrorAction Stop
            @($memResp.value | Where-Object {
                $_.'@odata.type' -eq '#microsoft.graph.group' -and
                $_.resourceProvisioningOptions -contains 'Team'
            }) | ForEach-Object { $teamsFound.Add($_.displayName) }
        }
        catch { $teamsFound.Add('(error reading Teams memberships)') }

        try {
            $mbx = Get-Mailbox -Identity $UserUPN -ErrorAction SilentlyContinue
            if ($mbx) {
                $dn  = $mbx.DistinguishedName
                @(Get-DistributionGroup -Filter "Members -eq '$dn'" -ErrorAction SilentlyContinue) |
                    ForEach-Object { $dlsFound.Add($_.DisplayName) }
            }
        }
        catch { }

        $parts = [System.Collections.Generic.List[string]]::new()
        if ($teamsFound.Count -gt 0) { $parts.Add("Would remove from $($teamsFound.Count) Team(s): $($teamsFound -join ', ')") }
        if ($dlsFound.Count -gt 0)   { $parts.Add("Would remove from $($dlsFound.Count) distribution list(s): $($dlsFound -join ', ')") }
        if ($parts.Count -eq 0)      { $parts.Add('No Teams memberships or distribution list memberships found') }
        $result.Status  = 'WhatIf'
        $result.Message = $parts -join '; '
        return $result
    }

    # ── Microsoft Teams ───────────────────────────────────────────────────────
    # Query memberOf and filter for Teams-connected M365 groups.
    # Using joinedTeams is unreliable — it only returns teams the user has
    # actively opened in the Teams client, missing users added via group
    # membership who never launched the app.
    # Removal is done via the Groups API on the backing M365 group, which is
    # authoritative and avoids the pagination/lookup issues of the Teams
    # membership endpoint.
    try {
        $memUri  = '/v1.0/users/' + $UserId + '/memberOf?$select=id,displayName,resourceProvisioningOptions&$top=100'
        $memResp = Invoke-MgGraphRequest -Method GET -Uri $memUri -ErrorAction Stop
        $teams   = @($memResp.value | Where-Object {
            $_.'@odata.type' -eq '#microsoft.graph.group' -and
            $_.resourceProvisioningOptions -contains 'Team'
        })

        foreach ($team in $teams) {
            try {
                Invoke-MgGraphRequest -Method DELETE `
                    -Uri ('/v1.0/groups/' + $team.id + '/members/' + $UserId + '/$ref') `
                    -ErrorAction Stop
                $removed.Add("Teams: $($team.displayName)")
            }
            catch {
                $errors.Add("Teams '$($team.displayName)': $_")
            }
        }
    }
    catch {
        $errors.Add("Failed to retrieve Teams memberships: $_")
    }

    # ── Exchange Distribution Lists ───────────────────────────────────────────
    try {
        # Resolve the mailbox's DistinguishedName (needed for DL filter)
        $mbx = Get-Mailbox -Identity $UserUPN -ErrorAction SilentlyContinue
        if ($mbx) {
            $dn  = $mbx.DistinguishedName
            $dls = @(Get-DistributionGroup -Filter "Members -eq '$dn'" -ErrorAction SilentlyContinue)

            foreach ($dl in $dls) {
                try {
                    Remove-DistributionGroupMember -Identity $dl.PrimarySmtpAddress `
                        -Member $UserUPN `
                        -Confirm:$false `
                        -ErrorAction Stop
                    $removed.Add("DL: $($dl.DisplayName)")
                }
                catch {
                    $errors.Add("DL '$($dl.DisplayName)': $_")
                }
            }
        }
    }
    catch {
        $errors.Add("Failed to process distribution lists: $_")
    }

    if ($removed.Count -eq 0 -and $errors.Count -eq 0) {
        $result.Status  = 'Skipped'
        $result.Message = 'User had no Teams memberships or distribution list memberships'
        return $result
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = "Removed from $($removed.Count) group(s): $($removed -join ', ')"
    }
    else {
        $result.Status  = 'Error'
        $parts = @()
        if ($removed.Count -gt 0) { $parts += "Removed: $($removed -join ', ')" }
        $parts += 'ERRORS: ' + ($errors -join '; ')
        $result.Message = $parts -join ' | '
    }

    return $result
}
