function DownloadPackage([string]$bearerToken, [string]$orchestratorApiBaseUrl, [string]$packageId, [string]$outFile, [string]$feedId = "", [bool]$debug = $false) {
    $myFeedId = ""
    if($feedId -ne "") {
        $myFeedId = ("?feedId=" + $feedId)
    }
        
    $uri = ("$($orchestratorApiBaseUrl)/odata/Processes/UiPath.Server.Configuration.OData.DownloadPackage(key='$($packageId)')" + $myFeedId)
    
    $tenantName = ExtractTenantNameFromUri -uri $uri
    
    if($debug) {
        Write-Host $uri
    }
    $headers = @{"Authorization"="Bearer $($bearerToken)"}
    
    $ProgressPreference = 'SilentlyContinue' 
    $response = Invoke-WebRequest -Method 'Get' -Uri $uri -Headers $headers -outFile $outFile
    $ProgressPreference = 'Continue'
    
    if($debug) {
        Write-Host $response
    }
    return $response
}

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
    return ConvertFrom-Json $response.Content
}

function PostOrchApi([string]$bearerToken, [string]$uri, $body, $headers = $null, [string]$contentType = "application/json", [bool]$debug = $false) {
    if($contentType -eq "application/json")
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
        Write-Host $headers
    }
    if( $headers -eq $null ) {
        $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-UIPATH-TenantName"="$($tenantName)"}
    }
    $response = Invoke-WebRequest -Method 'Post' -Uri $uri -Headers $headers -ContentType "$($contentType)" -Body $body_json
    if($debug) {
        Write-Host $response
    }
    if( $response.StatusCode -ne 200 )
    {
        Write-Host "::error::### :warning: Problem with authentication (Orchestrator)"
        #exit 1
    }
    return ConvertFrom-Json $response.Content
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
    return $response.access_token
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
                         [int]$minutesSinceLaunch, `
                         [ref]$jobs) {
    
    $uri = "$($orchestratorApiBaseUrl)/odata/Jobs?`$filter=((State%20eq%20%27$($jobState)%27)%20and%20(ProcessType%20eq%20%27Process%27))&`$top=100&`$expand=Machine&`$orderby=CreationTime%20desc"
    $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-Uipath-Organizationunitid"="$($folderId)"}
    
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($uri)" -headers $headers
    
    $currentTime = Get-Date

    foreach($aValue in $result.value) {
        if([datetime]::Parse($aValue.CreationTime) -le $currentTime.AddMinutes(-$minutesSinceLaunch)) {
            # Older than minutesSinceLaunch
            
            if($aValue.Machine.Name -ceq $machineName) {
                # On the machine we are monitoring
                
                $jobs.value += $aValue
                #Write-Host ("Adding Job " + $aValue.Key.ToString())
                #Write-Host ("There are " + $jobs.value.Count.ToString() + " elements in the array")
            }
        }
    }
}

function AuthenticateAndGetBearerToken(
                       [string]$identityServer, `
                       [string]$clientId, `
                       [string]$clientSecret, `
                       [string]$scopes, `
                       [string]$tenant)
{
    Write-Host "--> Authenticating for Tenant : $($tenant)"
    return AuthenticateToCloudAndGetBearerTokenClientCredentials -clientId "$($clientId)" -clientSecret "$($clientSecret)" -scopes "$($scopes)" -tenantName $tenant -identityServer "$($identityServer)" -debug $false
}


function GetAllJobs([hashtable]$inputConfig, `
                    [string]$bearerToken,`
                    [bool]$debug = $false)
{
    $baseUrl = $inputConfig["baseUrl"]
    $tenant = $inputConfig["tenant"]
    $machineName = $inputConfig["machineName"]
    $minutesSinceLaunch = $inputConfig["minutesSinceLaunch"]

    $jobs = @()
    $orchestratorApiBaseUrl = "$($baseUrl)/$($tenant)/orchestrator_"
    
    $folderIds = GetFolders -orchestratorApiBaseUrl $orchestratorApiBaseUrl -bearerToken $bearerToken

    foreach($aFolder in $folderIds) {

        $folderId = $aFolder.Split(":")[0]
        $folderName = $aFolder.Split(":")[1]
        
        if($debug)
        {
            Write-Host ("Getting jobs from folder " + $folderName)
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
                        -minutesSinceLaunch $minutesSinceLaunch `
                        -machineName $machineName `
                        -jobs ([ref]$jobs)
    }

    if($debug)
    {
        Write-Host (ConvertTo-Json -InputObject $jobs -Depth 5)
    }
    return $jobs
}

function CheckInstanceState([PSCustomObject]$resource, [bool]$debug = $false)
{
    $instanceOK = $false
    $instanceState = aws ec2 describe-instance-status --instance-id (GetIdFromInstance -resource $resource) --output json
    $instanceState = $instanceState -join ""

    if($debug)
    {
        Write-Host $instanceState
    }

    $instanceStateObject = ConvertFrom-Json $instanceState
    
    try {

        if( $instanceStateObject.InstanceStatuses[0].InstanceState.Name -eq "running" )
        {
            if( $instanceStateObject.InstanceStatuses[0].InstanceStatus.Details[0].Status -eq "passed" )
            {
                if( $instanceStateObject.InstanceStatuses[0].SystemStatus.Details[0].Status -eq "passed" )
                {
                    $instanceOK = $true
                }
            }
        }
    }
    catch
    {
        Write-Host "Error reading status..."
    }
    return $instanceOK
}

function CheckCommandState([PSCustomObject]$resource, [bool]$debug = $false)
{
    $commandOK = $false
    $commandState = aws ssm get-command-invocation --command-id (GetIdFromCommand -resource $resource) --instance-id ($resource.InstanceIds[0]) --output json
    $commandState = $commandState -join ""

    if($debug)
    {
        Write-Host $commandState
    }

    $commandStateObject = ConvertFrom-Json $commandState
    
    try
    {
        if ( $commandStateObject.Status -eq "Success" )
        {
            $commandOK = $true
        }
    }
    catch
    {
        Write-Host "Error reading status..."
    }
    return $commandOK
}

function CheckRobotServiceStarted([PSCustomObject]$resource, [bool]$debug = $false)
{
    $stateOK = $false
    $inputCommand = '{"commands":["(Get-Service -Name \"UiRobotSvc\").Status"]}'
    
    $outputCommand = aws ssm send-command --document-name "AWS-RunPowerShellScript" `
                                          --document-version "1" `
                                          --instance-ids $resource `
                                          --parameters $inputCommand `
                                          --timeout-seconds 60 `
                                          --max-errors "0" `
                                          --output json
    
    $outputCommand = $outputCommand -join ""

    if($debug)
    {
        Write-Host $outputCommand
    }

    $command = (ConvertFrom-Json $outputCommand).Command

    WaitForResourceToBeOK -resource $command -sleepTimer 15 -maxIntervals 8 -functionCheckResourceState ${function:CheckCommandState} -functionGetId ${function:GetIdFromCommand}
    
    $commandState = aws ssm get-command-invocation --command-id (GetIdFromCommand -resource $command) --instance-id $resource --output json
    $commandState = $commandState -join ""

    if($debug)
    {
        Write-Host $commandState
    }

    $commandStateObject = ConvertFrom-Json $commandState
    
    try
    {
        if ( $commandStateObject.StandardOutputContent.Contains("Running") )
        {
            $commandOK = $true
        }
    }
    catch
    {
        Write-Host "Error reading status..."
    }
    return $commandOK

}



function CheckSSMInstanceState([PSCustomObject]$resource, [bool]$debug = $false)
{
    $commandOK = $false
    $commandState = aws ssm describe-instance-information --filters ("Key=InstanceIds,Values="+$resource)
    $commandState = $commandState -join ""

    if($debug)
    {
        Write-Host $commandState
    }

    $commandStateObject = ConvertFrom-Json $commandState
    
    try {

        if( $commandStateObject.InstanceInformationList.Count -eq 1 )
        {
            if( $commandStateObject.InstanceInformationList[0].PingStatus -eq "Online" )
            {
                if( $commandStateObject.InstanceInformationList[0].ComputerName.Contains("WORKGROUP") )
                {
                    $commandOK = $true
                }
            }
        }
    }
    catch
    {
        Write-Host "Error reading status..."
    }
    return $commandOK
}

function GetIdFromInstance([PSCustomObject]$resource)
{
    return $resource.InstanceId
}

function GetIdFromCommand([PSCustomObject]$resource)
{
    return $resource.CommandId
}

function GetIdFromResource([PSCustomObject]$resource)
{
    return $resource
}

function WaitForResourceToBeOK([PSCustomObject]$resource, [int]$sleepTimer, [int]$maxIntervals, $functionCheckResourceState, $functionGetId, [bool]$debug = $false)
{
    $resourceOK = (& $functionCheckResourceState -resource $resource -debug $debug)

    $counter = 1
    $error = $false

    while(-not $resourceOK) 
    {
        if($counter -gt $maxIntervals)
        {
            $resourceOK = $true
            $error = $true
        }
        else
        {
            Write-Host ("Resource initializing : " + (& $functionGetId -resource $resource) + " / attempt : " + $counter.ToString())
            Start-Sleep -s $sleepTimer
            $resourceOK = (& $functionCheckResourceState -resource $resource -debug $debug)
            $counter++
        }
    }
    
    if($error)
    {
        Write-Host ("Timeout starting resource : " + (& $functionGetId -resource $resource))
    }
    else
    {
        Write-Host ("Resource is OK : " + (& $functionGetId -resource $resource) )
    }
}

function StartInstance([hashtable]$inputConfig)
{
    $InstanceCreateTemplate = $inputConfig.InstanceCreateTemplate

    $toReplace = @( `
        "ImageId",`
        "InstanceType",`
        "KeyName",`
        "SecurityGroups",`
        "Tags",`
        "IamInstanceProfile" `
    )

    $InstanceCreateJson = Get-Content -Path "$($InstanceCreateTemplate)"

    foreach($aKey in $toReplace) {
        $InstanceCreateJson = $InstanceCreateJson.Replace([string]("`%"+$aKey+"`%"),[string]$inputConfig[$aKey])
    }

    Set-Content -Value $InstanceCreateJson -Path "instancecreation.input.txt"

    $outputCommand = aws ec2 run-instances --cli-input-json "file://instancecreation.input.txt" --output json
    $outputCommand = $outputCommand -join ""

    Set-Content -Value $outputCommand -Path "instancecreation.output.txt"

    $instance = (ConvertFrom-Json $outputCommand).Instances[0]

    WaitForResourceToBeOK -resource $instance -sleepTimer 15 -maxIntervals 20 -functionCheckResourceState ${function:CheckInstanceState} -functionGetId ${function:GetIdFromInstance}

    Write-Host ("--> Instance started : " + $instance.InstanceId)

    return $instance
}

