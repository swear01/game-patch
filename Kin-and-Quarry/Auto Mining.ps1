[CmdletBinding()]
param([string]$Directory)

& (Join-Path $PSScriptRoot 'Invoke-QuarryAutoMine.ps1') @PSBoundParameters
