<#  
.SYNOPSIS
    Map SCEPman certificates to dummy devices in AD

.DESCRIPTION
    Combines the script to created dummy devices from Autopilot and the script that gets the certificates from
    Azure. Ensure all Autopilot devices are in AD as dummy devices and find the correct certificate serial
    and assign that as the altSecurityIdentity.

    When an identity is listed as "pending" for revoke status we will leave it there until there is a corresponding
    certificate with "none" as the revoke status. This might need tweaking depending on how certificate
    renewal works.

    Taken partly from Andrew Blackburn (https://sysmansquad.com/2021/04/27/working-around-nps-limitations-for-aadj-windows-devices/)

    SILENT VERSION, OUTPUT WILL BE SENT TO EVENT LOG

.NOTES
    Author: Phoebe Hurren and Roald Schutte
    Last Edit: 2023-01-10
    Version 1.0 - Created
#>


#$script:Silent = $true
# Tenatnt details - need to setup a app with Graph access to devices - and add a Secret - can also be done with a certificate using another function not in this script
$TenantId = ''
$clientID = ''
$clientSecret = ''

#AD server name or IP
$ADServer = '' 

# Get the Issuer details and go through each cert only saving the SCEPman and current ones
$SCEPmanIssuer = ''

#$groupTag = @('Shared Surface','Staff Surface Pro','Student Surface Pro') # Autopilot Devices Group Tag (All devices with a group tag set)
$groupTag = ''
$dummyComputersGroup = ''               # Group for NPS Group Policy (not DummyMachines)
$dummyComputersgroupDN = ''           # Distinguished Name for DummyComputers group for testing
$orgUnit = ''                     # OU for Dummy Computer

$ReportPath = ""  #report export path
$Report = (New-Object -TypeName System.Collections.Generic.List[Object]) 
$Filename = "" #Report file name

$webhook = "" #Webhook URL to Teams channel to receive updates from the script
Function Set-ReportPath([String]$Filename) {
    $date = Get-Date -Format "yyyyMMddHHmm"
    $script:ReportPath = "C:\temp\$($date)_$($Filename)"
    if (-not(Test-Path "C:\temp\")) { New-Item -Path "C:\" -Name "temp" -ItemType "directory" }
}


Function Get-TokenResponse {
    begin {
        $ReqTokenBody = @{
            Grant_Type    = "client_credentials"
            Scope         = "https://graph.microsoft.com/.default"
            client_Id     = $clientID
            Client_Secret = $clientSecret
        }
    }
    process {

        $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $ReqTokenBody

    }
    end {
        return $tokenResponse
    }
}

Function Get-CertificatesForIntuneDevices {
    [CmdletBinding()]
    param (
        [system.string]$accessToken
    )
    Begin {
        $headers = @{
            Authorization = "Bearer $accessToken"
        }
        $apiUrl = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurationsAllManagedDeviceCertificateStates"
    }
    Process {
        #$Data = Invoke-RestMethod @request
        $GroupMembersResponse = (Invoke-RestMethod -Uri $apiURL -Headers $headers -Method GET -ContentType "application/json") 
        $Members = $GroupMembersResponse.value
        $MembersNextLink = $GroupMembersResponse."@odata.nextLink"
        while ($MembersNextLink -ne $null) {

            $GroupMembersResponse = (Invoke-RestMethod -Uri $MembersNextLink -Headers $headers -Method Get -ContentType "application/json")
            $MembersNextLink = $GroupMembersResponse."@odata.nextLink"
            $Members += $GroupMembersResponse.value
        }
    }
    End {
        return $Members
    }
}

Function Get-ReversedSerial([String]$Serial) {
    # Get each byte in an array 
    $SerialArray = @()
    for ($idx = 0; $idx -lt $Serial.Length; $idx += 2) {
        $byte = $Serial.Substring($idx, 2)
        $SerialArray += $byte
    }

    # Reverse it
    [Array]::Reverse($SerialArray)

    # Turn it back into a string and output to user
    $ReversedSerial = $SerialArray -join ''
    return $ReversedSerial

}

#Get AutoPilot Devices
Function Get-AutoPilotDevicesUsingGraph {
    [CmdletBinding()]
    param (
        [system.string]$accessToken
    )
    Begin {
        $headers = @{
            Authorization = "Bearer $accessToken"
        }
        $apiUrl = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities"
    }
    Process {
        $GroupMembersResponse = (Invoke-RestMethod -Uri $apiURL -Headers $headers -Method GET -ContentType "application/json") 
        $Members = $GroupMembersResponse.value
        $MembersNextLink = $GroupMembersResponse."@odata.nextLink"
        while ($MembersNextLink -ne $null) {

            $GroupMembersResponse = (Invoke-RestMethod -Uri $MembersNextLink -Headers $headers -Method Get -ContentType "application/json")
            $MembersNextLink = $GroupMembersResponse."@odata.nextLink"
            $Members += $GroupMembersResponse.value
        }
    }
    End {
        return $Members
    }
}

Function Write-Msg {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [String]$Message,
        [Parameter(Mandatory = $False)][ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [String]$Level = 'INFO'
    )
    
    # Write it to Host or the Event Viewer
    if ($Silent) {
        # Check the Event Viewer source exists
        if (!([System.Diagnostics.EventLog]::SourceExists($LogSource))) {
            New-EventLog -LogName 'Application' -Source $LogSource -ErrorAction Continue
        }
        Write-EventLog -LogName 'Application' -Source $LogSource -EventID 9376 -EntryType $Level -Message $Message -Category 1
        
    }
    else {
        switch ($Level) {
            INFO { 
                Write-Host "$($Level): $Message" -ForegroundColor Magenta
                break
            }
            ERROR {
                Write-Host "$($Level): $($Message): $($Error)" -ForegroundColor Red
                $Error.Clear()
                break
            }
            WARNING {
                Write-Host "$($Level): $Message" -ForegroundColor Yellow
                break
            }
            SUCCESS {
                Write-Host "$($Level): $Message" -ForegroundColor Green
                break
            }
        }
    }
    return
}

Function Add-ReportLine([psCustomObject]$Line) {
    $Report.Add($Line)
}

Function Send-ToTeams() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [String]$Text,
        [Parameter(Mandatory = $False)]
        [String]$Title = "Powershell Script Alert"
    )

    # Send report to Teams
    $body = @{
        'Title' = $Title
        'Text'  = $Text
    }
    # convert to JSON params
    $Params = @{
        #Headers = @{'accept'='application/json'}
        ContentType = 'Application/Json'
        Body        = $body | ConvertTo-Json
        Method      = 'Post'
        URI         = $webhook 
    }
    try {
        # Send it to the Teams Channel
        Invoke-RestMethod @Params
    }
    catch {
        # Don't do anything
        Write-Msg "Error sending to Teams. $_." -Level ERROR
    }

}

Function Export-Report {
    try {
        if (!($script:Silent)) {
            $Report | Out-GridView
        }
        $Report | Export-Csv -Path $($script:ReportPath) -NoTypeInformation
    }
    catch {
        Write-Msg "Could not export report to $($script:ReportPath)" -Level ERROR
    }

    # Now we have exported it, clear it for the next use
    $script:Report.Clear()
}


function Get-IntuneDeviceByID {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]
        [string]$managedDeviceId,
        [Parameter(Mandatory)]
        [string]$accessToken
    )
    begin {
        $headers = @{
            Authorization = "Bearer $accessToken"
        }
        $apiUrl = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$managedDeviceId"
    }
    process {
        $authMethods = Invoke-RestMethod -Uri $apiURL -Headers $headers -Method GET
    }
    end {
        return $authMethods
    }
}


