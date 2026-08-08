# Development root structure

The installer creates this hierarchy under the configured development root. The root name and drive are deliberately not fixed by the template.

```text
<development-root>/
├─ src/
│  ├─ work/
│  ├─ personal/
│  ├─ forks/
│  ├─ upstream/
│  ├─ experiments/
│  └─ templates/
├─ cache/windows/
│  ├─ nuget/
│  ├─ npm/
│  ├─ pnpm/
│  ├─ cargo/
│  ├─ vcpkg/
│  ├─ conan/
│  ├─ maven/
│  ├─ gradle/
│  ├─ pip/
│  ├─ uv/
│  ├─ go/
│  └─ browser-binaries/
├─ build/
│  ├─ cmake/
│  ├─ msbuild/
│  ├─ dotnet/
│  ├─ java/
│  ├─ rust/
│  └─ temporary/
├─ artifacts/
│  ├─ releases/
│  ├─ packages/
│  ├─ containers/
│  ├─ sbom/
│  ├─ provenance/
│  ├─ test-results/
│  ├─ coverage/
│  ├─ benchmarks/
│  └─ reports/
├─ data/
│  ├─ external/
│  ├─ reference/
│  ├─ shared/
│  ├─ samples/
│  └─ archives/
├─ exchange/
│  ├─ from-windows/
│  ├─ from-wsl/
│  ├─ incoming/
│  └─ outgoing/
├─ wsl/
│  ├─ distributions/
│  ├─ exports/
│  └─ recovery/
├─ bootstrap/
│  ├─ manifests/
│  ├─ configuration/
│  ├─ checksums/
│  └─ inventories/
├─ scratch/
│  ├─ current/
│  └─ quarantine/
└─ archive/
   ├─ completed-projects/
   ├─ retired-builds/
   └─ migration-staging/
```

Linux-built repositories use the matching classifications under `~/projects` in the WSL ext4 filesystem. The Windows `src` tree is reserved for Windows-native work.

The template also adds `bootstrap/configuration/compose` for managed service definitions and `bootstrap/manifests/profiles` for exact profile state records. Generated files appear only under `bootstrap/checksums` and `bootstrap/inventories` after deployment.