function CheckSSMInstance([hashtable]$inputConfig, [string]$instanceId)
{
    WaitForResourceToBeOK -resource $instanceId -sleepTimer 10 -maxIntervals 9 -functionCheckResourceState ${function:CheckSSMInstanceState} -functionGetId ${function:GetIdFromResource}
}

function DomainJoinInstance([hashtable]$inputConfig, [string]$instanceId)
{
    $outputCommand = aws ssm send-command --document-name "AWS-JoinDirectoryServiceDomain" `
                         --document-version "1" `
                         --instance-ids $instanceId `
                         --parameters "dnsIpAddresses=172.31.33.93,directoryId=d-9c677598bc,directoryName=tam.local" `
                         --timeout-seconds 60 `
                         --max-errors "0"
    
    $outputCommand = $outputCommand -join ""

    $command = (ConvertFrom-Json $outputCommand).Command

    WaitForResourceToBeOK -resource $command -sleepTimer 15 -maxIntervals 8 -functionCheckResourceState ${function:CheckCommandState} -functionGetId ${function:GetIdFromCommand}
}

function WaitForRobotServiceToStart([hashtable]$inputConfig, [string]$instanceId)
{
    WaitForResourceToBeOK -resource $instanceId -sleepTimer 10 -maxIntervals 9 -functionCheckResourceState ${function:CheckRobotServiceStarted} -functionGetId ${function:GetIdFromResource}
}

function ConnectRobotToOrchestrator([hashtable]$inputConfig, [string]$instanceId)
{
    $baseUrl = $inputConfig["baseUrl"]
    $tenant = $inputConfig["tenant"]
    $orchestratorApiBaseUrl = "$($baseUrl)/$($tenant)/orchestrator_"

    $inputCommand = '{"commands":["& \"C:\\Program Files\\UiPath\\Studio\\UiRobot.exe\" connect --url \"%orchestratorApiBaseUrl%\" --clientID \"%clientID%\" --clientSecret \"%clientSecret%\""]}'
    $inputCommand = $inputCommand.Replace("%orchestratorApiBaseUrl%", $orchestratorApiBaseUrl)
    $inputCommand = $inputCommand.Replace("%clientID%", $inputConfig["clientID"])
    $inputCommand = $inputCommand.Replace("%clientSecret%", $inputConfig["clientSecret"])
    
    $outputCommand = aws ssm send-command --document-name "AWS-RunPowerShellScript" `
                                          --document-version "1" `
                                          --instance-ids $instanceId `
                                          --parameters $inputCommand `
                                          --timeout-seconds 60 `
                                          --max-errors "0" `
                                          --output json
    
    $outputCommand = $outputCommand -join ""

    $command = (ConvertFrom-Json $outputCommand).Command

    WaitForResourceToBeOK -resource $command -sleepTimer 15 -maxIntervals 8 -functionCheckResourceState ${function:CheckCommandState} -functionGetId ${function:GetIdFromCommand}
}

date

$inputConfig = @{ `
                    tenant = "UiPathDefault"; `
                    baseUrl = "https://cloud.uipath.com/uipatjuevqpo"; `
                    minutesSinceLaunch = 1; `
                    machineName = "MyEROtemplate"; `
                    ImageId = "ami-073ee0a3e2607d777"; `
                    InstanceType = "m6a.large"; `
                    KeyName = "FernandoCasanova"; `
                    SecurityGroups = "[`"sg-0bf99b92222cf86f6`"]"; `
                    Tags = "[{`"Key`": `"Name`",`"Value`": `"MyEROtemplate_Instance`"},{`"Key`": `"Owner`",`"Value`": `"fernando.casanova-coch@uipath.com`"},{`"Key`": `"Project`",`"Value`": `"TAM`"}]"; `
                    IamInstanceProfile = "arn:aws:iam::225248685317:instance-profile/EC2DirectoryJoined"; `
                    InstanceCreateTemplate = "InstanceCreate.json"; `
                    clientID = "0049e89c-b1f4-4c71-83f1-04a01db4bc2d"; `
                    clientSecret = "WnhwZsVCBOs1aeWQ" `
                }

$bearerToken = AuthenticateAndGetBearerToken -identityServer "https://cloud.uipath.com/identity_/connect/token" `
              -clientId "46e86435-b337-4309-95fe-bfe70d45ba88" `
              -clientSecret "8NKHjTOBr(lnebxt" `
              -scopes "OR.Assets OR.BackgroundTasks OR.Execution OR.Folders OR.Jobs OR.Machines.Read OR.Monitoring OR.Robots.Read OR.Settings.Read OR.TestSetExecutions OR.TestSets OR.TestSetSchedules OR.Users.Read" `
              -tenant "$($tenant)"

$jobs = GetAllJobs -inputConfig $inputConfig `
                   -bearerToken "$($bearerToken)"

if($jobs.Count -gt 0) {
    Write-Host ("--> Jobs found. Starting instance for " + $inputConfig["machineName"])
    $instance = StartInstance -inputConfig $inputConfig
    $instanceId = $instance.InstanceId

    Write-Host ("--> Checking SSM agent is responsive")
    CheckSSMInstance -inputConfig $inputConfig -instanceId $instanceId

    Write-Host ("--> Domain joining instance")
    DomainJoinInstance -inputConfig $inputConfig -instanceId $instanceId

    Write-Host ("--> Wait for robot service to start")
    ConnectRobotToOrchestrator -inputConfig $inputConfig -instanceId $instanceId

    Write-Host ("--> Connecting the robot to the Orchestrator")
    ConnectRobotToOrchestrator -inputConfig $inputConfig -instanceId $instanceId

    Write-Host ("--> Your new Robot is up and ready. Have a nice day!")
}
else {
    Write-Host ("--> No Jobs found")
}

date
