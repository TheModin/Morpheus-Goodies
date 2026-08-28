#Requires -Version 7.0

# Script: New-MorpheusWindowsVM.ps1
# Purpose: Provisions a Windows VM in HPE Morpheus VM Essentials (HVM/KVM) by
#          resolving all settings by name via the Morpheus REST API and submitting
#          a POST /api/instances request (fire-and-forget).
#
# How it works:
#   1. Validates parameters and PS7 environment
#   2. Resolves the target cloud by name → cloudId
#   3. Resolves the group (site) by name → groupId
#   4. Resolves the KVM provision type → provisionTypeId (for network lookup)
#   5. Resolves the virtual image by name → imageId
#   6. Resolves the layout by name (filtered to KVM) → layoutId
#   7. Resolves the service plan by name (filtered to cloud + layout) → planId
#   8. Resolves the resource pool (uses first available; omitted if none) → resourcePoolId
#   9. Resolves the network by name via zone network options → networkId
#  10. Resolves the NIC's IP assignment (DHCP vs. an IP pool) for that network
#  11. Generates a unique instance name: <Prefix><5 random digits>
#  12. POSTs to /api/instances and logs the result
#  13. Writes/updates a Wiki page on the new instance documenting who/when it
#      was provisioned, the source image's settings, and the deployment
#      settings used (best-effort — failures here do not fail the script)
#
# Requirements:
#   - PowerShell 7.0+
#   - HPE Morpheus VM Essentials 9.0 or later
#   - Network access to the Morpheus server
#   - A Morpheus API bearer token with provisioning permissions
#
# Parameters:
#   MorpheusServer       - Morpheus/VM Essentials hostname or IP (no https:// prefix)
#   MorpheusToken        - Morpheus API bearer token as SecureString
#   MorpheusSkipSSL      - Skip TLS certificate validation (use only in dev/lab)
#   InstanceNamePrefix   - Prefix for the generated VM name (default: 'AAA-')
#   CloudName            - Name of the Morpheus cloud to deploy into (default: 'HVM Cloud')
#   GroupName            - Name of the Morpheus group/site (default: 'HPE VME Admin')
#   ImageName            - Virtual image name to deploy from (default: 'Windows Server 2025 Template Sysprep')
#   LayoutName           - Instance type layout name (default: 'Single HVM')
#   LayoutId             - Override layout ID directly (skips name lookup; use when /api/library/layouts is restricted)
#   InstanceTypeCode     - Morpheus instance type code (default: 'mvm' for HVM instances)
#   ProvisionTypeCode    - Provision type code used for network lookup (default: 'kvm')
#   PlanName             - Service plan name (default: '4 CPU, 8GB Memory')
#   NetworkName          - Network name to attach the VM to (default: 'OVS dc-demo-dhcp - 25')
#   IpPoolName           - Explicit IP pool name override. If set, use this pool for the NIC
#                          instead of auto-detecting (mutually exclusive with -ForceDhcp)
#   ForceDhcp            - Explicit override: always use DHCP even if the network has pool(s)
#                          configured (mutually exclusive with -IpPoolName)
#   DomainName           - DNS domain for the VM hostname (default: 'int.hpedemo.se')
#   EnableUEFI           - Boot firmware: $true = UEFI, $false = BIOS (default: $true)
#   DiskSizeGB           - Root disk size in GB (default: 60)
#   DatastoreId          - Morpheus datastore ID for the root volume (default: 4). If this ID does not
#                          exist on the target server, the user is prompted to pick one from a list.
#   DatastoreName        - Optional datastore name filter applied to the interactive selection list (leave empty to show all)
#   StorageTypeId        - Morpheus storage type ID for the root volume (default: 1)
#   LogPath              - Directory for the provisioning log file

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateScript({
        if ($_ -match '^https?://') { throw "MorpheusServer must be a hostname or IP only — do not include 'https://'. Got: '$_'" }
        if ($_ -match '[/\\?#]')    { throw "MorpheusServer must be a plain hostname or IP with no path or query. Got: '$_'" }
        return $true
    })]
    [string]$MorpheusServer,

    [Parameter(Mandatory)]
    [System.Security.SecureString]$MorpheusToken,

    [switch]$MorpheusSkipSSL,

    [string]$InstanceNamePrefix  = 'AAA-',
    [string]$CloudName           = 'HVM Cloud',
    [string]$GroupName           = 'HPE VME Admin',
    [string]$ImageName           = 'Windows Server 2025 Template Sysprep',
    [string]$LayoutName          = 'Single HVM',
    [int]$LayoutId               = 0,
    [string]$InstanceTypeCode    = 'mvm',
    [string]$ProvisionTypeCode   = 'kvm',
    [string]$PlanName            = '4 CPU, 8GB Memory',
    [string]$NetworkName         = 'OVS dc-demo-dhcp - 25',
    [string]$IpPoolName          = '',
    [switch]$ForceDhcp,
    [string]$DomainName          = 'int.hpedemo.se',
    [bool]$EnableUEFI            = $true,
    [int]$DiskSizeGB             = 80,
    [int]$DatastoreId            = 4,
    [string]$DatastoreName       = '',
    [int]$StorageTypeId          = 1,
    [string]$LogPath             = 'C:\Windows\Logs\MorpheusProvision'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ForceDhcp.IsPresent -and $IpPoolName) {
    throw "-ForceDhcp and -IpPoolName are mutually exclusive. Specify only one."
}

