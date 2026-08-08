# Personal Dev Env

A reusable Windows 11 and WSL2 development environment bootstrap. It creates a structured development root, installs a deliberately scoped core toolchain, and exposes optional profiles through `devctl` without mixing project dependencies into the global environment.

This repository contains templates and locked manifests only. It intentionally excludes credentials, Git identity values, user-specific paths, WSL disks, inventories, caches, datasets, model weights, and generated evidence.

## What it installs

The core environment uses Windows Terminal, PowerShell 7, VS Code, Git for Windows, Git LFS, GitHub CLI, WSL2, Ubuntu 26.04 LTS, Docker Engine, mise, Python 3.14, Node 24 LTS, pnpm, Dev Container tooling, shell/search utilities, and defensive delivery tools. Exact Windows package IDs and WSL tool selections live under `template/bootstrap/manifests`.

The profile catalogue covers Python, TypeScript, browser automation, Rust, Go, C/C++, JVM, .NET, Ruby, PHP, Lua, databases, data science, local AI, MCP/agents, security, platform/IaC, Kubernetes, observability, documentation, media, embedded, mobile, CAD, and game development. Profiles are planned and installed only when needed.

## Prerequisites

- Windows 11 Pro with virtualization enabled.
- PowerShell 7 and WinGet.
- Enough free space for WSL, Docker images, and the selected profiles.
- An NTFS or ReFS destination that is not a drive root or user home directory.

Run PowerShell with the privileges required by WSL and package installers. The bootstrap may open Windows Terminal exactly once so you can set the Linux password privately. The password is never placed in arguments, files, inventories, logs, or shell history.

## Install

Review the plan first:

```powershell
pwsh -NoProfile -File .\scripts\install.ps1 `
  -DestinationRoot 'D:\dev' `
  -LinuxUser 'developer' `
  -DryRun
```

Deploy and bootstrap:

```powershell
pwsh -NoProfile -File .\scripts\install.ps1 `
  -DestinationRoot 'D:\dev' `
  -LinuxUser 'developer'
```

If password setup pauses the bootstrap, close the password terminal when finished and resume with:

```powershell
pwsh -NoProfile -File 'D:\dev\bootstrap\configuration\bootstrap.ps1' -Resume
```

The defaults are `Ubuntu-Dev`, `Ubuntu-26.04`, and Linux user `developer`. Override them with `-DistributionName`, `-DistributionSource`, and `-LinuxUser`. The installer rejects unsafe names and refuses to merge into a non-empty, unmanaged destination unless `-Force` is explicit. `-SkipBootstrap` deploys the files and structure without installing packages.

## Daily use

From the installed development root:

```text
devctl doctor
devctl profile resolve .
devctl profile plan <profile>
devctl profile install <profile>
devctl project bootstrap .
devctl core verify
devctl guidance verify
```

Linux-built repositories belong under `~/projects` in the WSL ext4 filesystem. Windows-native repositories belong under the installed root's `src` classifications. Use `exchange` for deliberate Windows/WSL handoffs rather than building continuously over `/mnt/d`.

## Safety model

- Only manifest-scoped Windows packages are installed or updated.
- Existing Windows runtimes, applications, Git configuration, and credentials are preserved.
- Only Windows Git `user.name` and `user.email` values are copied into Linux Git, through a process-scoped channel; their values are never inventoried.
- Docker Engine stays inside WSL and is not exposed on a public TCP socket. Docker-group membership is root-equivalent and should be treated accordingly.
- Profile uninstall removes only controller-owned, unreferenced components. It preserves models, datasets, database volumes, browser caches, project outputs, WSL distributions, exports, archives, core tools, and shared active tools.
- Sparse VHD management is off by default when WSL requires the vendor's unsafe acknowledgement.
- `devctl project bootstrap` honors committed lockfiles and never creates or refreshes one.

## Validate and customize

Run the repository validation before using or publishing a modified template:

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
```

Change generic host defaults in `template/bootstrap/manifests/environment.json`. Change core packages or tool versions only as a deliberate manifest update, then regenerate and verify the relevant lock data. The full installed routing is documented in `template/bootstrap/configuration/structure.md`; operational rules are in `template/AGENTS.md`.

No license is granted by this private repository unless one is added explicitly.
