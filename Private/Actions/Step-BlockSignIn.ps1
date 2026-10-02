function Step-BlockSignIn {
    <#
    .SYNOPSIS
        Blocks the user's sign-in and revokes all active sessions / refresh tokens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{},
        [switch]$WhatIf
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

    # ── Current state ─────────────────────────────────────────────────────────
    # Synced (hybrid) accounts are mastered on-premises: Graph refuses to change
    # accountEnabled, and the next sync would undo it anyway.
    $currentStatus = 'status unknown'
    $isSynced      = $false
    try {
        $userInfo = Invoke-MgGraphRequest -Method GET `
            -Uri ('/v1.0/users/' + $UserId + '?$select=accountEnabled,onPremisesSyncEnabled') `
            -ErrorAction Stop
        $currentStatus = if ($userInfo.accountEnabled) { 'currently enabled' } else { 'already blocked' }
        $isSynced      = $userInfo.onPremisesSyncEnabled -eq $true
    }
    catch {
        Write-Verbose "Step-BlockSignIn: state lookup suppressed for $UserId — $_"
    }
    $syncedNote = 'Account is synced from on-premises AD — disable it in on-premises AD; a cloud-only block would be overwritten at the next sync'

    # ── What-If: describe changes without applying them ───────────────────────
    if ($WhatIf) {
        $result.Status  = 'WhatIf'
        $result.Message = if ($isSynced) {
            "Would revoke all active sessions; would NOT block sign-in. $syncedNote"
        }
        else {
            "Would block sign-in ($currentStatus) and revoke all active sessions"
        }
        return $result
    }

    # ── Block sign-in ─────────────────────────────────────────────────────────
    if ($isSynced) {
        $errors.Add($syncedNote)
    }
    else {
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
        $result.Status  = 'Warning'
        $result.Message = ($messages -join '; ') + ' | ERRORS: ' + ($errors -join '; ')
    }
    else {
        $result.Status  = 'Error'
        $result.Message = $errors -join '; '
    }

    return $result
}
