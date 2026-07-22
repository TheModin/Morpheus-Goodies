# Changelog

All notable changes to `New-MorpheusWindowsVM` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  - Image: `Windows Server 2025 Template Sysprep (QCOW2)`
  - Layout: `Single KVM VM`
  - Plan: `4 CPU , 8GB Memory`
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
