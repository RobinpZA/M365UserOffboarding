#
# M365UserOffboarding.psm1 — Root module
# Dot-sources all private functions then exports public ones.
#

$script:ModuleRoot       = $PSScriptRoot
$script:AuditLog         = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:ServerStop       = $false
$script:Connected        = $false
$script:TenantName       = ''
$script:TenantId         = ''
$script:ConnectedAs      = ''
$script:HasIntuneLicense = $false
# Cursor cache for Graph user pagination (keyed by "$search|$pageNumber" → nextLink URL)
$script:UserPageCursors  = @{}

# ── Private functions ─────────────────────────────────────────────────────────
$privatePatterns = @(
    "$PSScriptRoot\Private\Auth\*.ps1",
    "$PSScriptRoot\Private\Server\*.ps1",
    "$PSScriptRoot\Private\Api\*.ps1",
    "$PSScriptRoot\Private\Actions\*.ps1",
    "$PSScriptRoot\Private\Logging\*.ps1"
)

foreach ($pattern in $privatePatterns) {
    foreach ($file in (Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue)) {
        try {
            . $file.FullName
        }
        catch {
            Write-Warning "Failed to load private function from $($file.Name): $_"
        }
    }
}

# ── Public functions ──────────────────────────────────────────────────────────
# FunctionsToExport in the module manifest is the authoritative export list.
foreach ($file in (Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)) {
    try {
        . $file.FullName
    }
    catch {
        Write-Warning "Failed to load public function from $($file.Name): $_"
    }
}
