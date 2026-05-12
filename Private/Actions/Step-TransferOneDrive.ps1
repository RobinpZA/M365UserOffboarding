function Step-TransferOneDrive {
    <#
    .SYNOPSIS
        Grants the user's manager write access to their OneDrive, enabling data retrieval before the account is deleted.
    .NOTES
        Requires Sites.FullControl.All permission.
        If the user has no manager, the step is skipped with a warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'TransferOneDrive'
        StepLabel = 'Transfer OneDrive Access to Manager'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # ── Resolve manager ───────────────────────────────────────────────────────
    $managerUpn = ''
    try {
        $mgrUri = '/v1.0/users/' + $UserId + '/manager?$select=userPrincipalName,displayName'
        $mgr    = Invoke-MgGraphRequest -Method GET -Uri $mgrUri -ErrorAction Stop
        $managerUpn = $mgr.userPrincipalName
    }
    catch {
        $result.Status  = 'Skipped'
        $result.Message = 'No manager found for user — OneDrive access not transferred. Assign manually via SharePoint admin.'
        return $result
    }

    if (-not $managerUpn) {
        $result.Status  = 'Skipped'
        $result.Message = 'Manager has no UPN — cannot grant OneDrive access automatically'
        return $result
    }

    # ── Get user's OneDrive ───────────────────────────────────────────────────
    $driveId = ''
    try {
        $driveUri = '/v1.0/users/' + $UserId + '/drive?$select=id,webUrl'
        $drive    = Invoke-MgGraphRequest -Method GET -Uri $driveUri -ErrorAction Stop
        $driveId  = $drive.id
    }
    catch {
        # 404 ResourceNotFound means the user never had a OneDrive provisioned.
        # Check both Exception.Message and the HTTP response body (ErrorDetails.Message) since
        # Invoke-MgGraphRequest stores the Graph error code in the response body, not just the exception.
        $errFull = $_.Exception.Message + ' ' + ($_.ErrorDetails?.Message ?? '')
        if ($errFull -match 'ResourceNotFound|mysite not found|404') {
            $result.Status  = 'Skipped'
            $result.Message = "User's OneDrive has not been provisioned — no data to transfer"
        }
        else {
            $result.Status  = 'Error'
            $result.Message = "Failed to get user's OneDrive: $_"
        }
        return $result
    }

    # ── Invite manager as contributor ─────────────────────────────────────────
    try {
        $inviteBody = @{
            requireSignIn  = $true
            sendInvitation = $false
            roles          = @('write')
            recipients     = @(@{ email = $managerUpn })
        } | ConvertTo-Json -Depth 5 -Compress

        Invoke-MgGraphRequest -Method POST `
            -Uri ('/v1.0/drives/' + $driveId + '/root/invite') `
            -Body $inviteBody `
            -ContentType 'application/json' `
            -ErrorAction Stop | Out-Null

        $result.Status  = 'Success'
        $result.Message = "Write access to OneDrive granted to manager: $managerUpn"
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to grant OneDrive access to manager: $_"
    }

    return $result
}
