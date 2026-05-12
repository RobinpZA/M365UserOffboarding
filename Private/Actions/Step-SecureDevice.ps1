function Step-SecureDevice {
    <#
    .SYNOPSIS
        Retires (BYOD) or wipes (company) Intune-managed devices belonging to the user.
    .NOTES
        Config keys:
          action — 'Wipe' (retire BYOD — removes company data) or 'Reset' (full factory wipe)

        This step is automatically skipped if the tenant has no Intune licence
        or if the user has no managed devices.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'SecureDevice'
        StepLabel = 'Secure Device (Intune)'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # ── Intune licence check ───────────────────────────────────────────────────
    if (-not $script:HasIntuneLicense) {
        $result.Status  = 'Skipped'
        $result.Message = 'Tenant does not have an Intune licence — step skipped'
        return $result
    }

    $action = ($Config['action'] ?? 'Wipe').Trim()

    # ── Get managed devices ───────────────────────────────────────────────────
    $devices = @()
    try {
        # Use the user-scoped endpoint — the global managedDevices endpoint
        # rejects $filter=userId with 400 when routed through the Intune proxy.
        $devUri  = '/v1.0/users/' + $UserId + '/managedDevices'
        $devResp = Invoke-MgGraphRequest -Method GET -Uri $devUri -ErrorAction Stop
        $devices = @($devResp.value)
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to retrieve managed devices: $_"
        return $result
    }

    if ($devices.Count -eq 0) {
        $result.Status  = 'Skipped'
        $result.Message = 'No Intune-managed devices found for this user'
        return $result
    }

    $messages = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    foreach ($device in $devices) {
        $deviceId   = $device.id
        $deviceName = $device.deviceName ?? $deviceId

        try {
            if ($action -eq 'Reset') {
                # Full factory wipe — company-owned devices
                Invoke-MgGraphRequest -Method POST `
                    -Uri ('/v1.0/deviceManagement/managedDevices/' + $deviceId + '/wipe') `
                    -Body (@{ keepEnrollmentData = $false; keepUserData = $false } | ConvertTo-Json -Compress) `
                    -ContentType 'application/json' `
                    -ErrorAction Stop | Out-Null
                $messages.Add("Device '$deviceName' wiped (full reset)")
            }
            else {
                # Retire — removes company data from BYOD device
                Invoke-MgGraphRequest -Method POST `
                    -Uri ('/v1.0/deviceManagement/managedDevices/' + $deviceId + '/retire') `
                    -Body '{}' `
                    -ContentType 'application/json' `
                    -ErrorAction Stop | Out-Null
                $messages.Add("Device '$deviceName' retired (company data removed)")
            }
        }
        catch {
            $errors.Add("Device '$deviceName' action failed: $_")
        }
    }

    if ($errors.Count -eq 0) {
        $result.Status  = 'Success'
        $result.Message = $messages -join '; '
    }
    else {
        $result.Status  = 'Error'
        $combined = if ($messages.Count -gt 0) { ($messages -join '; ') + ' | ERRORS: ' + ($errors -join '; ') } else { $errors -join '; ' }
        $result.Message = $combined
    }

    return $result
}
