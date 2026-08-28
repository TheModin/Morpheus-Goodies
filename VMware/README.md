# VMware Tools Removal Script

`Remove-VMware-Tools.ps1` removes VMware Tools from a Windows guest. It is intended for migration or cleanup scenarios where the standard VMware Tools uninstaller may fail because the VM is no longer running on VMware virtual hardware.

## Disclaimer

This script is provided as-is with no support or warranty. You are responsible for reviewing, testing, and using it appropriately. Test it in a safe, non-production environment before running it against any system that matters.

## What it does

The script runs `Remove-VMwareToolsInternal` immediately when executed. It uses a staged removal process:

1. Searches the 64-bit and 32-bit Windows uninstall registry locations for an installed product whose display name starts with `VMware Tools`.
2. Sets the machine environment variable `VIT_MSI_DISABLE_VMX_CHECK=1` to bypass VMware Tools VMX hardware checks.
3. Attempts a quiet MSI uninstall with `msiexec.exe /x <productCode> /qn /norestart`.
4. If the first uninstall fails, locates the cached MSI package through the Windows Installer registry metadata.
5. Opens the cached MSI database through the `WindowsInstaller.Installer` COM object and removes the `VM_LogStart` and `VM_CheckRequirements` custom actions.
6. Attempts a second quiet MSI uninstall using the patched cached MSI.
7. If MSI removal still fails, performs manual cleanup of VMware Tools services, VMware program files, and related registry keys.

## Requirements

- Windows PowerShell or PowerShell running on Windows.
- Administrator privileges.
- Local access to the guest operating system.
- Windows Installer service and registry metadata for the MSI-based removal stages.

## Usage

Run from an elevated PowerShell session:

```powershell
.\Remove-VMware-Tools.ps1
```

To capture output to a log file:

```powershell
.\Remove-VMware-Tools.ps1 *> .\Remove-VMware-Tools.log
```

## Output markers

The script writes plain text status markers to the output stream:

| Marker | Meaning |
| --- | --- |
| `VMWARETOOLS_NOT_FOUND` | VMware Tools was not found in the uninstall registry keys. |
| `FOUND: <name> <version>` | VMware Tools was found and removal is starting. |
| `STAGE1_EXIT: <code>` | Exit code from the first `msiexec` uninstall attempt. |
| `VMWARETOOLS_REMOVED` | VMware Tools was removed by one of the MSI uninstall stages. |
| `STAGE2_EXIT: <code>` | Exit code from the patched cached MSI uninstall attempt. |
| `VMWARETOOLS_REMOVED_MANUAL` | The script completed the manual forced cleanup path. |

Exit codes `0` and `3010` from `msiexec.exe` are treated as successful MSI removal. Code `3010` means a restart is required.

## Safety notes

- Run this only when you intend to remove VMware Tools from the guest.
- The fallback cleanup path deletes VMware Tools services, `C:\Program Files\VMware`, and VMware Tools uninstall registry keys.
- The script uses quiet uninstall flags and does not prompt for confirmation.
- Restart the guest after successful removal, especially when `msiexec.exe` returns `3010`.

## Troubleshooting

If VMware Tools remains installed after the script runs:

1. Review the console output or captured log for `STAGE1_EXIT` and `STAGE2_EXIT` values.
2. Confirm the script was run from an elevated PowerShell session.
3. Check whether the cached MSI path reported by the script exists on disk.
4. Restart the guest and verify VMware Tools services are no longer present.