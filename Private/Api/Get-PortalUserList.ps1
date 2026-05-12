function Get-PortalUserList {
    <#
    .SYNOPSIS
        Returns a paged list of users from Microsoft Graph for the portal user table.
    .DESCRIPTION
        Graph does not support $skip when ConsistencyLevel:eventual is in use.
        Pagination is handled via @odata.nextLink cursor caching in $script:UserPageCursors.
        Key format: "$search|$pageNumber" → nextLink URL to use when fetching that page.
        Page 1 is always fetched fresh. Subsequent pages use the stored cursor.
    .PARAMETER QueryString
        Raw HTTP query string, e.g. "search=john&page=2"
    #>
    [CmdletBinding()]
    param(
        [string]$QueryString = ''
    )

    # ── Parse query string ────────────────────────────────────────────────────
    $qs = @{ search = ''; page = '1' }
    if ($QueryString) {
        foreach ($pair in $QueryString.Split('&')) {
            $kv = $pair.Split('=', 2)
            if ($kv.Count -eq 2) {
                $qs[$kv[0].Trim()] = [System.Uri]::UnescapeDataString($kv[1].Trim())
            }
        }
    }

    $pageSize     = 25
    $page         = [Math]::Max(1, [int]($qs['page']))
    $search       = ($qs['search'] ?? '').Trim()
    $selectFields = 'id,displayName,userPrincipalName,department,jobTitle,accountEnabled,mail,userType'
    $headers      = @{ 'ConsistencyLevel' = 'eventual' }
    $cacheKey     = "$search|$page"

    try {
        $uri = $null

        if ($page -eq 1) {
            # Page 1 is always fetched fresh; clear any stale cursors for this search term
            $keysToRemove = @($script:UserPageCursors.Keys | Where-Object { $_ -like "$search|*" })
            foreach ($k in $keysToRemove) { $script:UserPageCursors.Remove($k) }

            if ($search) {
                $encodedSearch = [System.Uri]::EscapeDataString($search)
                $uri = '/v1.0/users?$select=' + $selectFields +
                       '&$top=' + $pageSize +
                       '&$count=true' +
                       '&$search="displayName:' + $encodedSearch + '" OR "userPrincipalName:' + $encodedSearch + '"' +
                       '&$orderby=displayName'
            }
            else {
                $uri = '/v1.0/users?$select=' + $selectFields +
                       '&$top=' + $pageSize +
                       '&$count=true' +
                       '&$orderby=displayName' +
                       '&$filter=userType eq ''Member'''
            }
        }
        elseif ($script:UserPageCursors.ContainsKey($cacheKey)) {
            # Use the nextLink cursor stored when page N-1 was fetched
            $uri = $script:UserPageCursors[$cacheKey]
        }
        else {
            # Cursor not available — user skipped pages or session restarted
            return @{
                users    = @()
                total    = 0
                page     = $page
                pageSize = $pageSize
                error    = 'Page cursor expired. Please return to page 1.'
            }
        }

        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers $headers -ErrorAction Stop

        # Cache the nextLink for the next page
        if ($response.'@odata.nextLink') {
            $nextKey = "$search|$($page + 1)"
            $script:UserPageCursors[$nextKey] = $response.'@odata.nextLink'
        }

        $users = @($response.value | ForEach-Object {
            @{
                id                = $_.id
                displayName       = $_.displayName
                userPrincipalName = $_.userPrincipalName
                department        = $_.department
                jobTitle          = $_.jobTitle
                accountEnabled    = $_.accountEnabled
                mail              = $_.mail
            }
        })

        $total = if ($null -ne $response.'@odata.count') { [int]$response.'@odata.count' } else { 0 }

        return @{
            users    = $users
            total    = $total
            page     = $page
            pageSize = $pageSize
            hasNext  = [bool]$response.'@odata.nextLink'
        }
    }
    catch {
        Write-Warning "Get-PortalUserList error: $_"
        return @{ users = @(); total = 0; page = $page; pageSize = $pageSize; error = $_.ToString() }
    }
}

