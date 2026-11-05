[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PublishDirectory,
    [Parameter(Mandatory = $true)][string] $OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string] $Version = '0.0.0.0'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# @cc [owner:ghuntley,label:release] windows-native-package-audit
# Audit the native publish tree before producing a portable ZIP or unsigned MSIX.
# This script never signs, installs, registers protocols, or publishes an artifact.
& (Join-Path $PSScriptRoot 'verify-release.ps1') -PublishDirectory $PublishDirectory
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$payload = Join-Path $output 'payload'
if (Test-Path -LiteralPath $payload) { throw 'package payload already exists' }
$null = New-Item -ItemType Directory -Path $payload
try {
    Copy-Item -Path (Join-Path $PublishDirectory '*') -Destination $payload -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'register-protocol.ps1') -Destination $payload
    $manifest = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Package.appxmanifest') -Raw).Replace('@VERSION@', $Version)
    Set-Content -LiteralPath (Join-Path $payload 'AppxManifest.xml') -Value $manifest -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Assets') -Destination $payload -Recurse
    # Build the portable archive only after staging the manifest and icon
    # assets.  Keeping the ZIP and MSIX payloads identical prevents the ZIP
    # install path from silently dropping the protocol-registration metadata
    # and package resources.
    Compress-Archive -Path (Join-Path $payload '*') -DestinationPath (Join-Path $output 'Mila-win-x64-unsigned.zip') -Force
    $sdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $makeAppx = Get-ChildItem -Path (Join-Path $sdkBin '*/x64/makeappx.exe') | Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -eq $makeAppx) { throw 'Windows SDK MakeAppx is required' }
    & $makeAppx.FullName pack /d $payload /p (Join-Path $output 'Mila-win-x64-unsigned.msix') /o
    if ($LASTEXITCODE -ne 0) { throw 'MakeAppx failed' }
    $lines = Get-ChildItem -LiteralPath $output -File | Where-Object { $_.Extension -in '.zip', '.msix' } | Sort-Object Name | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name
    }
    Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS') -Value $lines -Encoding ascii
} finally { Remove-Item -LiteralPath $payload -Recurse -Force }
