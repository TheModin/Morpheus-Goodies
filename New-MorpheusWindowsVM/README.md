# New-MorpheusWindowsVM (`New-MorpheusWindowsVM.ps1`)

A PowerShell 7 script that provisions a Windows VM in **HPE Morpheus VM Essentials (HVM/KVM)**. All settings are pre-configured with sensible defaults and fully overridable. Only the Morpheus server hostname and bearer token are required at runtime.

---

## Requirements

- PowerShell 7.0+
- **HPE Morpheus VM Essentials 9.0 or later** — the script checks the server version at startup and fails fast on older builds
- Network access to the Morpheus VM Essentials server
- A Morpheus API bearer token with provisioning permissions

---

## Quick Start

```powershell
$token = ConvertTo-SecureString 'your-api-token' -AsPlainText -Force

.\New-MorpheusWindowsVM.ps1 `
    -MorpheusServer 'morpheus.example.com' `
    -MorpheusToken  $token
```

This provisions a VM named `AAA-NNNNN` (5 random digits) using all default settings.

---

## Parameters

| Parameter | Required | Default | Description |
| :--- | :---: | :--- | :--- |
| `MorpheusServer` | ✅ | — | Morpheus hostname or IP. No `https://` prefix. |
| `MorpheusToken` | ✅ | — | Bearer token as `SecureString`. |
| `MorpheusSkipSSL` | | `$false` | Skip TLS certificate validation. For lab use only. |
| `InstanceNamePrefix` | | `AAA-` | Prefix for the generated VM name. Appended with 5 random digits. |
| `CloudName` | | `HVM Cloud` | Name of the Morpheus cloud to deploy onto. |
| `GroupName` | | `HPE VME Admin` | Name of the Morpheus group (site). |
| `ImageName` | | `Windows Server 2025 Template Sysprep` | Virtual image name to deploy from. |
| `LayoutName` | | `Single HVM` | Instance type layout name. Falls back to reading layout from an existing instance if `/api/library/layouts` returns 403. |
| `LayoutId` | | `0` | Override layout ID directly (0 = auto-resolve by name). Use when no existing HVM instances exist for the fallback. |
| `InstanceTypeCode` | | `mvm` | Morpheus instance type code. `mvm` is the HVM instance type. |
| `ProvisionTypeCode` | | `kvm` | Provision type code used for network resolution. HVM/KVM always use `kvm`. |
| `PlanName` | | `4 CPU, 8GB Memory` | Service plan name. Must match exactly. |
| `NetworkName` | | `OVS dc-demo-dhcp - 25` | Network name to attach the VM NIC to. |
| `IpPoolName` | | `` | Explicit IP pool name override. If set, the NIC uses this pool instead of auto-detecting. Mutually exclusive with `-ForceDhcp`. |
| `ForceDhcp` | | `$false` | Explicit override: always use DHCP for the NIC even if the network has pool(s) configured. Mutually exclusive with `-IpPoolName`. |
| `DomainName` | | `int.hpedemo.se` | DNS domain for the VM hostname. |
| `EnableUEFI` | | `$true` | `$true` = UEFI firmware, `$false` = Legacy BIOS. |
| `DiskSizeGB` | | `80` | Root disk size in GB. Must be ≥ the image minimum (~65 GB for the default image). |
| `DatastoreId` | | `4` | Root volume datastore ID. If this ID doesn't exist on the target server, the script prompts you to pick one from a list of available datastores. |
| `DatastoreName` | | `` | Optional name filter applied to the interactive datastore selection list. Leave empty to show all available datastores. |
| `StorageTypeId` | | `1` | Morpheus storage type ID for the root volume. |
| `LogPath` | | `C:\Windows\Logs\MorpheusProvision` | Directory for the log file. |

---

## Examples

### Provision with all defaults

```powershell
$token = Read-Host -AsSecureString 'Morpheus API token'

.\New-MorpheusWindowsVM.ps1 `
    -MorpheusServer 'morpheus.example.com' `
    -MorpheusToken  $token
```

### Override name prefix and plan

```powershell
.\New-MorpheusWindowsVM.ps1 `
    -MorpheusServer      'morpheus.example.com' `
    -MorpheusToken       $token `
    -InstanceNamePrefix  'PROD-' `
    -PlanName            '8 CPU, 16GB Memory'
```

### Skip SSL (lab/dev only)

```powershell
.\New-MorpheusWindowsVM.ps1 `
    -MorpheusServer  'morpheus.lab.local' `
    -MorpheusToken   $token `
    -MorpheusSkipSSL
```

### Dry run (WhatIf — resolves all IDs but does not provision)

```powershell
.\New-MorpheusWindowsVM.ps1 `
    -MorpheusServer 'morpheus.example.com' `
    -MorpheusToken  $token `
    -WhatIf
```

### Force a specific IP pool

```powershell
.\New-MorpheusWindowsVM.ps1 `
    -MorpheusServer 'morpheus.example.com' `
    -MorpheusToken  $token `
    -NetworkName    'OVS dc-demo-static - 25' `
    -IpPoolName     'dc-demo-static-pool-2'
```

### Force DHCP on a network that also has IP pool(s)

```powershell
.\New-MorpheusWindowsVM.ps1 `
    -MorpheusServer 'morpheus.example.com' `
    -MorpheusToken  $token `
    -NetworkName    'OVS dc-demo-static - 25' `
    -ForceDhcp
```

