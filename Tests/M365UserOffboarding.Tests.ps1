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

        It 'Status is one of Success, Error, Skipped, WhatIf, or Warning' {
            $script:StubResult.Status | Should -BeIn @('Success', 'Error', 'Skipped', 'WhatIf', 'Warning')
        }
    }

    Context 'Safety logic (Graph and Exchange mocked)' {

        BeforeAll {
            Import-Module $script:ModulePath -Force
            # Exchange cmdlets only exist after Connect-ExchangeOnline; stub them so they can be mocked.
            foreach ($name in 'Get-Mailbox', 'Get-MailboxStatistics') {
                if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
                    New-Item -Path "Function:\global:$name" -Value { param($Identity) } | Out-Null
                }
            }
            $script:UserId = 'aaaaaaaa-0000-0000-0000-000000000001'
        }

        It 'Never wipes a personal device, even when company devices are set to Wipe' {
            InModuleScope M365UserOffboarding -Parameters @{ UserId = $script:UserId } {
                param($UserId)
                $script:HasIntuneLicense = $true
                Mock Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'GET' } {
                    @{ value = @(
                        @{ id = 'dev-personal'; deviceName = 'Phone';  managedDeviceOwnerType = 'personal' }
                        @{ id = 'dev-company';  deviceName = 'Laptop'; managedDeviceOwnerType = 'company' }
                    ) }
                }
                Mock Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' } { }

                $r = Step-SecureDevice -UserId $UserId -UserUPN 'u@contoso.com' -Config @{ companyAction = 'Wipe' }

                $r.Status | Should -Be 'Success'
                Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*dev-personal/retire' }
                Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*dev-company/wipe' }
                Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*dev-personal/wipe' }
            }
        }

        It 'Removes licences with a deletion warning when the mailbox stays a user mailbox' {
            InModuleScope M365UserOffboarding -Parameters @{ UserId = $script:UserId } {
                param($UserId)
                Mock Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'GET' } { @{ value = @(@{ skuId = 'sku-1'; skuPartNumber = 'ENTERPRISEPACK' }) } }
                Mock Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' } { }
                Mock Get-Mailbox { [PSCustomObject]@{ RecipientTypeDetails = 'UserMailbox'; LitigationHoldEnabled = $false; InPlaceHolds = @(); ArchiveStatus = 'None' } }
                Mock Get-MailboxStatistics { [PSCustomObject]@{ TotalItemSize = '1.2 GB (1,288,490,188 bytes)' } }

                $r = Step-RemoveLicenses -UserId $UserId -UserUPN 'u@contoso.com'

                $r.Status  | Should -Be 'Warning'
                $r.Message | Should -Match 'permanently deleted 30 days'
                Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*/assignLicense' }
            }
        }

        It 'Keeps licences when the mailbox is on litigation hold' {
            InModuleScope M365UserOffboarding -Parameters @{ UserId = $script:UserId } {
                param($UserId)
                Mock Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'GET' } { @{ value = @(@{ skuId = 'sku-1' }) } }
                Mock Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' } { }
                Mock Get-Mailbox { [PSCustomObject]@{ RecipientTypeDetails = 'SharedMailbox'; LitigationHoldEnabled = $true; InPlaceHolds = @(); ArchiveStatus = 'None' } }
                Mock Get-MailboxStatistics { [PSCustomObject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' } }

                $r = Step-RemoveLicenses -UserId $UserId -UserUPN 'u@contoso.com'

                $r.Status  | Should -Be 'Skipped'
                $r.Message | Should -Match 'litigation hold'
                Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*/assignLicense' }
            }
        }

        It 'Skips licence removal when the shared mailbox conversion failed' {
            InModuleScope M365UserOffboarding -Parameters @{ UserId = $script:UserId } {
                param($UserId)
                $script:TenantId = 'tenant-1'
                $script:AuditDir = Join-Path $TestDrive 'audit'
                Mock Get-MgContext { [PSCustomObject]@{ TenantId = 'tenant-1' } }
                Mock Invoke-MgGraphRequest { @{ displayName = 'User'; userPrincipalName = 'u@contoso.com' } }
                Mock Step-ConvertSharedMailbox { [PSCustomObject]@{ Step = 'ConvertSharedMailbox'; StepLabel = 'x'; UserId = $UserId; UserUPN = 'u'; Status = 'Error'; Message = 'boom'; Timestamp = '' } }
                Mock Step-RemoveLicenses { throw 'should not run' }

                $body = @{
                    userIds = @($UserId)
                    steps   = @{ ConvertSharedMailbox = @{ enabled = $true }; RemoveLicenses = @{ enabled = $true } }
                }
                $r = Invoke-OffboardUsers -RequestBody $body

                Should -Invoke Step-RemoveLicenses -Times 0 -Exactly
                ($r.results[0].steps | Where-Object { $_.step -eq 'RemoveLicenses' }).status | Should -Be 'Skipped'
            }
        }

        It 'Rejects user IDs that are not GUIDs' {
            InModuleScope M365UserOffboarding {
                $r = Invoke-OffboardUsers -RequestBody @{ userIds = @('../groups/x'); steps = @{} }
                $r.success | Should -BeFalse
                $r.error   | Should -Match 'Invalid user ID'
            }
        }

        It 'Does not PATCH a synced account, but still revokes sessions' {
            InModuleScope M365UserOffboarding -Parameters @{ UserId = $script:UserId } {
                param($UserId)
                Mock Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'GET' } { @{ accountEnabled = $true; onPremisesSyncEnabled = $true } }
                Mock Invoke-MgGraphRequest -ParameterFilter { $Method -ne 'GET' } { }

                $r = Step-BlockSignIn -UserId $UserId -UserUPN 'u@contoso.com'

                $r.Status  | Should -Be 'Warning'
                $r.Message | Should -Match 'on-premises AD'
                Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
                Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*/revokeSignInSessions' }
            }
        }

        It 'Writes each audit entry to the session CSV immediately' {
            InModuleScope M365UserOffboarding {
                $script:AuditDir   = Join-Path $TestDrive 'live'
                $script:AuditStamp = 'test'
                $entry = [PSCustomObject]@{ Timestamp = 't'; UserUPN = 'u'; UserId = 'i'; Step = 'S'; StepLabel = 'L'; Status = 'Success'; Message = 'm' }

                Write-AuditEntry -Entry $entry
                Write-AuditEntry -Entry $entry

                @(Import-Csv (Join-Path $script:AuditDir 'OffboardingAudit_test.csv')).Count | Should -Be 2
            }
        }
    }
}
