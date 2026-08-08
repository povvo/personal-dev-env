[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$TemplateRoot = Join-Path $RepositoryRoot 'template'
$ManifestRoot = Join-Path $TemplateRoot 'bootstrap\manifests'
$ConfigurationRoot = Join-Path $TemplateRoot 'bootstrap\configuration'
$failures = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) { [void]$failures.Add($Message); Write-Host "FAIL $Message" -ForegroundColor Red }
function Add-Pass([string]$Message) { Write-Host "PASS $Message" -ForegroundColor Green }
function Add-Warning([string]$Message) { [void]$warnings.Add($Message); Write-Host "WARN $Message" -ForegroundColor Yellow }

$requiredFiles = @(
    'AGENTS.md','README.md','SECURITY.md','scripts\install.ps1','scripts\validate.ps1',
    'template\AGENTS.md','template\bootstrap\configuration\bootstrap.ps1',
    'template\bootstrap\configuration\devctl.ps1','template\bootstrap\configuration\devctl.cmd',
    'template\bootstrap\configuration\devctl','template\bootstrap\configuration\wsl-core.sh',
    'template\bootstrap\configuration\structure.md','template\bootstrap\manifests\environment.json',
    'template\bootstrap\manifests\windows-core.json','template\bootstrap\manifests\ubuntu-core.json',
    'template\bootstrap\manifests\mise.toml','template\bootstrap\manifests\mise.lock',
    'template\bootstrap\manifests\profiles.json'
)
foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $relative) -PathType Leaf)) { Add-Failure "missing required file: $relative" }
}
if ($failures.Count -eq 0) { Add-Pass "required file set ($($requiredFiles.Count))" }

foreach ($file in Get-ChildItem -LiteralPath $RepositoryRoot -Filter '*.json' -File -Recurse) {
    try { $null = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json }
    catch { Add-Failure "invalid JSON: $([IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName))" }
}
if (-not $failures.Where({ $_ -like 'invalid JSON:*' }).Count) { Add-Pass 'JSON manifests parse' }

foreach ($file in Get-ChildItem -LiteralPath $RepositoryRoot -Filter '*.ps1' -File -Recurse) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { Add-Failure "PowerShell syntax: $([IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName))" }
}
if (-not $failures.Where({ $_ -like 'PowerShell syntax:*' }).Count) { Add-Pass 'PowerShell syntax' }

$catalogue = Get-Content -Raw -LiteralPath (Join-Path $ManifestRoot 'profiles.json') | ConvertFrom-Json
$locks = @(Get-ChildItem -LiteralPath (Join-Path $ManifestRoot 'profiles') -Filter '*.lock.json' -File)
if (@($catalogue.profiles).Count -ne $locks.Count) { Add-Failure "profile catalogue has $(@($catalogue.profiles).Count) entries but $($locks.Count) lock records" }
else { Add-Pass "profile catalogue and lock records ($($locks.Count))" }

foreach ($agentsPath in @((Join-Path $RepositoryRoot 'AGENTS.md'), (Join-Path $TemplateRoot 'AGENTS.md'))) {
    $content = Get-Content -Raw -LiteralPath $agentsPath
    $lineCount = (Get-Content -LiteralPath $agentsPath).Count
    $byteCount = [Text.Encoding]::UTF8.GetByteCount($content)
    if ($lineCount -ge 200 -or $byteCount -gt 32768) { Add-Failure "$([IO.Path]::GetRelativePath($RepositoryRoot, $agentsPath)) exceeds instruction budget" }
    else { Add-Pass "$([IO.Path]::GetRelativePath($RepositoryRoot, $agentsPath)) instruction budget: $lineCount lines, $byteCount bytes" }
}

