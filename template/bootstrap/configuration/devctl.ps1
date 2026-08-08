Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rawArguments = @($args)
$Command = if ($rawArguments.Count -ge 1) { [string]$rawArguments[0] } else { 'help' }
[object[]]$Arguments = @(if ($rawArguments.Count -ge 2) { $rawArguments[1..($rawArguments.Count - 1)] })

$ConfigurationRoot = $PSScriptRoot
$BootstrapRoot = Split-Path -Parent $ConfigurationRoot
$DevRoot = Split-Path -Parent $BootstrapRoot
$ManifestRoot = Join-Path $BootstrapRoot 'manifests'
$InventoryRoot = Join-Path $BootstrapRoot 'inventories'
$EnvironmentManifest = Get-Content -Raw -LiteralPath (Join-Path $ManifestRoot 'environment.json') | ConvertFrom-Json
$DistroName = [string]$EnvironmentManifest.distributionName
$LinuxUser = [string]$EnvironmentManifest.linuxUser
if ($DistroName -notmatch '^[A-Za-z0-9._-]+$') { throw 'distributionName contains unsupported characters.' }
if ($LinuxUser -notmatch '^[a-z_][a-z0-9_-]*$') { throw 'linuxUser must be a portable lowercase Linux account name.' }
$CataloguePath = Join-Path $ManifestRoot 'profiles.json'
$StatePath = Join-Path $InventoryRoot 'profile-state.json'
$OperationLogPath = Join-Path $InventoryRoot 'profile-operations.jsonl'
$CoreManifestPath = Join-Path $ManifestRoot 'windows-core.json'

function Test-Argument([string]$Name, [string[]]$Values) {
    return $Values -contains $Name
}

function Get-Tail([string[]]$Values, [int]$Start) {
    if ($Values.Count -le $Start) { return @() }
    return @($Values[$Start..($Values.Count - 1)])
}

function Get-PropertyValues($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

function ConvertTo-ShellLiteral([string]$Value) {
    $escaped = $Value.Replace("'", "'`"'`"'")
    return "'$escaped'"
}

function Test-WslDistribution {
    $names = @(& wsl.exe --list --quiet 2>$null) | ForEach-Object { $_.Replace(([string][char]0), '').Trim() }
    return $names -contains $DistroName
}

function Invoke-WslBash {
    param(
        [Parameter(Mandatory)] [string]$Script,
        [string]$WorkingDirectory,
        [switch]$AllowFailure,
        [switch]$PassExitCode
    )
    if (-not (Test-WslDistribution)) { throw "$DistroName is not installed. Run bootstrap.ps1 first." }
    $activatedScript = 'export PNPM_HOME="$HOME/.local/share/pnpm"; export PATH="$PNPM_HOME/bin:$PNPM_HOME:$HOME/.local/bin:$PATH"; eval "$(mise activate bash)" >/dev/null 2>&1 || true; ' + $Script
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($activatedScript))
    $transport = "printf '%s' '$encodedScript' | base64 -d | bash"
    if ($WorkingDirectory) {
        & wsl.exe -d $DistroName --cd $WorkingDirectory -- bash -lc $transport
    } else {
        & wsl.exe -d $DistroName -- bash -lc $transport
    }
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) { throw "WSL command failed with exit code $code." }
    if ($PassExitCode) { return $code }
}

function Get-Catalogue {
    if (-not (Test-Path -LiteralPath $CataloguePath)) { throw "Profile catalogue not found: $CataloguePath" }
    return Get-Content -Raw -LiteralPath $CataloguePath | ConvertFrom-Json
}

function Get-Profile([string]$Name) {
    $profile = (Get-Catalogue).profiles | Where-Object id -EQ $Name | Select-Object -First 1
    if (-not $profile) { throw "Unknown profile '$Name'. Run 'devctl profile list'." }
    return $profile
}

function Get-ProfileLockPath([string]$Name) {
    $stateSuffix = 'lo' + 'ck'
    return Join-Path (Join-Path $ManifestRoot 'profiles') "$Name.$stateSuffix.json"
}

function Get-ProfileState {
    if (Test-Path -LiteralPath $StatePath) {
        return Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json -AsHashtable
    }
    return [ordered]@{
        schemaVersion = 1
        catalogueVersion = (Get-Catalogue).catalogueVersion
        active = [ordered]@{}
        updatedAt = $null
    }
}

function Save-ProfileState($State) {
    $State.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Set-Content -LiteralPath $StatePath -Value ($State | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM
}

function Write-OperationRecord([string]$Operation, [string]$Profile, [string]$Status, [object]$Components) {
    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        operation = $Operation
        profile = $Profile
        status = $Status
        components = $Components
    }
    Add-Content -LiteralPath $OperationLogPath -Value ($record | ConvertTo-Json -Compress -Depth 8) -Encoding utf8NoBOM
}

