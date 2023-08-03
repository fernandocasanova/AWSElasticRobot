$ErrorActionPreference = "Stop"

. .\OrchestratorFunctions.ps1
. .\CloudFunctions.ps1

function StartMachines([hashtable]$inputConfig, [string]$bearerToken, [bool]$debug = $false)
{
    $myDate = (date).ToString().Trim()
    Write-Output ("-> Starting Start Machines > " + $myDate)
    $jobs = GetAllPendingJobs -inputConfig $inputConfig `
                       -bearerToken "$($bearerToken)" `
                       -debug $debug

    $machines = GetAllMachines -inputConfig $inputConfig `
                               -bearerToken "$($bearerToken)" `
                               -debug $debug

    if($machines.Count -lt $inputConfig.minMachines) {
        Write-Output ("--> Below minimum Machine threshold. Not enough machines found. Starting instance for " + $inputConfig.machineName + " / " + ($machines.Count) + " of " + $inputConfig.maxMachines)
        $jobs = @("FakeJob")
    }

    if($machines.Count -ge $inputConfig.maxMachines) {
        Write-Output ("--> Maximum number of machines reached for " + $inputConfig.machineName + " / " + ($machines.Count) + " of " + $inputConfig.maxMachines)
        $jobs = @()
    }

    if($jobs.Count -gt 0) {
        Write-Output ("--> Jobs found. Starting instance for " + $inputConfig.machineName + " / " + ($machines.Count + 1) + " of " + $inputConfig.maxMachines)
        
        $instance = StartInstance -inputConfig $inputConfig -debug $debug
        $instanceId = $instance.InstanceId

        Write-Output ("--> Checking SSM agent is responsive")
        CheckSSMInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug

        Write-Output ("--> Domain joining instance")
        DomainJoinInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug

        Write-Output ("--> Wait for robot service to start")
        WaitForRobotServiceToStart -inputConfig $inputConfig -instanceId $instanceId -debug $debug

        Write-Output ("--> Connecting the robot to the Orchestrator")
        ConnectRobotToOrchestrator -inputConfig $inputConfig -instanceId $instanceId -debug $debug

        Write-Output ("--> Your new Robot is up and ready. Have a nice day!")
    }
    else {
        Write-Output ("--> No Jobs found")
    }
    $myDate = (date).ToString().Trim()
    Write-Output ("-> End Start Machines > " + $myDate)
}

