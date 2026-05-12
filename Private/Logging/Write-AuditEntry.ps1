function Write-AuditEntry {
    <#
    .SYNOPSIS
        Appends a step result to the module-level audit log.
    .PARAMETER Entry
        A PSCustomObject returned by a Step-* function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry
    )

    $script:AuditLog.Add($Entry)
}