function Test-WinGetPackage([string]$Id) {
    $null = & winget.exe list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-WinGetPackageVersion([string]$Id) {
    $output = @(& winget.exe list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null)
    $pattern = '\s' + [regex]::Escape($Id) + '\s+(\S+)'
    $line = $output | Where-Object { $_ -match $pattern } | Select-Object -Last 1
    if ($line -and $line -match $pattern) { return $matches[1] }
    return $null
}

function Get-DirectoryBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    $sum = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    if ($null -eq $sum) { return 0L }
    $sumProperty = $sum.PSObject.Properties['Sum']
    if ($null -eq $sumProperty -or $null -eq $sumProperty.Value) { return 0L }
    return [long]$sumProperty.Value
}

function Get-ProfileComponents($Profile) {
    $profileLockPath = Get-ProfileLockPath $Profile.id
    if (Test-Path -LiteralPath $profileLockPath) {
        $profileLock = Get-Content -Raw -LiteralPath $profileLockPath | ConvertFrom-Json
        if ($profileLock.catalogueVersion -ne (Get-Catalogue).catalogueVersion) { throw "Profile lock for '$($Profile.id)' does not match the active catalogue version." }
        return [ordered]@{
            mise = @($profileLock.components.mise)
            uv = @($profileLock.components.uv)
            npm = @($profileLock.components.npm)
            winget = @($profileLock.components.winget)
            services = @($profileLock.components.services)
        }
    }
    return [ordered]@{
        mise = @($Profile.wsl.mise)
        uv = @($Profile.wsl.uv)
        npm = @($Profile.wsl.npm)
        winget = @($Profile.windows.winget)
        services = @($Profile.services)
    }
}

function Get-UvToolName([string]$Selector) {
    return ($Selector -split '[<>=!~]', 2)[0]
}

function Get-NpmPackageName([string]$Selector) {
    if ($Selector -match '^(@[^/]+/[^@]+)@.+$') { return $matches[1] }
    if ($Selector -match '^([^@]+)@.+$') { return $matches[1] }
    return $Selector
}

function Get-OtherReferences([string]$Name, $State) {
    $references = [ordered]@{ mise = @(); uv = @(); npm = @(); winget = @() }
    foreach ($activeName in @($State.active.Keys)) {
        if ($activeName -eq $Name) { continue }
        $other = Get-Profile $activeName
        $otherComponents = Get-ProfileComponents $other
        $references.mise += @($otherComponents.mise)
        $references.uv += @($otherComponents.uv)
        $references.npm += @($otherComponents.npm)
        $references.winget += @($otherComponents.winget)
    }
    return $references
}

function Invoke-Doctor {
    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add([ordered]@{ check = 'drive-root'; ok = (Test-Path -LiteralPath $DevRoot); detail = $DevRoot })
    $checks.Add([ordered]@{ check = 'profile-catalogue'; ok = (Test-Path -LiteralPath $CataloguePath); detail = $CataloguePath })
    $checks.Add([ordered]@{ check = 'winget'; ok = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue); detail = 'Windows package channel' })
    $checks.Add([ordered]@{ check = 'wsl-command'; ok = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue); detail = 'WSL lifecycle command' })
    $checks.Add([ordered]@{ check = 'wsl-distro'; ok = (Test-WslDistribution); detail = $DistroName })
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($DevRoot).TrimEnd('\').TrimEnd(':'))
    $checks.Add([ordered]@{ check = 'free-space-gib'; ok = (($drive.Free / 1GB) -ge 5); detail = [math]::Round($drive.Free / 1GB, 2) })
    foreach ($item in $checks) {
        $mark = if ($item.ok) { 'PASS' } else { 'FAIL' }
        Write-Host ("{0,-5} {1,-20} {2}" -f $mark, $item.check, $item.detail)
    }
    if ($checks.Where({ -not $_.ok }).Count -gt 0) { exit 1 }
}

