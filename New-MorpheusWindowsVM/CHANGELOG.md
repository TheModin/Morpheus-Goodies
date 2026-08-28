# Changelog

All notable changes to `New-MorpheusWindowsVM` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

---

## [1.8.2] — 2026-07-24

### Fixed

- **Real (non-`-WhatIf`) provisioning against a pool-assigned network failed** with `HTTP 400: networkInterfaces: You must enter an ip address`. Root cause: the pool branch sent `ipMode='static'` + `poolId` + `networkPool.id`, but Morpheus's `ipMode:'static'` always requires an explicit `ipAddress`, regardless of any pool fields supplied — pools are not auto-assigned under `static` mode.
- Corrected to send `ipMode='pool'` + `poolId` (dropping the unused `networkPool` object) for the pool branch. This was confirmed against `vme.int.hpedemo.se` with real (non-`-WhatIf`) provisioning requests: the request is now accepted, and the resulting NIC correctly records `ipMode:"pool"` with the pool attached.

### Known issue (environment, not script)

- On `vme.int.hpedemo.se`, VMs provisioned with `ipMode='pool'` still receive a DHCP-leased address from a different subnet (`10.10.10.x`) rather than an address from the pool's own subnet (`10.10.20.0/24`). This appears to be a VLAN/OVS bridge tagging issue in that environment rather than an API payload problem — `ipMode='pool'` + `poolId` matches Morpheus's documented contract. Flagged for the network team to investigate separately.

## [1.8.1] — 2026-07-24

### Fixed

- **Corrected the IP pool JSON schema assumption from 1.8.0** after live verification against `vme.int.hpedemo.se`. The real `GET /api/options/zoneNetworkOptions` network object exposes a single optional `pool` object (`{id, name}` or `null`) plus `dhcpServer` (bool) and `allowStaticOverride` (bool) flags — never an array of multiple pools per network. `Resolve-NetworkIpAssignment` was rewritten to use these exact fields; the previously-added "multiple pools → interactive picker" branch was removed since a network can have at most one pool.
- Auto-detection now correctly honors `allowStaticOverride`: if a network has both DHCP and a pool but does not permit overriding DHCP, the script uses DHCP even though a pool exists (previously would have incorrectly preferred the pool).

### Verified

- Live end-to-end `-WhatIf` runs against `vme.int.hpedemo.se` (HVM Cloud) confirmed all paths: network with no pool → DHCP; network with pool + DHCP + override allowed → pool (auto-preferred); `-ForceDhcp` on a pool-capable network → DHCP; `-IpPoolName` with the correct name → pool; `-IpPoolName` with an unknown name → throws listing the actual available pool; `-IpPoolName` on a network with no pool at all → throws.

## [1.8.0] — 2026-07-24

### Added

- **IP pool / DHCP selection for the NIC**: previously the script always used `ipMode='dhcp'` with no way to select an IP pool. Added:
  - `-IpPoolName` parameter — explicit override to force a specific IP pool by name (must belong to the resolved network); throws with the list of available pool names if not found.
  - `-ForceDhcp` switch — explicit override to force DHCP even when the network has pool(s) configured. Mutually exclusive with `-IpPoolName`.
  - `Resolve-NetworkIpAssignment` function — auto-detects the correct default when neither override is given: no pools → DHCP; only a pool → use it; DHCP + exactly one pool → prefer the pool; multiple pools → interactive numbered prompt (mirrors the `Resolve-DatastoreId` UX), including a "Use DHCP instead" entry when DHCP is also valid on that network.
  - `Resolve-NetworkId` now also returns the resolved network object (in addition to the network ID) so `Resolve-NetworkIpAssignment` can inspect its pool data.
  - The Wiki page's Deployment Settings section now includes an `IP Assignment` line (`DHCP` or `Pool: <name> (id=N)`).

### Notes

- Superseded by 1.8.1 below: the exact pool field-name assumption here was corrected after live verification against `vme.int.hpedemo.se`.

## [1.7.0] — 2026-07-23

### Fixed

- `Resolve-DatastoreId` called `GET /api/storage-datastores` and `GET /api/storage-datastores/{id}`, which don't exist on this server (`404 Unable to find api endpoint`). Replaced with `GET /api/options/datastores`, which returns the same `{id, name}` list used by the Morpheus UI's datastore picker; the requested `-DatastoreId` is now matched against this list client-side instead of via a dedicated single-item GET.
- The `zoneId` query parameter was dropped from this call: `GET /api/options/datastores?zoneId={id}` returned an empty list on the live test server even for a valid, active cloud, which would have caused every run to fall through to the interactive picker. The endpoint is now called unfiltered.
- Live-tested end-to-end (`-WhatIf`) against `vme.int.hpedemo.se`: `Using datastore id=4 name='B10000-FC-Plugin - 11.0TB Free'.`

## [1.6.0] — 2026-07-23

### Added

- The Wiki page's **Source Image** section now includes an **Advanced** subsection covering the image's Advanced-tab settings: "Is Cloud Init Enabled?", "Cloud Guest Customization?", "Sysprepped / Generalized Image?", "Install Agent?", plus any other simple (boolean/string/number) property found on the image that isn't already shown elsewhere in the section — so the Wiki page reflects the image's Advanced options without hardcoding every possible field name.
- `Resolve-VirtualImageId` now fetches the full image detail via `GET /api/virtual-images/{id}` after resolving the ID from the name search, since the list endpoint returns a trimmed object that often lacks Advanced-tab fields. Falls back to the (trimmed) list object with a warning if the detail call fails — never fails the script.

### Fixed

- The catch-all Advanced-settings list excluded raw byte-count fields (`minRam`, `minDisk`, `rawSize`, `rawSizeGB` — GB-rounded equivalents are already shown) and, importantly, credential-bearing fields (`sshUsername`, `sshPassword`, `sshPasswordHash`, `sshKey`, `guestConsoleUsername`, `guestConsolePassword`, `guestConsolePasswordHash`) so a populated password/key can never leak into the Wiki page even though the catch-all only checks for `$null`.

### Notes

- Live-verified against `vme.int.hpedemo.se` (Morpheus 9.0.1) using virtual image "Windows Server 2025 Template Sysprep": `isCloudInit`, `isForceCustomization`, `isSysprep`, and `installAgent` are the correct live property names for all four requested settings — no alias fallback was needed on this server. The alias lists and catch-all remain in place as a safety net for other Morpheus versions/editions.

## [1.5.0] — 2026-07-23

### Changed

- `-DatastoreId` default changed from `0` to `4`.
- `Resolve-DatastoreId` no longer auto-detects a datastore by scanning existing instances' root volumes. It now looks up the requested datastore directly via `GET /api/storage-datastores/{DatastoreId}`. If that ID doesn't exist (or the request fails for any reason), the script fetches `GET /api/storage-datastores` (optionally filtered by `-DatastoreName`), prints a numbered list of available datastores, and prompts the user via `Read-Host` to pick one (re-prompts on invalid input).
- `Resolve-DatastoreId` now returns an object with `Id` and `Name` instead of a bare integer ID.
- The Wiki page's Deployment Settings section now shows `Datastore: <name> (id=N)` instead of the raw `Datastore ID`.

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
