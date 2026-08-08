[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()] [string]$DestinationRoot = 'D:\dev',
    [ValidatePattern('^[a-z_][a-z0-9_-]*$')] [string]$LinuxUser = 'developer',
    [ValidatePattern('^[A-Za-z0-9._-]+$')] [string]$DistributionName = 'Ubuntu-Dev',
    [ValidatePattern('^[A-Za-z0-9._-]+$')] [string]$DistributionSource = 'Ubuntu-26.04',
    [switch]$SkipBootstrap,
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$TemplateRoot = Join-Path $RepositoryRoot 'template'
$ResolvedDestination = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
$DestinationDriveRoot = [IO.Path]::GetPathRoot($ResolvedDestination).TrimEnd('\')
$ResolvedRepository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$ResolvedUserHome = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')

if ($ResolvedDestination -eq $DestinationDriveRoot) { throw 'DestinationRoot must be a dedicated directory, not a drive root.' }
if ($ResolvedDestination -eq $ResolvedUserHome) { throw 'DestinationRoot must not be the user home directory.' }
if ($ResolvedDestination.StartsWith($ResolvedRepository + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $ResolvedRepository.StartsWith($ResolvedDestination + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $ResolvedDestination -eq $ResolvedRepository) {
    throw 'DestinationRoot and the template repository must not contain one another.'
}

$markerPath = Join-Path $ResolvedDestination '.personal-dev-env.json'
if (Test-Path -LiteralPath $ResolvedDestination) {
    $existing = @(Get-ChildItem -LiteralPath $ResolvedDestination -Force -ErrorAction Stop)
    if ($existing.Count -gt 0 -and -not (Test-Path -LiteralPath $markerPath) -and -not $Force) {
        throw 'DestinationRoot is non-empty and is not marked as managed. Review it, then use -Force only for an intentional merge.'
    }
}

$relativeDirectories = @(
    'src','src\work','src\personal','src\forks','src\upstream','src\experiments','src\templates',
    'cache','cache\windows','cache\windows\nuget','cache\windows\npm','cache\windows\pnpm','cache\windows\cargo','cache\windows\vcpkg','cache\windows\conan','cache\windows\maven','cache\windows\gradle','cache\windows\pip','cache\windows\uv','cache\windows\go','cache\windows\browser-binaries',
    'build','build\cmake','build\msbuild','build\dotnet','build\java','build\rust','build\temporary',
    'artifacts','artifacts\releases','artifacts\packages','artifacts\containers','artifacts\sbom','artifacts\provenance','artifacts\test-results','artifacts\coverage','artifacts\benchmarks','artifacts\reports',
    'data','data\external','data\reference','data\shared','data\samples','data\archives',
    'exchange','exchange\from-windows','exchange\from-wsl','exchange\incoming','exchange\outgoing',
    'wsl','wsl\distributions','wsl\exports','wsl\recovery',
    'bootstrap','bootstrap\manifests','bootstrap\configuration','bootstrap\checksums','bootstrap\inventories',
    'scratch','scratch\current','scratch\quarantine',
    'archive','archive\completed-projects','archive\retired-builds','archive\migration-staging'
)

Write-Host "Destination: $ResolvedDestination"
Write-Host "WSL distribution: $DistributionName ($DistributionSource); Linux user: $LinuxUser"
Write-Host "Base directories: $($relativeDirectories.Count + 1); bootstrap: $(-not $SkipBootstrap)"
if ($DryRun) {
    Write-Host 'DRY-RUN No files, directories, packages, or WSL state were changed.' -ForegroundColor Yellow
    return
}

[void](New-Item -ItemType Directory -Path $ResolvedDestination -Force)
foreach ($relativeDirectory in $relativeDirectories) {
    [void](New-Item -ItemType Directory -Path (Join-Path $ResolvedDestination $relativeDirectory) -Force)
}

Copy-Item -LiteralPath (Join-Path $TemplateRoot 'AGENTS.md') -Destination (Join-Path $ResolvedDestination 'AGENTS.md') -Force
Copy-Item -Path (Join-Path $TemplateRoot 'bootstrap\configuration\*') -Destination (Join-Path $ResolvedDestination 'bootstrap\configuration') -Recurse -Force
Copy-Item -Path (Join-Path $TemplateRoot 'bootstrap\manifests\*') -Destination (Join-Path $ResolvedDestination 'bootstrap\manifests') -Recurse -Force

$environment = [ordered]@{
    schemaVersion = 1
    distributionName = $DistributionName
    distributionSource = $DistributionSource
    linuxUser = $LinuxUser
}
$environmentPath = Join-Path $ResolvedDestination 'bootstrap\manifests\environment.json'
Set-Content -LiteralPath $environmentPath -Value (($environment | ConvertTo-Json) + [Environment]::NewLine) -NoNewline -Encoding utf8NoBOM

$installedAt = if (Test-Path -LiteralPath $markerPath) {
    [string](Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json).installedAt
} else {
    (Get-Date).ToUniversalTime().ToString('o')
}
$marker = [ordered]@{
    schemaVersion = 1
    managedBy = 'personal-dev-env'
    installedAt = $installedAt
}
Set-Content -LiteralPath $markerPath -Value (($marker | ConvertTo-Json) + [Environment]::NewLine) -NoNewline -Encoding utf8NoBOM

$checksumRoot = Join-Path $ResolvedDestination 'bootstrap\checksums'
$managedFiles = @(
    Get-Item -LiteralPath (Join-Path $ResolvedDestination 'AGENTS.md')
    Get-ChildItem -LiteralPath (Join-Path $ResolvedDestination 'bootstrap\configuration') -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $ResolvedDestination 'bootstrap\manifests') -File -Recurse
)
$checksumLines = foreach ($file in ($managedFiles | Sort-Object FullName)) {
    $relative = [IO.Path]::GetRelativePath($ResolvedDestination, $file.FullName).Replace('\', '/')
    '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant(), $relative
}
Set-Content -LiteralPath (Join-Path $checksumRoot 'bootstrap.sha256') -Value $checksumLines -Encoding utf8NoBOM

if ($SkipBootstrap) {
    Write-Host "Template deployed to $ResolvedDestination. Bootstrap was skipped explicitly." -ForegroundColor Green
    return
}

$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$bootstrapPath = Join-Path $ResolvedDestination 'bootstrap\configuration\bootstrap.ps1'
$process = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$bootstrapPath) -Wait -PassThru -NoNewWindow
if ($process.ExitCode -eq 20) {
    Write-Warning "Linux password setup is waiting. Complete it in the dedicated terminal, then run: pwsh -NoProfile -File '$bootstrapPath' -Resume"
    exit 20
}
if ($process.ExitCode -ne 0) { throw "Bootstrap exited with code $($process.ExitCode). Rerun it safely after resolving the reported issue." }
Write-Host "Personal Dev Env is ready at $ResolvedDestination." -ForegroundColor Green
