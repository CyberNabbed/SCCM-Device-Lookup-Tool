<#
    .SYNOPSIS
    Quick SCCM Asset Lookup Tool

    .DESCRIPTION
    A tool to look up device Serial Numbers by Hostname or Primary User.
    Uses the AdminService API to avoid loading the full Configuration Manager console.
    
    .NOTES
    Make sure the you at least have  'Read' rights on the SMS Collection.
#>

#requires -Version 5.1 
[CmdletBinding()] 
param( 
    # TODO: UPDATE THESE TWO VARIABLES FOR YOUR ENVIRONMENT
    [string]$Provider = "YOUR_SMS_PROVIDER_FQDN", # e.g. sccm01.contoso.com
    [string]$SiteCode = "XYZ"                     # e.g. P01
) 

# Make the base URL for the WMI-over-HTTP service
$BaseUrl = "https://$Provider/AdminService/wmi" 

#Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 

# --------------------------
# HELPER FUNCTIONS
# --------------------------

function Invoke-AdminServiceQuery { 
    <#
    .SYNOPSIS
    Wrapper for the REST call to handle the URL construction and authentication.
    #>
    param( 
        [Parameter(Mandatory)] [string]$Class, 
        [string]$Filter, 
        [string]$Select 
    ) 

    $uri = "$BaseUrl/$Class" 
    
    # Build the query string components if parameters were passed
    $queryParams = @() 
    if ($Filter) { $queryParams += "`$filter=$([uri]::EscapeDataString($Filter))" } 
    if ($Select) { $queryParams += "`$select=$Select" } 
    
    # Join them with '&' if we have any
    if ($queryParams.Count -gt 0) { 
        $uri += "?" + ($queryParams -join "&") 
    } 

    # We use -UseDefaultCredentials to leverage the running user's AD token
    Invoke-RestMethod -Method GET -Uri $uri -UseDefaultCredentials -ErrorAction Stop 
} 

function Get-DeviceCandidatesByQuery { 
    <#
    .SYNOPSIS
    Finds devices doing a "fuzzy" search on the name.
    #>
    param([Parameter(Mandatory)] [string]$Query) 

    # Sanitize input for OData (single quotes need to be doubled)
    $sanitizedQuery = $Query.Replace("'", "''") 

    # 'SMS_R_System' is the main discovery class. We just need the ID and Name.
    $resp = Invoke-AdminServiceQuery -Class "SMS_R_System" -Filter "contains(Name,'$sanitizedQuery')" -Select "Name,ResourceId" 
    
    # Return as an array, even if only one result
    @($resp.value) 
} 

function Get-SerialByResourceId { 
    <#
    .SYNOPSIS
    Looks up the BIOS serial number from Hardware Inventory using the Resource ID.
    #>
    param([Parameter(Mandatory)] [int]$ResourceId) 

    $resp = Invoke-AdminServiceQuery -Class "SMS_G_System_PC_BIOS" -Filter "ResourceId eq $ResourceId" -Select "SerialNumber" 
    $row = @($resp.value) | Select-Object -First 1 
    
    if ($row) { return $row.SerialNumber } 
    return $null 
} 

function Show-SelectionMenu { 
    <#
    .SYNOPSIS
    If we get multiple hits (like searching "Lab-01"), let the user pick one.
    #>
    param( 
        [Parameter(Mandatory)] [array]$Items, 
        [Parameter(Mandatory)] [scriptblock]$DisplayProperty 
    ) 

    # If there's only one item, just return it. No need to bug the user.
    if ($Items.Count -le 1) { return ,@($Items) } 

    Write-Host "" 
    Write-Host "I found multiple matches. Which one did you mean?" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Items.Count; $i++) { 
        # Defines how the list looks (Index number -> Item Name)
        Write-Host (" [{0}] {1}" -f $i, (& $DisplayProperty $Items[$i])) 
    } 

    $choice = Read-Host "`nEnter the number to select one, or 'A' to grab them all" 
    
    if ($choice -match '^[Aa]$') { return ,$Items } 
    if ($choice -match '^\d+$') { 
        $idx = [int]$choice 
        if ($idx -ge 0 -and $idx -lt $Items.Count) { return ,@($Items[$idx]) } 
    } 
    
    throw "That selection wasn't valid. Please try again." 
} 

function Get-SafeProperty { 
    # Helper to check if a property exists on an object before trying to read it
    # This prevents errors when the API returns slightly different objects
    param($Obj, [string[]]$Names) 
    foreach ($n in $Names) { 
        if ($Obj.PSObject.Properties.Name -contains $n) { return $Obj.$n } 
    } 
    return $null 
} 

# --------------------------
# MAIN APPLICATION LOOP
# --------------------------

