function Start-OffboardingServer {
    <#
    .SYNOPSIS
        Binds a TcpListener to 127.0.0.1 and runs the HTTP request loop until $script:ServerStop is set.
    .PARAMETER PreferredPort
        Starting port. If in use, tries PreferredPort+1 through PreferredPort+9.
    .OUTPUTS
        Nothing — blocks until server is stopped.
    #>
    [CmdletBinding()]
    param(
        [int]$PreferredPort = 8080
    )

    # ── Bind listener ─────────────────────────────────────────────────────────
    $listener = $null
    $port     = $PreferredPort

    for ($p = $PreferredPort; $p -le ($PreferredPort + 9); $p++) {
        try {
            $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
            $l.Start()
            $listener = $l
            $port     = $p
            break
        }
        catch {
            Write-Verbose "Port $p in use, trying next."
        }
    }

    if (-not $listener) {
        throw "Could not bind to any port in the range $PreferredPort–$($PreferredPort + 9). Ensure at least one of those ports is free."
    }

    $url = "http://127.0.0.1:$port/"
    Write-Host ''
    Write-Host "  Portal URL : $url" -ForegroundColor Green
    Write-Host '  Press Ctrl+C or click "Close Server" in the portal to stop.' -ForegroundColor DarkGray
    Write-Host ''

    try {
        while (-not $script:ServerStop) {
            if ($listener.Pending()) {
                $client = $listener.AcceptTcpClient()
                try {
                    Invoke-RequestRouter -Client $client -ModuleRoot $script:ModuleRoot
                }
                catch {
                    Write-Warning "Request handling error: $_"
                }
                finally {
                    try { $client.Close() } catch { Write-Verbose "Client close suppressed: $_" }
                }
            }
            else {
                # Short sleep to avoid busy-spinning
                Start-Sleep -Milliseconds 25
            }
        }
    }
    finally {
        $listener.Stop()
        $script:ServerStop = $false   # Reset for next run
        Write-Host 'Offboarding server stopped.' -ForegroundColor Yellow
    }
}