function StopMachines([hashtable]$inputConfig, [string]$bearerToken, [bool]$debug = $false)
{
    $contextMachines = @{}
    
    $myDate = (date).ToString().Trim()
    Write-Output ("-> Starting Stop Machines > " + $myDate)
    
    $machines = GetAllMachines -inputConfig $inputConfig `
                               -bearerToken "$($bearerToken)" `
                               -debug $debug
    
    if($machines.Count -le $inputConfig.minMachines) {
        Write-Output ("--> Reached minimum Machine threshold. Cant't stop machine " + $inputConfig.machineName + " / " + ($machines.Count) + " of " + $inputConfig.maxMachines)
        $myDate = (date).ToString().Trim()
        Write-Output ("-> End Stop Machines > " + $myDate)
        return $null
    }
    
    $idlestMachine = ""
    $idlestMachineEndTime = (Get-Date).AddDays(999)
    
    $licensedMachines = GetLicensedMachines -inputConfig $inputConfig -bearerToken $bearerToken -debug $debug

    foreach($hostName in $machines)
    {
        if($licensedMachines.Contains($hostName)) {
            $job = GetLatestJobOnMachine -inputConfig $inputConfig `
                                         -bearerToken "$($bearerToken)" `
                                         -hostName $hostName
            
            if(($job.EndTime -gt (Get-Date).AddDays(-364)) -and ($job.EndTime -lt (Get-Date).AddMinutes(-$inputConfig.startMachinesAfterIdleMinutes))) {
                if($idlestMachineEndTime -gt $job.EndTime) {
                    $idlestMachineEndTime = $job.EndTime
                    $idlestMachine = $hostname
                }
                $contextMachines[$hostname] = $job.EndTime
            }
        }
    }
    
    if($debug) {
        Write-Output (ConvertTo-Json -InputObject $contextMachines -Depth 5)
    }
    
    if($idlestMachine -eq "") {
        Write-Output ("--> No machines available to be stopped. Have a nice day!")
        $myDate = (date).ToString().Trim()
        Write-Output ("-> End Stop Machines > " + $myDate)
        return $null
    }
    
    Write-Output ("--> Removing license from machine and ensuring no more work for " + $idlestMachine)
    $machineActuallyStopped = StopAndUnlicenseMachine -inputConfig $inputConfig `
                                                      -bearerToken "$($bearerToken)" `
                                                      -hostName "$($idlestMachine)" `
                                                      -otherMachines $contextMachines
    if($idlestMachine -ne $machineActuallyStopped) {
        Write-Output ("--> The idlest machine wasn't available anymore, we had to remove " + $machineActuallyStopped)
    }
    
    Write-Output ("--> Getting instance Id from Hostname " + $machineActuallyStopped)
    $instanceId = GetInstanceIdFromHostname -inputConfig $inputConfig `
                                              -hostName "$($machineActuallyStopped)"
    
    if($instanceId -ne "") {
        Write-Output ("--> Unjoining instance from AD " + $instanceId)
        DomainUnJoinInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Output ("--> Terminating instance " + $instanceId)
        TerminateInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Output ("--> Remove Sessions for machine " + $machineActuallyStopped)
        RemoveSessionsForMachine -inputConfig $inputConfig `
                                 -bearerToken "$($bearerToken)" `
                                 -hostName $machineActuallyStopped -debug $debug
    }
    else {
        Write-Output ("--> ERROR XXX Could not retrieve the Instance Id for " + $machineActuallyStopped)
    }
    
    $myDate = (date).ToString().Trim()
    Write-Output ("-> End Stop Machines > " + $myDate)
}

function SwapMachines([hashtable]$inputConfig, [string]$bearerToken, [bool]$debug = $false)
{
    $myDate = (date).ToString().Trim()
    Write-Output ("-> Starting Swap Machines > " + $myDate)
    
    Write-Output ("--> Setting up AMI target to " + $inputConfig.NewImageId + " instead of " + $inputConfig.ImageId)
    $inputConfig.ImageId = $inputConfig.NewImageId

    Write-Output ("-> Listing machines to swap")
    $machines = GetLicensedMachines -inputConfig $inputConfig -bearerToken $bearerToken -debug $debug
    
    if($debug) {
        Write-Output (ConvertTo-Json -InputObject $machines -Depth 5)
    }
    
    foreach($machine in $machines) {
        Write-Output ("===================== Starting processing $($machine) =====================")
        Write-Output ("--> Storing current job data on this machine to be able to resume later " + $machine)
        $job = GetLatestJobOnMachine -inputConfig $inputConfig `
                                     -bearerToken "$($bearerToken)" `
                                     -hostName "$($machine)" `
                                     -includeRunning $true `
                                     -debug $debug
        
        Write-Output ("--> Stopping jobs and removing license from machine and ensuring no more work for " + $machine)
        HardStopAndUnlicenseMachine -inputConfig $inputConfig `
                                    -bearerToken "$($bearerToken)" `
                                    -hostName "$($machine)" `
                                    -job $job `
                                    -debug $debug
        
        Write-Output ("--> Getting instance Id from Hostname " + $machine)
        $instanceId = GetInstanceIdFromHostname -inputConfig $inputConfig `
                                                  -hostName "$($machine)"
        
        Write-Output ("--> Unjoining instance from AD " + $instanceId)
        DomainUnJoinInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Output ("--> Terminating instance " + $instanceId)
        TerminateInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Output ("--> Remove Sessions for machine " + $machine)
        RemoveSessionsForMachine -inputConfig $inputConfig `
                                 -bearerToken "$($bearerToken)" `
                                 -hostName $machine -debug $debug
        
        Write-Output ("--> Starting instance for " + $inputConfig.machineName)
        $instance = StartInstance -inputConfig $inputConfig
        $instanceId = $instance.InstanceId

        Write-Output ("--> Checking SSM agent is responsive")
        CheckSSMInstance -inputConfig $inputConfig -instanceId $instanceId

        Write-Output ("--> Domain joining instance")
        DomainJoinInstance -inputConfig $inputConfig -instanceId $instanceId

        Write-Output ("--> Wait for robot service to start")
        WaitForRobotServiceToStart -inputConfig $inputConfig -instanceId $instanceId

        Write-Output ("--> Connecting the robot to the Orchestrator")
        ConnectRobotToOrchestrator -inputConfig $inputConfig -instanceId $instanceId
        
        Write-Output ("--> Getting Hostname from instance Id " + $instanceId)
        $hostName = GetHostnameFromInstanceId -inputConfig $inputConfig `
                                              -instanceId $instanceId


        Write-Output ("--> Your new Robot is up and ready. Have a nice day!")
        if($job.Keys -contains "State") {
            if($job.State -eq "Running") {
                StartJob -inputConfig $inputConfig `
                         -bearerToken "$($bearerToken)" `
                         -job $job `
                         -hostName "$($hostName)" `
                         -debug $debug
            }
        }

        Write-Output ("===================== End processing $($machine) =====================")
    }
    
    $myDate = (date).ToString().Trim()
    Write-Output ("-> End Swap Machines > " + $myDate)
}