# ═══════════════════════════════════════════════════════════════════════════════
# Logging
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level = 'INFO'
    )
    $ts       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $colours  = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red'; SUCCESS = 'Green' }
    $line     = "[$ts] [$Level] $Message"
    Write-Host $line -ForegroundColor $colours[$Level]

    try {
        $null = New-Item -ItemType Directory -Path $LogPath -Force
        Add-Content -Path (Join-Path $LogPath 'provision.log') -Value $line
    }
    catch {
        Write-Host "[$ts] [WARN] Could not write to log file: $_" -ForegroundColor Yellow
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Morpheus API helper
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-MorpheusApi {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Method      = 'GET',
        [hashtable]$Body     = $null,
        [hashtable]$Query    = @{}
    )

    # Decrypt bearer token for this request only; zero memory immediately after use
    $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:MorpheusToken)
    $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    $uri = "https://$script:MorpheusServer$Path"
    if ($Query.Count -gt 0) {
        $qs  = ($Query.GetEnumerator() |
                ForEach-Object { "$([Uri]::EscapeDataString($_.Key))=$([Uri]::EscapeDataString($_.Value.ToString()))" }) -join '&'
        $uri = "${uri}?${qs}"
    }

    $params = @{
        Uri                  = $uri
        Method               = $Method
        Headers              = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        SkipCertificateCheck = $script:MorpheusSkipSSL
    }
    if ($Body) { $params.Body = $Body | ConvertTo-Json -Depth 20 -Compress }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $statusCode = $_.Exception.Response?.StatusCode.value__
        $errMsg     = $null
        try {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
            $errMsg  = $errBody.msg ?? $errBody.message
            if ($errBody.errors) {
                $errFields = ($errBody.errors.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }) -join '; '
                $errMsg    = "$errMsg ($errFields)"
            }
        } catch {}
        throw "Morpheus API $Method $Path failed (HTTP $statusCode): $($errMsg ?? $_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Version gate — requires Morpheus 9.0+
# ═══════════════════════════════════════════════════════════════════════════════

