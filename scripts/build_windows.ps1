param([switch]$ChinaMirrors, [switch]$AllSources)
$ErrorActionPreference = "Stop"
$BuildArguments = @()
if ($ChinaMirrors) { $BuildArguments += "--cn-mirrors" }
if ($AllSources) { $BuildArguments += "--all-sources" }
python (Join-Path $PSScriptRoot "build_windows.py") @BuildArguments
exit $LASTEXITCODE
