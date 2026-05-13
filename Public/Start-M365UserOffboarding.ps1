function Start-M365UserOffboarding {
    <#
    .SYNOPSIS
        Launches the M365 User Offboarding portal.
    .DESCRIPTION
        Starts a local HTTP portal on 127.0.0.1 (default port 8080). Authentication
        to Microsoft Graph and Exchange Online is performed interactively from within
        the portal — click "Connect to Microsoft 365" on the landing screen.
    .PARAMETER Port
        Starting port for the portal server. Tries 8080–8089 if the preferred port
        is already in use.
    .EXAMPLE
        Start-M365UserOffboarding
    .EXAMPLE
        Start-M365UserOffboarding -Port 9090
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1024, 65535)]
        [int]$Port = 8080
    )

    # ── Banner ────────────────────────────────────────────────────────────
    $moduleVersion = $MyInvocation.MyCommand.Module.Version
    Write-Host ''
    Write-Host '  ╔═════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '  ║   M365 User Offboarding Portal          ║' -ForegroundColor Cyan
    Write-Host "  ║   Module version $moduleVersion$((' ' * [Math]::Max(0, 22 - "$moduleVersion".Length))) ║" -ForegroundColor Cyan
    Write-Host '  ╚═════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''

    # ── Reset session state ───────────────────────────────────────────────
    Write-Host '[1/2] Initialising session…' -ForegroundColor Yellow
    $script:AuditLog         = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:ServerStop       = $false
    $script:Connected        = $false
    $script:TenantName       = ''
    $script:TenantId         = ''
    $script:ConnectedAs      = ''
    $script:HasIntuneLicense = $false
    Write-Host ''

    # ── Launch portal ─────────────────────────────────────────────────────
    Write-Host '[2/2] Starting portal server…' -ForegroundColor Yellow

    # Auto-open default browser shortly after server bind succeeds.
    $browserJob = Start-Job -ScriptBlock {
        Start-Sleep -Seconds 1
        Start-Process "http://127.0.0.1:$using:Port/"
    }

    # Start-OffboardingServer is blocking — returns only when the user clicks Close.
    Start-OffboardingServer -PreferredPort $Port

    # Clean up the browser-launch job now that the server has stopped.
    $browserJob | Remove-Job -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'Portal closed.' -ForegroundColor Cyan

    # ── Prompt to export audit ─────────────────────────────────────────────
    if ($script:AuditLog.Count -gt 0) {
        Write-Host "$($script:AuditLog.Count) audit entries recorded." -ForegroundColor Yellow
        $choice = Read-Host 'Export audit log to Output\AuditLogs\ ? [Y/n]'
        if ($choice -ne 'n' -and $choice -ne 'N') {
            $files = Export-AuditLog
            Write-Host "Audit log saved:" -ForegroundColor Green
            $files | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
        }
    }

    Write-Host 'Done.' -ForegroundColor Cyan
}
