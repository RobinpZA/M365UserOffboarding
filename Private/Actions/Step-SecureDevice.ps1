function Step-SecureDevice {
    <#
    .SYNOPSIS
        Retires or wipes the user's Intune-managed devices, chosen per device by ownership.
    .NOTES
        Config keys:
          companyAction — what to do with company-owned devices: 'Retire' (default,
                          removes company data) or 'Wipe' (full factory reset)

        Personal (BYOD) devices and devices with unknown ownership are always retired,
        never wiped, so an employee's own phone is never factory-reset.

        This step is automatically skipped if the tenant has no Intune licence
        or if the user has no managed devices.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{},
        [switch]$WhatIf
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

    $companyAction = if (($Config['companyAction'] ?? '').Trim() -eq 'Wipe') { 'Wipe' } else { 'Retire' }

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

    # Only devices Intune reports as company-owned can be wiped.
    $plan = @($devices | ForEach-Object {
        @{
            Device = $_
            Name   = $_.deviceName ?? $_.id
            Action = if ($_.managedDeviceOwnerType -eq 'company') { $companyAction } else { 'Retire' }
        }
    })

    # ── What-If: describe changes without applying them ───────────────────────
    if ($WhatIf) {
        $lines = $plan | ForEach-Object {
            $label = if ($_.Action -eq 'Wipe') { 'factory wipe' } else { 'retire' }
            "$label '$($_.Name)' ($($_.Device.managedDeviceOwnerType ?? 'unknown'))"
        }
        $result.Status  = 'WhatIf'
        $result.Message = "Would $($lines -join '; ')"
        return $result
    }

    $messages = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $plan) {
        $deviceId   = $item.Device.id
        $deviceName = $item.Name

        try {
            if ($item.Action -eq 'Wipe') {
                # Full factory wipe — company-owned devices only
                Invoke-MgGraphRequest -Method POST `
                    -Uri ('/v1.0/deviceManagement/managedDevices/' + $deviceId + '/wipe') `
                    -Body (@{ keepEnrollmentData = $false; keepUserData = $false } | ConvertTo-Json -Compress) `
                    -ContentType 'application/json' `
                    -ErrorAction Stop | Out-Null
                $messages.Add("Device '$deviceName' wiped (full reset)")
            }
            else {
                # Retire — removes company data, leaves personal data
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
        $result.Status  = if ($messages.Count -gt 0) { 'Warning' } else { 'Error' }
        $combined = if ($messages.Count -gt 0) { ($messages -join '; ') + ' | ERRORS: ' + ($errors -join '; ') } else { $errors -join '; ' }
        $result.Message = $combined
    }

    return $result
}
