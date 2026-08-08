# Personal development environment

This directory is the operational control plane for the development drive. The scripts are intentionally re-runnable: they discover current state, install only declared components, and write secret-scrubbed inventories.

## Boundary

Windows owns Windows Terminal, PowerShell, VS Code, WinGet packages, the `devctl` entrypoint, WSL registration, and shared data on the development drive. The configured WSL distribution owns Linux source, builds, language runtimes, Git operations, Docker Engine, containers, services, and Linux caches. Active Linux repositories belong in `~/projects`, not under `/mnt/d`. Use `exchange` for explicit handoffs.

The system never maintains simultaneous active Windows and WSL copies of one repository. `src` is for Windows-native work only. The matching Linux classifications are `~/projects/{work,personal,forks,upstream,experiments,templates}`.

## Entry points

- `bootstrap.ps1`: idempotent Windows package, WSL distribution, and WSL core setup.
- `devctl.ps1`: canonical controller used from PowerShell and by the wrappers.
- `devctl.cmd`: Windows `cmd.exe` wrapper.
- `devctl`: WSL Bash wrapper.
- `wsl-core.sh`: Ubuntu core configuration run by `bootstrap.ps1` after the private user is initialized.

Run `devctl doctor` before work. Use `devctl profile resolve .` to detect likely context, inspect `devctl profile plan <profile>`, then install deliberately. Use `devctl project bootstrap .` only after inspecting the repository; it accepts existing lockfiles and will not generate or refresh them.

## Installation channels

- Windows packages: exact WinGet IDs in `../manifests/windows-core.json`.
- Ubuntu foundations and Docker repository packages: `../manifests/ubuntu-core.json`.
- Portable WSL core CLIs and runtimes: `../manifests/mise.toml` plus generated `mise.lock`.
- Python universal tools: isolated uv tool environments.
- Node universal tools: Corepack and versioned pnpm global packages.
- Context tools: the versioned catalogue in `../manifests/profiles.json`, exact per-profile state files under `../manifests/profiles`, and controller-owned active state in `../inventories/profile-state.json`.
- Large or dependency-heavy profiles: Dev Containers or Compose services rather than permanent Ubuntu mutation.

Only packages in these manifests are upgraded. Existing Windows Node, Python, Git identity, and unrelated applications are preserved. chezmoi is installed but not initialized until a dotfiles repository is explicitly selected.

## Profile lifecycle

`PROFILE` entries may be installed for a detected repository. `ON-DEMAND` entries require an explicit profile name. `XL` entries require `--acknowledge-size`. `ALTERNATIVE` entries are mutually exclusive with their declared alternatives. `EXPERIMENTAL` entries require `--acknowledge-experimental`. Dual-use security profiles require `--acknowledge-authorized-scope`.

The controller records profile-owned components and active references. Uninstall removes only controller-owned components that are no longer referenced; core and shared active components remain. Data, model weights, volumes, caches, project outputs, WSL distributions, exports, and archives are outside ordinary uninstall scope.

`devctl service down <profile>` stops only the named Compose project and preserves volumes. No service binds publicly in the provided Compose definitions.

## Recovery and updates

1. Run `devctl inventory` and preserve `../inventories`, `../checksums`, `../manifests`, and this directory.
2. Export WSL explicitly to `wsl/exports` before risky distro changes.
3. Never copy or edit the live VHD. Use `wsl --export`, `wsl --import`, and documented recovery operations.
4. Re-run `bootstrap.ps1`; it skips satisfied components and resumes missing work.
5. Update only manifest-scoped packages. Regenerate locks and checksums as a reviewed dependency change, then verify locked reinstall.

Removing a profile is reversible by reinstalling its manifest. Purging data, unregistering WSL, deleting a VHD/export/archive, or broad cache cleanup is intentionally not implemented by ordinary commands and requires a separate explicit, confirmed operation.

Sparse VHD management is not enabled by default on WSL releases that require `--allow-unsafe` and warn about potential data corruption. `bootstrap.ps1 -AllowUnsafeSparseVhd` exists only for a separately accepted exception; ordinary setup does not silently override that vendor safety boundary.

## Validation and evidence

Use `devctl core verify`, `devctl guidance verify`, and `devctl inventory`. Generated JSON inventories contain machine-readable detail without Git identity, credentials, registry dumps, tokens, or private URLs.