#Connect-ADServer
New-PSDrive -Name AD_DRIVE_NAME -PSProvider ActiveDirectory -Server $ADServer -Root "//RootDSE/" -Scope Global
Set-Location AD_DRIVE_NAME:

Set-ReportPath("DummyComputersCertMap.csv") # Initialise Report for telling the user what we did

# Get the header token for the Graph call
$TokenResponse = Get-TokenResponse

# Get device certificates from Graph - Beta Version
$AllCerts = Get-CertificatesForIntuneDevices -accessToken $TokenResponse.access_token
$Certificates = New-Object System.Collections.Generic.List[Object]

Write-Msg "Found $($AllCerts.count) certificates."
$idx = 0
#Build $Certificates by adding only the latest active unique certificates issued by SCEPman
foreach ($Cert in $AllCerts) {
    $idx++

    # Get the ones that have an issuer and that have SCEPman as the issuer and none as revoke status
    if (($null -ne $Cert.certificateIssuerName) -and ($Cert.certificateIssuerName.contains("SCEPman")) -and ($Cert.certificateRevokeStatus -eq 'none')) {
        # Reverse the certificate Serial
        $ReversedSerial = Get-ReversedSerial($Cert.certificateSerialNumber)
        # Add it to the alt security identity
        $altIdentity = "X509:<I>$($SCEPmanIssuer)<SR>$($ReversedSerial)"

        # Check if we already have one in the list
        $index = $Certificates.FindIndex({ $args[0].DisplayName -eq $Cert.managedDeviceDisplayName })
        if ($index -ne -1) {
            # We already have one with that display name, so get the most recent one
            if ($Certificates[$index].Expiry -lt $Cert.certificateExpirationDateTime) {
                # The one in the list is older, update it
                $Certificates[$index].altSecurityIdentity = $altIdentity
                $Certificates[$index].Expiry = $Cert.certificateExpirationDateTime
            }
            else {
                # The one in the list is the most recent one
                
            }
        }
        else {
            # Not already in the list, so add it
            $Line = [PSCustomObject]@{
                DisplayName         = $Cert.managedDeviceDisplayName
                altSecurityIdentity = $altIdentity
                Expiry              = $Cert.certificateExpirationDateTime
            }
            $Certificates.Add($Line)
        }       
    }
}
Write-Msg "Processed $idx of $($AllCerts.count) certificates. Found $($Certificates.count) current, non-duplicate SCEPman certificates."

