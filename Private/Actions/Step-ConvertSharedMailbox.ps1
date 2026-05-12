function Step-ConvertSharedMailbox {
    <#
    .SYNOPSIS
        Converts the user's mailbox to a shared mailbox and optionally assigns delegate access.
    .NOTES
        Config keys:
          delegateUpn  — UPN of the person to grant FullAccess + SendAs (optional)
          hideFromGal  — $true to hide the shared mailbox from the Global Address List (optional)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'ConvertSharedMailbox'
        StepLabel = 'Convert to Shared Mailbox'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $messages = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    # ── Convert mailbox type ──────────────────────────────────────────────────
    try {
        Set-Mailbox -Identity $UserUPN -Type Shared -ErrorAction Stop
        $messages.Add('Mailbox converted to Shared')
    }
    catch {
        $errors.Add("Convert to shared failed: $_")
    }

    # ── Hide from GAL ─────────────────────────────────────────────────────────
    $hideFromGal = $Config['hideFromGal'] -eq $true
    if ($hideFromGal) {
        try {
            Set-Mailbox -Identity $UserUPN -HiddenFromAddressListsEnabled $true -ErrorAction Stop
            $messages.Add('Mailbox hidden from GAL')
        }
        catch {
            $errors.Add("Hide from GAL failed: $_")
        }
    }

    # ── Assign delegate access ────────────────────────────────────────────────
    $delegateUpn = ($Config['delegateUpn'] ?? '').Trim()
    if ($delegateUpn) {
        try {
            Add-MailboxPermission -Identity $UserUPN `
                -User $delegateUpn `
                -AccessRights FullAccess `
                -AutoMapping $false `
                -ErrorAction Stop | Out-Null
            $messages.Add("FullAccess granted to $delegateUpn")
        }
        catch {
            $errors.Add("FullAccess grant failed: $_")
        }

        try {
            Add-RecipientPermission -Identity $UserUPN `
                -Trustee $delegateUpn `
                -AccessRights SendAs `
                -Confirm:$false `
                -ErrorAction Stop | Out-Null
            $messages.Add("SendAs granted to $delegateUpn")
        }
        catch {
            $errors.Add("SendAs grant failed: $_")
        }
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = $messages -join '; '
    }
    else {
        $result.Status  = 'Error'
        $combined       = if ($messages.Count -gt 0) { ($messages -join '; ') + ' | ERRORS: ' + ($errors -join '; ') } else { $errors -join '; ' }
        $result.Message = $combined
    }

    return $result
}
