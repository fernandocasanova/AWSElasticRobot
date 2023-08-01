
function GetOrchApi([string]$bearerToken, [string]$uri, $headers = $null, [string]$contentType = "application/json", [bool]$debug = $false) {
    $tenantName = ExtractTenantNameFromUri -uri $uri
    if($debug) {
        Write-Host $uri
    }
    if( $headers -eq $null ) {
        $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-UIPATH-TenantName"="$($tenantName)"}
    }
    $response = Invoke-WebRequest -Method 'Get' -Uri $uri -Headers $headers -ContentType "$($contentType)"
    if($debug) {
        Write-Host $response
    }
    return ConvertFrom-Json $response.Content -AsHashtable
}

function PostOrchApi([string]$bearerToken, [string]$uri, $body, $headers = $null, [string]$contentType = "application/json", [bool]$convert = $false, [bool]$debug = $false) {
    if($convert)
    {
        $body_json = $body | ConvertTo-Json
    }
    else
    {
        $body_json = $body
    }
    $tenantName = ExtractTenantNameFromUri -uri $uri

    if($debug) {
        Write-Host $uri
        Write-Host $body
        Write-Host (ConvertTo-Json -InputObject $headers -Depth 5)
        Write-Host $contentType
    }
    if( $headers -eq $null ) {
        $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-UIPATH-TenantName"="$($tenantName)"}
    }
    
    $response = Invoke-WebRequest -Method "Post" -Uri $uri -Headers $headers -ContentType "$($contentType)" -Body $body_json -SkipHttpErrorCheck
    
    if($debug) {
        Write-Host ("Response Code: " + $response.StatusCode)
        Write-Host $response.Content
        Write-Host $response.Content.GetType()
    }
    return $response.Content
}

# Interactions with the Orchestrator API

function AuthenticateToCloudAndGetBearerTokenClientCredentials([string]$clientId, [string]$clientSecret, [string]$scopes, [string]$tenantName, [string]$identityServer, [bool]$debug = $false) {
    $body = @{"grant_type"="client_credentials"; "client_id"="$($clientId)"; "client_secret"="$($clientSecret)";"scope"="$($scopes)"}
    $headers = @{}
    
    $uri = $identityServer
    $response = PostOrchApi -bearerToken "" -uri $uri -headers $headers -body $body -contentType "application/x-www-form-urlencoded" -debug $debug
    if($debug) {
        Write-Host $response
    }
    $responseObj = (ConvertFrom-Json $response -AsHashtable)
    return $responseObj.access_token
}

function ExtractTenantNameFromUri([string]$uri) {
    return "$uri" -replace "(?sm).*?.*/([^/]*?)/orchestrator_/(.*?)$.*","`$1"
}

function GetFolders([string]$orchestratorApiBaseUrl, [string]$bearerToken) {
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($orchestratorApiBaseUrl)/odata/Folders"
    $folders = @()
    foreach($aValue in $result.value) {
        $folders += ($aValue.Id.ToString() + ":" + $aValue.FullyQualifiedName.ToString())
    }
    return $folders
}

function GetJobsInFolder([string]$orchestratorApiBaseUrl, `
                         [string]$bearerToken, `
                         [string]$folderId, `
                         [string]$jobState, `
                         [string]$machineName, `
                         [int]$minMinutesSinceJobLaunch, `
                         [ref]$jobs) {
    
    $uri = "$($orchestratorApiBaseUrl)/odata/Jobs?`$filter=((State%20eq%20%27$($jobState)%27)%20and%20(ProcessType%20eq%20%27Process%27))&`$top=100&`$expand=Machine&`$orderby=CreationTime%20desc"
    $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-Uipath-Organizationunitid"="$($folderId)"}
    
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($uri)" -headers $headers
    
    $currentTime = Get-Date

    foreach($aValue in $result.value) {
        if($aValue.CreationTime -le $currentTime.AddMinutes(-$minMinutesSinceJobLaunch)) {
            # Older than minMinutesSinceJobLaunch
            
            if($aValue.Machine.Name -ceq $machineName) {
                # On the machine we are monitoring
                
                $jobs.value += $aValue
                #Write-Host ("Adding Job " + $aValue.Key.ToString())
                #Write-Host ("There are " + $jobs.value.Count.ToString() + " elements in the array")
            }
        }
    }
}

