function Export-AuditLog {
    <#
    .SYNOPSIS
        Exports the current session audit log to HTML and CSV files in Output\AuditLogs\.
    .PARAMETER ModuleRoot
        Root path of the module (used to resolve Output directory).
    .OUTPUTS
        [string] Path of the generated HTML file.
    #>
    [CmdletBinding()]
    param(
        [string]$ModuleRoot = $script:ModuleRoot
    )

    $outDir   = Join-Path $ModuleRoot 'Output' 'AuditLogs'
    if (-not (Test-Path $outDir)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $htmlPath  = Join-Path $outDir "OffboardingAudit_$timestamp.html"
    $csvPath   = Join-Path $outDir "OffboardingAudit_$timestamp.csv"

    $entries = @($script:AuditLog)

    # ── CSV ───────────────────────────────────────────────────────────────────
    $entries | Where-Object { $_ } |
        Select-Object Timestamp, UserUPN, UserId, Step, StepLabel, Status, Message |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    # ── HTML ──────────────────────────────────────────────────────────────────
    $successCount = @($entries | Where-Object { $_.Status -eq 'Success' }).Count
    $errorCount   = @($entries | Where-Object { $_.Status -eq 'Error'   }).Count
    $skippedCount = @($entries | Where-Object { $_.Status -eq 'Skipped' }).Count

    $rows = $entries | ForEach-Object {
        $badgeClass = switch ($_.Status) {
            'Success' { 'badge-green'  }
            'Error'   { 'badge-red'    }
            'Skipped' { 'badge-gray'   }
            default   { 'badge-blue'   }
        }
        "<tr>
          <td>$([System.Web.HttpUtility]::HtmlEncode($_.Timestamp))</td>
          <td>$([System.Web.HttpUtility]::HtmlEncode($_.UserUPN))</td>
          <td>$([System.Web.HttpUtility]::HtmlEncode($_.StepLabel ?? $_.Step))</td>
          <td><span class='badge $badgeClass'>$([System.Web.HttpUtility]::HtmlEncode($_.Status))</span></td>
          <td>$([System.Web.HttpUtility]::HtmlEncode($_.Message))</td>
        </tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>M365 Offboarding Audit Log — $timestamp</title>
  <style>
    * { box-sizing: border-box; }
    body { font-family: 'Segoe UI', sans-serif; background: #0f1117; color: #e2e8f0; margin: 0; padding: 24px; }
    h1 { color: #93c5fd; margin-bottom: 4px; }
    .meta { color: #64748b; font-size: 14px; margin-bottom: 24px; }
    .summary { display: flex; gap: 16px; margin-bottom: 24px; }
    .stat { background: #1a1d27; border: 1px solid #2e3347; border-radius: 8px; padding: 12px 20px; }
    .stat-value { font-size: 28px; font-weight: 700; }
    .stat-label { font-size: 12px; color: #64748b; }
    .green { color: #22c55e; } .red { color: #ef4444; } .gray { color: #94a3b8; }
    table { width: 100%; border-collapse: collapse; background: #1a1d27; border-radius: 8px; overflow: hidden; }
    th { background: #22263a; color: #94a3b8; text-align: left; padding: 10px 14px; font-size: 12px; text-transform: uppercase; letter-spacing: .05em; }
    td { padding: 10px 14px; border-bottom: 1px solid #2e3347; font-size: 14px; }
    tr:last-child td { border-bottom: none; }
    .badge { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; }
    .badge-green { background: #14532d; color: #22c55e; }
    .badge-red   { background: #450a0a; color: #ef4444; }
    .badge-gray  { background: #1e293b; color: #94a3b8; }
    .badge-blue  { background: #1e3a5f; color: #60a5fa; }
  </style>
</head>
<body>
  <h1>M365 Offboarding Audit Log</h1>
  <div class="meta">Tenant: $([System.Web.HttpUtility]::HtmlEncode($script:TenantName)) &nbsp;|&nbsp; Generated: $timestamp &nbsp;|&nbsp; By: $([System.Web.HttpUtility]::HtmlEncode($script:ConnectedAs))</div>
  <div class="summary">
    <div class="stat"><div class="stat-value green">$successCount</div><div class="stat-label">Succeeded</div></div>
    <div class="stat"><div class="stat-value red">$errorCount</div><div class="stat-label">Failed</div></div>
    <div class="stat"><div class="stat-value gray">$skippedCount</div><div class="stat-label">Skipped</div></div>
    <div class="stat"><div class="stat-value">$($entries.Count)</div><div class="stat-label">Total actions</div></div>
  </div>
  <table>
    <thead><tr><th>Timestamp</th><th>User</th><th>Step</th><th>Status</th><th>Details</th></tr></thead>
    <tbody>$($rows -join '')</tbody>
  </table>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($htmlPath, $html, [System.Text.Encoding]::UTF8)

    Write-Host "  Audit log exported:" -ForegroundColor Cyan
    Write-Host "    HTML: $htmlPath" -ForegroundColor Green
    Write-Host "    CSV:  $csvPath"  -ForegroundColor Green

    return $htmlPath
}
