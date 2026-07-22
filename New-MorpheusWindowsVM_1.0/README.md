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
| `DomainName` | | `int.hpedemo.se` | DNS domain for the VM hostname. |
| `EnableUEFI` | | `$true` | `$true` = UEFI firmware, `$false` = Legacy BIOS. |
| `DiskSizeGB` | | `80` | Root disk size in GB. Must be ≥ the image minimum (~65 GB for the default image). |
| `DatastoreId` | | `0` | Root volume datastore ID (0 = auto-detect from existing instances in the same cloud and layout). |
| `DatastoreName` | | `` | Optional datastore name filter used during auto-detection. Leave empty to accept the first available. |
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
    -PlanName            '8 CPU , 16GB Memory'
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
| **Version check** | `GET /api/setup/check` (unauthenticated, v9+) |

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

## Notes

- **Fire-and-forget**: The script returns as soon as the provisioning request is accepted. Monitor provisioning progress in the Morpheus UI or via `GET /api/instances/{id}`.
- **PlanName must match exactly**: The space before the comma in `4 CPU , 8GB Memory` is intentional and must match the plan name in Morpheus exactly.
- **StorageTypeId**: If the default `1` is invalid in your environment, find valid IDs via `GET /api/provision-types/{kvm_id}` and check `storageTypes[].id`.
- **UEFI**: Stored as `config.firmware = "uefi"`. If UEFI is not applying, your Morpheus version may use a different optionType field — check the layout's optionTypes via `GET /api/library/layouts/{layoutId}`.
