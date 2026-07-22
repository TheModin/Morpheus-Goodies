# Agent Instructions — New-MorpheusWindowsVM

This folder contains a single PowerShell 7 script: `New-MorpheusWindowsVM.ps1`.
See [README.md](README.md) for parameter reference and [CHANGELOG.md](CHANGELOG.md) for version history.

---

## Validate After Every Edit

Run the parse check before any test execution (run from the repository root):

```powershell
$e = $t = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path '.\New-MorpheusWindowsVM_1.0\New-MorpheusWindowsVM.ps1'),
    [ref]$t, [ref]$e
)
if ($e.Count -eq 0) { 'PARSE_OK' } else { $e | ForEach-Object { $_.Message } }
```

Must print `PARSE_OK`. Fix any errors before running the script.

---

## Script Structure

| Region | Purpose |
|--------|---------|
| `param(...)` | All script parameters with defaults |
| Strict mode + error prefs | `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'` |
| `Write-Log` | Logging helper (INFO/WARN/ERROR/SUCCESS) |
| `Invoke-MorpheusApi` | HTTP helper with bearer token, query string builder, error mapping |
| `Resolve-*` functions | Name-to-ID resolution for each Morpheus resource |
| Main execution block | Sets script-scope vars, resolves IDs, generates name, POSTs to `/api/instances` |

Key functions:

- `Test-MorpheusVersion` — calls `GET /api/setup/check`, parses `appVersion`, throws if major < 9; warns and continues if endpoint is unreachable
- `Invoke-MorpheusApi` — decrypts SecureString token per request, zeroes BSTR after use, handles query parameters and JSON body
- `Resolve-Cloud` — returns the full cloud object (not just ID); callers read `.id` and `.zoneType.code`
- `Resolve-ProvisionTypeId` — calls `GET /api/provision-types?code={code}`, returns numeric ID
- `Resolve-NetworkId` — primary lookup via `GET /api/options/zoneNetworkOptions`; fallback to `GET /api/networks`
- `Resolve-ServicePlanId` — must pass both `CloudId` and `LayoutId` to get the correct plan set
- `Resolve-LayoutId` — tries `/api/library/layouts` first, falls back to reading the layout from an existing instance if that endpoint returns 403 (non-admin tokens)
- `Resolve-DatastoreId` — auto-detects from an existing instance's root volume `datastoreId`; required because `datastoreId='auto'` in the volume spec is silently unresolved by Morpheus and results in a VM with no backing disk ("Error running vm")
- `Get-CurrentMorpheusUser` — calls `GET /api/whoami`, returns the token owner for the Wiki page's "provisioned by" field; failures are non-fatal (returns `$null`, logs a warning)
- `Set-InstanceWikiPage` — creates/updates a single Wiki page on the instance with three sections (Provisioning Info, Source Image, Deployment Settings); best-effort, never fails the script

---

## Critical Conventions

Follow all conventions in [../../VMware-to-HVM-Migration_8.1/AGENTS.md](../../VMware-to-HVM-Migration_8.1/AGENTS.md), in particular:

### Logging
Always use `Write-Log`, never `Write-Host` / `Write-Output` directly:

```powershell
Write-Log 'message'                   # INFO (default)
Write-Log 'message' -Level WARN
Write-Log 'message' -Level ERROR
Write-Log 'message' -Level SUCCESS
```

### Script-scope variables
Parameters are published to `$script:` scope before any helper function is called. Functions that read parameters use `$script:CloudName`, `$script:GroupName`, etc. Do not pass these as function parameters — they are intentionally script-scoped.

### SecureString token handling
`MorpheusToken` is typed `[System.Security.SecureString]`. Inside `Invoke-MorpheusApi`, the token is decrypted with `SecureStringToBSTR`, used for a single request, and immediately zeroed with `ZeroFreeBSTR`. Never convert to plain string outside `Invoke-MorpheusApi`.

### Network ID format
Morpheus expects network IDs in the provision body as strings prefixed with `"network-"` (e.g. `"network-5"`). `Resolve-NetworkId` normalises whatever the API returns into this format:

```powershell
$networkId = if ($network.id -is [string] -and $network.id -match '^network-') {
    $network.id
} else {
    "network-$($network.id)"
}
```

---

## Morpheus API Endpoints Used

| Purpose | Method | Path |
|---------|--------|------|
| Version check | GET | `/api/setup/check` (unauthenticated) |
| List clouds | GET | `/api/zones?name={name}` |
| List groups | GET | `/api/groups?name={name}` |
| List provision types | GET | `/api/provision-types?code={code}` |
| List virtual images | GET | `/api/virtual-images?name={name}` |
| List layouts | GET | `/api/library/layouts?provisionType=kvm&name={name}` |
| List service plans | GET | `/api/service-plans?zoneId={id}&layoutId={id}` |
| List resource pools | GET | `/api/zones/{cloudId}/resource-pools` |
| Zone network options | GET | `/api/options/zoneNetworkOptions?zoneId={id}&provisionTypeId={id}` |
| Current user | GET | `/api/whoami` |
| Wiki pages (list/create/update) | GET/POST/PUT | `/api/wiki/pages` (list does not honor `refType`/`refId` filters — filter client-side) |
| Provision instance | POST | `/api/instances` |

---

## PowerShell Requirement

The script enforces **PowerShell 7.0+** via `#Requires -Version 7.0`. Do not use PS5-only syntax. `SkipCertificateCheck` on `Invoke-RestMethod` is PS7-only — used intentionally.
