# Network Diagnostic Bundle

## Description

`Network-Diagnostic-Bundle.ps1` collects Windows network diagnostics into a single ZIP for help desk tickets. It checks adapters, IP/DNS/gateway settings, domain targets, ping, DNS resolution, TCP ports, traceroute, proxy, firewall, Wi-Fi, and recent network events.

The script automatically discovers useful local and domain-related targets, including the active default gateway, DNS suffixes, joined domain name, and domain controllers when available. It then runs ping, DNS resolution, TCP connectivity, and traceroute tests against those targets and saves the results in a compact set of report files.

The script creates a temporary working folder, compresses the reports into a ZIP file, and removes the uncompressed folder when complete. The final output is a single ZIP file that can be attached to a help desk ticket.

---

## What the Script Collects

The ZIP file contains 8 consolidated reports:

```text
00-HelpDesk-QuickRead.txt
01-System-And-Adapters.txt
02-IP-DNS-Gateway-Routes.txt
03-PingTests.txt
04-DnsResolutionTests.txt
05-TcpConnectivityTests.txt
06-TracerouteTests.txt
07-Proxy-Firewall-Wifi-Events.txt
```

### 00-HelpDesk-QuickRead.txt

A summary file intended for quick review by help desk staff. It includes:

* Computer name
* Logged-in user
* Manufacturer and model
* Serial number
* Operating system version
* Uptime
* Whether the script was run as administrator
* Active network adapters
* Discovered gateway, domain, DNS, and domain controller targets
* Ping, DNS, TCP, and traceroute target lists

### 01-System-And-Adapters.txt

Includes system and adapter details such as:

* `ipconfig /all`
* Network adapter status
* Adapter descriptions
* Link speed
* MAC addresses
* Network connection profiles

### 02-IP-DNS-Gateway-Routes.txt

Includes network configuration and routing information:

* IP address configuration
* DNS server addresses
* Default gateways
* Route table using `route print`

### 03-PingTests.txt

Runs ping tests against:

* Local loopback address
* Public DNS targets
* Active default gateway
* Discovered domain/DNS suffix targets
* Discovered domain controllers, when available
* Any custom ping targets provided when running the script

### 04-DnsResolutionTests.txt

Runs DNS resolution tests against:

* Default public names
* Discovered domain/DNS suffix targets
* Discovered domain controllers
* Any custom DNS names provided when running the script

### 05-TcpConnectivityTests.txt

Runs TCP port tests against configured targets, such as:

* `google.com:443`
* `microsoft.com:443`
* Any custom host and port combinations provided when running the script

This is useful for checking whether a device can reach web services, file shares, domain services, or internal applications.

### 06-TracerouteTests.txt

Runs traceroute tests against:

* Active default gateway
* `8.8.8.8`
* Selected DNS/domain targets

This helps identify where network traffic may be stopping or slowing down.

### 07-Proxy-Firewall-Wifi-Events.txt

Collects supporting network details such as:

* WinHTTP proxy settings
* Current user proxy registry settings
* Windows Firewall profile status
* VPN-like adapters
* Wi-Fi profile information
* Recent network-related Windows event logs

---

## Requirements

* Windows 10 or Windows 11
* PowerShell 5.1 or later
* Standard user permissions for basic diagnostics
* Administrator permissions recommended for the most complete results

The script can run without administrator rights, but some event log or system details may be limited.

---

## Basic Usage

Open PowerShell and run:

```powershell
.\Network-Diagnostic-Bundle.ps1
```

By default, the script saves the ZIP file to the current user's Desktop.

Example output path:

```text
C:\Users\username\Desktop\Network-Diagnostic-Bundle-COMPUTERNAME-20260101-120000.zip
```

---

## Recommended Help Desk Usage

For best results, run PowerShell as administrator:

1. Right-click PowerShell.
2. Select **Run as administrator**.
3. Browse to the folder containing the script.
4. Run the script.
5. Attach the generated ZIP file to the ticket.

