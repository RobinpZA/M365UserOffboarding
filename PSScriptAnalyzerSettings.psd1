@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Write-Host used intentionally for interactive terminal progress output
        'PSAvoidUsingWriteHost'
        # Step-* functions are private HTTP handlers dispatched dynamically; ShouldProcess adds no value
        'PSUseShouldProcessForStateChangingFunctions'
        # Step-* functions implement a custom -WhatIf switch rather than SupportsShouldProcess (internal handlers)
        'PSUseSupportsShouldProcess'
        # Private Step-* functions accept $Config for a consistent call interface even when unused
        'PSReviewUnusedParameter'
        # Plural nouns are intentional for functions that operate on collections (e.g. RemoveLicenses)
        'PSUseSingularNouns'
        # Module requires PS 7.2+ which uses UTF-8 without BOM by default; BOM is unnecessary
        'PSUseBOMForUnicodeEncodedFile'
        # Empty catch blocks in What-If branches intentionally swallow non-critical lookup errors
        'PSAvoidUsingEmptyCatchBlock'
    )
}