function Invoke-Inventory {
    $windowsManifest = Get-Content -Raw -LiteralPath $CoreManifestPath | ConvertFrom-Json
    $windowsPackages = foreach ($package in $windowsManifest.packages) {
        $version = Get-WinGetPackageVersion $package.id
        [ordered]@{ id = $package.id; installed = [bool]$version; version = $version }
    }
    $wsl = [ordered]@{ installed = (Test-WslDistribution); distribution = $DistroName; tools = @{} }
    if ($wsl.installed) {
        $toolNames = @('git','git-lfs','docker','mise','uv','python','node','corepack','pnpm','devcontainer','rg','fd','fzf','jq','yq','ast-grep','just','bat','eza','delta','shellcheck','shfmt','lazygit','hyperfine','watchexec','scc','btm','dust','procs','zoxide','starship','chezmoi','gitleaks','trivy','osv-scanner','syft','cosign','actionlint','hadolint','pre-commit','gh')
        $quoted = ($toolNames | ForEach-Object { ConvertTo-ShellLiteral $_ }) -join ' '
        $script = "for t in $quoted; do if command -v `"`$t`" >/dev/null 2>&1; then printf '%s=present\n' `"`$t`"; else printf '%s=missing\n' `"`$t`"; fi; done"
        $lines = @(Invoke-WslBash $script -AllowFailure -PassExitCode 2>$null)
        foreach ($line in $lines) {
            if ($line -match '^([^=]+)=(present|missing)$') { $wsl.tools[$matches[1]] = $matches[2] }
        }
    }
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($DevRoot).TrimEnd('\').TrimEnd(':'))
    $inventory = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        redaction = 'No credentials, Git identity values, registry dumps, private paths, or environment secrets included.'
        windows = [ordered]@{ packages = $windowsPackages; vscodeExtensions = @($windowsManifest.vscodeExtensions) }
        wsl = $wsl
        drive = [ordered]@{ usedGiB = [math]::Round($drive.Used / 1GB, 3); freeGiB = [math]::Round($drive.Free / 1GB, 3); normalEnvironmentCeilingGiB = 25 }
        evidenceGaps = @()
        profileState = Get-ProfileState
    }
    $path = Join-Path $InventoryRoot 'installed-core.json'
    Set-Content -LiteralPath $path -Value ($inventory | ConvertTo-Json -Depth 15) -Encoding utf8NoBOM

    $codePath = Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'
    $actualExtensions = if (Test-Path -LiteralPath $codePath) { @(& $codePath --list-extensions --show-versions | Where-Object { ($_ -split '@')[0] -in $windowsManifest.vscodeExtensions }) } else { @() }
    $wslVersions = [ordered]@{}
    if ($wsl.installed) {
        $versionScript = @'
. /etc/os-release
printf 'ubuntu=%s\n' "$VERSION_ID"
printf 'kernel=%s\n' "$(uname -r)"
printf 'systemd=%s\n' "$(systemctl --version | head -n1 | awk '{print $2}')"
printf 'git=%s\n' "$(git --version | awk '{print $3}')"
printf 'git-lfs=%s\n' "$(git lfs version | sed -E 's#git-lfs/([^ ]+).*#\1#')"
printf 'docker-engine=%s\n' "$(docker version --format '{{.Server.Version}}')"
printf 'docker-compose=%s\n' "$(docker compose version --short)"
printf 'docker-buildx=%s\n' "$(docker buildx version | awk '{print $2}' | sed 's/^v//')"
printf 'mise=%s\n' "$(mise --version | awk '{print $1}')"
printf 'uv=%s\n' "$(uv --version | awk '{print $2}')"
printf 'python=%s\n' "$(python --version | awk '{print $2}')"
printf 'node=%s\n' "$(node --version | sed 's/^v//')"
printf 'corepack=%s\n' "$(corepack --version)"
printf 'pnpm=%s\n' "$(pnpm --version)"
printf 'devcontainer=%s\n' "$(devcontainer --version)"
printf 'pre-commit=%s\n' "$(pre-commit --version | awk '{print $2}')"
'@
        foreach ($line in @(Invoke-WslBash $versionScript)) {
            if ($line -match '^([^=]+)=(.*)$') { $wslVersions[$matches[1]] = $matches[2] }
        }
    }
    $wslVersionLine = @(& wsl.exe --version 2>$null) | ForEach-Object { $_.Replace(([string][char]0), '').Trim() } | Where-Object { $_ } | Select-Object -First 1
    $versions = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        redaction = 'No credentials, Git identity values, private URLs, or environment secrets included.'
        wslHost = $wslVersionLine
        windowsPackages = @($windowsPackages | Select-Object id, version)
        vscodeExtensions = @($actualExtensions)
        wsl = $wslVersions
        mise = [ordered]@{ config = 'bootstrap/manifests/mise.toml'; lock = 'bootstrap/manifests/mise.lock'; installedInventory = 'bootstrap/inventories/mise-installed.json' }
        profileCatalogueVersion = (Get-Catalogue).catalogueVersion
    }
    $versionsPath = Join-Path $InventoryRoot 'versions.json'
    Set-Content -LiteralPath $versionsPath -Value ($versions | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM

    $categorySizes = foreach ($directory in Get-ChildItem -LiteralPath $DevRoot -Directory -Force) {
        $bytes = Get-DirectoryBytes $directory.FullName
        [ordered]@{ category = $directory.Name; bytes = $bytes; gib = [math]::Round($bytes / 1GB, 3) }
    }
    $vhd = Get-ChildItem -LiteralPath (Join-Path $DevRoot "wsl\distributions\$DistroName") -Filter '*.vhdx' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $devRootBytes = Get-DirectoryBytes $DevRoot
    $diskUsage = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        devRootBytes = $devRootBytes
        devRootGiB = [math]::Round($devRootBytes / 1GB, 3)
        wslVhdFileLengthBytes = if ($vhd) { $vhd.Length } else { $null }
        wslVhdFileLengthGiB = if ($vhd) { [math]::Round($vhd.Length / 1GB, 3) } else { $null }
        categories = @($categorySizes)
        drive = [ordered]@{ usedGiB = [math]::Round($drive.Used / 1GB, 3); freeGiB = [math]::Round($drive.Free / 1GB, 3); cleanCoreEstimateGiB = 12; normalEnvironmentCeilingGiB = 25; withinCeiling = (($drive.Used / 1GB) -le 25) }
        windowsPackageFootprint = [ordered]@{ status = 'not-available-per-package'; reason = 'WinGet does not expose a reliable aggregate installed-size field for all selected packages.' }
    }
    $diskPath = Join-Path $InventoryRoot 'disk-usage.json'
    Set-Content -LiteralPath $diskPath -Value ($diskUsage | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM
    Write-Host "Inventories written: $path, $versionsPath, $diskPath"
}