function Test-MorpheusVersion {
    # GET /api/setup/check is unauthenticated and returns buildVersion in Morpheus 9+ builds.
    # If the endpoint is unavailable or the field is empty we warn and continue —
    # failing here should never block a deployment unnecessarily.
    Write-Log "Checking Morpheus server version (requires 9.0+)..."
    try {
        $resp = Invoke-RestMethod `
            -Uri                  "https://$script:MorpheusServer/api/setup/check" `
            -Method               GET `
            -SkipCertificateCheck:$script:MorpheusSkipSSL `
            -TimeoutSec           10

        # Use PSObject to safely read the property without tripping Set-StrictMode
        $appVersion = $resp.PSObject.Properties['buildVersion']?.Value
        if ([string]::IsNullOrWhiteSpace($appVersion)) {
            Write-Log "Version check: buildVersion field is empty — version information unavailable, skipping version gate." -Level WARN
            return
        }
        # Parse major version from strings like "9.0.1-123" or "9.0.1"
        $major = [int]($appVersion -split '[.\-]')[0]
        if ($major -lt 9) {
            throw "This script requires HPE Morpheus 9.0 or later. Detected version: $appVersion"
        }
        Write-Log "Morpheus version: $appVersion  ✓ (meets 9.0+ requirement)" -Level SUCCESS
    }
    catch [System.Net.Http.HttpRequestException] {
        Write-Log "Version check: /api/setup/check unreachable — skipping version gate." -Level WARN
    }
    catch {
        # Re-throw only if it's the version mismatch we raised above
        if ($_.Exception.Message -match 'requires HPE Morpheus') { throw }
        Write-Log "Version check: unexpected response from /api/setup/check — skipping version gate. ($($_.Exception.Message))" -Level WARN
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# ID resolution helpers — all resolve by name, fail loudly with helpful messages
# ═══════════════════════════════════════════════════════════════════════════════

function Resolve-Cloud {
    Write-Log "Resolving cloud '$script:CloudName'..."
    $resp  = Invoke-MorpheusApi -Path '/api/zones' -Query @{ name = $script:CloudName; max = '10' }
    $cloud = $resp.zones | Where-Object { $_.name -eq $script:CloudName } | Select-Object -First 1
    if (-not $cloud) {
        $available = ($resp.zones | Select-Object -ExpandProperty name) -join ', '
        throw "Cloud '$script:CloudName' not found. Available clouds: $available"
    }
    Write-Log "Cloud resolved: id=$($cloud.id)  zoneType=$($cloud.zoneType?.code)" -Level SUCCESS
    return $cloud
}

function Resolve-GroupId {
    Write-Log "Resolving group '$script:GroupName'..."
    $resp  = Invoke-MorpheusApi -Path '/api/groups' -Query @{ name = $script:GroupName; max = '10' }
    $group = $resp.groups | Where-Object { $_.name -eq $script:GroupName } | Select-Object -First 1
    if (-not $group) {
        $available = ($resp.groups | Select-Object -ExpandProperty name) -join ', '
        throw "Group '$script:GroupName' not found. Available groups: $available"
    }
    Write-Log "Group resolved: id=$($group.id)" -Level SUCCESS
    return [int]$group.id
}

function Resolve-ProvisionTypeId {
    Write-Log "Resolving provision type '$script:ProvisionTypeCode'..."
    $resp = Invoke-MorpheusApi -Path '/api/provision-types' -Query @{ code = $script:ProvisionTypeCode; max = '5' }
    $pt   = $resp.provisionTypes | Where-Object { $_.code -eq $script:ProvisionTypeCode } | Select-Object -First 1
    if (-not $pt) { throw "Provision type with code '$script:ProvisionTypeCode' not found." }
    Write-Log "Provision type resolved: id=$($pt.id)  code=$($pt.code)" -Level SUCCESS
    return [int]$pt.id
}

function Resolve-VirtualImageId {
    Write-Log "Resolving virtual image '$script:ImageName'..."
    $resp = Invoke-MorpheusApi -Path '/api/virtual-images' -Query @{ name = $script:ImageName; max = '5' }
    $img  = $resp.virtualImages | Where-Object { $_.name -eq $script:ImageName } | Select-Object -First 1
    if (-not $img) { throw "Virtual image '$script:ImageName' not found." }

    # The list endpoint returns a trimmed object — fetch the full detail so the
    # instance Wiki page can include the image's Advanced-tab settings.
    try {
        $detailResp = Invoke-MorpheusApi -Path "/api/virtual-images/$($img.id)"
        if ($detailResp.virtualImage) { $img = $detailResp.virtualImage }
    }
    catch {
        Write-Log "Could not fetch full virtual image detail (id=$($img.id)): $($_.Exception.Message) — Wiki 'Advanced' section may be incomplete." -Level WARN
    }

    Write-Log "Virtual image resolved: id=$($img.id)" -Level SUCCESS
    return $img
}

function Resolve-LayoutId {
    param([int]$CloudId)

    # If caller provided an explicit layout ID, skip all API lookups
    if ($script:LayoutId -gt 0) {
        Write-Log "Using explicit LayoutId=$($script:LayoutId) (name lookup skipped)." -Level SUCCESS
        return $script:LayoutId
    }

    Write-Log "Resolving layout '$script:LayoutName'..."

    # Primary: admin library endpoint (may return 403 for non-admin tokens)
    try {
        $resp   = Invoke-MorpheusApi -Path '/api/library/layouts' -Query @{
            provisionType = $script:ProvisionTypeCode
            name          = $script:LayoutName
            max           = '10'
        }
        $layout = $resp.instanceTypeLayouts | Where-Object { $_.name -eq $script:LayoutName } | Select-Object -First 1
        if ($layout) {
            Write-Log "Layout resolved via library: id=$($layout.id)" -Level SUCCESS
            return [int]$layout.id
        }
    }
    catch {
        if ($_.Exception.Message -notmatch '403|Forbidden') { throw }
        Write-Log "/api/library/layouts returned 403 (token lacks admin permission) — trying instance-based fallback..." -Level WARN
    }

    # Fallback: infer layout ID from an existing instance in this cloud
    $instResp = Invoke-MorpheusApi -Path '/api/instances' -Query @{ zoneId = $CloudId; max = '20' }
    $match    = $instResp.instances | Where-Object { $_.layout.name -eq $script:LayoutName } | Select-Object -First 1
    if ($match) {
        Write-Log "Layout resolved via existing instance: id=$($match.layout.id)" -Level SUCCESS
        return [int]$match.layout.id
    }

    throw "Layout '$script:LayoutName' not found. If /api/library/layouts is restricted use -LayoutId to provide the layout ID directly."
}

function Resolve-ServicePlanId {
    param([int]$CloudId, [int]$LayoutId)
    Write-Log "Resolving service plan '$script:PlanName'..."

    # Try with layout filter first (more targeted)
    $resp = Invoke-MorpheusApi -Path '/api/service-plans' -Query @{
        zoneId   = $CloudId
        layoutId = $LayoutId
        max      = '200'
    }
    $plan = $resp.servicePlans | Where-Object { $_.name -eq $script:PlanName } | Select-Object -First 1

    # Fallback: broader search without layout filter (some plans are not layout-indexed by this API)
    if (-not $plan) {
        Write-Log "Plan not found in layout-filtered results — retrying with zone-only filter..." -Level WARN
        $resp2 = Invoke-MorpheusApi -Path '/api/service-plans' -Query @{ zoneId = $CloudId; max = '200' }
        $plan  = $resp2.servicePlans | Where-Object { $_.name -eq $script:PlanName } | Select-Object -First 1
    }

    if (-not $plan) {
        $available = ($resp.servicePlans | Select-Object -ExpandProperty name) -join ', '
        throw "Service plan '$script:PlanName' not found. Available plans (layout-filtered): $available"
    }
    Write-Log "Service plan resolved: id=$($plan.id)" -Level SUCCESS
    return [int]$plan.id
}

function Resolve-ResourcePoolId {
    param([int]$CloudId)
    Write-Log "Checking for resource pools in cloud id=$CloudId..."
    $resp = Invoke-MorpheusApi -Path "/api/zones/$CloudId/resource-pools" -Query @{ max = '10' }
    $pool = $resp.resourcePools | Select-Object -First 1
    if (-not $pool) {
        Write-Log "No resource pools found — resourcePoolId will be omitted from request." -Level WARN
        return $null
    }
    Write-Log "Resource pool resolved: id=$($pool.id)  name=$($pool.name)" -Level SUCCESS
    return [int]$pool.id
}

function Resolve-DatastoreId {
    param([int]$CloudId)

    Write-Log "Fetching available datastores..."
    $listResp  = Invoke-MorpheusApi -Path '/api/options/datastores'
    $datastores = @($listResp.data)
    if ($script:DatastoreName) {
        $datastores = @($datastores | Where-Object { $_.name -eq $script:DatastoreName })
    }
    if (-not $datastores -or $datastores.Count -eq 0) {
        throw "No datastores available. Use -DatastoreId/-DatastoreName to match an existing datastore."
    }

    # Try the requested datastore ID directly first (default is 4, overridable via -DatastoreId)
    if ($script:DatastoreId -gt 0) {
        $ds = $datastores | Where-Object { [int]$_.id -eq $script:DatastoreId } | Select-Object -First 1
        if ($ds) {
            Write-Log "Using datastore id=$($ds.id) name='$($ds.name)'." -Level SUCCESS
            return [pscustomobject]@{ Id = [int]$ds.id; Name = $ds.name }
        }
        Write-Log "Datastore id=$($script:DatastoreId) not found — showing available datastores instead." -Level WARN
    }

    # Fall back: let the user pick one interactively
    Write-Host ''
    Write-Host 'Available datastores:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $datastores.Count; $i++) {
        Write-Host ("  [{0}] id={1}  name={2}" -f ($i + 1), $datastores[$i].id, $datastores[$i].name)
    }
    Write-Host ''

    do {
        $selection = Read-Host "Select a datastore [1-$($datastores.Count)]"
    } until ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $datastores.Count)

    $chosen = $datastores[[int]$selection - 1]
    Write-Log "Datastore selected interactively: id=$($chosen.id) name='$($chosen.name)'." -Level SUCCESS
    return [pscustomobject]@{ Id = [int]$chosen.id; Name = $chosen.name }
}

