# M365DSC.PSDesiredStateConfiguration

This is the [Microsoft365DSC](https://github.com/microsoft/Microsoft365DSC) fork of the
[PowerShell/PSDesiredStateConfiguration](https://github.com/PowerShell/PSDesiredStateConfiguration) module:
a DSC configuration compiler tuned for very large class-based resource modules such as Microsoft365DSC
(>530 class-based resources). It compiles DSC `Configuration` scripts into MOF documents.

Current version: **3.1.0**, dual-edition - the same module runs on **Windows PowerShell 5.1** (Desktop)
and **PowerShell 7** (Core) and produces byte-identical MOF output on both.

The fork is rebased onto the upstream v2.0.7 pure-script lineage: it is plain PowerShell script with no
binary DSC subsystem, and the build is a simple copy of the source tree.

## What this fork adds

- Dual-edition support (Windows PowerShell 5.1 and PowerShell 7) from a single module.
- Deterministic MOF output: no `Author`/`GenerationDate`/`GenerationHost` stamps, LF line endings,
  UTF-8 without BOM on both editions.
- Keyword cache retention across compiles: repeat compiles for class-based resources in the same session drop from 38-41s to 2-4.5s.
- A fast compilation host (`Invoke-DscFastCompile`) backed by a persistent JSON schema cache:
  fresh-process compiles in about 6 s instead of 67-96s.
- Upstream MOF emission fixes [#127](https://github.com/PowerShell/PSDesiredStateConfiguration/pull/127)
  and [#128](https://github.com/PowerShell/PSDesiredStateConfiguration/issues/128) retained.

## Support matrix

| Resource type | Standard path, Windows PowerShell 5.1 | Standard path, PowerShell 7 | Fast host |
| --- | --- | --- | --- |
| Class-based | Supported | Supported | Supported |
| Script-based (`*.schema.mof`) | Supported | Supported | Automatic fallback to the standard path |
| Composite (`*.schema.psm1`) | Supported | Supported | Automatic fallback to the standard path |

## Quick start

Put the engine's `Compat` folder on `PSModulePath`, then import the engine by path:

```powershell
$repo = 'C:\path\to\PSDesiredStateConfiguration'
$env:PSModulePath = (Join-Path $repo 'M365DSC.PSDesiredStateConfiguration\Compat') + [System.IO.Path]::PathSeparator + $env:PSModulePath
Import-Module (Join-Path $repo 'M365DSC.PSDesiredStateConfiguration\M365DSC.PSDesiredStateConfiguration.psd1') -Force
```

> **Important:** both steps are required. Compiled configuration bodies call
> `PSDesiredStateConfiguration\Configuration`, and the engine resolves that name through `PSModulePath`
> while the configuration statement executes. The package therefore ships a small compatibility module
> named `PSDesiredStateConfiguration` (same version) under the engine's `Compat` folder, which forwards
> to it. Import the engine without that folder on `PSModulePath` and compilation silently falls through
> to the inbox 1.1 module (Windows PowerShell 5.1) or the gallery 2.x module (PowerShell 7).

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
`Import-DscResource` statements are satisfied from a persistent schema cache instead:

```powershell
# Compile a Microsoft365DSC export (defines and invokes its own configuration)
Invoke-DscFastCompile -Path .\M365TenantConfig.ps1

# Pre-generate the schema cache for a module (one-time, ~17 s for Microsoft365DSC)
Export-DscSchemaCache -ModuleName Microsoft365DSC

# Validate a cache against a module (CI drift gate with -Detailed)
Test-DscSchemaCache -ModulePath $moduleBase -CachePath $cacheJson -Detailed

# Reset all keyword/schema caching state (module-development escape hatch)
Clear-DscKeywordCache
```

Scripts that use script-based or composite resources automatically fall back to the standard
compilation path (use `-NoFallback` to fail instead). Full command reference, cache format, and the
consumer contract are in [docs/FastHostContract.md](docs/FastHostContract.md); how the compiler and the
fast host work, with diagrams, is in [docs/Architecture.md](docs/Architecture.md).

### Schema cache resolution order

1. `<ModuleBase>\DscSchemaCache.json` - shipped inside the resource module package.
2. `%LOCALAPPDATA%\M365DSC.PSDesiredStateConfiguration\SchemaCache\<Name>_<Version>_<fingerprint>.json` - written after a live generation.
3. Live generation (then persisted to 2).

A cache is used only when its module name, version, and fingerprint match the resolved module.

## Performance

Measured compiling Microsoft365DSC configurations on a developer laptop; your numbers will vary.

| Scenario | Windows PowerShell 5.1 | PowerShell 7 |
| --- | --- | --- |
| Baseline: inbox 1.1 (5.1) / gallery 2.0.7 (PS 7), parse + compile | 28 s + 38 s | 41 s + 55 s |
| Fork, standard path, repeat compile in the same session | 2-4.5 s | 2-4.5 s |
| Fork, fast host, fresh process, warm cache | 7-20 s | 6-19 s |
| Fork, fast host, repeat in the same session | 2-7 s | 2-5 s |

Fresh-process fast host figures vary with operating system file cache warmth: the run loads the
multi-megabyte schema cache and registers about a thousand keywords. One-time schema cache generation
costs 20-110 s depending on the same factor. The first standard-path compile in a fresh session still
pays the full parse and import cost; the fast host avoids it.

## Coexistence with other PSDesiredStateConfiguration versions

- Windows PowerShell 5.1 ships an inbox PSDesiredStateConfiguration 1.1 in `System32`; PowerShell 7
  users typically install gallery 2.0.7. The engine module has its own name and never collides with them.
- The bundled compatibility module does use the name `PSDesiredStateConfiguration`. Resolution is
  highest-version-wins, so **never place it in a `PSModulePath`-visible location with a lower version
  than an installed gallery module** - compilation would silently run through that module instead.
- Put the compatibility module on `PSModulePath` only for sessions that compile configurations, rather
  than installing it machine-wide, if you also use the gallery module for other work.

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
- `CacheRetention.Tests.ps1` - keyword cache retention across compiles
- `SchemaCache.Tests.ps1` - schema cache export/validation

Run them through the build script, or directly:

```powershell
$repo = 'C:\path\to\PSDesiredStateConfiguration'
$env:PSModulePath = (Join-Path $repo 'M365DSC.PSDesiredStateConfiguration\Compat') + [System.IO.Path]::PathSeparator +
    (Join-Path $repo 'test\TestModules') + [System.IO.Path]::PathSeparator + $env:PSModulePath
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
