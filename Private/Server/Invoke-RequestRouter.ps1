function Invoke-RequestRouter {
    <#
    .SYNOPSIS
        Reads an HTTP/1.1 request from a TcpClient, parses it, and dispatches to the correct handler.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.Sockets.TcpClient]$Client,

        [Parameter(Mandatory)]
        [string]$ModuleRoot
    )

    $stream = $Client.GetStream()

    try {
        # ── Read request headers ──────────────────────────────────────────────
        $headerBytes     = [System.Collections.Generic.List[byte]]::new()
        $buf             = New-Object byte[] 1
        $crlfcrlfPattern = [byte[]]@(13, 10, 13, 10)  # \r\n\r\n

        # Read one byte at a time until we see \r\n\r\n (end of headers)
        while ($stream.CanRead) {
            $read = $stream.Read($buf, 0, 1)
            if ($read -eq 0) { break }
            $headerBytes.Add($buf[0])

            if ($headerBytes.Count -ge 4) {
                $tail = $headerBytes.GetRange($headerBytes.Count - 4, 4)
                if ($tail[0] -eq $crlfcrlfPattern[0] -and $tail[1] -eq $crlfcrlfPattern[1] -and
                    $tail[2] -eq $crlfcrlfPattern[2] -and $tail[3] -eq $crlfcrlfPattern[3]) {
                    break
                }
            }
            if ($headerBytes.Count -gt 16384) { break }  # guard against oversized headers
        }

        $rawHeader  = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
        $headerLines = $rawHeader -split '\r\n'

        if ($headerLines.Count -eq 0 -or -not $headerLines[0]) { return }

        # ── Parse request line ────────────────────────────────────────────────
        $requestLineParts = $headerLines[0].Split(' ')
        if ($requestLineParts.Count -lt 2) { return }

        $method   = $requestLineParts[0].ToUpper()
        $fullPath = $requestLineParts[1]

        $qMark = $fullPath.IndexOf('?')
        if ($qMark -ge 0) {
            $path        = $fullPath.Substring(0, $qMark)
            $queryString = $fullPath.Substring($qMark + 1)
        }
        else {
            $path        = $fullPath
            $queryString = ''
        }

        # ── Parse headers ─────────────────────────────────────────────────────
        $headers = @{}
        foreach ($line in $headerLines[1..($headerLines.Count - 1)]) {
            $colonIdx = $line.IndexOf(':')
            if ($colonIdx -gt 0) {
                $key         = $line.Substring(0, $colonIdx).Trim().ToLower()
                $val         = $line.Substring($colonIdx + 1).Trim()
                $headers[$key] = $val
            }
        }

        # ── Read body (POST) ──────────────────────────────────────────────────
        $body = $null
        if ($method -eq 'POST' -and $headers['content-length']) {
            $contentLength = [int]$headers['content-length']
            if ($contentLength -gt 0 -and $contentLength -le 1048576) {  # max 1 MB body
                $bodyBytes = New-Object byte[] $contentLength
                $totalRead = 0
                while ($totalRead -lt $contentLength) {
                    $read = $stream.Read($bodyBytes, $totalRead, $contentLength - $totalRead)
                    if ($read -eq 0) { break }
                    $totalRead += $read
                }
                $bodyStr = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $totalRead)
                try {
                    $body = $bodyStr | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                }
                catch {
                    $body = $null
                }
            }
        }

        # ── Dispatch ──────────────────────────────────────────────────────────
        $ctx = @{
            Method      = $method
            Path        = $path
            QueryString = $queryString
            Headers     = $headers
            Body        = $body
            Stream      = $stream
            ModuleRoot  = $ModuleRoot
        }

        Invoke-Route -Context $ctx
    }
    finally {
        try { $stream.Close() } catch { Write-Verbose "Stream close suppressed: $_" }
    }
}

