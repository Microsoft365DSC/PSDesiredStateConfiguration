# Fast Host Contract

Interface between this module (`M365DSC.PSDesiredStateConfiguration` >= 3.1.0, PSData tag `M365DSCFastHost`) and consumers such as Microsoft365DSC tooling.

For how the compiler and fast host work internally, see [Architecture.md](Architecture.md).

## Module layout

The package contains two modules:

| Folder | Purpose |
|---|---|
| `M365DSC.PSDesiredStateConfiguration` | The engine: compiler, fast host, schema cache. Import this one, by path. |
| `M365DSC.PSDesiredStateConfiguration\Compat\PSDesiredStateConfiguration` | A compatibility module of the same version that re-exports the engine's commands. |

The compatibility module exists because the PowerShell engine resolves the module named `PSDesiredStateConfiguration` while it executes a `Configuration ... { }` statement, and that module then owns the qualified `PSDesiredStateConfiguration\Configuration` call every compiled configuration body makes. Without it, compilation silently falls through to the inbox 1.1 (Windows PowerShell) or gallery 2.x (PowerShell 7) module. The engine's `Compat` folder must therefore be on `PSModulePath`. The compatibility module reuses an already-loaded engine instance rather than importing a second one.

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
    [-Force]                            # regenerate a stale cache instead of treating it as missing
    [-ValidateMof]                      # opt-in MI validation (requires live CIM classes, slower)
    [-NoFallback]                       # fail instead of degrading to the standard path
```

Returns the generated `.mof` files (`FileInfo[]`). Scripts that invoke their own configuration (the Microsoft365DSC export shape) run as-is; the self-invocation performs the compilation.

While the script executes, `$Global:PSDscFastCompileActive` is `$true`. Generated export trailers use this as a recursion guard.

Falls back to standard compilation (with a warning) when: an `Import-DscResource` uses non-constant arguments or `-Name` without `-ModuleName`; a module contains script-based (`*.schema.mof`) or composite (`*.schema.psm1`) resources; or no usable schema cache can be obtained.

### Export-DscSchemaCache

```powershell
Export-DscSchemaCache -ModuleName <string> [-RequiredVersion <version>] [-OutputPath <string>]
Export-DscSchemaCache -Module <PSModuleInfo> [-OutputPath <string>]
```

Discovers all class-based resources of a module (one-time engine import, ~6 s for Microsoft365DSC) and writes the schema cache JSON. Default output: `<ModuleBase>\DscSchemaCache.json`. Returns a summary (`ModuleName`, `ModuleVersion`, `ResourceCount`, `KeywordCount`, `Fingerprint`, `Path`).

### Test-DscSchemaCache

```powershell
Test-DscSchemaCache -ModulePath <string> -CachePath <string> [-Detailed]
```

Returns `$true`/`$false`. Validates format version and module version; `-Detailed` re-hashes every file recorded in `sourceHash` (CI drift gate).

### Clear-DscKeywordCache

Resets all keyword/schema caching state (escape hatch for module-development loops).

## Schema cache resolution order

1. `<ModuleBase>\DscSchemaCache.json` — shipped inside the resource module package.
2. `%LOCALAPPDATA%\M365DSC.PSDesiredStateConfiguration\SchemaCache\<Name>_<Version>_<fingerprint>.json` — written after a live generation.
3. Live generation (then persisted to 2).

A cache is used only when its module name, version, and fingerprint (`fileCount:maxLastWriteTimeUtcTicks` over `*.psm1|*.psd1|*.mof`) match the resolved module.

## Cache format (formatVersion 1)

```json
{
  "formatVersion": 1,
  "generator": { "psdscVersion": "3.1.0", "psVersion": "7.4.0" },
  "module": {
    "name": "Microsoft365DSC",
    "version": "1.26.805.2",
    "fingerprint": "594:639219468181493516",
    "sourceHash": { "Classes\\Part00.psm1": "<sha256>", "...": "..." }
  },
  "keywords": [
    {
      "keyword": "AADGroup",
      "resourceName": "AADGroup",
      "implementingModule": "Microsoft365DSC",
      "implementingModuleVersion": "1.26.805.2",
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
  ]
}
```

Embedded complex types are ordinary `NoName` keywords in the same flat list. `valueMap` is an array of key/value pairs because DSC allows empty-string map keys, which JSON object properties cannot represent portably.

Consumers must reject caches with a `formatVersion` greater than the one they know and regenerate.

## Module resolution requirement

Compiled configuration bodies call `PSDesiredStateConfiguration\Configuration`, and the engine resolves that name **through PSModulePath while the configuration statement executes**. Consumers must therefore put the engine's `Compat` folder on `PSModulePath` (Microsoft365DSC's `Import-M365DSCDscEngine` does this), then import `M365DSC.PSDesiredStateConfiguration` by path. Importing the engine alone without the compatibility module on the path is not enough, the first compile succeeds through the engine's in-session claim of that function name, but a later one silently reverts to the inbox or gallery module.