function GetLatestJobOnMachineInFolder([string]$orchestratorApiBaseUrl, `
                         [string]$bearerToken, `
                         [string]$folderId, `
                         [string]$machineName, `
                         [string]$hostName, `
                         [bool]$debug = $false) {
    
    $uri = "$($orchestratorApiBaseUrl)/odata/Jobs?`$filter=((ProcessType%20eq%20%27Process%27) and (Machine/Name eq '%MACHINENAME%') and (HostMachineName eq '%HOSTNAME%'))&`$top=100&`$expand=Machine&`$orderby=EndTime%20desc"
    $uri = $uri.Replace("%MACHINENAME%", $machineName)
    $uri = $uri.Replace("%HOSTNAME%", $hostName)
    
    $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-Uipath-Organizationunitid"="$($folderId)"}
    
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($uri)" -headers $headers
    
    if($debug) {
        Write-Host (ConvertTo-Json -InputObject $result -Depth 5)
    }
    
    $latestEndDate = (Get-Date).AddDays(-365)
    $latestJob = @{EndTime = $latestEndDate}
    
    foreach($aValue in $result.value) {
        if($aValue.State -eq "Running") {
        }
        else {
            if($aValue.EndTime -gt $latestJob.EndTime) {
                $latestJob = $aValue
            }
        }
    }
    if($debug) {
        Write-Host (ConvertTo-Json -InputObject $latestJob -Depth 5)
    }
    return $latestJob
}

function GetAllPendingJobs([hashtable]$inputConfig, `
                    [string]$bearerToken,`
                    [bool]$debug = $false)
{
    $baseUrl = $inputConfig["baseUrl"]
    $tenant = $inputConfig["tenant"]
    $machineName = $inputConfig["machineName"]
    $minMinutesSinceJobLaunch = $inputConfig["minMinutesSinceJobLaunch"]

    $jobs = @()
    $orchestratorApiBaseUrl = "$($baseUrl)/$($tenant)/orchestrator_"
    
    $folderIds = GetFolders -orchestratorApiBaseUrl $orchestratorApiBaseUrl -bearerToken $bearerToken

    foreach($aFolder in $folderIds) {

        $folderId = $aFolder.Split(":")[0]
        $folderName = $aFolder.Split(":")[1]
        
        if($debug)
        {
            Write-Host ("Getting pending jobs from folder " + $folderName)
        }

        # Job State to monitor (hardcoded):
        # Pending		0
        # Running		1
        # Stopping		2
        # Terminating	3
        # Faulted		4
        # Successful	5
        # Stopped		6
        # Suspended		7
        # Resumed		8
        GetJobsInFolder -orchestratorApiBaseUrl $orchestratorApiBaseUrl `
                        -bearerToken $bearerToken `
                        -folderId $folderId `
                        -jobState "0" `
                        -minMinutesSinceJobLaunch $minMinutesSinceJobLaunch `
                        -machineName $machineName `
                        -jobs ([ref]$jobs)
    }

    if($debug)
    {
        Write-Host (ConvertTo-Json -InputObject $jobs -Depth 5)
    }
    return $jobs
}

function GetLatestJobOnMachine([hashtable]$inputConfig, `
                    [string]$bearerToken,`
                    [array]$hostName,`
                    [bool]$debug = $false)
{
    $baseUrl = $inputConfig["baseUrl"]
    $tenant = $inputConfig["tenant"]
    $machineName = $inputConfig["machineName"]

    $latestJob = @{ EndTime = (Get-Date).AddDays(-365) }
    $orchestratorApiBaseUrl = "$($baseUrl)/$($tenant)/orchestrator_"
    
    $folderIds = GetFolders -orchestratorApiBaseUrl $orchestratorApiBaseUrl -bearerToken $bearerToken

    foreach($aFolder in $folderIds) {
        $folderId = $aFolder.Split(":")[0]
        $folderName = $aFolder.Split(":")[1]
        
        if($debug)
        {
            Write-Host ("Getting current and past jobs from folder " + $folderName)
        }

        $aJob = GetLatestJobOnMachineInFolder -orchestratorApiBaseUrl $orchestratorApiBaseUrl `
                        -bearerToken $bearerToken `
                        -folderId $folderId `
                        -machineName $machineName `
                        -hostName $hostName `
                        -debug $debug
        
        if($aJob.EndTime -gt $latestJob.EndTime) {
            $latestJob = $aJob
        }
    }
    return $latestJob
}

function GetLicensedMachines([hashtable]$inputConfig, `
                             [string]$bearerToken,`
                             [bool]$debug = $false)
 {
    $baseUrl = $inputConfig["baseUrl"]
    $tenant = $inputConfig["tenant"]

    $machines = @()
    $orchestratorApiBaseUrl = "$($baseUrl)/$($tenant)/orchestrator_"
    
    $uri = ("$($orchestratorApiBaseUrl)/odata/LicensesRuntime/UiPath.Server.Configuration.OData.GetLicensesRuntime(robotType='Unattended')?`$filter=(IsLicensed%20eq%20true)")
    
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($uri)" -debug $debug
    
    foreach($aValue in $result.value) {
        $machines += $aValue.HostMachineName
    }
    return $machines
 }


function GetAllMachines([hashtable]$inputConfig, `
                        [string]$bearerToken,`
                        [bool]$debug = $false)
{
    $baseUrl = $inputConfig["baseUrl"]
    $tenant = $inputConfig["tenant"]
    $machineName = $inputConfig["machineName"]

    $machines = @()
    $orchestratorApiBaseUrl = "$($baseUrl)/$($tenant)/orchestrator_"
    
    $uri = ("$($orchestratorApiBaseUrl)/odata/Machines?`$filter=Name%20eq%20'" + $machineName + "'&`$orderby=Id%20desc")
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($uri)" -debug $debug
    
    $machineId = $result.value[0].Id
    
    if($debug)
    {
        Write-Host ("machineId = " + $machineId)
    }
    
    $uri = "$($orchestratorApiBaseUrl)/odata/Sessions/UiPath.Server.Configuration.OData.GetMachineSessions(key=MACHINEID)?`$filter=(State%20eq%20'Available')"
    $uri = $uri.Replace("MACHINEID", $machineId)
    
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($uri)" -debug $debug
    
    foreach($aValue in $result.value) {
        $machines += $aValue.HostMachineName
    }

    if($debug)
    {
        Write-Host (ConvertTo-Json -InputObject $machines -Depth 5)
    }
    return $machines
}

function TryUnlicenseMachine([hashtable]$inputConfig, `
                             [string]$bearerToken,`
                             [string]$hostName,`
                             [bool]$debug = $false)
{
    $baseUrl = $inputConfig["baseUrl"]
    $tenant = $inputConfig["tenant"]
    $machineName = $inputConfig["machineName"]

    $orchestratorApiBaseUrl = "$($baseUrl)/$($tenant)/orchestrator_"
    
    $success = $true
    
    $uri = ("$($orchestratorApiBaseUrl)/odata/LicensesRuntime('" + $machineName + "')/UiPath.Server.Configuration.OData.ToggleEnabled")
    $body = "{""key"": """+$machineName + "@" + $hostName + """, ""robotType"": ""Unattended"", ""enabled"": false }"
    $headers = @{Authorization="Bearer $($bearerToken)"; accept = "application/json"}
    
    $result = PostOrchApi -bearerToken $bearerToken -uri "$($uri)" -body $body -headers $headers -debug $debug
    
    if($result -ne $null) {
        $resultObj = ConvertFrom-Json $result -AsHashtable

        if($resultObj.ContainsKey("message") -and $resultObj.ContainsKey("errorCode")) {
            if($resultObj.message -eq "Cannot disable a machine while there are running robots on that machine!") {
                $success = $false
            }
        }
    }
    
    return $success
}

function StopAndUnlicenseMachine([hashtable]$inputConfig, `
                                 [string]$bearerToken,`
                                 [string]$hostName,`
                                 [hashtable]$otherMachines,`
                                 [bool]$debug = $false)
{
    $hostNameToStop = $hostName
    
    while($otherMachines.Keys.Count -gt 0) {
        if($debug) {
            Write-Host ("Machine to stop: " + $hostNameToStop)
            Write-Host (ConvertTo-Json -InputObject $otherMachines -Depth 5)
        }
        
        $result = TryUnlicenseMachine -inputConfig $inputConfig `
                                      -bearerToken "$($bearerToken)" `
                                      -hostName "$($hostNameToStop)" `
                                      -debug $debug
        
        if($result) {
            # Managed to switch off the machine
            # Exit the loop
            $otherMachines = @{}
        }
        else {
            # Did not manage to switch off the machine
            # remove hostNameToStop from otherMachines
            $otherMachines.Remove($hostNameToStop)
            
            $hostNameToStop = $otherMachines.Keys[0]
            
            if($otherMachines.Keys.Count -eq 0) {
                $hostNameToStop = ""
            }
        }
        if($debug) {
            Write-Host ("Machine to stop: " + $hostNameToStop)
            Write-Host (ConvertTo-Json -InputObject $otherMachines -Depth 5)
        }
    }
    return $hostNameToStop
}

