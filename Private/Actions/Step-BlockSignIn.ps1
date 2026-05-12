function Step-BlockSignIn {
    <#
    .SYNOPSIS
        Blocks the user's sign-in and revokes all active sessions / refresh tokens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'BlockSignIn'
        StepLabel = 'Block Sign-In & Revoke Sessions'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $messages = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    # ── Block sign-in ─────────────────────────────────────────────────────────
    try {
        Invoke-MgGraphRequest -Method PATCH `
            -Uri ('/v1.0/users/' + $UserId) `
            -Body (@{ accountEnabled = $false } | ConvertTo-Json -Compress) `
            -ContentType 'application/json' `
            -ErrorAction Stop
        $messages.Add('Sign-in blocked (accountEnabled = false)')
    }
    catch {
        $errors.Add("Block sign-in failed: $_")
    }

    # ── Revoke all refresh tokens / sessions ──────────────────────────────────
    try {
        Invoke-MgGraphRequest -Method POST `
            -Uri ('/v1.0/users/' + $UserId + '/revokeSignInSessions') `
            -Body '{}' `
            -ContentType 'application/json' `
            -ErrorAction Stop | Out-Null
        $messages.Add('All active sessions revoked')
    }
    catch {
        $errors.Add("Revoke sessions failed: $_")
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = $messages -join '; '
    }
    elseif ($messages.Count -gt 0) {
        $result.Status  = 'Error'
        $result.Message = ($messages -join '; ') + ' | ERRORS: ' + ($errors -join '; ')
    }
    else {
        $result.Status  = 'Error'
        $result.Message = $errors -join '; '
    }

    return $result
}
