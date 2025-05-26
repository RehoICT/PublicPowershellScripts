<#  
.SYNOPSIS
Create new customer accounts (Parent)

.DESCRIPTION
Create new customer accounts in external ID via TASS API then add account in TASS for SAML login
    
.NOTES
Author: Rehobohth Christian College 
Version 1 

TODO compare and remove non-current customer accounts
#>


Import-Module TassApiFunctions
Install-Module Microsoft.Graph

#Tass Variables
$StudentTokenKey = "YourStudentTokenKey" #Replace with your TASS Student Token Key
$StudentApiVersion = "3" #Replace with your TASS Student API Version
$StudentAppCode = "YourStudentAppCode" #Replace with your TASS Student App - API12 by default 
$IdMTokenKey = "YourIdM TokenKey" #Replace with your TASS IDM Token Key
$IdMAppCode = "YourIdMAppCode" #Replace with your TASS IDM App Code
$IdMApiVersion = "3" #Replace with your TASS IDM API Version - API23 by default
$Endpoint = "https://school.domain.tass.cloud/tassweb/api/" #Replace with your TASS API Endpoint

#External ID Variables
$EntraExternalIDTenantId = "ExternalIDTenantId" #Replace with your Entra External ID Directory ID
$ExternalIDParentgGroupId = "ExternalIDParentgGroupId" #Replace with your Entra External ID Parent Group ID
$Issuer = "domain.onmicrosoft.com" #Replace with your Entra External ID dmoain


#Tass Functions

#Encypt Tass token
#This function encrypts the parameters using the TASS encryption token key.
#https://github.com/TheAlphaSchoolSystemPTYLTD/api-introduction/blob/master/EncryptDecrypt.ps1
function Get-TASSEncryptedToken($TokenKey, $Parameters) {
    # Convert encryption token from Base64 encoding to byte array.
    $keyArray = [System.Convert]::FromBase64String($TokenKey)

    # Store the string to be encrypted as a byte array.
    $toEncryptArray = [System.Text.Encoding]::UTF8.GetBytes($Parameters)

    # Create a cryptography object with the necessary settings.
    $rDel = New-Object System.Security.Cryptography.RijndaelManaged
    $rDel.Key = $keyArray
    $rDel.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $rDel.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $rDel.BlockSize = 128;

    # Encrypt, return as a byte array, and convert to a Base 64 encoded string. 
    $cTransform = $rDel.CreateEncryptor($keyArray, $null)
    [byte[]]$resultArray = $cTransform.TransformFinalBlock($toEncryptArray, 0, $toEncryptArray.Length)
    $resultBase64 = [System.Convert]::ToBase64String($resultArray, 0, $resultArray.Length)

    # Return as Base 64 encoded string. 
    return $resultBase64
}

#Get current students' communications
#https://github.com/TheAlphaSchoolSystemPTYLTD/student-details/blob/master/getCommunicationRulesDetails.md
function Get-TassCurrentStudentsCommunications {
    [CmdletBinding()]
    param (
        [system.string]$comm_type = "tkco",
        [system.string]$status = "current"
    )
    # Define the API endpoint.
    $parameters = "{ 'currentstatus':'$status',
                     'commtype':'$comm_type'}"
    $Method = 'getCommunicationRulesDetails'
    
    # Encrypt the token.
    $encryptedToken = Get-TASSEncryptedToken -tokenKey $StudentTokenKey -parameters $parameters
   
    # Build the request body
    $body = @{
        method  = $Method
        appcode = $StudentAppCode
        company = $CompanyCode
        v       = $StudentApiVersion
        token   = $encryptedToken
    }
   
    # Invoke REST request
    return (Invoke-RestMethod -Method GET -Uri $Endpoint -Body $body -ContentType "application/json").commrules
}

#Add parent email to Tass Parent Lounge SAML
#https://github.com/TheAlphaSchoolSystemPTYLTD/IdM/blob/master/SetParent.md
function Set-IdmParentEmail {
    [CmdletBinding()]
    param (
        [system.string]$user_code,
        [system.string]$username
    )
    $parameters = "{
                        'user_code':'$user_code',
                        'username':'$username'
                    }"
                    
    $Method = "setParent"

    # Encrypt the token.
    $encryptedToken = Get-TASSEncryptedToken -tokenKey $IdMTokenKey -parameters $parameters
   
    # Build the request body
    $body = @{
        method  = $Method
        appcode = $IdMAppCode
        company = $CompanyCode
        v       = $IdMApiVersion
        token   = $encryptedToken
    }
   
    # Invoke REST request
    return Invoke-RestMethod -Method GET -Uri $Endpoint -Body $body -ContentType "application/json"
}


#Get all parent emails flagged with teacher kiosk correspondance
$ParentsBronze = Get-TassCurrentStudentsCommunications -comm_type "tkco"  #gen

#Seprate mother and father emails from atomic families
$ParentsSilver = New-Object -TypeName System.Collections.Generic.List[Object]
#Seperate parents' emails
foreach ($parent_a in ($ParentsBronze)) {
    foreach ($addresses in $parent_a.addresses) {  
    
        $record = $null
        $record = [PSCustomObject] @{      
       
            "DisplayName" = $addresses.m_first_name + " " + $addresses.m_surname
            "Email"       = $addresses.email
            "Parent_ID"   = $addresses.parent_code
            "Student_id"  = $parent_a.studcode
        }
        $ParentsSilver.Add($record)

        $record = $null
        $record = [PSCustomObject] @{      
       
            "DisplayName" = $addresses.f_first_name + " " + $addresses.f_surname
            "Email"       = $addresses.email_2
            "Parent_ID"   = $addresses.parent_code
            "Student_id"  = $parent_a.studcode
        }
        $ParentsSilver.Add($record)
    }
    
}

