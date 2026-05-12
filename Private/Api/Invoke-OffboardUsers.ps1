function Invoke-OffboardUsers {
    <#
    .SYNOPSIS
        Orchestrates the offboarding workflow for one or more users.
    .PARAMETER RequestBody
        Hashtable parsed from the POST /api/offboard JSON body.
        Expected: { userIds: string[], steps: { StepKey: { enabled: bool, ...config } } }
    #>
    [CmdletBinding()]
    param(
        [hashtable]$RequestBody
    )

    if (-not $RequestBody) {
        return @{ success = $false; error = 'Missing request body' }
    }

    $userIds     = $RequestBody['userIds']
    $stepsConfig = $RequestBody['steps']

    if (-not $userIds -or $userIds.Count -eq 0) {
        return @{ success = $false; error = 'No users specified' }
    }
    if (-not $stepsConfig) {
        return @{ success = $false; error = 'No steps configuration provided' }
    }

    # Ordered step map: key → function name
    # CleanupPermissions runs FIRST: admin roles must be removed before Graph
    # will accept a sign-in block (PATCH accountEnabled) on a privileged user.
    $stepMap = [ordered]@{
        'CleanupPermissions'    = 'Step-CleanupPermissions'
        'BlockSignIn'           = 'Step-BlockSignIn'
        'ConvertSharedMailbox'  = 'Step-ConvertSharedMailbox'
        'SetOutOfOffice'        = 'Step-SetOutOfOffice'
        'SecureDevice'          = 'Step-SecureDevice'
        'RemoveLicenses'        = 'Step-RemoveLicenses'
        'TransferOneDrive'      = 'Step-TransferOneDrive'
        'RemoveTeamsAndDLs'     = 'Step-RemoveTeamsAndDLs'
        'RemoveDelegatedAccess' = 'Step-RemoveDelegatedAccess'
        'RemoveSharePoint'      = 'Step-RemoveSharePointAccess'
        'DisableMfa'            = 'Step-DisableMfa'
    }

    $allResults = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($userId in $userIds) {

        $userResult = @{
            userId      = $userId
            userUPN     = ''
            displayName = ''
            steps       = [System.Collections.Generic.List[PSCustomObject]]::new()
        }

        # Resolve display name and UPN for readable audit entries
        try {
            $info = Invoke-MgGraphRequest -Method GET -Uri ('/v1.0/users/' + $userId + '?$select=displayName,userPrincipalName') -ErrorAction SilentlyContinue
            $userResult.userUPN     = $info.userPrincipalName
            $userResult.displayName = $info.displayName
        }
        catch {
            $userResult.userUPN = $userId
        }

        Write-Host "  Offboarding: $($userResult.displayName) ($($userResult.userUPN))" -ForegroundColor Cyan

        foreach ($stepKey in $stepMap.Keys) {

            $fnName     = $stepMap[$stepKey]
            $stepCfg    = $stepsConfig[$stepKey]
            $isEnabled  = $stepCfg -and ($stepCfg['enabled'] -eq $true)

            if (-not $isEnabled) {
                $skipped = [PSCustomObject]@{
                    Step      = $stepKey
                    StepLabel = $stepKey
                    UserId    = $userId
                    UserUPN   = $userResult.userUPN
                    Status    = 'Skipped'
                    Message   = 'Step disabled by operator'
                    Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
                $userResult.steps.Add($skipped)
                Write-AuditEntry -Entry $skipped
                continue
            }

            # Build config hashtable (everything except 'enabled')
            $config = @{}
            if ($stepCfg) {
                foreach ($k in $stepCfg.Keys) {
                    if ($k -ne 'enabled') { $config[$k] = $stepCfg[$k] }
                }
            }

            Write-Host "    [$stepKey] running..." -ForegroundColor DarkGray
            try {
                $stepResult = & $fnName `
                    -UserId  $userId `
                    -UserUPN $userResult.userUPN `
                    -Config  $config

                $userResult.steps.Add($stepResult)
                Write-AuditEntry -Entry $stepResult

                $color = switch ($stepResult.Status) {
                    'Success' { 'Green'  }
                    'Skipped' { 'Yellow' }
                    default   { 'Red'    }
                }
                Write-Host "    [$stepKey] $($stepResult.Status): $($stepResult.Message)" -ForegroundColor $color
            }
            catch {
                $errResult = [PSCustomObject]@{
                    Step      = $stepKey
                    StepLabel = $stepKey
                    UserId    = $userId
                    UserUPN   = $userResult.userUPN
                    Status    = 'Error'
                    Message   = "Unhandled exception: $_"
                    Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
                $userResult.steps.Add($errResult)
                Write-AuditEntry -Entry $errResult
                Write-Host "    [$stepKey] ERROR: $_" -ForegroundColor Red
            }
        }

        $allResults.Add($userResult)
    }

    # Explicitly convert each step PSCustomObject to a plain hashtable so that
    # ConvertTo-Json serialises everything as predictable JSON objects with
    # known lowercase keys.  This avoids intermittent serialisation quirks
    # that occur when PSCustomObjects are nested inside generic List<T> values
    # inside another hashtable.
    $serializable = @($allResults | ForEach-Object {
        $ur = $_
        @{
            userId      = $ur.userId
            userUPN     = $ur.userUPN
            displayName = $ur.displayName
            steps       = @($ur['steps'] | ForEach-Object {
                @{
                    step      = [string]$_.Step
                    stepLabel = [string]$_.StepLabel
                    userId    = [string]$_.UserId
                    userUPN   = [string]$_.UserUPN
                    status    = [string]$_.Status
                    message   = [string]$_.Message
                    timestamp = [string]$_.Timestamp
                }
            })
        }
    })

    return @{ success = $true; results = $serializable }
}
