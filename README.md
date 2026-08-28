# Morpheus-Goodies

A collection of automation scripts and tools for **HPE Morpheus VM Essentials** and related infrastructure workflows.

## Scripts

| Folder | Description |
| :--- | :--- |
| [VMware-to-HVM-Migration_8.1](./VMware-to-HVM-Migration_8.1/) | Automated migration of Windows VMs from VMware vSphere to HPE Morpheus VM Essentials (HVM). Handles offline VirtIO driver injection, Morpheus migration plan execution, and post-migration cleanup. Morpheus 9.x handles a lot of this built-in, so no need to use this script on 9.x |
| [New-MorpheusWindowsVM](./New-MorpheusWindowsVM/) | Provisions a Windows VM in Morpheus VM Essentials (HVM/KVM) with all settings pre-configured. Resolves all resources by name, supports UEFI, domain join config, and fire-and-forget provisioning via the Morpheus REST API. |

## Requirements

- PowerShell 7.0+
- VMware PowerCLI
- Access to a Morpheus VM Essentials instance

See each script's own `README.md` for detailed prerequisites and usage.

## License

See individual script folders for license information.
