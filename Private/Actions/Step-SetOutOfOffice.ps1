function Step-SetOutOfOffice {
    <#
    .SYNOPSIS
        Enables out-of-office auto-reply on the user's mailbox.
    .NOTES
        Config keys:
          internalMessage — message sent to internal senders (required)
          message         — message sent to external senders (falls back to internalMessage)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'SetOutOfOffice'
        StepLabel = 'Set Out of Office'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $internalMsg = ($Config['internalMessage'] ?? '').Trim()
    $externalMsg = ($Config['message'] ?? '').Trim()

    if (-not $internalMsg) {
        $internalMsg = "This user has left the organisation. Please contact your manager or IT for assistance."
    }
    if (-not $externalMsg) {
        $externalMsg = $internalMsg
    }

    try {
        Set-MailboxAutoReplyConfiguration `
            -Identity        $UserUPN `
            -AutoReplyState  Enabled `
            -InternalMessage $internalMsg `
            -ExternalMessage $externalMsg `
            -ErrorAction Stop

        $result.Status  = 'Success'
        $result.Message = 'Out-of-office auto-reply enabled (internal and external)'
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to set out-of-office: $_"
    }

    return $result
}