function Resolve-NetworkId {
    param([int]$CloudId, [int]$ProvisionTypeId)
    Write-Log "Resolving network '$script:NetworkName'..."

    # Primary: zone-aware network options (provision-type filtered)
    $resp    = Invoke-MorpheusApi -Path '/api/options/zoneNetworkOptions' -Query @{
        zoneId          = $CloudId
        provisionTypeId = $ProvisionTypeId
        max             = '100'
    }
    $networks = $resp.data?.networks ?? $resp.networks
    $network = $networks | Where-Object { $_.name -eq $script:NetworkName } | Select-Object -First 1

    # Fallback: direct network list
    if (-not $network) {
        Write-Log "Network not found via zoneNetworkOptions — trying /api/networks fallback..." -Level WARN
        $fallback = Invoke-MorpheusApi -Path '/api/networks' -Query @{ name = $script:NetworkName; max = '5' }
        $network  = $fallback.networks | Where-Object { $_.name -eq $script:NetworkName } | Select-Object -First 1
    }

    if (-not $network) {
        $available = ($networks | Select-Object -ExpandProperty name) -join ', '
        throw "Network '$script:NetworkName' not found. Available in zone: $available"
    }

    # Morpheus expects network IDs in the format "network-{id}" in the provision body
    $networkId = if ($network.id -is [string] -and $network.id -match '^network-') {
        $network.id
    } else {
        "network-$($network.id)"
    }

    Write-Log "Network resolved: $networkId" -Level SUCCESS
    return [pscustomobject]@{ NetworkId = $networkId; Network = $network }
}

