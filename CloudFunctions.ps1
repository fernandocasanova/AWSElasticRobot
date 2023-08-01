
function CheckInstanceStateRunning($resource, [bool]$debug = $false)
{
    $instanceOK = $false
    $instanceState = aws ec2 describe-instance-status --instance-id (GetIdFromInstance -resource $resource) --output json
    $instanceState = $instanceState -join ""

    if($debug)
    {
        Write-Host $instanceState
    }

    $instanceStateObject = ConvertFrom-Json $instanceState -AsHashtable
    
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

function CheckInstanceStateTerminated($resource, [bool]$debug = $false)
{
    $instanceOK = $false
    $instanceState = aws ec2 describe-instance-status --instance-id (GetIdFromResource -resource $resource) --output json
    $instanceState = $instanceState -join ""

    if($debug)
    {
        Write-Host $instanceState
    }

    $instanceStateObject = ConvertFrom-Json $instanceState -AsHashtable
    
    try {
        if( $instanceStateObject.InstanceStatuses.Count -eq 0 )
        {
            return $true
        }
        if( $instanceStateObject.InstanceStatuses[0].InstanceState.Name -eq "terminated" )
        {
            $instanceOK = $true
        }
        
    }
    catch
    {
        Write-Host "Error reading status..."
    }
    return $instanceOK
}

function CheckCommandState($resource, [bool]$debug = $false)
{
    $commandOK = $false
    $commandState = aws ssm get-command-invocation --command-id (GetIdFromCommand -resource $resource) --instance-id ($resource.InstanceIds[0]) --output json
    $commandState = $commandState -join ""

    if($debug)
    {
        Write-Host $commandState
    }

    $commandStateObject = ConvertFrom-Json $commandState -AsHashtable
    
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

function CheckRobotServiceStarted($resource, [bool]$debug = $false)
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

    $command = (ConvertFrom-Json $outputCommand -AsHashtable).Command

    WaitForResourceToBeOK -resource $command -sleepTimer 15 -maxIntervals 8 -functionCheckResourceState ${function:CheckCommandState} -functionGetId ${function:GetIdFromCommand}
    
    $commandState = aws ssm get-command-invocation --command-id (GetIdFromCommand -resource $command) --instance-id $resource --output json
    $commandState = $commandState -join ""

    if($debug)
    {
        Write-Host $commandState
    }

    $commandStateObject = ConvertFrom-Json $commandState -AsHashtable
    
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

function CheckSSMInstanceState($resource, [bool]$debug = $false)
{
    $commandOK = $false
    $commandState = aws ssm describe-instance-information --filters ("Key=InstanceIds,Values="+$resource)
    $commandState = $commandState -join ""

    if($debug)
    {
        Write-Host $commandState
    }

    $commandStateObject = ConvertFrom-Json $commandState -AsHashtable
    
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

function GetIdFromInstance($resource)
{
    return $resource.InstanceId
}

function GetIdFromCommand($resource)
{
    return $resource.CommandId
}

function GetIdFromResource($resource)
{
    return $resource
}

function WaitForResourceToBeOK($resource, [int]$sleepTimer, [int]$maxIntervals, $functionCheckResourceState, $functionGetId, [bool]$debug = $false)
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

    $instance = (ConvertFrom-Json $outputCommand -AsHashtable).Instances[0]

    WaitForResourceToBeOK -resource $instance -sleepTimer 15 -maxIntervals 20 -functionCheckResourceState ${function:CheckInstanceStateRunning} -functionGetId ${function:GetIdFromInstance}

    Write-Host ("--> Instance started : " + $instance.InstanceId)

    return $instance
}

function TerminateInstance([hashtable]$inputConfig, [string]$instanceId, [bool]$debug = $false)
{
    $outputCommand = aws ec2 terminate-instances --instance-ids "$($instanceId)" --output json
    $outputCommand = $outputCommand -join ""
    
    if($debug)
    {
        Write-Host $outputCommand
    }

    WaitForResourceToBeOK -resource $instanceId -sleepTimer 15 -maxIntervals 20 -functionCheckResourceState ${function:CheckInstanceStateTerminated} -functionGetId ${function:GetIdFromResource}
}


function CheckSSMInstance([hashtable]$inputConfig, [string]$instanceId)
{
    WaitForResourceToBeOK -resource $instanceId -sleepTimer 10 -maxIntervals 9 -functionCheckResourceState ${function:CheckSSMInstanceState} -functionGetId ${function:GetIdFromResource}
}

function DomainJoinInstance([hashtable]$inputConfig, [string]$instanceId)
{
    $dnsIpAddresses = $inputConfig["dnsIpAddresses"]
    $directoryId = $inputConfig["directoryId"]
    $directoryName = $inputConfig["directoryName"]
    
    $outputCommand = aws ssm send-command --document-name "AWS-JoinDirectoryServiceDomain" `
                         --document-version "1" `
                         --instance-ids $instanceId `
                         --parameters "dnsIpAddresses=$($dnsIpAddresses),directoryId=$($directoryId),directoryName=$($directoryName)" `
                         --timeout-seconds 60 `
                         --max-errors "0"
    
    $outputCommand = $outputCommand -join ""

    $command = (ConvertFrom-Json $outputCommand -AsHashtable).Command

    WaitForResourceToBeOK -resource $command -sleepTimer 15 -maxIntervals 8 -functionCheckResourceState ${function:CheckCommandState} -functionGetId ${function:GetIdFromCommand}
}

function DomainUnJoinInstance([hashtable]$inputConfig, [string]$instanceId, [bool]$debug = $false)
{
    $inputCommand = '{"commands":["whoami"]}'
    
    $outputCommand = aws ssm send-command --document-name "AWS-RunPowerShellScript" `
                                          --document-version "1" `
                                          --instance-ids $instanceId `
                                          --parameters $inputCommand `
                                          --timeout-seconds 60 `
                                          --max-errors "0" `
                                          --output json
    
    $outputCommand = $outputCommand -join ""

    if($debug)
    {
        Write-Host $outputCommand
    }

    $command = (ConvertFrom-Json $outputCommand -AsHashtable).Command

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

    $command = (ConvertFrom-Json $outputCommand -AsHashtable).Command

    WaitForResourceToBeOK -resource $command -sleepTimer 15 -maxIntervals 8 -functionCheckResourceState ${function:CheckCommandState} -functionGetId ${function:GetIdFromCommand}
}

function GetInstanceNameFromHostname([hashtable]$inputConfig, [string]$hostName, [bool]$debug = $false)
{
    $instanceId = ""
    
    $directoryName = $inputConfig["directoryName"]
    
    $instances = aws ssm describe-instance-information `
                                          --query "InstanceInformationList[].{InstanceId:InstanceId,ComputerName:ComputerName}" `
                                          --output json
    
    $instances = $instances -join ""

    if($debug)
    {
        Write-Host $instances
    }

    $instancesObj = (ConvertFrom-Json $instances -AsHashtable)
    
    foreach($instance in $instancesObj) {
        $ComputerName = $instance.ComputerName.Replace(("."+ $directoryName), "")
        
        if($ComputerName -eq $hostName) {
            $instanceId = $instance.InstanceId
        }
    }

    if($debug)
    {
        Write-Host "Hostname: $($hostName) corresponds to instanceId: $($instanceId)"
    }
    
    return $instanceId
}
