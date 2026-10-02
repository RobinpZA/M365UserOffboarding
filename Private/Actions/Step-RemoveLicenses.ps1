function Step-RemoveLicenses {
    <#
    .SYNOPSIS
        Removes all Microsoft 365 licences assigned to the user.
    .NOTES
        Config keys:
          convertSharedEnabled — set by Invoke-OffboardUsers; $true when the Convert to
                                 Shared Mailbox step is enabled in the same run
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{},
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        Step      = 'RemoveLicenses'
        StepLabel = 'Remove All Licences'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # ── Get assigned licences ─────────────────────────────────────────────────
    $skuIds = @()
    try {
        $licUri  = '/v1.0/users/' + $UserId + '/licenseDetails'
        $licResp = Invoke-MgGraphRequest -Method GET -Uri $licUri -ErrorAction Stop
        $skuIds  = @($licResp.value | ForEach-Object { $_.skuId } | Where-Object { $_ })
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to retrieve licences: $_"
        return $result
    }

    if ($skuIds.Count -eq 0) {
        $result.Status  = 'Skipped'
        $result.Message = 'User has no assigned licences'
        return $result
    }
    # ── Mailbox safety check ──────────────────────────────────────────────────
    # A shared mailbox still needs a licence when it is over 50 GB, has an archive,
    # or is on hold — those block removal. A mailbox that is still a user mailbox is
    # soft-deleted 30 days after its licence goes; that may be intended (the operator
    # left Convert to Shared off), so it only raises a warning.
    $blockers       = [System.Collections.Generic.List[string]]::new()
    $deletionNotice = ''
    try {
        $mbx = Get-Mailbox -Identity $UserUPN -ErrorAction Stop
        # In What-If the conversion step has not really run, so the type is still
        # UserMailbox — only warn when conversion is not part of this run.
        $staysUserMailbox = $mbx.RecipientTypeDetails -eq 'UserMailbox' -and
                            -not ($WhatIf -and $Config['convertSharedEnabled'] -eq $true)
        if ($staysUserMailbox) {
            $deletionNotice = 'WARNING: mailbox was not converted to Shared and will be permanently deleted 30 days after licence removal'
        }
        if ($mbx.LitigationHoldEnabled)             { $blockers.Add('litigation hold is enabled') }
        if (@($mbx.InPlaceHolds).Count -gt 0)       { $blockers.Add("$(@($mbx.InPlaceHolds).Count) in-place/retention hold(s)") }
        if ($mbx.ArchiveStatus -eq 'Active')        { $blockers.Add('archive mailbox is active') }

        $stats = Get-MailboxStatistics -Identity $UserUPN -ErrorAction Stop
        if ("$($stats.TotalItemSize)" -match '\(([\d,]+) bytes\)') {
            $sizeBytes = [long]($Matches[1] -replace ',', '')
            if ($sizeBytes -gt 50GB) { $blockers.Add("mailbox is $([Math]::Round($sizeBytes / 1GB, 1)) GB (over the 50 GB shared limit)") }
        }
    }
    catch {
        $errFull = $_.Exception.Message + ' ' + ($_.ErrorDetails?.Message ?? '')
        if ($errFull -notmatch "couldn't be found|ManagementObjectNotFound") {
            $result.Status  = 'Error'
            $result.Message = "Licences not removed: could not verify mailbox state ($_)"
            return $result
        }
        # No mailbox — nothing in Exchange depends on the licence.
    }

    if ($blockers.Count -gt 0) {
        $result.Status  = if ($WhatIf) { 'WhatIf' } else { 'Skipped' }
        $verb           = if ($WhatIf) { 'Would not remove' } else { 'Not removed' }
        $result.Message = "$verb licences — mailbox still needs one: $($blockers -join '; ')"
        return $result
    }

    # ── What-If: describe changes without applying them ───────────────────────
    # $licResp is always set by this point — the catch above returns on failure.
    if ($WhatIf) {
        $skuNames = $licResp.value | ForEach-Object { $_.skuPartNumber ?? $_.skuId }
        $result.Status  = 'WhatIf'
        $result.Message = "Would remove $($skuIds.Count) licence(s): $($skuNames -join ', ')"
        if ($deletionNotice) { $result.Message += " | $deletionNotice" }
        return $result
    }
    # ── Remove all licences in one call ───────────────────────────────────────
    try {
        $body = @{
            addLicenses    = @()
            removeLicenses = $skuIds
        } | ConvertTo-Json -Compress

        Invoke-MgGraphRequest -Method POST `
            -Uri ('/v1.0/users/' + $UserId + '/assignLicense') `
            -Body $body `
            -ContentType 'application/json' `
            -ErrorAction Stop | Out-Null

        if ($deletionNotice) {
            $result.Status  = 'Warning'
            $result.Message = "$($skuIds.Count) licence(s) removed | $deletionNotice"
        }
        else {
            $result.Status  = 'Success'
            $result.Message = "$($skuIds.Count) licence(s) removed"
        }
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to remove licences: $_"
    }

    return $result
}