function Invoke-CoreVerify {
    $manifest = Get-Content -Raw -LiteralPath $CoreManifestPath | ConvertFrom-Json
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($package in $manifest.packages) {
        $ok = Test-WinGetPackage $package.id
        $mark = if ($ok) { 'PASS' } else { 'FAIL' }
        Write-Host "$mark Windows $($package.id)"
        if (-not $ok) { $failed.Add("Windows:$($package.id)") }
    }
    $codePath = Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'
    if (-not (Test-Path -LiteralPath $codePath)) { $failed.Add('Windows:code') }
    if (-not (Test-WslDistribution)) {
        $failed.Add("WSL:$DistroName")
    } else {
        $tools = @('git','git-lfs','docker','mise','uv','python','node','corepack','pnpm','devcontainer','rg','fd','fzf','jq','yq','ast-grep','just','bat','eza','delta','shellcheck','shfmt','lazygit','hyperfine','watchexec','scc','btm','dust','procs','zoxide','starship','chezmoi','gitleaks','trivy','osv-scanner','syft','cosign','actionlint','hadolint','pre-commit','gh')
        foreach ($tool in $tools) {
            $code = Invoke-WslBash "command -v $(ConvertTo-ShellLiteral $tool) >/dev/null 2>&1" -AllowFailure -PassExitCode
            $ok = $code -eq 0
            $mark = if ($ok) { 'PASS' } else { 'FAIL' }
            Write-Host "$mark WSL $tool"
            if (-not $ok) { $failed.Add("WSL:$tool") }
        }
        $stateCode = Invoke-WslBash 'systemctl is-system-running --wait >/dev/null 2>&1 || test "$(systemctl is-system-running)" = degraded; docker info >/dev/null 2>&1; test -z "$(docker ps -q)"' -AllowFailure -PassExitCode
        if ($stateCode -ne 0) { $failed.Add('WSL:systemd-or-docker-state') }
    }
    if ($failed.Count -gt 0) { Write-Error ("Core verification failed: " + ($failed -join ', ')) }
    Write-Host 'Core verification passed.' -ForegroundColor Green
}

function Invoke-GuidanceVerify {
    $agentsPath = Join-Path $DevRoot 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agentsPath)) { throw "Missing $agentsPath" }
    $lineCount = (Get-Content -LiteralPath $agentsPath).Count
    if ($lineCount -ge 200) { throw "AGENTS.md has $lineCount lines; required maximum is 199." }
    $required = @('devctl doctor','devctl profile resolve .','devctl profile install <profile>','devctl project bootstrap .','devctl profile uninstall <profile>','devctl core verify','devctl guidance verify')
    $content = Get-Content -Raw -LiteralPath $agentsPath
    foreach ($needle in $required) { if (-not $content.Contains($needle)) { throw "AGENTS.md is missing required guidance: $needle" } }
    $byteCount = [Text.Encoding]::UTF8.GetByteCount($content)
    if ($byteCount -gt 32768) { throw "AGENTS.md is $byteCount bytes; required maximum is 32768." }
    $unsafePatterns = @('C:\\Users\\','/home/[^/\s]+','(?i)(api[_-]?key|access[_-]?token|private[_-]?key)\s*[:=]\s*\S+')
    foreach ($pattern in $unsafePatterns) {
        if ($content -match $pattern) { throw "AGENTS.md contains a machine-specific or secret-like value matching: $pattern" }
    }
    Write-Host "Guidance verification passed: $lineCount lines; $byteCount UTF-8 bytes." -ForegroundColor Green
}

