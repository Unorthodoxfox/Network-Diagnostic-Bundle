<#
.SYNOPSIS
    Collects a help desk network troubleshooting bundle and saves it as a ZIP file.

.DESCRIPTION
    This script gathers common network diagnostics used for help desk triage:
    - Computer, user, OS, and uptime summary
    - Network adapter status
    - IP configuration
    - DNS client configuration
    - Routing table
    - ARP cache
    - NetIP configuration
    - Proxy settings
    - Firewall profile status
    - VPN-like adapters
    - Wi-Fi profile summary, when available
    - Ping tests
    - DNS resolution tests
    - TCP connectivity tests
    - Traceroute/pathping output
    - Recent network-related event logs

.NOTES
    Run in normal PowerShell for basic diagnostics.
    Run as Administrator for the most complete event log and system details.

.EXAMPLE
    .\Network-Diagnostic-Bundle.ps1

.EXAMPLE
    .\Network-Diagnostic-Bundle.ps1 -PingTargets "8.8.8.8","fileserver01" -DnsNames "contoso.com","intranet.contoso.com" -TcpTargets "contoso.com:443","fileserver01:445"
#>

[CmdletBinding()]
param(
    [string[]]$PingTargets = @(
        "127.0.0.1",
        "8.8.8.8",
        "1.1.1.1"
    ),

    [string[]]$DnsNames = @(
        "google.com",
        "microsoft.com"
    ),

    # Format: hostname:port
    [string[]]$TcpTargets = @(
        "google.com:443",
        "microsoft.com:443"
    ),

    [string]$OutputRoot = "$env:USERPROFILE\Desktop",

    [int]$RecentEventHours = 24
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Continue"

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BundleName = "Network-Diagnostic-Bundle-$env:COMPUTERNAME-$Timestamp"
$OutputFolder = Join-Path $OutputRoot $BundleName
$ZipPath = "$OutputFolder.zip"

New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $Line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $Line
    # Keep ZIP output concise; progress messages are shown in the console only.
}

function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return ($Name -replace '[\\/:*?"<>|]', '_')
}

function Save-CommandOutput {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $SafeName = ConvertTo-SafeFileName -Name $Name
    $Path = Join-Path $OutputFolder "$SafeName.txt"

    Write-Log "Collecting $Name"

    try {
        & $ScriptBlock 2>&1 | Out-String -Width 4096 | Out-File -FilePath $Path -Encoding UTF8
    }
    catch {
        "FAILED: $($_.Exception.Message)" | Out-File -FilePath $Path -Encoding UTF8
        Write-Log "Failed collecting $Name`: $($_.Exception.Message)"
    }
}

function Save-JsonOutput {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $SafeName = ConvertTo-SafeFileName -Name $Name
    $Path = Join-Path $OutputFolder "$SafeName.json"

    Write-Log "Collecting $Name"

    try {
        $Data = & $ScriptBlock
        $Data | ConvertTo-Json -Depth 6 | Out-File -FilePath $Path -Encoding UTF8
    }
    catch {
        @{ Error = $_.Exception.Message } | ConvertTo-Json | Out-File -FilePath $Path -Encoding UTF8
        Write-Log "Failed collecting $Name`: $($_.Exception.Message)"
    }
}

