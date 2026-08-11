# PSDesiredStateConfiguration (Microsoft365DSC fork)

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

Import the module by path and put its parent directory on `PSModulePath`:

```powershell
$repo = 'C:\path\to\PSDesiredStateConfiguration'
$env:PSModulePath = (Join-Path $repo 'src') + [System.IO.Path]::PathSeparator + $env:PSModulePath
Import-Module (Join-Path $repo 'src\PSDesiredStateConfiguration\PSDesiredStateConfiguration.psd1') -Force
```

> **Important:** the engine-compiled configuration body resolves `PSDesiredStateConfiguration\Configuration`
> **by name through `PSModulePath` at invocation time**, even when the module is already imported.
> The fork must therefore be discoverable via `PSModulePath` and be the highest version visible there.
> If you only `Import-Module` by path without adjusting `PSModulePath`, plain configuration invocations
> silently run through the inbox 1.1 module (Windows PowerShell 5.1) or the gallery 2.x module (PowerShell 7).
> `Invoke-DscFastCompile` performs this correction automatically. Plain usage must do both steps above.

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
consumer contract are in [docs/FastHostContract.md](docs/FastHostContract.md).

### Schema cache resolution order

1. `<ModuleBase>\DscSchemaCache.json` - shipped inside the resource module package.
2. `%LOCALAPPDATA%\PSDesiredStateConfiguration\SchemaCache\<Name>_<Version>_<fingerprint>.json` - written after a live generation.
3. Live generation (then persisted to 2).

A cache is used only when its module name, version, and fingerprint match the resolved module.

## Performance

Measured compiling Microsoft365DSC configurations on a developer laptop; your numbers will vary.

| Scenario | Windows PowerShell 5.1 | PowerShell 7 |
| --- | --- | --- |
| Baseline: inbox 1.1 (5.1) / gallery 2.0.7 (PS 7), parse + compile | 28 s + 38 s | 41 s + 55 s |
| Fork, standard path, repeat compile in the same session | 2-4.5 s | 2-4.5 s |
| Fork, fast host, fresh process | 6.6 s | 5.9 s |
| Fork, fast host, repeat in the same session | 2.3 s | 2.1 s |

One-time schema cache generation: ~17 s. The first standard-path compile in a fresh session still pays
the full parse and import cost; the fast host avoids it.

## Coexistence with other PSDesiredStateConfiguration versions

- Windows PowerShell 5.1 ships an inbox PSDesiredStateConfiguration 1.1 in `System32`; PowerShell 7
  users typically install gallery 2.0.7. The fork (3.1.0) coexists with both.
- Because `Configuration` resolves by name with highest-version-wins semantics, **never install the fork
  in a `PSModulePath`-visible location with a lower version than the gallery module** - it would silently
  lose the resolution race described above.

## Build

Requires the [`PSPackageProject`](https://www.powershellgallery.com/packages/PSPackageProject) module.

```powershell
.\build.ps1 -Build -Clean
```

The module is pure script, the build is a plain copy of `src\PSDesiredStateConfiguration` to
`out\PSDesiredStateConfiguration`.

## Tests

Tests use **Pester 6**. The suites in `test\` are:

- `PSDesiredStateConfiguration.Tests.ps1` - core module tests
- `FastHost.Tests.ps1` - `Invoke-DscFastCompile` behavior
- `CacheRetention.Tests.ps1` - keyword cache retention across compiles
- `SchemaCache.Tests.ps1` - schema cache export/validation

They import the module under test by path and expect `test\TestModules` and the repo `src` directory on
`PSModulePath`:

```powershell
$repo = 'C:\path\to\PSDesiredStateConfiguration'
$env:PSModulePath = (Join-Path $repo 'src') + [System.IO.Path]::PathSeparator +
    (Join-Path $repo 'test\TestModules') + [System.IO.Path]::PathSeparator + $env:PSModulePath
Invoke-Pester -Script (Join-Path $repo 'test')
```

CI (`.github\workflows\ci.yml`) runs all suites under both editions plus a PSScriptAnalyzer error-level
lint. Benchmark tooling lives in `tools\benchmarks` (`Compare-DscMofOutput.ps1`,
`New-DscBenchmarkConfig.ps1`, `Invoke-DscCompileBenchmark.ps1`).

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
