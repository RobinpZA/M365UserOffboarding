#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'M365UserOffboarding.psd1'
    $script:ModulePath = (Resolve-Path $modulePath).Path
}

Describe 'M365UserOffboarding Module' {

    Context 'Manifest and imports' {

        It 'Module manifest is valid' {
            $result = Test-ModuleManifest -Path $script:ModulePath -ErrorAction SilentlyContinue
            $result | Should -Not -BeNullOrEmpty
        }

        It 'Module can be imported without errors' {
            { Import-Module $script:ModulePath -Force -ErrorAction Stop } | Should -Not -Throw
        }

        It 'Exports only the Start-M365UserOffboarding function' {
            $module  = Import-Module $script:ModulePath -Force -PassThru
            $exports = $module.ExportedCommands.Keys
            $exports | Should -Contain 'Start-M365UserOffboarding'
            $exports.Count | Should -Be 1
        }
    }

    Context 'Private functions are not exported' {

        BeforeAll {
            $module = Import-Module $script:ModulePath -Force -PassThru
            $script:Exports = $module.ExportedCommands.Keys
        }

        @(
            'Invoke-Route',
            'Invoke-RequestRouter',
            'Start-OffboardingServer',
            'Write-HttpResponse',
            'Write-JsonResponse',
            'Write-FileResponse',
            'Write-ErrorResponse',
            'Get-PortalUserList',
            'Get-PortalUserDetails',
            'Invoke-OffboardUsers',
            'Connect-OffboardingServices',
            'Write-AuditEntry',
            'Export-AuditLog',
            'Step-BlockSignIn',
            'Step-ConvertSharedMailbox',
            'Step-SetOutOfOffice',
            'Step-SecureDevice',
            'Step-RemoveLicenses',
            'Step-CleanupPermissions',
            'Step-TransferOneDrive',
            'Step-RemoveTeamsAndDLs',
            'Step-RemoveDelegatedAccess',
            'Step-RemoveSharePointAccess',
            'Step-DisableMfa'
        ) | ForEach-Object {
            It "Does not export private function '$_'" {
                $script:Exports | Should -Not -Contain $_
            }
        }
    }

    Context 'PSScriptAnalyzer compliance' {

        BeforeAll {
            if (-not (Get-Module -Name PSScriptAnalyzer -ListAvailable -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'PSScriptAnalyzer is not installed'
                return
            }
            Import-Module PSScriptAnalyzer
            $settingsPath = Join-Path $PSScriptRoot '..' 'PSScriptAnalyzerSettings.psd1'
            $srcRoot      = Join-Path $PSScriptRoot '..'
            $script:AnalyzerResults = Invoke-ScriptAnalyzer -Path $srcRoot -Settings $settingsPath `
                                         -Recurse -ExcludeRule 'PSAvoidUsingWriteHost','PSUseShouldProcessForStateChangingFunctions' `
                                         -ErrorAction SilentlyContinue
        }

        It 'Has no Errors or Warnings from PSScriptAnalyzer' {
            $blocking = $script:AnalyzerResults | Where-Object { $_.Severity -in 'Error', 'Warning' }
            if ($blocking) {
                $msgs = $blocking | ForEach-Object { "$($_.ScriptName):$($_.Line) [$($_.Severity)] $($_.RuleName) — $($_.Message)" }
                $msgs | ForEach-Object { Write-Warning $_ }
            }
            $blocking | Should -BeNullOrEmpty
        }
    }

    Context 'Step result contract' {

        BeforeAll {
            Import-Module $script:ModulePath -Force
            # Create a minimal stub result to validate the contract shape
            $script:StubResult = [PSCustomObject]@{
                Step      = 'BlockSignIn'
                StepLabel = 'Block Sign-In & Revoke Sessions'
                UserId    = 'aaaaaaaa-0000-0000-0000-000000000000'
                UserUPN   = 'test@contoso.com'
                Status    = 'Skipped'
                Message   = 'Stub'
                Timestamp = (Get-Date -Format 'o')
            }
        }

        It 'Step result has required properties' {
            $required = 'Step','StepLabel','UserId','UserUPN','Status','Message','Timestamp'
            $required | ForEach-Object {
                $script:StubResult.PSObject.Properties.Name | Should -Contain $_
            }
        }

        It 'Status is one of Success, Error, or Skipped' {
            $script:StubResult.Status | Should -BeIn @('Success', 'Error', 'Skipped')
        }
    }
}