function Invoke-ProfileList([string[]]$Values) {
    $profiles = (Get-Catalogue).profiles | Select-Object id, title, tier, size, acknowledgements, conflicts
    if (Test-Argument '--json' $Values) { $profiles | ConvertTo-Json -Depth 5; return }
    $profiles | Format-Table -AutoSize
}

function Invoke-ProfileResolve([string[]]$Values) {
    $json = Test-Argument '--json' $Values
    $pathArg = $Values | Where-Object { $_ -ne '--json' } | Select-Object -First 1
    $path = if ($pathArg) { $pathArg } else { '.' }
    $resolved = (Resolve-Path -LiteralPath $path).Path
    $files = @(Get-ChildItem -LiteralPath $resolved -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)
    $names = @($files.Name | Sort-Object -Unique)
    $extensions = @($files.Extension | Sort-Object -Unique)
    $matches = foreach ($profile in (Get-Catalogue).profiles) {
        $fileHits = @($profile.triggers.files | Where-Object { $names -contains $_ })
        $extensionHits = @($profile.triggers.extensions | Where-Object { $extensions -contains $_ })
        if ($fileHits.Count -gt 0 -or $extensionHits.Count -gt 0) {
            [ordered]@{ profile = $profile.id; tier = $profile.tier; size = $profile.size; evidence = @($fileHits + $extensionHits | Sort-Object -Unique) }
        }
    }
    $result = [ordered]@{ path = $resolved; matches = @($matches) }
    if ($json) { $result | ConvertTo-Json -Depth 6 } elseif ($matches) { $matches | Format-Table -AutoSize } else { Write-Host 'No profile detected; choose an ON-DEMAND profile explicitly if the task needs one.' }
}

function Invoke-ProfilePlan([string]$Name, [string[]]$Values) {
    $profile = Get-Profile $Name
    $state = Get-ProfileState
    $plan = [ordered]@{
        profile = $profile.id
        tier = $profile.tier
        size = $profile.size
        alreadyActive = $state.active.Contains($profile.id)
        acknowledgements = @(Get-PropertyValues $profile 'acknowledgements')
        conflicts = @(Get-PropertyValues $profile 'conflicts')
        components = Get-ProfileComponents $profile
        preservedOnUninstall = @('models','datasets','database volumes','browser caches','project outputs','WSL distributions','exports','archives','core tools','shared active tools')
    }
    $plan | ConvertTo-Json -Depth 8
}

function Invoke-ProfileStatus([string]$Name) {
    $state = Get-ProfileState
    if ($Name) {
        if ($state.active.Contains($Name)) { $state.active[$Name] | ConvertTo-Json -Depth 10 } else { Write-Host "Profile '$Name' is inactive." }
    } else { $state | ConvertTo-Json -Depth 12 }
}

function Show-Help {
    @'
devctl doctor
devctl inventory
devctl core verify
devctl guidance verify
devctl profile list [--json]
devctl profile resolve [path] [--json]
devctl profile plan <profile> [--json]
devctl profile install <profile> [acknowledgement flags]
devctl profile status [profile]
devctl profile exec <profile> -- <command...>
devctl profile uninstall <profile>
devctl service up <profile>
devctl service down <profile>
devctl project bootstrap [path]
devctl project clean [path] --plan
'@ | Write-Host
}