function Resolve-NetworkIpAssignment {
    param([Parameter(Mandatory)]$Network)

    # Live-verified against vme.int.hpedemo.se (GET /api/options/zoneNetworkOptions):
    # each network object carries a single optional "pool" object (id, name) — never an
    # array/multiple pools — plus "dhcpServer" (bool: is DHCP valid on this network) and
    # "allowStaticOverride" (bool: is the operator allowed to pick the pool instead of DHCP
    # when both are available). Example:
    #   { "name": "OVS dc-demo-mgmt - 20", "dhcpServer": true, "allowStaticOverride": true,
    #     "pool": { "id": 57, "name": "10.10.20.0/24" } }
    #   { "name": "OVS dc-demo-dhcp - 25", "dhcpServer": true, "allowStaticOverride": false, "pool": null }
    $pool            = $Network.pool
    $dhcpAvailable   = if ($Network.PSObject.Properties.Name -contains 'dhcpServer') { [bool]$Network.dhcpServer } else { $true }
    $overrideAllowed = if ($Network.PSObject.Properties.Name -contains 'allowStaticOverride') { [bool]$Network.allowStaticOverride } else { $true }

    # Explicit overrides take precedence over auto-detection
    if ($script:ForceDhcp) {
        Write-Log "IP assignment: DHCP (forced via -ForceDhcp)." -Level SUCCESS
        return [pscustomobject]@{ Mode = 'dhcp'; PoolId = $null; PoolName = $null }
    }

    if ($script:IpPoolName) {
        if (-not $pool) {
            throw "IP pool '$script:IpPoolName' requested via -IpPoolName, but network '$($Network.name)' has no IP pool configured."
        }
        if ($pool.name -ne $script:IpPoolName) {
            throw "IP pool '$script:IpPoolName' not found on network '$($Network.name)'. Available pool: '$($pool.name)'."
        }
        if ($dhcpAvailable -and -not $overrideAllowed) {
            Write-Log "Network '$($Network.name)' does not permit static/pool override of DHCP (allowStaticOverride=false) — ignoring -IpPoolName and using DHCP." -Level WARN
            return [pscustomobject]@{ Mode = 'dhcp'; PoolId = $null; PoolName = $null }
        }
        Write-Log "IP assignment: pool '$($pool.name)' (id=$($pool.id)), forced via -IpPoolName." -Level SUCCESS
        return [pscustomobject]@{ Mode = 'pool'; PoolId = [int]$pool.id; PoolName = $pool.name }
    }

    # Auto-detect
    if (-not $pool) {
        Write-Log "IP assignment: DHCP (no IP pool configured on this network)." -Level SUCCESS
        return [pscustomobject]@{ Mode = 'dhcp'; PoolId = $null; PoolName = $null }
    }

    if ($dhcpAvailable -and -not $overrideAllowed) {
        Write-Log "IP assignment: DHCP (network has pool '$($pool.name)' but allowStaticOverride=false)." -Level SUCCESS
        return [pscustomobject]@{ Mode = 'dhcp'; PoolId = $null; PoolName = $null }
    }

    # Either DHCP isn't available (pool is the only option), or both are available and
    # override is permitted — prefer the pool automatically in both cases.
    $reason = if ($dhcpAvailable) { 'preferred over DHCP — both are available and override is permitted' } else { 'only option — DHCP is not available on this network' }
    Write-Log "IP assignment: pool '$($pool.name)' (id=$($pool.id)) — $reason." -Level SUCCESS
    return [pscustomobject]@{ Mode = 'pool'; PoolId = [int]$pool.id; PoolName = $pool.name }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Instance Wiki documentation
# ═══════════════════════════════════════════════════════════════════════════════

function Get-CurrentMorpheusUser {
    # Best-effort — the wiki page is still written (with an "Unknown" author)
    # if this call fails, since it should never block a successful deployment.
    try {
        $resp = Invoke-MorpheusApi -Path '/api/whoami'
        return $resp.user
    }
    catch {
        Write-Log "Could not resolve current Morpheus user via /api/whoami: $($_.Exception.Message)" -Level WARN
        return $null
    }
}

function Set-InstanceWikiPage {
    param(
        [Parameter(Mandatory)][int]$InstanceId,
        [Parameter(Mandatory)][string]$InstanceName,
        [Parameter(Mandatory)]$Image,
        [Parameter(Mandatory)][hashtable]$DeploymentSettings
    )

    Write-Log "Writing instance Wiki page for '$InstanceName'..."

    $user        = Get-CurrentMorpheusUser
    $provisioner = if ($user) { "$($user.displayName) ($($user.username))" } else { 'Unknown' }
    $localTime   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $utcTime     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # ── Section 1: Provisioning Info ──────────────────────────────────────
    $provisioningInfo = @(
        '## Provisioning Info'
        "- **Provisioned on:** $localTime (local) / $utcTime (UTC)"
        "- **Provisioned by:** $provisioner"
        "- **Script:** New-MorpheusWindowsVM.ps1"
    ) -join "`n"

    # ── Section 2: Source Image ────────────────────────────────────────────
    $imageLines = [System.Collections.Generic.List[string]]::new()
    $imageLines.Add('## Source Image')
    $imageLines.Add("- **Name:** $($Image.name)")
    if ($Image.osType?.name)  { $imageLines.Add("- **OS type:** $($Image.osType.name)") }
    if ($Image.imageType)     { $imageLines.Add("- **Image format:** $($Image.imageType)") }
    if ($Image.minDiskGB)     { $imageLines.Add("- **Minimum disk:** $($Image.minDiskGB) GB") }
    if ($Image.minRamGB)      { $imageLines.Add("- **Minimum RAM:** $($Image.minRamGB) GB") }
    $imageLines.Add("- **Sysprep:** $([bool]$Image.isSysprep)")
    $imageLines.Add("- **Cloud-Init:** $([bool]$Image.isCloudInit)")
    $imageLines.Add("- **UEFI-capable:** $([bool]$Image.uefi)")
    if ($null -ne $Image.tpm)            { $imageLines.Add("- **TPM:** $([bool]$Image.tpm)") }
    if ($null -ne $Image.secureBoot)     { $imageLines.Add("- **Secure Boot:** $([bool]$Image.secureBoot)") }
    if ($Image.storageProvider) {
        $storageProviderName = if ($Image.storageProvider -is [string]) { $Image.storageProvider } else { $Image.storageProvider.name }
        $imageLines.Add("- **Storage provider:** $storageProviderName")
    }

    # ── Advanced image settings (from the image's "Advanced" tab) ─────────
    # Property names for these vary across Morpheus versions/editions, so
    # each requested setting checks a short list of plausible aliases and
    # renders whichever one is actually present on the resolved image object.
    $imageLines.Add('')
    $imageLines.Add('### Advanced')

    $advancedFields = [ordered]@{
        'Is Cloud Init Enabled?'          = @('isCloudInit')
        'Cloud Guest Customization?'      = @('isForceCustomization', 'guestCustomization', 'cloudInitGuestCustomization', 'forceCustomization')
        'Sysprepped / Generalized Image?' = @('isSysprep')
        'Install Agent?'                  = @('installAgent')
    }
    $shownImageProps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($label in $advancedFields.Keys) {
        $shown = $false
        foreach ($prop in $advancedFields[$label]) {
            if ($Image.PSObject.Properties.Name -contains $prop -and $null -ne $Image.$prop) {
                $val = $Image.$prop
                $display = if ($val -is [bool]) { [bool]$val } else { $val }
                $imageLines.Add("- **${label}** $display")
                [void]$shownImageProps.Add($prop)
                $shown = $true
                break
            }
        }
        # 'Install Agent?' may be exposed inverted as 'noAgent' on some versions
        if (-not $shown -and $label -eq 'Install Agent?' -and $Image.PSObject.Properties.Name -contains 'noAgent') {
            $imageLines.Add("- **${label}** $(-not [bool]$Image.noAgent)")
            [void]$shownImageProps.Add('noAgent')
        }
    }

    # Catch-all: any other simple (bool/string/number) top-level image
    # property not already shown above, so no Advanced-tab setting is missed
    # even if the exact schema differs from the aliases guessed above.
    $imageDenylist = @(
        'id', 'name', 'code', 'category', 'imageType', 'osType', 'minDiskGB', 'minRamGB',
        'uefi', 'tpm', 'secureBoot', 'storageProvider', 'dateCreated', 'lastUpdated',
        'externalId', 'accountId', 'tenantId', 'owner', 'ownerId', 'account', 'region', 'bucket',
        'key', 'config', 'refType', 'refId', 'deleted', 'systemImage', 'uniqueId',
        'remotePath', 'imagePath', 'externalType', 'internalId', 'visibility',
        'minRam', 'minDisk', 'rawSize', 'rawSizeGB',
        # Never surface credentials/secrets in the Wiki page, even if populated on the image
        'sshUsername', 'sshPassword', 'sshPasswordHash', 'sshKey',
        'guestConsoleUsername', 'guestConsolePassword', 'guestConsolePasswordHash'
    ) + @($shownImageProps)

    foreach ($prop in $Image.PSObject.Properties) {
        if ($imageDenylist -contains $prop.Name) { continue }
        $val = $prop.Value
        if ($null -eq $val) { continue }
        if ($val -isnot [bool] -and $val -isnot [string] -and $val -isnot [int] -and $val -isnot [long]) { continue }
        if ($val -is [string] -and ($val.Length -eq 0 -or $val.Length -gt 60)) { continue }
        $label = ($prop.Name -creplace '([a-z0-9])([A-Z])', '$1 $2')
        $label = (Get-Culture).TextInfo.ToTitleCase($label.ToLower())
        $imageLines.Add("- **${label}:** $val")
    }

    $sourceImage = $imageLines -join "`n"

    # ── Section 3: Deployment Settings ─────────────────────────────────────
    $deployLines = [System.Collections.Generic.List[string]]::new()
    $deployLines.Add('## Deployment Settings')
    $deployLines.Add("- **Instance name:** $InstanceName")
    foreach ($key in $DeploymentSettings.Keys) {
        $deployLines.Add("- **${key}:** $($DeploymentSettings[$key])")
    }
    $deploymentSettingsText = $deployLines -join "`n"

    $content = "$provisioningInfo`n`n$sourceImage`n`n$deploymentSettingsText"

    try {
        # The Wiki list endpoint does not honor refType/refId query filters —
        # fetch all pages and filter client-side to find an existing page.
        $existingResp = Invoke-MorpheusApi -Path '/api/wiki/pages' -Query @{ max = '1000' }
        $existing     = $existingResp.pages |
            Where-Object { $_.refType -eq 'Instance' -and $_.refId -eq $InstanceId } |
            Select-Object -First 1

        if ($existing) {
            $body = @{ page = @{ name = $InstanceName; content = $content; format = 'markdown' } }
            Invoke-MorpheusApi -Path "/api/wiki/pages/$($existing.id)" -Method PUT -Body $body | Out-Null
            Write-Log "Instance Wiki page updated (id=$($existing.id))." -Level SUCCESS
        }
        else {
            $body = @{
                page = @{
                    name     = $InstanceName
                    category = 'instances'
                    refId    = $InstanceId
                    refType  = 'Instance'
                    format   = 'markdown'
                    content  = $content
                }
            }
            $created = Invoke-MorpheusApi -Path '/api/wiki/pages' -Method POST -Body $body
            Write-Log "Instance Wiki page created (id=$($created.page.id))." -Level SUCCESS
        }
    }
    catch {
        # The VM is already provisioned at this point — a wiki failure must
        # never be treated as fatal, so warn and continue.
        Write-Log "Could not write instance Wiki page: $($_.Exception.Message)" -Level WARN
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main execution
# ═══════════════════════════════════════════════════════════════════════════════

# Publish parameters to script scope so helper functions can read them
$script:MorpheusServer    = $MorpheusServer
$script:MorpheusToken     = $MorpheusToken
$script:MorpheusSkipSSL   = $MorpheusSkipSSL.IsPresent
$script:CloudName         = $CloudName
$script:GroupName         = $GroupName
$script:ImageName         = $ImageName
$script:LayoutName        = $LayoutName
$script:LayoutId          = $LayoutId
$script:ProvisionTypeCode = $ProvisionTypeCode
$script:PlanName          = $PlanName
$script:NetworkName       = $NetworkName
$script:IpPoolName        = $IpPoolName
$script:ForceDhcp         = $ForceDhcp.IsPresent
$script:DatastoreId       = $DatastoreId
$script:DatastoreName     = $DatastoreName

Write-Log ('─' * 70)
Write-Log 'New-MorpheusWindowsVM  —  VM Provisioning'
Write-Log ('─' * 70)
Write-Log "Server         : $MorpheusServer"
Write-Log "Cloud          : $CloudName"
Write-Log "Group          : $GroupName"
Write-Log "Image          : $ImageName"
Write-Log "Plan           : $PlanName"
Write-Log "Network        : $NetworkName"
Write-Log "Domain         : $DomainName"
Write-Log "UEFI           : $EnableUEFI"
Write-Log "Name prefix    : $InstanceNamePrefix"
Write-Log ('─' * 70)

# Gate: verify Morpheus 9.0+
Test-MorpheusVersion

# Resolve all required IDs
$cloud           = Resolve-Cloud
$cloudId         = [int]$cloud.id
$groupId         = Resolve-GroupId
$provisionTypeId = Resolve-ProvisionTypeId
$image           = Resolve-VirtualImageId
$imageId         = [int]$image.id
$layoutId        = Resolve-LayoutId -CloudId $cloudId
$planId          = Resolve-ServicePlanId -CloudId $cloudId -LayoutId $layoutId
$resourcePoolId  = Resolve-ResourcePoolId -CloudId $cloudId
$datastore       = Resolve-DatastoreId -CloudId $cloudId
$datastoreId     = $datastore.Id
$networkResolved = Resolve-NetworkId -CloudId $cloudId -ProvisionTypeId $provisionTypeId
$networkId       = $networkResolved.NetworkId
$ipAssignment    = Resolve-NetworkIpAssignment -Network $networkResolved.Network

# Generate unique VM name: prefix + exactly 5 random digits
$suffix       = '{0:D5}' -f (Get-Random -Minimum 0 -Maximum 99999)
$instanceName = "$InstanceNamePrefix$suffix"
Write-Log "Generated VM name: $instanceName"

# Build provisioning request body
$config = @{
    imageId    = $imageId
    firmware   = if ($EnableUEFI) { 'uefi' } else { 'bios' }
    createUser = $false
}

if (-not [string]::IsNullOrWhiteSpace($DomainName)) {
    $config['customOptions'] = @{ domainName = $DomainName }
}

if ($null -ne $resourcePoolId) {
    $config['resourcePoolId'] = $resourcePoolId
}

$provisionBody = @{
    zoneId   = $cloudId
    instance = @{
        name         = $instanceName
        hostName     = $instanceName
        site         = @{ id = $groupId }
        instanceType = @{ code = $InstanceTypeCode }
        layout       = @{ id = $layoutId }
        plan         = @{ id = $planId }
    }
    config            = $config
    networkInterfaces = @(
        @{
            network = @{ id = $networkId }
        } + $(
            if ($ipAssignment.Mode -eq 'pool') {
                # ipMode='pool' + poolId auto-assigns an IP from the network's IP pool.
                # ipMode='static' requires an explicit ipAddress and fails with
                # "You must enter an ip address" if none is supplied - it is not used for pools.
                @{ ipMode = 'pool'; poolId = $ipAssignment.PoolId }
            } else {
                @{ ipMode = 'dhcp' }
            }
        )
    )
    volumes           = @(
        @{
            id          = -1
            rootVolume  = $true
            name        = 'root'
            size        = $DiskSizeGB
            storageType = $StorageTypeId
            datastoreId = $datastoreId
        }
    )
}

Write-Log ('─' * 70)
Write-Log "Submitting provision request for '$instanceName'..."

if ($PSCmdlet.ShouldProcess($instanceName, 'Provision Morpheus VM')) {
    $resp     = Invoke-MorpheusApi -Path '/api/instances' -Method POST -Body $provisionBody
    $instance = $resp.instance

    Write-Log ('─' * 70)
    Write-Log 'VM provisioning submitted successfully!' -Level SUCCESS
    Write-Log "  Instance Name : $($instance.name)"
    Write-Log "  Instance ID   : $($instance.id)"
    Write-Log "  Status        : $($instance.status)"
    Write-Log "  URL           : https://$MorpheusServer/#/provisioning/instances/$($instance.id)"
    Write-Log ('─' * 70)

    # Document the provisioning event on the instance Wiki page (best-effort)
    $deploymentSettings = [ordered]@{
        Cloud            = $CloudName
        Group            = $GroupName
        'Instance Type'  = $InstanceTypeCode
        Layout           = $LayoutName
        Plan             = $PlanName
        Network          = $NetworkName
        'IP Assignment'  = if ($ipAssignment.Mode -eq 'pool') { "Pool: $($ipAssignment.PoolName) (id=$($ipAssignment.PoolId))" } else { 'DHCP' }
        Domain           = $DomainName
        Firmware         = if ($EnableUEFI) { 'UEFI' } else { 'BIOS' }
        'Disk Size (GB)' = $DiskSizeGB
        'Datastore'      = "$($datastore.Name) (id=$($datastore.Id))"
    }
    if ($null -ne $resourcePoolId) { $deploymentSettings['Resource Pool ID'] = $resourcePoolId }

    Set-InstanceWikiPage -InstanceId ([int]$instance.id) -InstanceName $instance.name `
        -Image $image -DeploymentSettings $deploymentSettings

    return [pscustomobject]@{
        Name   = $instance.name
        Id     = $instance.id
        Status = $instance.status
        Url    = "https://$MorpheusServer/#/provisioning/instances/$($instance.id)"
    }
}
