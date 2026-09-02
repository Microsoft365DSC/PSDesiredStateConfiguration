# Fast Host Contract

Interface between this module (`M365DSC.PSDesiredStateConfiguration` >= 3.1.0, PSData tag `M365DSCFastHost`) and consumers such as Microsoft365DSC tooling.

For how the compiler and fast host work internally, see [Architecture.md](Architecture.md).

## Module layout

The package contains two modules:

| Folder | Purpose |
| --- | --- |
| `M365DSC.PSDesiredStateConfiguration` | The engine: compiler, fast host, schema cache. Import this one, by path. |
| `M365DSC.PSDesiredStateConfiguration\Compat\PSDesiredStateConfiguration` | A compatibility module of the same version that re-exports the engine's commands. |

The compatibility module exists because the PowerShell engine resolves the module named `PSDesiredStateConfiguration` while it executes a `Configuration ... { }` statement, and that module then owns the qualified `PSDesiredStateConfiguration\Configuration` call every compiled configuration body makes. Without it, compilation silently falls through to the inbox 1.1 (Windows PowerShell) or gallery 2.x (PowerShell 7) module. Importing the engine loads the compatibility module and prepends its folder to the process `PSModulePath`. The compatibility module reuses an already-loaded engine instance rather than importing a second one.

## Commands

### Invoke-DscFastCompile

Compiles a configuration script without triggering the engine's parse-time resource import. `Import-DscResource` statements are stripped from the text, resource keywords are registered from a persistent schema cache, and per-resource adapter functions drive the standard MOF emission pipeline.

```powershell
Invoke-DscFastCompile
    -Path <string> | -ScriptText <string>
    [-ConfigurationName <string>]       # required only when the script defines several configurations and does not invoke one itself
    [-Parameters <hashtable>]           # splatted onto the configuration invocation
    [-ConfigurationData <hashtable|string>]
    [-OutputPath <string>]
    [-SchemaCachePath <string[]>]       # explicit cache files; otherwise resolution order below
    [-Force]                            # ignore every cache on disk, generate a fresh one and use it
    [-ValidateMof]                      # opt-in MI validation (requires live CIM classes, slower)
    [-NoFallback]                       # fail instead of degrading to the standard path
```

Returns the generated `.mof` files (`FileInfo[]`). Scripts that invoke their own configuration (the Microsoft365DSC export shape) run as-is; the self-invocation performs the compilation.

While the script executes, `$Global:PSDscFastCompileActive` is `$true`. Generated export trailers use this as a recursion guard.

Modules named by `Import-DscResource` are located by scanning `$env:PSModulePath` for `<Name>\<Name>.psd1` and `<Name>\<Version>\<Name>.psd1` and reading `ModuleVersion` from the manifest. `Get-Module -ListAvailable` runs only when a cache has to be generated.

Falls back to standard compilation (with a warning) when: an `Import-DscResource` uses non-constant arguments or `-Name` without `-ModuleName`; a module contains composite (`*.schema.psm1`) resources; or no usable schema cache can be obtained. Class-based resources and schema-based (`*.schema.mof`) resources compile on the fast path.

### Get-DscFastCompileTiming

```powershell
Get-DscFastCompileTiming
```

Returns an ordered dictionary with the milliseconds of the last `Invoke-DscFastCompile` in this session: `parse`, `resolve`, `cache`, `rewrite`, `compile` and `total`. `$null` before the first compile.

### Export-DscSchemaCache

```powershell
Export-DscSchemaCache -ModuleName <string> [-RequiredVersion <version>] [-OutputPath <string>]
Export-DscSchemaCache -Module <PSModuleInfo> [-OutputPath <string>]
```

Discovers the class-based resources of a module through the engine (one-time import, ~6 s for Microsoft365DSC), reads every `DscResources\<Name>\<Name>.schema.mof`, and writes the schema cache. Default output: `<ModuleBase>\DscSchemaCache.json`. Returns a summary (`ModuleName`, `ModuleVersion`, `ResourceCount`, `KeywordCount`, `Fingerprint`, `Path`).

### Test-DscSchemaCache

```powershell
Test-DscSchemaCache -ModulePath <string> -CachePath <string> [-Detailed]
```

Returns `$true`/`$false`. Validates format version and module version and that every recorded source file still exists; `-Detailed` re-hashes every recorded file (CI drift gate).

## Schema cache resolution order

1. Paths given through `-SchemaCachePath`.
2. `<ModuleBase>\DscSchemaCache.json` - shipped inside the resource module package.
3. `%LOCALAPPDATA%\M365DSC.PSDesiredStateConfiguration\SchemaCache\<Name>_<Version>_<fingerprint>.json` - written after a live generation.
4. Live generation (then persisted to 3).

A cache is used only when its format version is the one the reader knows, its module name and version match the resolved module, and its fingerprint matches. The fingerprint is `fileCount:totalBytes:hash` over the sorted list of relative path and size of every `*.psm1`, `*.psd1` and `*.mof` file below the module base. It carries no write times, so a copy or an installation of the same files keeps its fingerprint. When the file set below the module base grew, the fingerprint is recomputed over the files the cache recorded, so an unrelated file placed next to the module does not invalidate it.

## Cache format (formatVersion 2)

The file is UTF-8 without BOM, one JSON document per line.

Line 1, the header:

```json
{
  "formatVersion": 2,
  "generator": { "psdscVersion": "3.1.7", "psVersion": "7.6.5" },
  "module": { "name": "Microsoft365DSC", "version": "1.26.1007.1", "fingerprint": "595:10345678:bc7d0588069ae1cb" },
  "resourceCount": 531,
  "keywordCount": 998,
  "index": { "AADGroup": 2, "MSFT_AADGroupMember": 3 }
}
```

`index` maps every keyword name to its zero-based line number.

Line 2, the recorded source files:

```json
{ "Classes\\Part00.psm1": { "length": 713777, "sha256": "<sha256>" } }
```

Every further line is one keyword:

```json
{
  "keyword": "AADGroup",
  "resourceName": "AADGroup",
  "implementingModule": "Microsoft365DSC",
  "implementingModuleVersion": "1.26.1007.1",
  "nameMode": "NameRequired",
  "bodyMode": "Hashtable",
  "directCall": false,
  "metaStatement": false,
  "properties": {
    "DisplayName": {
      "name": "DisplayName", "typeConstraint": "String",
      "mandatory": true, "isKey": true,
      "attributes": [], "values": [],
      "valueMap": [ { "key": "...", "value": "..." } ]
    }
  }
}
```

Embedded complex types are ordinary `NoName` keywords. `valueMap` is an array of key/value pairs because DSC allows empty-string map keys, which JSON object properties cannot represent portably.

The fast host reads the header at registration time and deserializes a keyword line the first time a compile asks for that keyword. Consumers must reject caches whose `formatVersion` differs from the one they know and regenerate.

## Module resolution requirement

Compiled configuration bodies call `PSDesiredStateConfiguration\Configuration` and the generated configuration function runs `Import-Module PSDesiredStateConfiguration` ahead of it. Both resolve **by module name while the configuration statement executes**, so whichever module holds that name owns the compile. Consumers import `M365DSC.PSDesiredStateConfiguration` by path and nothing else. That import claims the name for the process by loading the bundled compatibility module (under `/Compat`) and prepending the engine's `Compat` folder to `$env:PSModulePath`. `Remove-Module` undoes both for cleanup. A consumer that overwrites `$env:PSModulePath` after importing the engine has to re-add that folder. Otherwise the generated import pulls in the inbox or gallery module, whose exports then own `Configuration`, `Get-DscResource` and other functions.
