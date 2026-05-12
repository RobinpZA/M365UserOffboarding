function Step-RemoveLicenses {
    <#
    .SYNOPSIS
        Removes all Microsoft 365 licences assigned to the user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$UserId,
        [Parameter(Mandatory)] [string]$UserUPN,
        [hashtable]$Config = @{}
    )

    $result = [PSCustomObject]@{
        Step      = 'RemoveLicenses'
        StepLabel = 'Remove All Licences'
        UserId    = $UserId
        UserUPN   = $UserUPN
        Status    = 'Error'
        Message   = ''
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # ── Get assigned licences ─────────────────────────────────────────────────
    $skuIds = @()
    try {
        $licUri  = '/v1.0/users/' + $UserId + '/licenseDetails'
        $licResp = Invoke-MgGraphRequest -Method GET -Uri $licUri -ErrorAction Stop
        $skuIds  = @($licResp.value | ForEach-Object { $_.skuId } | Where-Object { $_ })
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to retrieve licences: $_"
        return $result
    }

    if ($skuIds.Count -eq 0) {
        $result.Status  = 'Skipped'
        $result.Message = 'User has no assigned licences'
        return $result
    }

    # ── Remove all licences in one call ───────────────────────────────────────
    try {
        $body = @{
            addLicenses    = @()
            removeLicenses = $skuIds
        } | ConvertTo-Json -Compress

        Invoke-MgGraphRequest -Method POST `
            -Uri ('/v1.0/users/' + $UserId + '/assignLicense') `
            -Body $body `
            -ContentType 'application/json' `
            -ErrorAction Stop | Out-Null

        $result.Status  = 'Success'
        $result.Message = "$($skuIds.Count) licence(s) removed"
    }
    catch {
        $result.Status  = 'Error'
        $result.Message = "Failed to remove licences: $_"
    }

    return $result
}
