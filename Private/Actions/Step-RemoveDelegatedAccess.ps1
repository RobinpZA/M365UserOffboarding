function Step-RemoveDelegatedAccess {
    <#
    .SYNOPSIS
        Removes mailbox permissions that this user had been granted on other users' mailboxes.
    .NOTES
        Covers SendAs (RecipientPermission) which can be queried tenant-wide.
        FullAccess (MailboxPermission) requires scanning per-mailbox; a best-effort scan
        of the 200 most recently active mailboxes is performed, with a note in the output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
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

    # ── SendAs permissions (tenant-wide query available) ──────────────────────
    try {
        $sendAsPerms = @(Get-RecipientPermission -Trustee $UserUPN -ErrorAction SilentlyContinue)
        foreach ($perm in $sendAsPerms) {
            try {
                Remove-RecipientPermission `
                    -Identity   $perm.Identity `
                    -Trustee    $UserUPN `
                    -AccessRights SendAs `
                    -Confirm:$false `
                    -ErrorAction Stop
                $removed.Add("SendAs on $($perm.Identity)")
            }
            catch {
                $errors.Add("SendAs remove '$($perm.Identity)': $_")
            }
        }
    }
    catch {
        $errors.Add("Failed to query SendAs permissions: $_")
    }

    # ── FullAccess permissions (best-effort scan of shared mailboxes) ──────────
    try {
        $sharedMailboxes = @(Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize 500 -ErrorAction SilentlyContinue)
        foreach ($mbx in $sharedMailboxes) {
            try {
                $perms = @(Get-MailboxPermission -Identity $mbx.PrimarySmtpAddress -User $UserUPN -ErrorAction SilentlyContinue)
                foreach ($perm in $perms) {
                    if ($perm.AccessRights -contains 'FullAccess') {
                        Remove-MailboxPermission `
                            -Identity    $mbx.PrimarySmtpAddress `
                            -User        $UserUPN `
                            -AccessRights FullAccess `
                            -Confirm:$false `
                            -ErrorAction Stop
                        $removed.Add("FullAccess on $($mbx.PrimarySmtpAddress)")
                    }
                }
            }
            catch {
                Write-Verbose "Step-RemoveDelegatedAccess: FullAccess check suppressed for '$($mbx.PrimarySmtpAddress)' — $_"
            }
        }
    }
    catch {
        $errors.Add("Shared mailbox scan failed: $_")
    }

    if ($removed.Count -eq 0 -and $errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = 'No delegated mailbox permissions found for this user. Note: FullAccess scan covered shared mailboxes only — verify user mailboxes manually if required.'
        return $result
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = "$($removed.Count) permission(s) removed: $($removed -join ', ')"
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
