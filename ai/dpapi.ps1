param([Parameter(Mandatory)][ValidateSet('protect','unprotect')][string] $Operation)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$inputBytes = [Convert]::FromBase64String([Console]::In.ReadToEnd().Trim())
$scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
if ($Operation -eq 'protect') {
    $outputBytes = [System.Security.Cryptography.ProtectedData]::Protect($inputBytes, $null, $scope)
} else {
    $outputBytes = [System.Security.Cryptography.ProtectedData]::Unprotect($inputBytes, $null, $scope)
}
[Console]::Write([Convert]::ToBase64String($outputBytes))