$inputConfig = @{ `
                    tenant = "UiPathDefault"; `
                    baseUrl = "https://cloud.uipath.com/uipatjuevqpo"; `
                    minMinutesSinceJobLaunch = 1; `
                    startMachinesAfterIdleMinutes = 5; `
                    minMachines = 2; `
                    maxMachines = 3; `
                    maxAttemptsAtUnlicense = 3; `
                    maxAttemptsAtStop = 3; `
                    maxAttemptsAtKill = 3; `
                    stopInterval = 5; `
                    killInterval = 5; `
                    machineName = "MyEROtemplate"; `
                    ImageId = "ami-073ee0a3e2607d777"; `
                    NewImageId = "ami-02f7e6d82360d818d"; `
                    dnsIpAddresses = "172.31.33.93"; `
                    directoryId = "d-9c677598bc"; `
                    directoryName = "tam.local"; `
                    InstanceType = "m6a.large"; `
                    KeyName = "FernandoCasanova"; `
                    SecurityGroups = "[`"sg-0bf99b92222cf86f6`"]"; `
                    Tags = "[{`"Key`": `"Name`",`"Value`": `"MyEROtemplate_Instance`"},{`"Key`": `"Owner`",`"Value`": `"fernando.casanova-coch@uipath.com`"},{`"Key`": `"Project`",`"Value`": `"TAM`"}]"; `
                    IamInstanceProfile = "arn:aws:iam::225248685317:instance-profile/EC2DirectoryJoined"; `
                    InstanceCreateTemplate = "InstanceCreate.json"; `
                    clientID = "0049e89c-b1f4-4c71-83f1-04a01db4bc2d"; `
                    clientSecret = "WnhwZsVCBOs1aeWQ" `
                }

$bearerToken = AuthenticateToCloudAndGetBearerTokenClientCredentials -identityServer "https://cloud.uipath.com/identity_/connect/token" `
              -clientId "46e86435-b337-4309-95fe-bfe70d45ba88" `
              -clientSecret "8NKHjTOBr(lnebxt" `
              -scopes "OR.Assets OR.BackgroundTasks OR.Execution OR.Folders OR.Jobs OR.Machines OR.Monitoring OR.Robots OR.Settings.Read OR.TestSetExecutions OR.TestSets OR.TestSetSchedules OR.Users.Read OR.License" `
              -tenantName "$($tenant)"

StartMachines -inputConfig $inputConfig -bearerToken $bearerToken -debug $true

#StopMachines -inputConfig $inputConfig -bearerToken $bearerToken

#SwapMachines -inputConfig $inputConfig -bearerToken $bearerToken