function RemoveSessionsForMachine([hashtable]$inputConfig, `
                                 [string]$bearerToken,`
                                 [string]$hostName,`
                                 [bool]$debug = $false)
{
    $baseUrl = $inputConfig["baseUrl"]
    $tenant = $inputConfig["tenant"]
    $machineName = $inputConfig["machineName"]

    $sessions = @()
    $orchestratorApiBaseUrl = "$($baseUrl)/$($tenant)/orchestrator_"
    
    $uri = "$($orchestratorApiBaseUrl)/odata/Sessions/UiPath.Server.Configuration.OData.GetMachineSessionRuntimes?`$filter=(MachineName%20eq%20'$($machineName)')%20and%20(HostMachineName%20eq%20'$($hostName)')"
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($uri)" -debug $debug
    
    foreach($session in $result.value) {
        if($sessions -notcontains $session.SessionId) {
            $sessions += $session.SessionId
        }
    }
    
    if($debug)
    {
        (ConvertTo-Json -InputObject $sessions -Depth 5)
    }
    
    $uri = "$($orchestratorApiBaseUrl)/odata/Sessions/UiPath.Server.Configuration.OData.DeleteInactiveUnattendedSessions"
    
    $body = "{""sessionIds"": [" + ($sessions -join ",") + "]}"
    $headers = @{Authorization="Bearer $($bearerToken)"; accept = "application/json"}
    PostOrchApi -bearerToken $bearerToken -uri "$($uri)" -body $body -headers $headers
}