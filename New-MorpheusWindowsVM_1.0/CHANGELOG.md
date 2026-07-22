# Changelog

All notable changes to `New-MorpheusWindowsVM` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.4.0] — 2026-07-22

### Added

- **Instance Wiki documentation**: after a successful (non-`-WhatIf`) provisioning request, the script now writes a Wiki page to the new instance with three sections:
  1. Provisioning Info — date/time (local + UTC) and who ran the script (via `GET /api/whoami`)
  2. Source Image — image name and settings (OS type, format, minimum disk, Sysprep/Cloud-Init, UEFI/TPM/Secure Boot, storage provider)
  3. Deployment Settings — cloud, group, instance type, layout, plan, network, domain, firmware, disk size, datastore ID, resource pool ID
- `Get-CurrentMorpheusUser` function — resolves the token owner via `/api/whoami`
- `Set-InstanceWikiPage` function — creates or updates (idempotent) the Wiki page via `/api/wiki/pages`; content format is Markdown

### Changed

- `Resolve-VirtualImageId` now returns the full virtual image object (previously only the ID) so its properties can be used in the Wiki page
- The Wiki page write is best-effort: any failure (API error, permissions, etc.) is logged as a warning and does not fail the script, since the VM has already been provisioned successfully by that point
- Note: `GET /api/wiki/pages` does not honor `refType`/`refId` query filters on this server — the script fetches all pages and filters client-side to find an existing page for the instance

---

## [1.3.0] — 2026-07-22

### Fixed

- **Root cause of "Error running vm"**: root disk was not assigned to any datastore because `datastoreId='auto'` in the volume spec is not resolved by Morpheus. The VM was created but QEMU had no backing storage, so it failed to start.

### Added

- `Resolve-DatastoreId` function: iterates existing provisioned instances in the same cloud and layout, reads the root volume's `datastoreId` from each server record, and returns the first match. Skips instances whose volume has no datastore (i.e., the previously broken VMs).
- `-DatastoreId` parameter (default `0` = auto-detect) — override with an explicit integer ID to skip instance scanning entirely.
- `-DatastoreName` parameter (default empty) — optional name filter applied during auto-detection to prefer a specific datastore by name.

---



### Fixed

- **Layout resolution** — `/api/library/layouts` returns 403 for non-admin tokens; added fallback that resolves the layout ID from an existing instance with the same layout name. Admin tokens continue to use the library endpoint directly.
- **InstanceTypeCode default** — changed from `kvm` to `mvm` (correct HVM instance type code in Morpheus)
- **LayoutName default** — changed from `Single KVM VM` to `Single HVM`
- **PlanName default** — corrected from `4 CPU , 8GB Memory` to `4 CPU, 8GB Memory` (no extra space before comma)
- **DiskSizeGB default** — increased from 60 to 80 GB; the Windows Server 2025 template requires ≥ 65 GB
- **Network resolution** — `GET /api/options/zoneNetworkOptions` wraps networks inside a `data` object; the resolver now reads `$resp.data.networks` with a fallback to `$resp.networks` for compatibility
- **Error messages** — `Invoke-MorpheusApi` now surfaces `msg` and per-field `errors` from the Morpheus API 400 response body, giving actionable failure messages

### Added

- `-LayoutId` parameter (default `0`) — provide the layout integer ID directly to skip name-based lookup entirely; useful in fresh environments with no existing HVM instances

---



### Added

- Runtime version check: calls `GET /api/setup/check` at startup and fails with a clear error if the Morpheus server is older than 9.0. If the endpoint is unreachable (firewall, restricted environment) the check is skipped with a warning so deployments are never blocked unnecessarily.
- `Test-MorpheusVersion` function added after `Invoke-MorpheusApi`

### Changed

- Script header and README updated to document the Morpheus 9.0+ requirement

---

## [1.0.0] — 2026-07-22

### Added

- Initial release of `New-MorpheusWindowsVM.ps1`
- Resolves all Morpheus resource names (cloud, group, virtual image, layout, plan, network) to IDs via the Morpheus REST API at runtime — no hardcoded IDs
- All VM settings have pre-configured defaults (cloud, image, plan, network, domain, UEFI, disk size) and are fully overridable via parameters
- Two required parameters only: `-MorpheusServer` and `-MorpheusToken`
- Default settings:
  - Cloud: `HVM Cloud`
  - Group: `HPE VME Admin`
  - Image: `Windows Server 2025 Template Sysprep`
  - Layout: `Single HVM`
  - Plan: `4 CPU, 8GB Memory`
  - Network: `OVS dc-demo-dhcp - 25`
  - Domain: `int.hpedemo.se`
  - UEFI: enabled
  - VM name: `AAA-NNNNN` (5 random digits)
- Fire-and-forget provisioning: returns immediately after the API request is accepted
- `Write-Log` with INFO/WARN/ERROR/SUCCESS levels, colour-coded console output, and log file at `C:\Windows\Logs\MorpheusProvision\provision.log`
- `Invoke-MorpheusApi` with bearer token handling (SecureString, zeroed after use), query string builder, and structured error messages
- `-WhatIf` support via `[CmdletBinding(SupportsShouldProcess)]` — resolves all IDs without submitting the provision request
- `-MorpheusSkipSSL` switch for lab/dev environments with self-signed certificates
- Network ID resolution via `GET /api/options/zoneNetworkOptions` with fallback to `GET /api/networks`
- Resource pool auto-detection with graceful omission if none exist
- Returns a `PSCustomObject` with `Name`, `Id`, `Status`, and `Url` properties for pipeline use