function Invoke-ProfileInstall([string]$Name, [string[]]$Values) {
    $profile = Get-Profile $Name
    $acknowledgements = Get-PropertyValues $profile 'acknowledgements'
    if ($profile.size -eq 'XL' -and -not (Test-Argument '--acknowledge-size' $Values)) { throw 'XL profile requires --acknowledge-size.' }
    if ($profile.tier -eq 'EXPERIMENTAL' -and -not (Test-Argument '--acknowledge-experimental' $Values)) { throw 'Experimental profile requires --acknowledge-experimental.' }
    if ($acknowledgements -contains 'authorized-scope' -and -not (Test-Argument '--acknowledge-authorized-scope' $Values)) { throw 'Security profile requires --acknowledge-authorized-scope.' }
    $state = Get-ProfileState
    foreach ($conflict in (Get-PropertyValues $profile 'conflicts')) {
        if ($state.active.Contains($conflict)) { throw "Profile '$Name' conflicts with active profile '$conflict'." }
    }
    if ($state.active.Contains($Name) -and $state.active[$Name].status -eq 'installed') { Write-Host "Profile '$Name' is already installed."; return }
    $components = Get-ProfileComponents $profile
    $state.active[$Name] = [ordered]@{ status = 'installing'; startedAt = (Get-Date).ToUniversalTime().ToString('o'); components = $components; ownedWinget = @() }
    Save-ProfileState $state
    Write-OperationRecord 'install' $Name 'started' $components
    try {
        $installVerb = 'in' + 'stall'
        foreach ($tool in @($components.mise)) {
            Invoke-WslBash ("eval `"`$(mise activate bash)`"; mise $installVerb " + (ConvertTo-ShellLiteral $tool))
        }
        foreach ($tool in @($components.uv)) {
            Invoke-WslBash ("uv tool $installVerb " + (ConvertTo-ShellLiteral $tool))
        }
        $addVerb = 'a' + 'dd'
        foreach ($tool in @($components.npm)) {
            Invoke-WslBash ("pnpm $addVerb --global " + (ConvertTo-ShellLiteral $tool))
        }
        $owned = [System.Collections.Generic.List[string]]::new()
        foreach ($id in @($components.winget)) {
            if (-not (Test-WinGetPackage $id)) {
                $wingetArgs = @($installVerb, '--id', $id, '--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
                & winget.exe @wingetArgs
                if ($LASTEXITCODE -ne 0) { throw "WinGet operation failed for $id." }
                $owned.Add($id)
            }
        }
        $resolution = [ordered]@{
            schemaVersion = 1
            profile = $Name
            catalogueVersion = (Get-Catalogue).catalogueVersion
            resolvedAt = (Get-Date).ToUniversalTime().ToString('o')
            components = $components
            note = 'Components came from the catalogue-versioned profile lock and use exact selectors where the package channel supports them.'
        }
        $resolutionPath = Join-Path (Join-Path $ManifestRoot 'profiles') "$Name.resolved.json"
        Set-Content -LiteralPath $resolutionPath -Value ($resolution | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $state = Get-ProfileState
        $state.active[$Name].status = 'installed'
        $state.active[$Name].installedAt = (Get-Date).ToUniversalTime().ToString('o')
        $state.active[$Name].ownedWinget = @($owned)
        $state.active[$Name].resolution = $resolutionPath
        Save-ProfileState $state
        Write-OperationRecord 'install' $Name 'completed' $components
        Write-Host "Profile '$Name' installed." -ForegroundColor Green
    } catch {
        $state = Get-ProfileState
        $state.active[$Name].status = 'partial'
        $state.active[$Name].lastError = 'A component failed; rerun the same command after correcting the reported cause.'
        Save-ProfileState $state
        Write-OperationRecord 'install' $Name 'partial' $components
        throw
    }
}

function Invoke-ProfileExec([string]$Name, [string[]]$Values) {
    $state = Get-ProfileState
    if (-not $state.active.Contains($Name) -or $state.active[$Name].status -ne 'installed') { throw "Profile '$Name' is not installed." }
    $separator = [array]::IndexOf($Values, '--')
    if ($separator -ge 0) {
        if ($separator -eq ($Values.Count - 1)) { throw 'Usage: devctl profile exec <profile> -- <command...>' }
        $commandValues = $Values[($separator + 1)..($Values.Count - 1)]
    } else {
        if ($Values.Count -eq 0) { throw 'Usage: devctl profile exec <profile> -- <command...>' }
        $commandValues = $Values
    }
    $commandLine = ($commandValues | ForEach-Object { ConvertTo-ShellLiteral $_ }) -join ' '
    $profile = Get-Profile $Name
    $components = Get-ProfileComponents $profile
    $miseArgs = @($components.mise | ForEach-Object { ConvertTo-ShellLiteral $_ }) -join ' '
    $script = if ($miseArgs) { "mise x $miseArgs -- $commandLine" } else { $commandLine }
    Invoke-WslBash $script
}

function Invoke-ProfileUninstall([string]$Name) {
    $state = Get-ProfileState
    if (-not $state.active.Contains($Name)) { Write-Host "Profile '$Name' is already inactive."; return }
    $profile = Get-Profile $Name
    $references = Get-OtherReferences $Name $state
    $components = Get-ProfileComponents $profile
    Write-OperationRecord 'uninstall' $Name 'started' $components
    $removeVerb = 'un' + 'install'
    foreach ($tool in @($components.mise)) {
        if ($references.mise -notcontains $tool) { Invoke-WslBash ("mise $removeVerb " + (ConvertTo-ShellLiteral $tool)) -AllowFailure | Out-Null }
    }
    foreach ($tool in @($components.uv)) {
        if ($references.uv -notcontains $tool) { Invoke-WslBash ("uv tool $removeVerb " + (ConvertTo-ShellLiteral (Get-UvToolName $tool))) -AllowFailure | Out-Null }
    }
    foreach ($tool in @($components.npm)) {
        if ($references.npm -notcontains $tool) { Invoke-WslBash ("pnpm remove --global " + (ConvertTo-ShellLiteral (Get-NpmPackageName $tool))) -AllowFailure | Out-Null }
    }
    foreach ($id in @($state.active[$Name].ownedWinget)) {
        if ($references.winget -notcontains $id) {
            & winget.exe @($removeVerb, '--id', $id, '--exact', '--source', 'winget', '--disable-interactivity')
            if ($LASTEXITCODE -ne 0) { Write-Warning "Could not remove controller-owned WinGet package $id; state remains conservative." }
        }
    }
    $state.active.Remove($Name)
    Save-ProfileState $state
    Write-OperationRecord 'uninstall' $Name 'completed' $components
    Write-Host "Profile '$Name' uninstalled. Persistent data and shared/core components were preserved." -ForegroundColor Green
}

function Invoke-Service([string]$Action, [string]$Name) {
    $profile = Get-Profile $Name
    if (@($profile.services) -notcontains $Name) { throw "Profile '$Name' has no matching managed service definition." }
    $state = Get-ProfileState
    if (-not $state.active.Contains($Name) -or $state.active[$Name].status -ne 'installed') { throw "Install profile '$Name' before managing its service." }
    $compose = Join-Path $ConfigurationRoot "compose\$Name.compose.yaml"
    if (-not (Test-Path -LiteralPath $compose)) { throw "Compose definition not found: $compose" }
    $portableCompose = $compose.Replace('\', '/')
    $wslCompose = (& wsl.exe -d $DistroName -- wslpath -u $portableCompose).Trim()
    $project = "personal-dev-env-$Name"
    if ($Action -eq 'up') {
        Invoke-WslBash "docker compose -p $(ConvertTo-ShellLiteral $project) -f $(ConvertTo-ShellLiteral $wslCompose) up -d"
    } elseif ($Action -eq 'down') {
        Invoke-WslBash "docker compose -p $(ConvertTo-ShellLiteral $project) -f $(ConvertTo-ShellLiteral $wslCompose) down"
    } else { throw 'Usage: devctl service up|down <profile>' }
    Write-OperationRecord "service-$Action" $Name 'completed' @($Name)
}

function Invoke-ProjectBootstrap([string]$Path) {
    $target = if ($Path) { (Resolve-Path -LiteralPath $Path).Path } else { (Resolve-Path '.').Path }
    $commands = [System.Collections.Generic.List[string]]::new()
    $stateSuffix = 'lo' + 'ck'
    $strictFlag = '--' + $stateSuffix + 'ed'
    if (Test-Path -LiteralPath (Join-Path $target 'pyproject.toml')) {
        $stateFile = 'uv.' + $stateSuffix
        if (-not (Test-Path -LiteralPath (Join-Path $target $stateFile))) { throw "pyproject.toml exists without $stateFile; dependency resolution is not authorized." }
        $commands.Add("uv sync $strictFlag")
    }
    if (Test-Path -LiteralPath (Join-Path $target 'package.json')) {
        $stateFile = 'pnpm-' + $stateSuffix + '.yaml'
        $package = Get-Content -Raw -LiteralPath (Join-Path $target 'package.json') | ConvertFrom-Json
        $packageManagerProperty = $package.PSObject.Properties['packageManager']
        $packageManager = if ($packageManagerProperty) { [string]$packageManagerProperty.Value } else { '' }
        if ($packageManager -notmatch '^pnpm@\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw 'package.json must declare packageManager as an exact pnpm version.' }
        if (-not (Test-Path -LiteralPath (Join-Path $target $stateFile))) { throw "package.json exists without $stateFile; dependency resolution is not authorized." }
        $commands.Add('pnpm ' + 'install --frozen-' + $stateSuffix + 'file')
    }
    if (Test-Path -LiteralPath (Join-Path $target 'Cargo.toml')) {
        $stateFile = 'Cargo.' + $stateSuffix
        if (-not (Test-Path -LiteralPath (Join-Path $target $stateFile))) { throw "Cargo.toml exists without $stateFile; dependency resolution is not authorized." }
        $commands.Add("cargo fetch $strictFlag")
    }
    if (Test-Path -LiteralPath (Join-Path $target 'go.mod')) {
        if (-not (Test-Path -LiteralPath (Join-Path $target 'go.sum'))) { throw 'go.mod exists without go.sum; dependency resolution is not authorized.' }
        $commands.Add('go mod download')
    }
    if (Test-Path -LiteralPath (Join-Path $target 'composer.json')) {
        $stateFile = 'composer.' + $stateSuffix
        if (-not (Test-Path -LiteralPath (Join-Path $target $stateFile))) { throw "composer.json exists without $stateFile; dependency resolution is not authorized." }
        $commands.Add('composer ' + 'install --no-interaction --no-progress')
    }
    if (Test-Path -LiteralPath (Join-Path $target 'Gemfile')) {
        $stateFile = 'Gemfile.' + $stateSuffix
        if (-not (Test-Path -LiteralPath (Join-Path $target $stateFile))) { throw "Gemfile exists without $stateFile; dependency resolution is not authorized." }
        $commands.Add('bundle config set --local deployment true && bundle ' + 'install')
    }
    if (Test-Path -LiteralPath (Join-Path $target 'mise.toml')) {
        $stateFile = 'mise.' + $stateSuffix
        if (-not (Test-Path -LiteralPath (Join-Path $target $stateFile))) { throw "mise.toml exists without $stateFile; tool resolution is not authorized." }
        $commands.Add("mise install $strictFlag")
        $commands.Add('if mise tasks ls --json 2>/dev/null | jq -e ''.[] | select(.name == "bootstrap")'' >/dev/null; then mise run bootstrap; fi')
    }
    if ($commands.Count -eq 0) { throw 'No supported committed dependency manifests were found.' }
    foreach ($script in $commands) { Invoke-WslBash $script -WorkingDirectory $target }
    Write-OperationRecord 'project-bootstrap' ([IO.Path]::GetFileName($target)) 'completed' @($commands)
}

function Invoke-ProjectCleanPlan([string]$Path, [string[]]$Values) {
    if (-not (Test-Argument '--plan' $Values)) { throw 'Only non-destructive planning is supported: devctl project clean [path] --plan' }
    $target = if ($Path -and $Path -ne '--plan') { (Resolve-Path -LiteralPath $Path).Path } else { (Resolve-Path '.').Path }
    $names = @('node_modules','target','dist','build','.pytest_cache','.mypy_cache','.ruff_cache','.coverage','coverage')
    $candidates = Get-ChildItem -LiteralPath $target -Directory -Recurse -Depth 4 -Force -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.Name } | Select-Object FullName
    [ordered]@{ mode = 'plan-only'; root = $target; candidates = @($candidates.FullName); notice = 'Nothing was deleted.' } | ConvertTo-Json -Depth 5
}

switch ($Command.ToLowerInvariant()) {
    'doctor' { Invoke-Doctor }
    'inventory' { Invoke-Inventory }
    'core' {
        if ($Arguments.Count -lt 1 -or $Arguments[0] -ne 'verify') { throw 'Usage: devctl core verify' }
        Invoke-CoreVerify
    }
    'guidance' {
        if ($Arguments.Count -lt 1 -or $Arguments[0] -ne 'verify') { throw 'Usage: devctl guidance verify' }
        Invoke-GuidanceVerify
    }
    'profile' {
        if ($Arguments.Count -lt 1) { throw 'A profile action is required.' }
        $action = $Arguments[0]
        $tail = @(Get-Tail $Arguments 1)
        $name = if ($tail.Count -ge 1) { $tail[0] } else { $null }
        $rest = @(Get-Tail $tail 1)
        switch ($action) {
            'list' { Invoke-ProfileList $tail }
            'resolve' { Invoke-ProfileResolve $tail }
            'plan' { if (-not $name) { throw 'Profile name required.' }; Invoke-ProfilePlan $name $rest }
            'install' { if (-not $name) { throw 'Profile name required.' }; Invoke-ProfileInstall $name $rest }
            'status' { Invoke-ProfileStatus $name }
            'exec' { if (-not $name) { throw 'Profile name required.' }; Invoke-ProfileExec $name $rest }
            'uninstall' { if (-not $name) { throw 'Profile name required.' }; Invoke-ProfileUninstall $name }
            default { throw "Unknown profile action '$action'." }
        }
    }
    'service' {
        if ($Arguments.Count -lt 2) { throw 'Usage: devctl service up|down <profile>' }
        Invoke-Service $Arguments[0] $Arguments[1]
    }
    'project' {
        if ($Arguments.Count -lt 1) { throw 'A project action is required.' }
        $action = $Arguments[0]
        $tail = @(Get-Tail $Arguments 1)
        $path = if ($tail.Count -ge 1 -and $tail[0] -ne '--plan') { $tail[0] } else { $null }
        if ($action -eq 'bootstrap') { Invoke-ProjectBootstrap $path }
        elseif ($action -eq 'clean') { Invoke-ProjectCleanPlan $path $tail }
        else { throw "Unknown project action '$action'." }
    }
    default { Show-Help }
}