function Test-IsAdmin {
    try {
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
        return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-DefaultGatewayTargets {
    try {
        Get-NetIPConfiguration |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
            ForEach-Object { $_.IPv4DefaultGateway.NextHop } |
            Sort-Object -Unique
    }
    catch {
        @()
    }
}

function Get-DomainDiagnosticTargets {
    $Targets = New-Object System.Collections.Generic.List[string]

    try {
        if ($env:USERDNSDOMAIN) {
            $Targets.Add($env:USERDNSDOMAIN)
        }

        $ComputerSystem = Get-CimInstance Win32_ComputerSystem
        if ($ComputerSystem.PartOfDomain -and $ComputerSystem.Domain) {
            $Targets.Add($ComputerSystem.Domain)
        }

        Get-DnsClientGlobalSetting |
            Select-Object -ExpandProperty SuffixSearchList -ErrorAction SilentlyContinue |
            Where-Object { $_ } |
            ForEach-Object { $Targets.Add($_) }

        Get-DnsClient |
            Where-Object { $_.ConnectionSpecificSuffix } |
            ForEach-Object { $Targets.Add($_.ConnectionSpecificSuffix) }
    }
    catch {
        # Domain discovery is best-effort only.
    }

    return $Targets | Where-Object { $_ } | Sort-Object -Unique
}

function Get-DomainControllerTargets {
    param(
        [string[]]$DomainNames
    )

    $Targets = New-Object System.Collections.Generic.List[string]

    foreach ($DomainName in $DomainNames) {
        try {
            Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -ErrorAction Stop |
                Where-Object { $_.NameTarget } |
                ForEach-Object { $Targets.Add($_.NameTarget.TrimEnd('.')) }
        }
        catch {
            # SRV lookup can fail off-domain, off-VPN, or with public DNS. Continue collecting other evidence.
        }
    }

    return $Targets | Where-Object { $_ } | Sort-Object -Unique
}

function Invoke-PingTests {
    param(
        [string[]]$Targets
    )

    foreach ($Target in $Targets | Sort-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($Target)) {
            continue
        }

        Write-Output ""
        Write-Output "===== PING: $Target ====="

        try {
            Test-Connection -ComputerName $Target -Count 4 -ErrorAction Stop |
                Select-Object Address, IPV4Address, ResponseTime, StatusCode
        }
        catch {
            Write-Output "Ping failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-DnsTests {
    param(
        [string[]]$Names
    )

    foreach ($Name in $Names | Sort-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            continue
        }

        Write-Output ""
        Write-Output "===== DNS RESOLUTION: $Name ====="

        try {
            Resolve-DnsName -Name $Name -ErrorAction Stop |
                Select-Object Name, Type, TTL, IPAddress, NameHost, QueryType, Section
        }
        catch {
            Write-Output "DNS resolution failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-TcpTests {
    param(
        [string[]]$Targets
    )

    foreach ($Item in $Targets | Sort-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($Item)) {
            continue
        }

        $Parts = $Item.Split(":")
        if ($Parts.Count -ne 2 -or -not ($Parts[1] -as [int])) {
            Write-Output "Skipping invalid TCP target '$Item'. Use format hostname:port."
            continue
        }

        $HostName = $Parts[0]
        $Port = [int]$Parts[1]

        Write-Output ""
        Write-Output "===== TCP TEST: $HostName on port $Port ====="

        try {
            Test-NetConnection -ComputerName $HostName -Port $Port -InformationLevel Detailed
        }
        catch {
            Write-Output "TCP test failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-TraceTests {
    param(
        [string[]]$Targets
    )

    foreach ($Target in $Targets | Select-Object -First 5) {
        if ([string]::IsNullOrWhiteSpace($Target)) {
            continue
        }

        Write-Output ""
        Write-Output "===== TRACERT: $Target ====="
        tracert -d $Target
    }
}

function Get-WifiProfileSummary {
    $ProfilesRaw = netsh wlan show profiles 2>&1
    $ProfilesRaw

    $ProfileNames = $ProfilesRaw |
        Select-String -Pattern "All User Profile\s*:\s*(.+)$" |
        ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }

    foreach ($ProfileName in $ProfileNames) {
        Write-Output ""
        Write-Output "===== WI-FI PROFILE DETAILS: $ProfileName ====="
        netsh wlan show profile name="$ProfileName" 2>&1
    }
}

function Get-ProxySettings {
    Write-Output "===== WinHTTP Proxy ====="
    netsh winhttp show proxy

    Write-Output ""
    Write-Output "===== Current User Internet Settings Proxy Registry ====="
    Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" |
        Select-Object ProxyEnable, ProxyServer, AutoConfigURL, AutoDetect
}

function Get-NetworkEventLogs {
    $StartTime = (Get-Date).AddHours(-1 * $RecentEventHours)

    $Providers = @(
        "Microsoft-Windows-DNS-Client",
        "Microsoft-Windows-Dhcp-Client",
        "Microsoft-Windows-NetworkProfile",
        "Microsoft-Windows-WLAN-AutoConfig",
        "Microsoft-Windows-TCPIP",
        "Microsoft-Windows-NlaSvc"
    )

    foreach ($Provider in $Providers) {
        Write-Output ""
        Write-Output "===== Provider: $Provider ====="

        try {
            Get-WinEvent -FilterHashtable @{
                ProviderName = $Provider
                StartTime    = $StartTime
            } -ErrorAction Stop |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Format-List
        }
        catch {
            Write-Output "No events found or unable to read provider '$Provider': $($_.Exception.Message)"
        }
    }
}

Write-Log "Starting network diagnostic bundle"
Write-Log "Output folder: $OutputFolder"
Write-Log "Running as administrator: $(Test-IsAdmin)"

$GatewayTargets = @(Get-DefaultGatewayTargets)
$DomainTargets = @(Get-DomainDiagnosticTargets)
$DomainControllerTargets = @(Get-DomainControllerTargets -DomainNames $DomainTargets)
$AllDnsNames = @($DnsNames + $DomainTargets + $DomainControllerTargets) | Where-Object { $_ } | Sort-Object -Unique
$AllPingTargets = @($PingTargets + $GatewayTargets + $DomainTargets + $DomainControllerTargets) | Where-Object { $_ } | Sort-Object -Unique
$TraceTargets = @($GatewayTargets + "8.8.8.8" + ($AllDnsNames | Select-Object -First 4)) | Where-Object { $_ } | Sort-Object -Unique

# Consolidated reports. Keep this small so the ZIP is easy to review and attach to a ticket.
Save-CommandOutput -Name "00-HelpDesk-QuickRead" -ScriptBlock {
    $Os = Get-CimInstance Win32_OperatingSystem
    $Computer = Get-CimInstance Win32_ComputerSystem
    $Bios = Get-CimInstance Win32_BIOS
    $Uptime = (Get-Date) - $Os.LastBootUpTime

    Write-Output "Network Diagnostic Bundle Quick Read"
    Write-Output "===================================="
    Write-Output "Computer: $env:COMPUTERNAME"
    Write-Output "User: $env:USERDOMAIN\$env:USERNAME"
    Write-Output "Manufacturer/Model: $($Computer.Manufacturer) $($Computer.Model)"
    Write-Output "Serial Number: $($Bios.SerialNumber)"
    Write-Output "OS: $($Os.Caption) $($Os.Version) build $($Os.BuildNumber)"
    Write-Output "Uptime: $($Uptime.Days) days $($Uptime.Hours) hours $($Uptime.Minutes) minutes"
    Write-Output "Generated: $(Get-Date)"
    Write-Output "Running as admin: $(Test-IsAdmin)"
    Write-Output ""

    Write-Output "Active adapters:"
    Get-NetAdapter |
        Where-Object Status -eq "Up" |
        Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress |
        Format-Table -AutoSize

    Write-Output ""
    Write-Output "Gateway targets discovered: $($GatewayTargets -join ', ')"
    Write-Output "Domain/DNS suffix targets discovered: $($DomainTargets -join ', ')"
    Write-Output "Domain controller targets discovered: $($DomainControllerTargets -join ', ')"
    Write-Output "Ping test targets: $($AllPingTargets -join ', ')"
    Write-Output "DNS test names: $($AllDnsNames -join ', ')"
    Write-Output "TCP test targets: $($TcpTargets -join ', ')"
    Write-Output "Traceroute targets: $($TraceTargets -join ', ')"
}

Save-CommandOutput -Name "01-System-And-Adapters" -ScriptBlock {
    Write-Output "===== IPCONFIG /ALL ====="
    ipconfig /all

    Write-Output ""
    Write-Output "===== NETWORK ADAPTERS ====="
    Get-NetAdapter | Sort-Object Status, Name | Format-Table -AutoSize

    Write-Output ""
    Write-Output "===== CONNECTION PROFILES ====="
    Get-NetConnectionProfile | Format-List
}

Save-CommandOutput -Name "02-IP-DNS-Gateway-Routes" -ScriptBlock {
    Write-Output "===== NET IP CONFIGURATION ====="
    Get-NetIPConfiguration | Format-List

    Write-Output ""
    Write-Output "===== DNS SERVER ADDRESSES ====="
    Get-DnsClientServerAddress | Format-Table -AutoSize

    Write-Output ""
    Write-Output "===== ROUTE PRINT ====="
    route print
}

Save-CommandOutput -Name "03-PingTests" -ScriptBlock {
    Invoke-PingTests -Targets $AllPingTargets
}

Save-CommandOutput -Name "04-DnsResolutionTests" -ScriptBlock {
    Invoke-DnsTests -Names $AllDnsNames
}

Save-CommandOutput -Name "05-TcpConnectivityTests" -ScriptBlock {
    Invoke-TcpTests -Targets $TcpTargets
}

Save-CommandOutput -Name "06-TracerouteTests" -ScriptBlock {
    Invoke-TraceTests -Targets $TraceTargets
}

Save-CommandOutput -Name "07-Proxy-Firewall-Wifi-Events" -ScriptBlock {
    Write-Output "===== PROXY SETTINGS ====="
    Get-ProxySettings

    Write-Output ""
    Write-Output "===== FIREWALL PROFILES ====="
    Get-NetFirewallProfile |
        Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction, AllowInboundRules, AllowLocalFirewallRules |
        Format-Table -AutoSize

    Write-Output ""
    Write-Output "===== VPN-LIKE ADAPTERS ====="
    Get-NetAdapter |
        Where-Object {
            $_.InterfaceDescription -match "VPN|TAP|TUN|WireGuard|Cisco|AnyConnect|GlobalProtect|Fortinet|Palo Alto|Pulse|OpenVPN|Zscaler" -or
            $_.Name -match "VPN|TAP|TUN|WireGuard|Cisco|AnyConnect|GlobalProtect|Fortinet|Palo Alto|Pulse|OpenVPN|Zscaler"
        } |
        Format-List *

    Write-Output ""
    Write-Output "===== WI-FI PROFILES ====="
    Get-WifiProfileSummary

    Write-Output ""
    Write-Output "===== NETWORK EVENT LOGS ====="
    Get-NetworkEventLogs
}

Write-Log "Creating ZIP file"

try {
    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }

    Compress-Archive -Path (Join-Path $OutputFolder "*") -DestinationPath $ZipPath -Force
    Remove-Item -Path $OutputFolder -Recurse -Force
    Write-Log "ZIP created: $ZipPath"
}
catch {
    Write-Log "Failed to create ZIP: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Network diagnostic bundle complete." -ForegroundColor Green
Write-Host "ZIP:    $ZipPath"