$textExtensions = @('.md','.ps1','.cmd','.sh','.json','.toml','.yaml','.yml','.gitignore')
$privacyPatterns = [ordered]@{
    'Windows user profile path' = 'C:\\Users\\[^\\\s]+'
    'literal Linux home' = '/home/[a-z_][a-z0-9_-]+/'
    'email address' = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
    'secret assignment' = '(?i)\b(api[_-]?key|access[_-]?token|private[_-]?key|client[_-]?secret)\s*[:=]\s*["'']?\S+'
}
foreach ($file in Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse | Where-Object { $_.Extension -in $textExtensions -or $_.Name -eq '.gitignore' }) {
    $content = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($entry in $privacyPatterns.GetEnumerator()) {
        if ($content -match $entry.Value) { Add-Failure "$($entry.Key): $([IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName))" }
    }
}
if (-not $failures.Where({ $_ -match 'profile path|Linux home|email address|secret assignment' }).Count) { Add-Pass 'privacy and secret-pattern scan' }

$environment = Get-Content -Raw -LiteralPath (Join-Path $ManifestRoot 'environment.json') | ConvertFrom-Json
$distroName = [string]$environment.distributionName
$wslNames = @(& wsl.exe --list --quiet 2>$null) | ForEach-Object { $_.Replace(([string][char]0), '').Trim() } | Where-Object { $_ }
if ($wslNames -contains $distroName) {
    foreach ($file in @((Join-Path $ConfigurationRoot 'wsl-core.sh'), (Join-Path $ConfigurationRoot 'devctl'))) {
        $portable = $file.Replace('\', '/')
        $wslPath = (& wsl.exe -d $distroName -- wslpath -u $portable).Trim()
        & wsl.exe -d $distroName -- bash -n $wslPath
        if ($LASTEXITCODE -ne 0) { Add-Failure "Bash syntax: $([IO.Path]::GetRelativePath($RepositoryRoot, $file))" }
        & wsl.exe -d $distroName -- shellcheck $wslPath
        if ($LASTEXITCODE -ne 0) { Add-Failure "ShellCheck: $([IO.Path]::GetRelativePath($RepositoryRoot, $file))" }
    }
    if (-not $failures.Where({ $_ -match 'Bash syntax|ShellCheck' }).Count) { Add-Pass 'Bash syntax and ShellCheck' }

    foreach ($compose in Get-ChildItem -LiteralPath (Join-Path $ConfigurationRoot 'compose') -Filter '*.compose.yaml' -File) {
        $portable = $compose.FullName.Replace('\', '/')
        $wslPath = (& wsl.exe -d $distroName -- wslpath -u $portable).Trim()
        & wsl.exe -d $distroName -- docker compose -f $wslPath config --quiet
        if ($LASTEXITCODE -ne 0) { Add-Failure "Compose config: $($compose.Name)" }
    }
    if (-not $failures.Where({ $_ -like 'Compose config:*' }).Count) { Add-Pass 'Compose definitions' }

    $portableRepository = $RepositoryRoot.Replace('\', '/')
    $wslRepository = (& wsl.exe -d $distroName -- wslpath -u $portableRepository).Trim()
    & wsl.exe -d $distroName -- mise exec -- gitleaks detect --no-git --source $wslRepository --redact --no-banner --exit-code 1
    if ($LASTEXITCODE -ne 0) { Add-Failure 'gitleaks scan' } else { Add-Pass 'gitleaks scan' }
} else {
    Add-Warning "$distroName is unavailable; skipped Bash, ShellCheck, Compose, and gitleaks checks"
}

try {
    & (Join-Path $PSScriptRoot 'install.ps1') -DestinationRoot 'D:\dev' -DryRun
    Add-Pass 'installer dry run'
} catch {
    Add-Failure "installer dry run: $($_.Exception.Message)"
}

if ($warnings.Count -gt 0) { Write-Host "Validation warnings: $($warnings.Count)" -ForegroundColor Yellow }
if ($failures.Count -gt 0) {
    Write-Error "Validation failed with $($failures.Count) issue(s)."
}
Write-Host 'Repository validation passed.' -ForegroundColor Green
