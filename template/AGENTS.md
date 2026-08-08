# Development Drive Guidance

## Scope

- This file governs the configured development root and every directory below it.
- Use this root for reproducible development, build handoffs, generated evidence, and recoverable environment state.
- Keep one authoritative working copy of each repository.

## Windows and WSL boundary

- Windows owns the editor, terminal, Windows-native tools, package discovery, WSL lifecycle, and this drive's shared storage.
- The configured WSL distribution owns Linux repositories, Git work, runtimes, builds, containers, services, and automation.
- Linux-built repositories live under `~/projects` on WSL ext4; do not run active build loops from `/mnt/d`.
- `src` is only for genuinely Windows-native repositories and tooling.
- Transfer cross-boundary files through `exchange`; do not keep active duplicate checkouts.

## Source routing

- `~/projects/work`: organization-owned repositories and client work.
- `~/projects/personal`: repositories owned by the user.
- `~/projects/forks`: writable forks of third-party projects.
- `~/projects/upstream`: read-only reference clones; move intended changes to a fork or owned branch first.
- `~/projects/experiments`: disposable spikes and prototypes.
- `~/projects/templates`: reusable starters without generated outputs.
- Mirror these classifications under `src` only for Windows-native work.

## Storage routing

- `cache/windows`: Windows-native caches only; keep WSL caches inside WSL.
- `build`: disposable Windows-native build trees, grouped by build system.
- `artifacts/releases` and `packages`: release outputs and distributable packages.
- `artifacts/containers`: container exports; `sbom` and `provenance`: delivery evidence.
- `artifacts/test-results`, `coverage`, `benchmarks`, and `reports`: generated verification evidence.
- `data/external`: immutable third-party data; `reference`: curated reference data; `shared`: reusable owned data.
- `data/samples`: small safe fixtures; `archives`: retained data snapshots.
- `exchange/incoming`: untrusted handoffs; `outgoing`: staged exports; `from-windows` and `from-wsl`: boundary handoffs.
- `scratch/current`: short-lived work; `quarantine`: isolated untrusted files and repositories.
- `wsl`: distribution VHDs, exports, and recovery material. Never edit a VHD manually.
- `archive`: completed projects, retired builds, and migration staging; archive deletion is always explicit.

## Standard routine

From PowerShell or WSL, run:

1. `devctl doctor`
2. `devctl profile resolve .`
3. `devctl profile install <profile>`
4. `devctl project bootstrap .`
5. Run the repository's own documented validation tasks.
6. `devctl profile uninstall <profile>` when the context is finished and no active work references it.

Inspect changes before mutation with `devctl profile plan <profile>` and `devctl project clean . --plan`.

## Managed core

- Windows: WSL, Windows Terminal, PowerShell, VS Code, system Git and Git LFS, GitHub CLI, zoxide, Starship, and chezmoi.
- WSL: Git, Docker Engine with Compose and Buildx, mise, uv/Python, Node/Corepack/pnpm, Dev Container CLI, shell/search/inspection tools, and defensive delivery tools.
- Context-dependent language, service, security, platform, data, media, hardware, mobile, CAD, game, and local-AI tools are managed as profiles.
- See `bootstrap/inventories/versions.json` for exact versions and `bootstrap/manifests/profiles.json` for the profile catalogue.

## Dependencies and generated files

- Keep application libraries, frameworks, test runners, and project formatters in repository manifests and committed lockfiles.
- Do not globally install project dependencies or create a second formatter/runtime without an explicit migration request.
- `devctl project bootstrap` may perform only lockfile-faithful installs; it must not create, update, or repair a lockfile.
- Treat generated build output, caches, coverage, SBOMs, provenance, and reports as disposable or reproducible unless repository guidance says otherwise.
- Do not edit generated files unless regeneration is unavailable and the exception is documented.

## Trust and execution

- Put untrusted downloads and repositories in quarantine first.
- Inspect manifests before running package scripts, mise tasks, Dev Containers, Compose files, Git hooks, notebooks, or MCP servers.
- Use `MISE_SAFE=1` while inspecting untrusted repositories.
- Docker-group and Docker-socket access are root-equivalent. Never expose the daemon on a public TCP interface.
- Bind development services to loopback or private container networks unless the user explicitly approves wider access.

## Guardrails

- Never store credentials, tokens, private keys, secrets, or private service URLs in this drive's guidance, manifests, logs, inventories, or shell history.
- Do not copy credential helpers, private keys, or Git `safe.directory` entries across the Windows/WSL boundary.
- Ask before changing dependencies or lockfiles, authentication or billing settings, deploying, publishing, or sending external messages.
- Ask before destructive Git operations, history rewrites, force pushes, broad deletion, data purges, WSL unregister, VHD deletion, or archive deletion.
- Ordinary profile uninstall preserves models, datasets, database volumes, WSL distributions, exports, browser caches, project outputs, and shared/core tools.
- Service teardown preserves volumes by default. Stop all profile services when the task no longer needs them.
- Preserve user configuration; make bootstrap and controller changes idempotent and secret-scrubbed.

## Validation

- Run `devctl core verify` to check the installed Windows and WSL core.
- Run `devctl guidance verify` to validate required commands, instruction budgets, and machine-specific or secret-like content.
- Run `devctl inventory` after material environment changes.
- Do not claim setup success from intended state; use the inventories and command results.

## Deeper context

- Environment defaults: `bootstrap/manifests/environment.json`
- Directory specification: `bootstrap/configuration/structure.md`
- Installation, recovery, and profile lifecycle: `bootstrap/configuration/README.md`
- Profile catalogue and classifications: `bootstrap/manifests/profiles.json`
- Current installed state: `bootstrap/inventories/installed-core.json`
