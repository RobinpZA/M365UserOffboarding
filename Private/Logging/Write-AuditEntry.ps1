function Write-AuditEntry {
    <#
    .SYNOPSIS
        Appends a step result to the module-level audit log and to the session CSV on disk.
    .DESCRIPTION
        Writing each entry straight to disk means a crash or a closed console never loses
        the record of changes already made to the tenant.
    .PARAMETER Entry
        A PSCustomObject returned by a Step-* function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry
    )

    $script:AuditLog.Add($Entry)

    try {
        if (-not (Test-Path $script:AuditDir)) {
            New-Item -Path $script:AuditDir -ItemType Directory -Force | Out-Null
        }
        if (-not $script:AuditStamp) { $script:AuditStamp = Get-Date -Format 'yyyy-MM-dd_HHmmss' }
        $csvPath = Join-Path $script:AuditDir "OffboardingAudit_$($script:AuditStamp).csv"
        $Entry | Select-Object Timestamp, UserUPN, UserId, Step, StepLabel, Status, Message |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Append
    }
    catch {
        Write-Warning "Audit entry could not be written to disk: $_"
    }
}