function Invoke-Route {
    <#
    .SYNOPSIS
        Dispatches a parsed HTTP request context to the appropriate API handler.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $method     = $Context.Method
    $path       = $Context.Path
    $stream     = $Context.Stream
    $body       = $Context.Body
    $query      = $Context.QueryString
    $moduleRoot = $Context.ModuleRoot

    try {
        switch -Regex ($path) {

            '^/$' {
                $indexPath = Join-Path $moduleRoot 'Assets' 'portal' 'index.html'
                Write-FileResponse -Stream $stream -FilePath $indexPath
                return
            }

            '^/static/(.+)$' {
                $requestedFile = $Matches[1]
                # Whitelist to prevent path traversal
                $allowed = @('app.js', 'style.css')
                if ($requestedFile -notin $allowed) {
                    Write-ErrorResponse -Stream $stream -Message 'Not found' -StatusCode 404
                    return
                }
                $filePath = Join-Path $moduleRoot 'Assets' 'portal' $requestedFile
                if (Test-Path $filePath) {
                    Write-FileResponse -Stream $stream -FilePath $filePath
                }
                else {
                    Write-ErrorResponse -Stream $stream -Message 'Static file not found' -StatusCode 404
                }
                return
            }

            '^/api/context$' {
                $ctx = @{
                    connected        = ($script:Connected -eq $true)
                    tenantName       = [string]$script:TenantName
                    tenantId         = [string]$script:TenantId
                    connectedAs      = [string]$script:ConnectedAs
                    hasIntuneLicense = $script:HasIntuneLicense
                }
                Write-JsonResponse -Stream $stream -Data $ctx
                return
            }

            '^/api/connect$' {
                if ($method -ne 'POST') {
                    Write-ErrorResponse -Stream $stream -Message 'Method not allowed' -StatusCode 405; return
                }
                if ($script:Connected) {
                    Write-JsonResponse -Stream $stream -Data @{
                        tenantName       = [string]$script:TenantName
                        connectedAs      = [string]$script:ConnectedAs
                        hasIntuneLicense = $script:HasIntuneLicense
                        exchange         = $true
                    }
                    return
                }
                try {
                    $auth = Connect-OffboardingServices
                    if (-not $auth.Graph) {
                        Write-JsonResponse -Stream $stream -Data @{ error = 'Failed to connect to Microsoft Graph.' } -StatusCode 500
                        return
                    }
                    Write-JsonResponse -Stream $stream -Data @{
                        tenantName       = [string]$auth.TenantName
                        connectedAs      = [string]$auth.ConnectedAs
                        hasIntuneLicense = $auth.HasIntuneLicense
                        exchange         = $auth.Exchange
                    }
                }
                catch {
                    Write-JsonResponse -Stream $stream -Data @{ error = [string]$_.ToString() } -StatusCode 500
                }
                return
            }

            '^/api/(users|offboard|audit|export-audit)' {
                if (-not $script:Connected) {
                    Write-JsonResponse -Stream $stream -Data @{ error = 'Not connected. Please connect via the portal first.' } -StatusCode 401
                    return
                }
                # No return — switch continues to match the specific route below
            }

            '^/api/users$' {
                $result = Get-PortalUserList -QueryString $query
                Write-JsonResponse -Stream $stream -Data $result
                return
            }

            '^/api/users/([^/?]+)$' {
                $userId = $Matches[1]
                $result = Get-PortalUserDetails -UserId $userId
                Write-JsonResponse -Stream $stream -Data $result
                return
            }

            '^/api/offboard$' {
                if ($method -ne 'POST') {
                    Write-ErrorResponse -Stream $stream -Message 'Method not allowed' -StatusCode 405; return
                }
                $result = Invoke-OffboardUsers -RequestBody $body
                Write-JsonResponse -Stream $stream -Data $result
                return
            }

            '^/api/audit$' {
                # Convert PSCustomObjects to plain hashtables with lowercase keys.
                # ConvertTo-Json has intermittent serialisation quirks when the source
                # is a List[PSCustomObject] — same fix applied in Invoke-OffboardUsers.
                $entries = @($script:AuditLog | ForEach-Object {
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
                Write-JsonResponse -Stream $stream -Data @{ entries = $entries }
                return
            }

            '^/api/export-audit$' {
                if ($method -ne 'POST') {
                    Write-ErrorResponse -Stream $stream -Message 'Method not allowed' -StatusCode 405; return
                }
                $htmlPath = Export-AuditLog -ModuleRoot $moduleRoot
                Write-JsonResponse -Stream $stream -Data @{ filename = $htmlPath }
                return
            }

            '^/api/close$' {
                if ($method -ne 'POST') {
                    Write-ErrorResponse -Stream $stream -Message 'Method not allowed' -StatusCode 405; return
                }
                Write-JsonResponse -Stream $stream -Data @{ message = 'Server stopping...' }
                $script:ServerStop = $true
                return
            }

            '^/api/disconnect$' {
                if ($method -ne 'POST') {
                    Write-ErrorResponse -Stream $stream -Message 'Method not allowed' -StatusCode 405; return
                }
                Write-Host '  Disconnecting from Microsoft Graph...' -ForegroundColor Cyan
                try {
                    $null = Disconnect-MgGraph -ErrorAction Stop
                    Write-Host '  [OK] Microsoft Graph disconnected' -ForegroundColor Green
                }
                catch {
                    Write-Host "  [WARN] Graph disconnect: $_" -ForegroundColor Yellow
                }
                Write-Host '  Disconnecting from Exchange Online...' -ForegroundColor Cyan
                try {
                    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Host '  [OK] Exchange Online disconnected' -ForegroundColor Green
                }
                catch {
                    Write-Host "  [WARN] Exchange disconnect: $_" -ForegroundColor Yellow
                }
                $script:Connected        = $false
                $script:TenantName       = ''
                $script:TenantId         = ''
                $script:ConnectedAs      = ''
                $script:HasIntuneLicense = $false
                Write-JsonResponse -Stream $stream -Data @{ ok = $true }
                return
            }

            default {
                Write-ErrorResponse -Stream $stream -Message 'Not found' -StatusCode 404
            }
        }
    }
    catch {
        Write-Warning "Route error [$method $path]: $_"
        try {
            Write-ErrorResponse -Stream $stream -Message "Internal server error: $($_.ToString())" -StatusCode 500
        }
        catch { Write-Verbose "Could not send error response: $_" }
    }
}