---

## IP Pool / DHCP Selection

Some networks are configured with both DHCP and a static IP pool. By default
(no `-IpPoolName` / `-ForceDhcp` given), the script picks the NIC's IP
assignment based on the network's `dhcpServer`, `pool`, and
`allowStaticOverride` fields (as returned by
`GET /api/options/zoneNetworkOptions`):

| Network configuration | Default behavior |
| :--- | :--- |
| No IP pool configured | Uses DHCP |
| Pool configured, DHCP not available | Uses the pool (only option) |
| Pool configured, DHCP available, override **not** permitted (`allowStaticOverride=false`) | Uses DHCP |
| Pool configured, DHCP available, override permitted (`allowStaticOverride=true`) | Uses the pool |

Use `-IpPoolName '<pool name>'` to force the pool non-interactively (throws
if the network has no pool, if the name doesn't match, or is silently
downgraded to DHCP with a warning if the network doesn't permit override), or
`-ForceDhcp` to force DHCP regardless of pool configuration. These two
parameters are mutually exclusive.

> **Live-verified** against `vme.int.hpedemo.se`: a network can have at most
> one assigned pool (`network.pool` is a single `{id, name}` object or
> `null` — never an array/multiple pools). Verified end-to-end with
> `-WhatIf` for: no-pool → DHCP, pool+DHCP+override-allowed → pool
> (auto-preferred), `-ForceDhcp` override → DHCP, `-IpPoolName` with a valid
> name → pool, `-IpPoolName` with an unknown name → throws with the
> available pool name, `-IpPoolName` on a network with no pool → throws.
> Also verified with **real (non-`-WhatIf`)** provisioning: the pool branch
> submits `ipMode='pool'` + `poolId` (not `'static'`, which requires an
> explicit `ipAddress` and fails with `You must enter an ip address`).

---

## How it resolves names to IDs

The script calls the following Morpheus API endpoints to translate names into IDs before provisioning:

| What | API Endpoint |
| :--- | :--- |
| Cloud | `GET /api/zones?name={CloudName}` |
| Group | `GET /api/groups?name={GroupName}` |
| Provision type | `GET /api/provision-types?code={ProvisionTypeCode}` |
| Virtual image | `GET /api/virtual-images?name={ImageName}` |
| Layout | `GET /api/library/layouts?provisionType=kvm&name={LayoutName}` |
| Service plan | `GET /api/service-plans?zoneId={cloudId}&layoutId={layoutId}` |
| Resource pool | `GET /api/zones/{cloudId}/resource-pools` (uses first available) |
| Network | `GET /api/options/zoneNetworkOptions?zoneId={cloudId}&provisionTypeId={id}` |
| IP assignment (DHCP vs. pool) | Uses `dhcpServer`/`pool`/`allowStaticOverride` fields on the same network object returned above; see [IP Pool / DHCP Selection](#ip-pool--dhcp-selection) |
| Datastore | `GET /api/options/datastores` (default ID `4`, matched client-side); falls back to an interactive prompt if that ID isn't in the list |
| **Version check** | `GET /api/setup/check` (unauthenticated, v9+) |
| **Current user** (for Wiki) | `GET /api/whoami` |
| **Instance Wiki page** | `GET/POST/PUT /api/wiki/pages` |

---

## Output

On success, the script returns a `PSCustomObject` and logs the result:

```
Instance Name : AAA-47291
Instance ID   : 42
Status        : provisioning
URL           : https://morpheus.example.com/#/provisioning/instances/42
```

---

## Instance Wiki documentation

After a successful (non-`-WhatIf`) provisioning request, the script writes a
Wiki page to the new instance in Morpheus (visible on the instance's **Wiki**
tab) with three sections:

1. **Provisioning Info** — date/time provisioned (local + UTC) and who ran
   the script (resolved via `GET /api/whoami`)
2. **Source Image** — the image name and its relevant settings (OS type,
   image format, minimum disk, Sysprep/Cloud-Init flags, UEFI/TPM/Secure
   Boot capability, storage provider), plus an **Advanced** subsection with
   "Is Cloud Init Enabled?", "Cloud Guest Customization?",
   "Sysprepped / Generalized Image?", "Install Agent?", and any other
   Advanced-tab settings found on the image (best-effort — exact fields
   depend on the Morpheus version)
3. **Deployment Settings** — the actual settings used for this VM (cloud,
   group, instance type, layout, plan, network, domain, firmware, disk size,
   datastore name, resource pool ID if used)

The page is created if none exists for the instance, or updated in place if
run again against the same instance ID. This step is **best-effort**: if the
Wiki API call fails for any reason, the script logs a warning and continues
— it never fails an otherwise-successful deployment.

---

## Notes

- **Fire-and-forget**: The script returns as soon as the provisioning request is accepted. Monitor provisioning progress in the Morpheus UI or via `GET /api/instances/{id}`.
- **PlanName must match exactly**: it must match the plan name in Morpheus exactly (e.g. `4 CPU, 8GB Memory`).
- **StorageTypeId**: If the default `1` is invalid in your environment, find valid IDs via `GET /api/provision-types/{kvm_id}` and check `storageTypes[].id`.
- **UEFI**: Stored as `config.firmware = "uefi"`. If UEFI is not applying, your Morpheus version may use a different optionType field — check the layout's optionTypes via `GET /api/library/layouts/{layoutId}`.
