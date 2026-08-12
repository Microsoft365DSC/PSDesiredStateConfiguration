# M365DSC.PSDesiredStateConfiguration

This is the [Microsoft365DSC](https://github.com/microsoft/Microsoft365DSC) fork of the
[PowerShell/PSDesiredStateConfiguration](https://github.com/PowerShell/PSDesiredStateConfiguration) module:
a DSC configuration compiler tuned for very large class-based resource modules such as Microsoft365DSC
(>530 class-based resources). It compiles DSC `Configuration` scripts into MOF documents.

Current version: **3.1.0**, dual-edition - the same module runs on **Windows PowerShell 5.1** (Desktop)
and **PowerShell 7** (Core).

The fork is rebased onto the upstream v2.0.7 pure-script lineage, with a couple of patches from the v3.0-beta commits.

## What this fork adds

- Dual-edition support (Windows PowerShell 5.1 and PowerShell 7) from a single module.
- Deterministic MOF output: no `Author`/`GenerationDate`/`GenerationHost` stamps, LF line endings,
  UTF-8 without BOM on both editions.
- A fast compilation host (`Invoke-DscFastCompile`) backed by a persistent JSON schema cache:
  fresh-process compiles between 5x and 10x faster than a default run.
- Upstream MOF emission fixes [#127](https://github.com/PowerShell/PSDesiredStateConfiguration/pull/127)
  and [#128](https://github.com/PowerShell/PSDesiredStateConfiguration/issues/128) retained.

## Support matrix

| Resource type | Standard path, Windows PowerShell 5.1 | Standard path, PowerShell 7 | Fast host |
| --- | --- | --- | --- |
| Class-based | Supported | Supported | Supported |
| Script-based (`*.schema.mof`) | Supported | Supported | Automatic fallback to the standard path |
| Composite (`*.schema.psm1`) | Supported | Supported | Automatic fallback to the standard path |

## Quick start

Import the module engine:

```powershell
$repo = 'C:\path\to\PSDesiredStateConfiguration'
Import-Module (Join-Path $repo 'M365DSC.PSDesiredStateConfiguration\M365DSC.PSDesiredStateConfiguration.psd1') -Force
```

It uses some unique optimization aspects like the following:

> **How the name is claimed:** compiled configuration bodies call
> `PSDesiredStateConfiguration\Configuration`, and the prologue the engine bakes into every configuration
> function runs `Import-Module PSDesiredStateConfiguration` first. The package therefore ships a small
> compatibility module named `PSDesiredStateConfiguration` (same version) under the engine's `Compat`
> folder, which forwards to the engine. Importing the engine loads that module and puts its parent folder
> first on the process `PSModulePath`, so the prologue resolves to it instead of loading the inbox 1.1
> module (Windows PowerShell 5.1) or the gallery 2.x module (PowerShell 7). Both are undone by
> `Remove-Module M365DSC.PSDesiredStateConfiguration`.
>
> Without the claim, that prologue import wins the session: the foreign module's exports take over
> `Configuration`, `Get-DscResource` and `New-DscChecksum` from the first compile onwards.

Then compile a configuration as usual:

```powershell
Configuration MyConfig {
    Import-DscResource -ModuleName Microsoft365DSC
    Node localhost {
        # ...
    }
}
MyConfig -OutputPath .\Output
```

## Fast host

The fast host compiles a configuration script without triggering the engine's parse-time resource import.
`Import-DscResource` statements are satisfied from a persistent schema cache instead.

```powershell
# Compile an export, e.g. from Microsoft365DSC (defines and invokes its own configuration)
Invoke-DscFastCompile -Path .\M365TenantConfig.ps1

# Pre-generate the schema cache for a module (one-time effort during build)
Export-DscSchemaCache -ModuleName Microsoft365DSC

# Validate a cache against a module (CI drift gate with -Detailed)
Test-DscSchemaCache -ModulePath $moduleBase -CachePath $cacheJson -Detailed
```

Full command reference, cache format, and the
consumer contract are in [docs/FastHostContract.md](docs/FastHostContract.md); how the compiler and the
fast host work, with diagrams, is in [docs/Architecture.md](docs/Architecture.md).

### Schema cache resolution order

1. `<ModuleBase>\DscSchemaCache.json` - shipped inside the resource module package.
2. `%LOCALAPPDATA%\M365DSC.PSDesiredStateConfiguration\SchemaCache\<Name>_<Version>_<fingerprint>.json` - written after a live generation.
3. Live generation (then persisted to 2).

A cache is used only when its module name, version, and fingerprint match the resolved module.

## Coexistence with other PSDesiredStateConfiguration versions

- Windows PowerShell 5.1 ships an inbox PSDesiredStateConfiguration 1.1 in `C:\Windows\System32`, and PowerShell 7
  users typically install gallery 2.0.7. The engine module has its own name and never collides with them.
- The bundled compatibility module does use the name `PSDesiredStateConfiguration`, but only for the
  process that imported the engine. The `PSModulePath` entry is added to the process environment and
  removed again on `Remove-Module` (or session closure). Other sessions and other users are unaffected.
- While the engine is loaded, `Import-Module PSDesiredStateConfiguration` and every unqualified
  `Configuration`, `Get-DscResource` etc. call resolve to the
  engine. Reach the installed module explicitly by path if a session needs both.
- Do not copy the compatibility module into a machine-wide module folder with a version lower than an
  installed gallery module - name resolution takes the first `PSModulePath` folder that has the module
  and then its highest version, so a lower version in the same folder loses.

## Build

The module is pure script and is published straight from the `M365DSC.PSDesiredStateConfiguration`
folder, so there is nothing to compile. One script validates it:

```powershell
.\Utilities\Build.ps1          # sync the compatibility module version, validate manifests and exports
.\Utilities\Build.ps1 -Test    # the same, then run every Pester suite on both editions
```

## Tests

Tests use **Pester 6**. The suites in `test\` are:

- `M365DSC.PSDesiredStateConfiguration.Tests.ps1` - core module tests
- `FastHost.Tests.ps1` - `Invoke-DscFastCompile` behavior
- `SchemaCache.Tests.ps1` - schema cache export/validation
- `ModuleNameClaim.Tests.ps1` - out-of-process check that an engine imported by path alone still owns
  the `PSDesiredStateConfiguration` name across repeated compiles

Run them through the build script, or directly:

```powershell
$repo = 'C:\path\to\PSDesiredStateConfiguration'
$env:PSModulePath = (Join-Path $repo 'test\TestModules') + [System.IO.Path]::PathSeparator + $env:PSModulePath
Invoke-Pester -Path (Join-Path $repo 'test')
```

`.github\workflows\Build and Test.yml` runs the build script, the suites and a PSScriptAnalyzer
error-level pass on every pull request; `PublishToGallery.yml` publishes on push to master. Benchmark
tooling lives in `tools\benchmarks` (`Compare-DscMofOutput.ps1`, `New-DscBenchmarkConfig.ps1`,
`Invoke-DscCompileBenchmark.ps1`).

## Changelog

See [CHANGELOG/v3.md](CHANGELOG/v3.md) for fork releases and [CHANGELOG/v2.md](CHANGELOG/v2.md) for the
upstream lineage this fork is based on.

## Upstream and license

This fork is based on [PowerShell/PSDesiredStateConfiguration](https://github.com/PowerShell/PSDesiredStateConfiguration)
by Microsoft Corporation. Upstream development has moved to [DSC v3](https://github.com/powershell/dsc).
Licensed under the [MIT License](LICENSE).

## Code of Conduct

Please see our [Code of Conduct](.github/CODE_OF_CONDUCT.md) before participating in this project.

## Security Policy

For any security issues, please see our [Security Policy](.github/SECURITY.md).
