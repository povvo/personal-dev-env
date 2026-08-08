# Personal Dev Env Repository Guidance

## Scope

- This repository is a reusable, private-by-default installer for a Windows 11 and WSL2 development environment.
- Repository guidance applies to contributor work here. `template/AGENTS.md` is copied to an installed development root and governs that root.
- Preserve a clean separation between repository files and generated machine state.

## Layout

- `scripts/install.ps1` deploys the template and optionally runs the environment bootstrap.
- `scripts/validate.ps1` checks syntax, manifests, privacy hygiene, profile state, Compose definitions, and shell scripts.
- `template/` contains only files that may be copied to a development root.
- `template/bootstrap/manifests/environment.json` holds configurable, non-secret defaults.
- `template/bootstrap/inventories` and `template/bootstrap/checksums` are generated after deployment and must not be committed.

## Change rules

- Keep the installer idempotent and safe on partially completed environments.
- Never commit credentials, Git identity values, private URLs, user home paths, registry dumps, inventories, VHDs, exports, datasets, caches, or model weights.
- Do not hard-code a Windows profile name, drive owner, Linux account, distribution location, or repository owner.
- Preserve the private Linux password boundary: it is entered only in the dedicated terminal and never passed through a command, file, log, or history.
- Use exact WinGet IDs and pinned tool selectors. Treat dependency-pin or core-package changes as reviewed dependency changes.
- Do not broaden deletion, WSL unregister, VHD handling, data purge, service binding, publication, or deployment behavior without explicit approval.
- Keep services loopback-only or on private container networks; never expose the Docker daemon on public TCP.
- Keep profile uninstall ownership-aware and preserve user data and shared/core components.
- Do not make `project bootstrap` generate or refresh repository lockfiles.

## Validation

- Run `pwsh -NoProfile -File scripts/validate.ps1` before committing.
- Run `pwsh -NoProfile -File scripts/install.ps1 -DryRun` to review the deployment plan.
- Run `git diff --check` and inspect `git status --short` before publishing.
- If the `agents-md` skill is available, validate both the repository root and `template/`, then run its hygiene scan across the repository.
- A validation warning caused only by an unavailable optional local tool must be reported; validation failures must be fixed.

## Documentation

- Update `README.md` when entrypoints, prerequisites, defaults, safety boundaries, or recovery behavior changes.
- Update `template/bootstrap/configuration/structure.md` when routing changes.
- Keep `template/AGENTS.md` concise, operational, and below 200 lines.
- Generated evidence belongs in the installed root, not in this repository.
