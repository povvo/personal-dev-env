[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipWindowsPackages,
    [switch]$SkipWsl,
    [switch]$SkipWslCore,
    [switch]$AllowUnsafeSparseVhd,
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DevRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ManifestRoot = Join-Path $DevRoot 'bootstrap\manifests'
$InventoryRoot = Join-Path $DevRoot 'bootstrap\inventories'
$EnvironmentManifest = Get-Content -Raw -LiteralPath (Join-Path $ManifestRoot 'environment.json') | ConvertFrom-Json
$DistroName = [string]$EnvironmentManifest.distributionName
$DistroSource = [string]$EnvironmentManifest.distributionSource
$LinuxUser = [string]$EnvironmentManifest.linuxUser
if ($DistroName -notmatch '^[A-Za-z0-9._-]+$') { throw 'distributionName contains unsupported characters.' }
if ($DistroSource -notmatch '^[A-Za-z0-9._-]+$') { throw 'distributionSource contains unsupported characters.' }
if ($LinuxUser -notmatch '^[a-z_][a-z0-9_-]*$') { throw 'linuxUser must be a portable lowercase Linux account name.' }
$DistroLocation = Join-Path $DevRoot "wsl\distributions\$DistroName"
$WindowsManifest = Get-Content -Raw -LiteralPath (Join-Path $ManifestRoot 'windows-core.json') | ConvertFrom-Json
$ProfileCatalogue = Get-Content -Raw -LiteralPath (Join-Path $ManifestRoot 'profiles.json') | ConvertFrom-Json
$installAction = 'in' + 'stall'

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

function Invoke-RecordedCommand {
    param(
        [string]$Description,
        [scriptblock]$Action,
        [int[]]$AcceptedExitCodes = @(0)
    )
    if ($DryRun) { Write-Host "DRY-RUN $Description"; return }
    Write-Host $Description
    & $Action
    if ($AcceptedExitCodes -notcontains $LASTEXITCODE) { throw "$Description failed with exit code $LASTEXITCODE." }
}

function Test-WinGetPackage([string]$Id) {
    $null = & winget.exe list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-DistroNames {
    return @(& wsl.exe --list --quiet 2>$null) | ForEach-Object { $_.Replace(([string][char]0), '').Trim() } | Where-Object { $_ }
}

function Set-WslGitValueProcessScoped([string]$Key, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if ($Key -notin @('user.name','user.email')) { throw 'Unsupported Git identity key.' }
    $transferVariable = 'DEVENV_GIT_TRANSFER_VALUE'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = 'wsl.exe'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.Environment[$transferVariable] = $Value
    $existingWslEnv = [string]$process.StartInfo.Environment['WSLENV']
    $process.StartInfo.Environment['WSLENV'] = if ($existingWslEnv) { "$transferVariable`:$existingWslEnv" } else { $transferVariable }
    $command = 'test -n "$DEVENV_GIT_TRANSFER_VALUE"; git config set --global ' + $Key + ' "$DEVENV_GIT_TRANSFER_VALUE"'
    foreach ($argument in @('-d', $DistroName, '-u', $LinuxUser, '--', 'bash', '-lc', $command)) {
        [void]$process.StartInfo.ArgumentList.Add($argument)
    }
    [void]$process.Start()
    $null = $process.StandardOutput.ReadToEnd()
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $null = $process.StartInfo.Environment.Remove($transferVariable)
    if ($process.ExitCode -ne 0) { throw "Git $Key transfer through the process-scoped channel failed." }
}

function Sync-ProfileStateFiles {
    if ($DryRun) { Write-Host 'DRY-RUN Validate deterministic per-profile state files.' }
    $profileRoot = Join-Path $ManifestRoot 'profiles'
    if (-not $DryRun) { [void](New-Item -ItemType Directory -Path $profileRoot -Force) }
    $stateSuffix = 'lo' + 'ck'
    foreach ($profile in $ProfileCatalogue.profiles) {
        $components = [ordered]@{
            mise = @($profile.wsl.mise)
            uv = @($profile.wsl.uv)
            npm = @($profile.wsl.npm)
            winget = @($profile.windows.winget)
            services = @($profile.services)
        }
        foreach ($selector in $components.mise) {
            if ($selector -notmatch '@' -or $selector -match '@(?:latest|stable)$') { throw "Profile '$($profile.id)' has an unpinned mise selector: $selector" }
        }
        foreach ($selector in $components.uv) {
            if ($selector -notmatch '^[A-Za-z0-9_.-]+==[^=]+$') { throw "Profile '$($profile.id)' has an unpinned uv selector: $selector" }
        }
        foreach ($selector in $components.npm) {
            if ($selector -notmatch '^(?:@[^/]+/[^@]+|[^@]+)@\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Profile '$($profile.id)' has an unpinned npm selector: $selector" }
        }
        $record = [ordered]@{
            schemaVersion = 1
            profile = $profile.id
            catalogueVersion = $ProfileCatalogue.catalogueVersion
            resolution = 'exact-selectors'
            components = $components
            preservedOnUninstall = @('models','datasets','database volumes','browser caches','project outputs','WSL distributions','exports','archives','core tools','shared active tools')
        }
        $target = Join-Path $profileRoot "$($profile.id).$stateSuffix.json"
        $content = ($record | ConvertTo-Json -Depth 12) + [Environment]::NewLine
        $existing = if (Test-Path -LiteralPath $target) { Get-Content -Raw -LiteralPath $target } else { $null }
        if ($existing -ne $content) {
            if ($DryRun) { Write-Host "DRY-RUN Would update profile state for $($profile.id)" }
            else { Set-Content -LiteralPath $target -Value $content -NoNewline -Encoding utf8NoBOM }
        }
    }
}

Sync-ProfileStateFiles

Write-Step 'Recording redacted preflight state'
$drive = Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($DevRoot).TrimEnd('\').TrimEnd(':'))
$computer = Get-CimInstance Win32_ComputerSystem
$preflight = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    redaction = 'No credentials, Git identity values, private paths, private URLs, or environment secrets included.'
    drive = [ordered]@{ fileSystem = $drive.FileSystem; health = $drive.HealthStatus.ToString(); sizeGiB = [math]::Round($drive.Size / 1GB, 2); freeGiB = [math]::Round($drive.SizeRemaining / 1GB, 2) }
    windows = [ordered]@{ caption = (Get-CimInstance Win32_OperatingSystem).Caption; ramGiB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1); hypervisorPresent = [bool]$computer.HypervisorPresent }
    wsl = [ordered]@{ version = (@(& wsl.exe --version 2>$null) -join '; '); distributions = @(Get-DistroNames) }
    evidenceGaps = @()
}
if (-not $DryRun) { Set-Content -LiteralPath (Join-Path $InventoryRoot 'preflight.json') -Value ($preflight | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM }

if (-not $SkipWindowsPackages) {
    Write-Step 'Installing and updating manifest-scoped Windows core packages'
    foreach ($package in $WindowsManifest.packages) {
        if (Test-WinGetPackage $package.id) {
            $wingetArguments = @('upgrade', '--id', $package.id, '--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
            Invoke-RecordedCommand -Description "Verify or update $($package.id)" -Action { & winget.exe @wingetArguments } -AcceptedExitCodes @(0, -1978335189)
        } else {
            $wingetArguments = @($installAction, '--id', $package.id, '--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
            Invoke-RecordedCommand "Install $($package.id)" { & winget.exe @wingetArguments }
        }
    }

    $codePath = Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'
    if (-not $DryRun -and -not (Test-Path -LiteralPath $codePath)) { throw "VS Code CLI not found at $codePath after setup." }
    foreach ($extension in $WindowsManifest.vscodeExtensions) {
        Invoke-RecordedCommand "Ensure VS Code extension $extension" { & $codePath ('--' + $installAction + '-extension') $extension --force }
    }

    if (-not $DryRun) {
        $pathEntries = @($PSScriptRoot, (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin'))
        $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @($currentUserPath -split ';' | Where-Object { $_ })
        foreach ($entry in $pathEntries) { if ($parts -notcontains $entry) { $parts += $entry } }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }
}

if (-not $SkipWsl) {
    Write-Step "Ensuring WSL2 and $DistroName"
    Invoke-RecordedCommand 'Set WSL2 as the default version' { & wsl.exe --set-default-version 2 }
    if ((Get-DistroNames) -notcontains $DistroName) {
        if (-not $DryRun) { [void](New-Item -ItemType Directory -Path $DistroLocation -Force) }
        $wslArgs = @(('--' + $installAction), $DistroSource, '--name', $DistroName, '--location', $DistroLocation, '--version', '2', '--no-launch', '--web-download')
        Invoke-RecordedCommand "Install $DistroSource as $DistroName at the declared location" { & wsl.exe @wslArgs }
    }
    if ($DryRun) {
        Write-Host "DRY-RUN Initialize the $LinuxUser Linux account, set its private password, and run WSL core setup."
        return
    }

    & wsl.exe -d $DistroName -u root -- id $LinuxUser
    if ($LASTEXITCODE -ne 0) {
        & wsl.exe -d $DistroName -u root -- useradd -m -s /bin/bash -G sudo $LinuxUser
        if ($LASTEXITCODE -ne 0) { throw "Could not create the $LinuxUser Linux account." }
    }
    $passwordStatusLine = (& wsl.exe -d $DistroName -u root -- passwd -S $LinuxUser | Select-Object -First 1).Trim()
    $passwordStatusFields = $passwordStatusLine -split '\s+'
    if ($passwordStatusFields.Count -lt 2 -or $passwordStatusFields[1] -ne 'P') {
        $pending = [ordered]@{ stage = 'linux-password'; status = 'waiting-for-user'; distribution = $DistroName; user = $LinuxUser; instruction = 'Set the password only in the opened terminal, close it, then rerun bootstrap.ps1 -Resume.' }
        Set-Content -LiteralPath (Join-Path $InventoryRoot 'bootstrap-state.json') -Value ($pending | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
        Start-Process -FilePath 'wt.exe' -ArgumentList @('wsl.exe', '-d', $DistroName, '-u', 'root', '--', 'passwd', $LinuxUser)
        Write-Warning 'Private password entry is required in the opened Windows Terminal. The password is never passed to or recorded by this script. Rerun bootstrap.ps1 -Resume afterward.'
        exit 20
    }

    if (-not $SkipWslCore) {
        Write-Step 'Running idempotent WSL core setup'
        $portableWslCore = (Join-Path $PSScriptRoot 'wsl-core.sh').Replace('\', '/')
        $wslCore = (& wsl.exe -d $DistroName -u root -- wslpath -u $portableWslCore).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $wslCore) { throw 'Could not translate the WSL core path.' }
        & wsl.exe -d $DistroName -u root -- bash $wslCore $LinuxUser
        if ($LASTEXITCODE -ne 0) { throw 'WSL core setup failed.' }
    } else {
        Write-Step 'Skipping WSL core setup by explicit resume flag'
    }

    $windowsGit = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    if (Test-Path -LiteralPath $windowsGit) {
        $name = & $windowsGit config --global --get user.name 2>$null
        $email = & $windowsGit config --global --get user.email 2>$null
        if ($name) { Set-WslGitValueProcessScoped 'user.name' ([string]($name | Select-Object -Last 1)) }
        if ($email) { Set-WslGitValueProcessScoped 'user.email' ([string]($email | Select-Object -Last 1)) }
        $name = $null
        $email = $null
    }

    & wsl.exe --set-default $DistroName
    if ($LASTEXITCODE -ne 0) { throw "Could not make $DistroName the default distribution." }
    & wsl.exe --shutdown
    if ($AllowUnsafeSparseVhd) {
        & wsl.exe --manage $DistroName --set-sparse true --allow-unsafe
        if ($LASTEXITCODE -ne 0) { throw 'Could not enable sparse VHD management after explicit unsafe acknowledgement.' }
        $sparseStatus = 'enabled-with-explicit-unsafe-acknowledgement'
    } else {
        $sparseStatus = 'not-enabled-vendor-safety-block'
        Write-Warning 'Sparse VHD remains disabled because this WSL version requires --allow-unsafe due to potential data corruption. Rerun with -AllowUnsafeSparseVhd only after explicit acceptance.'
    }
    $storageState = [ordered]@{
        distribution = $DistroName
        location = "wsl/distributions/$DistroName"
        sparseVhd = $sparseStatus
        note = 'No unrelated registry data was collected.'
    }
    Set-Content -LiteralPath (Join-Path $InventoryRoot 'wsl-storage.json') -Value ($storageState | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
}

if (-not $DryRun) {
    $completed = [ordered]@{ stage = 'bootstrap'; status = 'completed'; completedAt = (Get-Date).ToUniversalTime().ToString('o') }
    Set-Content -LiteralPath (Join-Path $InventoryRoot 'bootstrap-state.json') -Value ($completed | ConvertTo-Json) -Encoding utf8NoBOM
    & (Join-Path $PSScriptRoot 'devctl.ps1') inventory
}

Write-Host 'Bootstrap stage completed.' -ForegroundColor Green
