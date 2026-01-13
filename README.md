# SCCM Quick Asset Lookup

I wrote this script because I was tired of waiting 5 minutes for the full Configuration Manager console to load just to look up a serial number for a machine.

This tool runs in a standard PowerShell window. It hits the **AdminService** API directly (WMI over HTTPS), effectively bypassing the console to get you data instantly.

## What it does
1.  **Search by Hostname:** You can type part of a name (e.g., `HR-Laptop`) and it will find all matches.
2.  **Search by Username:** You can type a username (e.g., `bjones`) and it will find their Primary Device.
3.  **Gets Serial Numbers:** Once it finds the device, it pulls the BIOS Serial Number from the hardware inventory.

## Prerequisites
* **PowerShell 5.1** (Standard on Windows 10/11).
* **Permissions:** You must have at least **Read** permissions to the Collections in SCCM. If you can see the device in the console, you can see it here.
* **Network:** You need to be on the internal network or VPN (able to reach the SCCM server).

## Setup
You need to edit the top of the script with your specific server details before running it.

Open the script and look for lines 15-16:

```powershell
[string]$Provider = "YOUR_SMS_PROVIDER_FQDN", # Put your server name here
[string]$SiteCode = "XYZ"                     # Put your Site Code here (e.g. PS1)
