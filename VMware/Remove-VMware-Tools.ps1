# Disclaimer:
# This script is provided as-is with no support or warranty. You are responsible
# for reviewing, testing, and using it appropriately. Test it in a safe,
# non-production environment before running it against any system that matters.
function Remove-VMwareToolsInternal {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $toolsKey = Get-ChildItem $regPaths -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -like 'VMware Tools*' } |
        Select-Object -First 1
    if (-not $toolsKey) { Write-Output 'VMWARETOOLS_NOT_FOUND'; return }
    Write-Output "FOUND: $($toolsKey.DisplayName) $($toolsKey.DisplayVersion)"
    $productCode = $toolsKey.PSChildName
 
    # Stage 1: set env var to bypass VMX hardware check
    [System.Environment]::SetEnvironmentVariable('VIT_MSI_DISABLE_VMX_CHECK', '1', 'Machine')
    $p = Start-Process msiexec.exe -ArgumentList "/x $productCode /qn /norestart" -Wait -PassThru -NoNewWindow
    Write-Output "STAGE1_EXIT: $($p.ExitCode)"
    if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Write-Output 'VMWARETOOLS_REMOVED'; return }
 
    # Stage 2: patch cached MSI via COM using InvokeMember (required for WindowsInstaller COM in PS)
    # Uses packed-GUID registry lookup for the exact LocalPackage path (ref: KGHague gist).
    # Deletes VM_LogStart and VM_CheckRequirements from the CustomAction table (not InstallExecuteSequence).
    Write-Output "Stage 1 returned $($p.ExitCode) — attempting MSI database patch..."
    $localPackage = $null
    try {
        $guid = [System.Guid]::Parse($productCode.Trim('{}'))
        $gs = $guid.ToString('N')
        $idxLen = [ordered]@{ 0=8; 8=4; 12=4; 16=2; 18=2; 20=12 }
        $packed = ''
        foreach ($kv in $idxLen.GetEnumerator()) {
            $sub = $gs.Substring($kv.Key, $kv.Value)
            if ($kv.Key -eq 20) {
                ($sub -split '(.{2})' | Where-Object { $_ }) | ForEach-Object {
                    $ch = $_ -split '(.{1})' | Where-Object { $_ }
                    [System.Array]::Reverse($ch); $packed += $ch -join ''
                }
            } else {
                $ch = $sub.ToCharArray(); [System.Array]::Reverse($ch); $packed += $ch -join ''
            }
        }
        $packedGuid = [System.Guid]::Parse($packed).ToString('N').ToUpper()
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$packedGuid\InstallProperties"
        $localPackage = (Get-ItemProperty -Path $regPath -ErrorAction Stop).LocalPackage
        Write-Output "Found LocalPackage: $localPackage"
    } catch { Write-Output "LocalPackage lookup failed: $_ — cannot patch MSI" }
 
    if ($localPackage -and (Test-Path $localPackage)) {
        $patched = $false
        $ins2 = $null; $db2 = $null; $vw2 = $null
        try {
            $ins2 = New-Object -ComObject WindowsInstaller.Installer
            $db2  = $ins2.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $ins2, @($localPackage, 2))
            $vw2  = $db2.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db2,
                        @("DELETE FROM CustomAction WHERE Action='VM_LogStart' OR Action='VM_CheckRequirements'"))
            $vw2.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $vw2, $null)
            $vw2.GetType().InvokeMember('Close',   'InvokeMethod', $null, $vw2, $null)
            $db2.GetType().InvokeMember('Commit',  'InvokeMethod', $null, $db2, $null)
            Write-Output 'MSI patched: VM_LogStart and VM_CheckRequirements removed from CustomAction'
            $patched = $true
        } catch { Write-Output "MSI patch failed: $_" }
        finally {
            if ($vw2)  { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($vw2)  | Out-Null }
            if ($db2)  { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($db2)  | Out-Null }
            if ($ins2) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($ins2) | Out-Null }
        }
        if ($patched) {
            $p2 = Start-Process msiexec.exe -ArgumentList "/x `"$localPackage`" /qn /norestart" -Wait -PassThru -NoNewWindow
            Write-Output "STAGE2_EXIT: $($p2.ExitCode)"
            if ($p2.ExitCode -eq 0 -or $p2.ExitCode -eq 3010) { Write-Output 'VMWARETOOLS_REMOVED'; return }
            Write-Output "Stage 2 returned $($p2.ExitCode) — falling back to manual removal"
        }
    } else { Write-Output 'LocalPackage not found on disk — falling back to manual removal' }
 
    # Stage 3: manual forced cleanup (bypasses MSI entirely)
    Write-Output 'Starting manual VMware Tools cleanup...'
    foreach ($svc in @('VMTools', 'VGAuthService', 'vmvss', 'VMwareCAFCommAmqpListener', 'VMwareCAFManagementAgentHost')) {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        & sc.exe delete $svc 2>&1 | Out-Null
    }
    $vmDir = 'C:\Program Files\VMware'
    if (Test-Path $vmDir) { Remove-Item $vmDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "Deleted: $vmDir" }
    foreach ($regKey in @(
        'HKLM:\SOFTWARE\VMware, Inc.',
        'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.',
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$productCode",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
    )) {
        if (Test-Path $regKey) { Remove-Item $regKey -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "Removed: $regKey" }
    }
    Write-Output 'VMWARETOOLS_REMOVED_MANUAL'
}
Remove-VMwareToolsInternal
