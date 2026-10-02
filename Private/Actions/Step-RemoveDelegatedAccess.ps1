function Step-RemoveDelegatedAccess {
    <#
    .SYNOPSIS
        Removes mailbox permissions that this user had been granted on other mailboxes.
    .NOTES
        Covers SendAs and Send on Behalf (both queried tenant-wide) and FullAccess.
        FullAccess has no tenant-wide query, so every user, shared, room and equipment
        mailbox is checked one by one — expect roughly 1–2 minutes per 500 mailboxes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{},
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        Step      = 'RemoveDelegatedAccess'
        StepLabel = 'Remove Delegated Mailbox Access'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    $errors  = [System.Collections.Generic.List[string]]::new()

    # Each finding: Kind (SendAs | SendOnBehalf | FullAccess), Mailbox (identity), Label
    # A user with no mail-enabled recipient cannot hold SendAs or Send on Behalf, so
    # "not found" from those lookups means "nothing to remove", not a failure.
    $notFound = { param($err) "$($err.Exception.Message) $($err.ErrorDetails?.Message)" -match "couldn't be found|ManagementObjectNotFound" }
    $found = [System.Collections.Generic.List[hashtable]]::new()

    # ── SendAs ────────────────────────────────────────────────────────────────
    try {
        @(Get-RecipientPermission -Trustee $UserUPN -ResultSize Unlimited -ErrorAction Stop) |
            Where-Object { $_.AccessRights -contains 'SendAs' } |
            ForEach-Object { $found.Add(@{ Kind = 'SendAs'; Mailbox = $_.Identity; Label = "SendAs on $($_.Identity)" }) }
    }
    catch {
        if (-not (& $notFound $_)) { $errors.Add("SendAs query failed: $_") }
    }

    # ── Send on Behalf ────────────────────────────────────────────────────────
    try {
        $dn = (Get-Recipient -Identity $UserUPN -ErrorAction Stop).DistinguishedName
        @(Get-Mailbox -Filter "GrantSendOnBehalfTo -eq '$dn'" -ResultSize Unlimited -ErrorAction Stop) |
            ForEach-Object { $found.Add(@{ Kind = 'SendOnBehalf'; Mailbox = $_.PrimarySmtpAddress; Label = "Send on Behalf on $($_.PrimarySmtpAddress)" }) }
    }
    catch {
        if (-not (& $notFound $_)) { $errors.Add("Send on Behalf query failed: $_") }
    }

    # ── FullAccess (per-mailbox scan) ─────────────────────────────────────────
    $scanFailures = [System.Collections.Generic.List[string]]::new()
    $scanned      = 0
    try {
        $mailboxes = @(Get-Mailbox -RecipientTypeDetails UserMailbox, SharedMailbox, RoomMailbox, EquipmentMailbox `
                                   -ResultSize Unlimited -ErrorAction Stop |
                       Where-Object { $_.ExternalDirectoryObjectId -ne $UserId })
        foreach ($mbx in $mailboxes) {
            $scanned++
            if ($scanned % 250 -eq 0) {
                Write-Host "      FullAccess scan: $scanned / $($mailboxes.Count) mailboxes" -ForegroundColor DarkGray
            }
            try {
                $perms = @(Get-MailboxPermission -Identity $mbx.PrimarySmtpAddress -User $UserUPN -ErrorAction Stop)
                if ($perms | Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited }) {
                    $found.Add(@{ Kind = 'FullAccess'; Mailbox = $mbx.PrimarySmtpAddress; Label = "FullAccess on $($mbx.PrimarySmtpAddress)" })
                }
            }
            catch {
                $scanFailures.Add([string]$mbx.PrimarySmtpAddress)
            }
        }
    }
    catch {
        $errors.Add("Mailbox list for FullAccess scan failed: $_")
    }
    if ($scanFailures.Count -gt 0) {
        $sample = ($scanFailures | Select-Object -First 5) -join ', '
        $errors.Add("FullAccess check failed on $($scanFailures.Count) mailbox(es), verify manually: $sample$(if ($scanFailures.Count -gt 5) { ', …' })")
    }

    # ── What-If: describe changes without applying them ───────────────────────
    if ($WhatIf) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($found.Count -gt 0) { $parts.Add("Would remove $($found.Count) delegated permission(s): $($found.Label -join ', ')") }
        else                    { $parts.Add("No delegated mailbox permissions found ($scanned mailboxes scanned)") }
        if ($errors.Count -gt 0) { $parts.Add('ERRORS: ' + ($errors -join '; ')) }
        $result.Status  = 'WhatIf'
        $result.Message = $parts -join ' | '
        return $result
    }

    # ── Remove ────────────────────────────────────────────────────────────────
    foreach ($item in $found) {
        try {
            switch ($item.Kind) {
                'SendAs' {
                    Remove-RecipientPermission -Identity $item.Mailbox -Trustee $UserUPN -AccessRights SendAs `
                        -Confirm:$false -ErrorAction Stop | Out-Null
                }
                'SendOnBehalf' {
                    Set-Mailbox -Identity $item.Mailbox -GrantSendOnBehalfTo @{ Remove = $UserUPN } -ErrorAction Stop
                }
                'FullAccess' {
                    Remove-MailboxPermission -Identity $item.Mailbox -User $UserUPN -AccessRights FullAccess `
                        -Confirm:$false -ErrorAction Stop | Out-Null
                }
            }
            $removed.Add($item.Label)
        }
        catch {
            $errors.Add("$($item.Label): $_")
        }
    }

    if ($removed.Count -eq 0 -and $errors.Count -eq 0) {
        $result.Status  = 'Skipped'
        $result.Message = "No delegated mailbox permissions found ($scanned mailboxes scanned)"
        return $result
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = "$($removed.Count) permission(s) removed: $($removed -join ', ')"
    }
    else {
        $result.Status  = if ($removed.Count -gt 0) { 'Warning' } else { 'Error' }
        $parts = @()
        if ($removed.Count -gt 0) { $parts += "Removed: $($removed -join ', ')" }
        $parts += 'ERRORS: ' + ($errors -join '; ')
        $result.Message = $parts -join ' | '
    }

    return $result
}
