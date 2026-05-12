function Step-RemoveSharePointAccess {
    <#
    .SYNOPSIS
        Removes the user from SharePoint site memberships using the Microsoft Graph sites API.
    .NOTES
        Scans up to 100 sites. Sites where the user has permissions through a group are handled
        by the CleanupPermissions step (group membership removal). Direct site permissions are
        removed here. Requires Sites.FullControl.All.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'RemoveSharePoint'
        StepLabel = 'Remove SharePoint Site Memberships'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    $errors  = [System.Collections.Generic.List[string]]::new()

    # ── Enumerate sites ───────────────────────────────────────────────────────
    $sites = @()
    try {
        $sitesUri  = '/v1.0/sites?$select=id,displayName,webUrl&$top=100'
        $sitesResp = Invoke-MgGraphRequest -Method GET -Uri $sitesUri -ErrorAction Stop
        $sites     = @($sitesResp.value)
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to enumerate SharePoint sites: $_"
        return $result
    }

    # ── Check and remove per-site permissions ─────────────────────────────────
    foreach ($site in $sites) {
        try {
            $permsUri  = '/v1.0/sites/' + $site.id + '/permissions'
            $permsResp = Invoke-MgGraphRequest -Method GET -Uri $permsUri -ErrorAction SilentlyContinue
            if (-not $permsResp) { continue }

            foreach ($perm in $permsResp.value) {
                # Check if this permission involves our user
                $grantedToList = @()
                if ($perm.grantedToIdentitiesV2) {
                    $grantedToList = @($perm.grantedToIdentitiesV2 | ForEach-Object { $_.user })
                }
                elseif ($perm.grantedToV2) {
                    $grantedToList = @($perm.grantedToV2.user)
                }

                $isUser = $grantedToList | Where-Object { $_ -and ($_.id -eq $UserId -or $_.email -eq $UserUPN) }
                if ($isUser) {
                    try {
                        Invoke-MgGraphRequest -Method DELETE `
                            -Uri ('/v1.0/sites/' + $site.id + '/permissions/' + $perm.id) `
                            -ErrorAction Stop
                        $removed.Add($site.displayName ?? $site.webUrl)
                    }
                    catch {
                        $errors.Add("Site '$($site.displayName)': $_")
                    }
                }
            }
        }
        catch {
            Write-Verbose "Step-RemoveSharePointAccess: site permission check suppressed for '$($site.displayName)' — $_"
        }
    }

    if ($removed.Count -eq 0 -and $errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = 'No direct SharePoint site permissions found. Group-based access is handled by the Cleanup Permissions step.'
        return $result
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = "Direct site permissions removed from $($removed.Count) site(s): $($removed -join ', ')"
    }
    else {
        $result.Status  = 'Error'
        $parts = @()
        if ($removed.Count -gt 0) { $parts += "Removed from: $($removed -join ', ')" }
        $parts += 'ERRORS: ' + ($errors -join '; ')
        $result.Message = $parts -join ' | '
    }

    return $result
}
