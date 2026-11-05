[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# @cc [owner:ghuntley,label:security] windows-portable-protocol-owner
# Explicit portable installation registers only this user's overalls URI handler,
# pointing to this audited directory; activation itself remains navigation-only.
$executable = Join-Path $PSScriptRoot 'Mila.Windows.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Mila.Windows.exe is required' }
$key = 'HKCU:\Software\Classes\overalls'
$null = New-Item -Path $key -Force
Set-Item -LiteralPath $key -Value 'URL:Mila'
$null = New-ItemProperty -LiteralPath $key -Name 'URL Protocol' -Value '' -PropertyType String -Force
$null = New-Item -Path "$key\shell\open\command" -Force
Set-Item -LiteralPath "$key\shell\open\command" -Value ('"' + $executable + '" "%1"')