# Connect to MSGraph and get Autopilot Devices 
if ($groupTag -ne "") {
    Write-Msg "Getting $groupTag devices from Autopilot..."
    $AutopilotDevices = Get-AutoPilotDevicesUsingGraph -accessToken $TokenResponse.access_token | Where-Object { $groupTag -ccontains $_.groupTag }
}
else {
    Write-Msg "Getting ALL devices from Autopilot..."
    $AutopilotDevices = Get-AutoPilotDevicesUsingGraph -accessToken $TokenResponse.access_token
}

# Initialise the text we send to Teams channel via Webhook
$text = ""

# Go through each Autopilot device and check we have a dummy object with the correct certificate serial
Write-Msg "Processing $($AutopilotDevices.count) Autopilot Devices."
$idx = 0
foreach ($Device in $AutopilotDevices) {
    $idx++

    # Get the Autopilot Device Data
    $DeviceID = $Device.azureActiveDirectoryDeviceId
    $SAM = $Device.azureActiveDirectoryDeviceId.Substring(0, 15)
    $Serial = $Device.serialNumber
    $inDevice = $null

    # Report line variables
    $created = ""
    $mapped = ""
    $group = ""

    # Check if we have a certificate for this device - Our devices is named acording to serialnumber
    $index = $Certificates.Where({ $_.DisplayName -contains "$($Serial)" })
    if ($index) {
        $altSecIdentity = $index.altSecurityIdentity
        $expiry = $index.Expiry

        # Check if the Dummy Computer Object already exists. If it doesn't, Get-ADComputer will fail and execution jumps to the catch{}
        try {
            $object = Get-ADComputer -Identity $SAM -Properties *  -ErrorAction Stop
            #Write-Msg "$DeviceID already exists."
            $created = "SKIP: Already exists"

            # If the object is enabled, perform some sanity checks
            if ($object.Enabled) {

                # Sanity check on full device ID in case it's just the first 15 characters of the Device ID (SAM = first 15 characters of Device ID) that match
                if (-not ($object.Name -eq $DeviceID)) {
                    $created = "ERROR: AD Computer Object exists with same SAM but different serial`n- Existing AD Object: $($object.Name)"

                }
                else {
                    if (!$object.memberOf -ccontains $dummyComputersgroupDN) {
                        $group = "WARNING: AD Computer Object exists but isn't in DummyComputers Group"
                        # Don't just put it in because we might have left it out for a reason. Let a human make the decision

                    }
                    else {
                        # Everything looks good, check if it has the most recent certificate
                        if (!($object.altSecurityIdentities -ccontains $altSecIdentity)) {
                            # Get the logged in user name - Only do this if we really have to, very time consuming
                            $inID = $Device.managedDeviceId
                            if ($inID) {
                                $inDevice = Get-IntuneDeviceByID -accessToken $TokenResponse.access_token -managedDeviceId $inID
                                if ($inDevice) {
                                    $Username = $inDevice.userDisplayName
                                }
                            }
                            # Current certificate doesn't match, update it
                            try {
                                Set-ADComputer -Identity $SAM -Clear 'altSecurityIdentities' -ErrorAction Stop
                                Set-ADComputer -Identity $SAM -Add @{'altSecurityIdentities' = "$altSecIdentity" } -ErrorAction Stop

                                if ($Serial) {
                                    $text += "    $($Serial.PadRight(16,' '))|    $($Username.PadRight(40,' ')) |    CERT UPDATED  `n"
                                }
                                else {
                                    $text += "       NO SERIAL     |    $($Username.PadRight(40,' ')) |    CERT UPDATED  `n"
                                }
                                $mapped = "DONE"
                            }
                            catch {
                                # Updating the cert failed
                                if ($Serial) {
                                    $text += "    $($Serial.PadRight(16,' '))|    $($Username.PadRight(40,' ')) |    CERT UPDATE FAILED   `n"
                                }
                                else {
                                    $text += "     NO SERIAL      |    $($Username.PadRight(40,' ')) |    CERT UPDATE FAILED   `n"
                                }
                                $mapped = "ERROR: Failed to updated altSecurityIdentity"
                            }
                        }
                        else {
                            # Current certificate matches
                            $mapped = "SKIP: Current certificate matches. Expires $expiry"

                            # If it will try to renew soon, let us know
                            if ((New-TimeSpan -Start (Get-Date).ToUniversalTime() -End $expiry).Days -eq 36) {
                                # Get the logged in user name - Only do this if we really have to, very time consuming
                                $inID = $Device.managedDeviceId
                                if ($inID) {
                                    $inDevice = Get-IntuneDeviceByID -accessToken $TokenResponse.access_token -managedDeviceId $inID
                                    if ($inDevice) {
                                        $Username = $inDevice.userDisplayName
                                    }
                                }
                                if ($Serial) {
                                    $text += "    $($Serial.PadRight(16,' '))|    $($Username.PadRight(40,' ')) |    CERT UPDATING SOON   `n"
                                }
                                else {
                                    $text += "        NO SERIAL     |    $($Username.PadRight(40,' ')) |    CERT UPDATING SOON   `n"
                                }
                            }
                        }
                    }
                }
            }
            else {
                # Maybe they don't realise it is there and disabled so let them know
                $created = "WARNING: AD Computer Object exists but is DISABLED"
            }

        }
        catch {
            # Create new AD Computer Object
            try {
                New-ADComputer -Name $DeviceID -SAMAccountName "$SAM`$" -ServicePrincipalNames "HOST/$DeviceID" -Path $orgUnit -ErrorAction Stop
                Write-Msg "Computer Object $DeviceID created." -Level SUCCESS
                $created = "DONE"

                # Perform Name Mapping and add Serial Number as Description
                try {
                    Set-ADComputer -Identity $SAM -Description $Serial -Add @{'altSecurityIdentities' = "$altSecIdentity" } -ErrorAction Stop                
                    $mapped = "DONE"
                }
                catch {
                    #Write-Msg "Name Mapping failed - $DeviceID" -Level ERROR
                    $mapped = "ERROR: Failed to updated altSecurityIdentity"
                }

                # Add Dummy Computer to the DummyComputer Group
                try {
                    Add-ADGroupMember -Identity $dummyComputersGroup -Members "$SAM`$" -ErrorAction Stop
                    $group = "DONE"
                }
                catch {
                    $group = "ERROR: Failed to add device object to group"
                }

                # Creating Computer Object failed
            }
            catch {
                $created = "ERROR: Failed to created computer object"
            }
        }
    }
    else {
        # No cert found for this device
        $created = "ERROR: No certificate found for device"
    }

    # Add it to the report
    $Line = [PSCustomObject] @{
        Name    = $DeviceID
        SAM     = $SAM
        Serial  = $Serial
        Created = $created
        Mapped  = $mapped
        Group   = $group
        Sync    = ""
    }
    Add-ReportLine($Line)
}
Write-Msg "Processed $idx of $($AutopilotDevices.count) Autopilot Devices."