#Remove duplicates, main tentant emails (As we sync this with cross tenant sync) and emails that are from DCP
$ParentsGold = $ParentsSilver | Where-Object { $_.Email -notlike "*rehoboth*" -and $_.Email -notlike "" -and $_.Email -notlike "*communities.wa.gov.au" } | Sort-Object -Property Email -Unique 
#Export to Excel for review
$ParentsGold | Export-Excel "C:\temp\Azure\ExternalID\$(Get-Date -Format "yyyyMMddHHmm")_CustomerCreationLog.xlsx" -NoNumberConversion *

#Check if we have any parents to create
if ($ParentsGold.Count -gt 1) {
    Write-Output -Message "$($ParentsGold.Count) Accounts retrieved from Tass" 
}
else {
    Write-Output "No user retreived from external ID" 
    exit
}

#Connect to External ID Graph
Connect-MgGraph -TenantId $EntraExternalIDTenantId -Scopes 'User.ReadWrite.All','UserAuthenticationMethod.ReadWrite.All'

#Get all emails external ID users
$ExternalIDAccounts = Get-MgUser -All | Select-Object Mail
if ($ExternalIDAccounts.Count -gt 1) {
    Write-Output -Message "$($ExternalIDAccounts.Count) Accounts retrieved from External ID" 
}
else {
    Write-Output "No user found in external ID"
    exit
}

#Create a list to log created users
$CreatedUserLog = New-Object -TypeName System.Collections.Generic.List[Object]

#Loop and create missing accounts
ForEach ($Account in ($ParentsGold)) {
    $PasswordProfile = $null
    $Identities = $null
    $UserParams = $null
    $user = $null
    $Exist = $null
    $password = $null
    $Tassstatus = $null

    #Check if email is in external ID - create it if not
    $Exist = $ExternalIDAccounts | Where-Object { $_.Mail -eq $Account.Email }
    
    if ($Exist) {
        Write-Output -Message "$($Account.Email) Account already exist"
    }
    else {
        #Get random password from https://password.ninja/api
        $password = ((Invoke-WebRequest -Uri "https://password.ninja/api/password?animals=false&colours=true&food=true&capitals=true&symbols=true" | Select-Object -ExpandProperty content) -replace "[] []", "").split(",").replace('"', '')
        
        #Create password profile
        $PasswordProfile = @{
            Password                             = $password
            ForceChangePasswordNextSignIn        = $True         
            ForceChangePasswordNextSignInWithMfa = $True
        }

        $Identities = @{
            SignInType       = "emailAddress"
            Issuer           = $Issuer
            IssuerAssignedId = $Account.Email
        }

        # Create Microsoft External ID customer account
        $UserParams = @{
            DisplayName     = $Account.DisplayName
            mail            = $Account.Email
            PasswordProfile = $PasswordProfile
            AccountEnabled  = $true
            Identities      = $Identities 
        }
        Write-Output -Message "Creating Account for $($Account.Email) " 
        $user = New-MgUser @UserParams 
        
        #Wait a couple of secods for the account to be created
        Start-Sleep -Seconds 2

        #Add email authentication method
        $paramsEmailAuth = $null
        $paramsEmailAuth = @{
            emailAddress = $user.Mail
        }
        New-MgUserAuthenticationEmailMethod -UserId $user.id -BodyParameter $paramsEmailAuth


        $status = $null
        if ($user) {
            #Add parent to parent group in External ID
            try {
                Write-Output -Message "$($Account.Email) Account created successfully" 
                New-MgGroupmember -GroupId $ExternalIDParentgGroupId  -DirectoryObject $user.id 
                $status = "Success"
                
                #Set SAML in Tass IDP
                try {
                    $Tassstatus = Set-IdmParentEmail -user_code $Account.Parent_ID -username $Account.Email
                }
                catch {
                    $Tassstatus = "Failed"
                    Write-Output -Message "$($Account.Email) Account not created in TASS -Failed $_"
                }
            }
            catch {
                $status = "Failed"
                Write-Output -Message "$($Account.Email) Account not added to group -Failed $_" 
            }
        
        }
        else {
            $status = "Failed"
            Write-Output -Message "$($Account.Email) Account not created in External ID -Failed " 
        }
        
        #Log status
        $line = $null
        $line = [PSCustomObject] @{      
       
            "Account"           = $UserParams.DisplayName
            "DisplayName"       = $user.DisplayName
            "Id"                = $user.Id
            "Mail"              = $Account.Email
            "UserPrincipalName" = $user.UserPrincipalName
            "Status"            = $status
            "Pass"              = $password
            "ParentID"          = $Account.Parent_ID
            "TassCreationSatus" = $Tassstatus.success
            "StudentID"         = $Account.Student_id
        }
        $CreatedUserLog.Add($Line)
    }
}

$CreatedUserLog | Format-Table
$CreatedUserLog | Export-Excel "C:\temp\Azure\ExternalID\$(Get-Date -Format "yyyyMMddHHmm")_CustomerCreationLog.xlsx" -NoNumberConversion *

disconnect-MgGraph 