---

## Custom Test Targets

You can provide custom ping, DNS, and TCP targets.

```powershell
.\Network-Diagnostic-Bundle.ps1 `
  -PingTargets "8.8.8.8","fileserver01","dc01.company.local" `
  -DnsNames "company.local","intranet.company.local" `
  -TcpTargets "intranet.company.local:443","fileserver01:445","dc01.company.local:389"
```

### Common TCP Ports for Troubleshooting

```text
443  HTTPS / web applications
445  SMB file shares
3389 Remote Desktop
389  LDAP
636  LDAPS
53   DNS
88   Kerberos
```

---

## Parameters

### -PingTargets

Specifies additional devices or hostnames to ping.

Default values:

```powershell
"127.0.0.1", "8.8.8.8", "1.1.1.1"
```

The script also automatically adds discovered gateways, domain targets, and domain controllers.

### -DnsNames

Specifies DNS names to resolve.

Default values:

```powershell
"google.com", "microsoft.com"
```

The script also automatically adds discovered domain and DNS suffix targets.

### -TcpTargets

Specifies TCP connectivity tests in `hostname:port` format.

Default values:

```powershell
"google.com:443", "microsoft.com:443"
```

Example:

```powershell
-TcpTargets "fileserver01:445","intranet.company.local:443"
```

### -OutputRoot

Specifies where the ZIP file should be created.

Default:

```powershell
$env:USERPROFILE\Desktop
```

Example:

```powershell
.\Network-Diagnostic-Bundle.ps1 -OutputRoot "C:\Temp"
```

### -RecentEventHours

Specifies how many hours of recent network-related event logs to collect.

Default:

```powershell
24
```

Example:

```powershell
.\Network-Diagnostic-Bundle.ps1 -RecentEventHours 48
```

---

## Example Scenarios

### User cannot access the internet

Run the default script:

```powershell
.\Network-Diagnostic-Bundle.ps1
```

Review:

* `03-PingTests.txt`
* `04-DnsResolutionTests.txt`
* `06-TracerouteTests.txt`
* `07-Proxy-Firewall-Wifi-Events.txt`

### User cannot access file shares

Run with file server and SMB port checks:

```powershell
.\Network-Diagnostic-Bundle.ps1 `
  -PingTargets "fileserver01" `
  -DnsNames "fileserver01.company.local" `
  -TcpTargets "fileserver01:445"
```

Review:

* `03-PingTests.txt`
* `04-DnsResolutionTests.txt`
* `05-TcpConnectivityTests.txt`

### User cannot reach internal apps over VPN

Run with internal app and domain controller targets:

```powershell
.\Network-Diagnostic-Bundle.ps1 `
  -PingTargets "dc01.company.local","intranet.company.local" `
  -DnsNames "company.local","intranet.company.local" `
  -TcpTargets "dc01.company.local:389","intranet.company.local:443"
```

Review:

* `00-HelpDesk-QuickRead.txt`
* `02-IP-DNS-Gateway-Routes.txt`
* `05-TcpConnectivityTests.txt`
* `06-TracerouteTests.txt`
* `07-Proxy-Firewall-Wifi-Events.txt`

---

## Notes and Limitations

* Some networks block ICMP, so failed ping tests do not always mean the target is offline.
* Some firewalls block traceroute traffic, so traceroute results may be incomplete.
* Domain controller discovery depends on DNS SRV lookup availability.
* If the device is off VPN or using public DNS, internal domain lookups may fail.
* The script collects diagnostics only; it does not make network changes or attempt repairs.

---

## Suggested Ticket Note

Use this note when attaching the ZIP to a ticket:

```text
Attached network diagnostic bundle collected from the affected workstation. The bundle includes system/network configuration, gateway/domain discovery, ping tests, DNS resolution tests, TCP connectivity tests, traceroute results, proxy/firewall details, Wi-Fi information, and recent network-related event logs.
```