while ($true) { 
    Clear-Host 
    Write-Host "=============================================" -ForegroundColor Cyan 
    Write-Host "      SCCM Asset Lookup Tool" -ForegroundColor Cyan 
    Write-Host "=============================================" 
    Write-Host "How do you want to search?" 
    Write-Host " 1) Computer Name (e.g. 'Accounting-PC')" 
    Write-Host " 2) Primary User (e.g. 'jsmith')" 
    Write-Host "" 
      
    $mode = Read-Host "Select 1, 2, or just press Enter to quit" 
      
    # Exit condition
    if ([string]::IsNullOrWhiteSpace($mode)) { 
        Write-Host "Thanks for using the tool. Goodbye!" -ForegroundColor Green
        break 
    } 

    try { 
        if ($mode -notin @('1','2')) { throw "Please just type 1 or 2." } 

        # --- OPTION 1: SEARCH BY HOSTNAME --- 
        if ($mode -eq '1') { 
            $query = Read-Host "Enter the computer name (partial names represent okay)" 
            if ([string]::IsNullOrWhiteSpace($query)) { throw "I can't search for an empty name." } 

            Write-Host "Searching..." -ForegroundColor DarkGray
            $candidates = Get-DeviceCandidatesByQuery -Query $query 
            
            if ($candidates.Count -eq 0) { 
                Write-Warning "No devices found matching '$query'." 
            } 
            else { 
                # Sort alphabetically to make the list easier to read
                $candidates = $candidates | Sort-Object Name 
                $picked = Show-SelectionMenu -Items $candidates -DisplayProperty { param($x) "$($x.Name)" } 

                $results = foreach ($dev in $picked) { 
                    $serial = Get-SerialByResourceId -ResourceId $dev.ResourceId 
                    if (-not $serial) { $serial = "N/A (Not in Hardware Inventory)" } 

                    [pscustomobject]@{ 
                        Hostname     = $dev.Name 
                        SerialNumber = $serial 
                    } 
                } 
                
                Write-Host "`nResults:" -ForegroundColor Green
                $results | Format-Table -AutoSize 
            } 
        } 

        # --- OPTION 2: SEARCH BY USERNAME --- 
        elseif ($mode -eq '2') { 
            $user = Read-Host "Enter the username (e.g. jdoe)" 
            if ([string]::IsNullOrWhiteSpace($user)) { throw "I need a username to search for." } 

            $u = $user.Replace("'", "''") 
            $filter = "contains(UniqueUserName,'$u')" 
            
            Write-Host "Looking up relationships..." -ForegroundColor DarkGray
            
            # Query the User/Machine relationship mapping class
            $relResp = Invoke-AdminServiceQuery -Class "SMS_UserMachineRelationship" -Filter $filter 
            $rels = @($relResp.value) 

            if ($rels.Count -eq 0) { 
                Write-Warning "I couldn't find any machines assigned to '$user'." 
            } 
            else { 
                # Filter down to "Primary User" if possible, otherwise show all associations
                $primary = $rels | Where-Object { 
                    $ipu = Get-SafeProperty $_ @('IsPrimaryUser') 
                    if ($null -ne $ipu) { return [bool]$ipu } 
                    return $true 
                } 
                # If they have no primary device, fall back to showing whatever they have logged into
                if ($primary.Count -eq 0) { $primary = $rels } 

                # Extract the machine names and IDs from the relationship objects
                $devices =  
                    $primary | ForEach-Object { 
                        $name = Get-SafeProperty $_ @('ResourceName','MachineName','MachineResourceName','ComputerName','Name') 
                        $rid  = Get-SafeProperty $_ @('ResourceId','ResourceID','MachineResourceId','MachineResourceID') 

                        if ($name -or $rid) { 
                            [pscustomobject]@{ 
                                Name       = $name 
                                ResourceId = if ($rid) { [int]$rid } else { $null } 
                            } 
                        } 
                    } | Where-Object { $_ } | 
                    Sort-Object -Property ResourceId, Name -Unique 

                if ($devices.Count -eq 0) { 
                    Write-Warning "I found the user, but couldn't link them to a specific computer object." 
                } 
                else { 
                    $pickedDevices = Show-SelectionMenu -Items $devices -DisplayProperty { param($x) "$($x.Name)" } 

                    $results = foreach ($dev in $pickedDevices) { 
                        $serial = $null 
                        if ($dev.ResourceId) { 
                            $serial = Get-SerialByResourceId -ResourceId $dev.ResourceId 
                        } 
                        if (-not $serial) { $serial = "N/A (Not in Hardware Inventory)" } 

                        [pscustomobject]@{ 
                            Hostname     = $dev.Name 
                            SerialNumber = $serial 
                        } 
                    } 
                    Write-Host "`nResults:" -ForegroundColor Green
                    $results | Format-Table -AutoSize 
                } 
            } 
        } 

    } catch { 
        # Generic error catching to keep the script from crashing hard
        Write-Host "" 
        Write-Host ("Oops, something went wrong: {0}" -f $_.Exception.Message) -ForegroundColor Red 
    }   
 
    Write-Host "" 
    Read-Host "Press Enter to return to the main menu..." | Out-Null 
}