# Find any Computer Objects in AD that are no longer in Autopilot and flag them
Write-Msg "Comparing AD Computer Objects with Autopilot Devices"
#$AllAutopilotDevices.Count = Get-AutopilotDevice
$AllAutopilotDevices = Get-AutoPilotDevicesUsingGraph -accessToken $TokenResponse.access_token
$DummyComputers = Get-ADComputer -Filter * -SearchBase $orgUnit -Properties * | Select-Object Name, SAMAccountName, Description
foreach ($Computer in $DummyComputers) {
    # Refresh all the data
    $DeviceID = $Computer.Name
    $SAM = $Computer.SAMAccountName
    $Serial = $Computer.Description
    $sync = ""

    # Look for the AD Computer Object in our Autopilot Devices
    if (-not ($AllAutopilotDevices.azureActiveDirectoryDeviceId -contains $DeviceID)) {
        # Not found so just tell the user about it
        $sync = "WARNING: Computer Object in AD but not in Autopilot Devices."
        if ($Serial) {
            $text += "    $($Serial.PadRight(16,' '))|    $($DeviceID.PadRight(40,' ')) |    IN AD BUT NOT AP   `n"
        }
        else {
            $text += "    NO SERIAL         |    $($DeviceID.PadRight(40,' ')) |    IN AD BUT NOT AP   `n"
        }

        # Add it to the report
        $Line = [PSCustomObject] @{
            Name    = $DeviceID
            SAM     = $SAM
            Serial  = $Serial
            Created = ""
            Mapped  = ""
            Group   = ""
            Sync    = $sync
        }
        Add-ReportLine($Line)
    }
}

if ($text -ne "") {
    # Setup text to send to Teams
    $headertext = "    SERIAL          |    USER/COMPUTER NAME                                |    STATUS              `n"
    $headertext += "    ------------------------------------------------------------------------------------------ `n"
    $headertext += $text
    "DONE"
    Send-ToTeams -Text $headertext -Title "Devices in AD but not in AutoPilot"
}

# Export the report
Export-Report

#Disconnect-ADServer
Remove-PSDrive -Name AD_DRIVE_NAME
