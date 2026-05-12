function Step-DisableMfa {
    <#
    .SYNOPSIS
        Removes all non-password authentication methods (MFA factors) registered for the user.
    .NOTES
        Requires UserAuthenticationMethod.ReadWrite.All.
        The password authentication method cannot be deleted and is intentionally skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'DisableMfa'
        StepLabel = 'Disable / Reset MFA Methods'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # Map @odata.type to the correct Graph sub-path for DELETE
    $methodSubPaths = @{
        '#microsoft.graph.phoneAuthenticationMethod'                   = 'phoneMethods'
        '#microsoft.graph.fido2AuthenticationMethod'                   = 'fido2Methods'
        '#microsoft.graph.softwareOathAuthenticationMethod'            = 'softwareOathMethods'
        '#microsoft.graph.temporaryAccessPassAuthenticationMethod'     = 'temporaryAccessPassMethods'
        '#microsoft.graph.emailAuthenticationMethod'                   = 'emailMethods'
        '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod' = 'windowsHelloForBusinessMethods'
        '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'  = 'microsoftAuthenticatorMethods'
    }

    # ── Get all registered methods ────────────────────────────────────────────
    $methods = @()
    try {
        $methodsUri  = '/v1.0/users/' + $UserId + '/authentication/methods'
        $methodsResp = Invoke-MgGraphRequest -Method GET -Uri $methodsUri -ErrorAction Stop
        $methods     = @($methodsResp.value)
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to retrieve authentication methods: $_"
        return $result
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    $errors  = [System.Collections.Generic.List[string]]::new()

    foreach ($method in $methods) {
        $odataType = $method.'@odata.type'

        # Skip password — it cannot be deleted
        if ($odataType -eq '#microsoft.graph.passwordAuthenticationMethod') { continue }

        $subPath = $methodSubPaths[$odataType]
        if (-not $subPath) {
            # Unknown method type — skip silently
            continue
        }

        try {
            Invoke-MgGraphRequest -Method DELETE `
                -Uri ('/v1.0/users/' + $UserId + '/authentication/' + $subPath + '/' + $method.id) `
                -ErrorAction Stop
            $removed.Add($odataType.Split('.')[-1] -replace 'AuthenticationMethod', '')
        }
        catch {
            $errors.Add("$($odataType.Split('.')[-1]): $_")
        }
    }

    if ($removed.Count -eq 0 -and $errors.Count -eq 0) {
        $result.Status  = 'Skipped'
        $result.Message = 'No removable MFA methods registered for this user'
        return $result
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = "$($removed.Count) MFA method(s) removed: $($removed -join ', ')"
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
