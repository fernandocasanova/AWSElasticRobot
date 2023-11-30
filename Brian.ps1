$ErrorActionPreference = "Stop"

. .\OrchestratorFunctions.ps1
. .\CloudFunctions.ps1

function StartMachines([hashtable]$inputConfig, [string]$bearerToken, [bool]$debug = $false)
{
    $myDate = (date).ToString().Trim()
    Write-Host ("-> Starting Start Machines > " + $myDate)
    $jobs = GetAllPendingJobs -inputConfig $inputConfig `
                       -bearerToken "$($bearerToken)" `
                       -debug $debug

    Write-Host ("-> Get all machines")
    $machines = GetAllMachines -inputConfig $inputConfig `
                               -bearerToken "$($bearerToken)" `
                               -debug $debug

    if($machines.Count -lt $inputConfig.minMachines) {
        Write-Host ("--> Below minimum Machine threshold. Not enough machines found. Starting instance for " + $inputConfig.machineName + " / " + ($machines.Count) + " of " + $inputConfig.maxMachines)
        $jobs = @("FakeJob")
    }

    if($machines.Count -ge $inputConfig.maxMachines) {
        Write-Host ("--> Maximum number of machines reached for " + $inputConfig.machineName + " / $($inputConfig.minMachines) < $($machines.Count) <= $($inputConfig.maxMachines)")
        $jobs = @()
    }

    if($jobs.Count -gt 0) {
        Write-Host ("--> Jobs found. Starting instance for " + $inputConfig.machineName + " / $($inputConfig.minMachines) < * $($machines.Count) * < $($inputConfig.maxMachines)")
        
        $instance = StartInstance -inputConfig $inputConfig -debug $debug
        $instanceId = $instance.InstanceId

        Write-Host ("--> Checking SSM agent is responsive")
        CheckSSMInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug

        Write-Host ("--> Domain joining instance")
        DomainJoinInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug

        Write-Host ("--> Wait for robot service to start")
        WaitForRobotServiceToStart -inputConfig $inputConfig -instanceId $instanceId -debug $debug

        Write-Host ("--> Connecting the robot to the Orchestrator")
        ConnectRobotToOrchestrator -inputConfig $inputConfig -instanceId $instanceId -debug $debug

        Write-Host ("--> Your new Robot is up and ready. Have a nice day!")
    }
    else {
        Write-Host ("--> No Jobs found")
    }
    $myDate = (date).ToString().Trim()
    Write-Host ("-> End Start Machines > " + $myDate)
}

function StopMachines([hashtable]$inputConfig, [string]$bearerToken, [bool]$debug = $false)
{
    $contextMachines = @{}
    
    $myDate = (date).ToString().Trim()
    Write-Host ("-> Starting Stop Machines > " + $myDate)
    
    $machines = GetAllMachines -inputConfig $inputConfig `
                               -bearerToken "$($bearerToken)" `
                               -debug $debug
    
    if($machines.Count -le $inputConfig.minMachines) {
        Write-Host ("--> Reached minimum Machine threshold. Cant't stop machine " + $inputConfig.machineName + " / $($inputConfig.minMachines) <= $($machines.Count) < $($inputConfig.maxMachines)")
        $myDate = (date).ToString().Trim()
        Write-Host ("-> End Stop Machines > " + $myDate)
        return $null
    }
    
    $idlestMachine = ""
    $idlestMachineEndTime = (Get-Date).AddDays(999)
    
    $licensedMachines = GetLicensedMachines -inputConfig $inputConfig -bearerToken $bearerToken -debug $debug
    
    foreach($hostName in $machines)
    {
        if($licensedMachines.Contains($hostName)) {
            
            if( -not (IsMachineBusy -inputConfig $inputConfig -bearerToken $bearerToken -hostName $hostName -debug $debug) ) {
            
                $job = GetLatestJobOnMachine -inputConfig $inputConfig `
                                             -bearerToken "$($bearerToken)" `
                                             -hostName $hostName
                
                if($debug) {
                    Write-Host ($hostName + " Job EndTime " + $job.EndTime.ToString().Trim() + " / killMachinesAfterIdleMinutes " + (Get-Date).AddMinutes(-$inputConfig.killMachinesAfterIdleMinutes).ToString().Trim())
                }
                
                if($job.EndTime -lt (Get-Date).AddMinutes(-$inputConfig.killMachinesAfterIdleMinutes)) {
                    if($job.EndTime -lt $idlestMachineEndTime) {
                        $idlestMachineEndTime = $job.EndTime
                        $idlestMachine = $hostname
                    }
                    $contextMachines[$hostname] = $job.EndTime
                }
            }
        }
    }
    
    if($debug) {
        Write-Host (ConvertTo-Json -InputObject $contextMachines -Depth 5)
    }
    
    if($idlestMachine -eq "") {
        Write-Host ("--> No machines available to be stopped. Have a nice day!")
        $myDate = (date).ToString().Trim()
        Write-Host ("-> End Stop Machines > " + $myDate)
        return $null
    }
    
    Write-Host ("--> Removing license from machine and ensuring no more work for " + $idlestMachine)
    $successfullyStopped = StopJobsAndUnlicenseMachine -inputConfig $inputConfig `
                                                       -bearerToken "$($bearerToken)" `
                                                       -hostName "$($idlestMachine)" `
                                                       -debug $debug
                                                       
    if($successfullyStopped) {
        Write-Host ("--> ERROR: Could not stop machine " + $idlestMachine)
    }
    
    Write-Host ("--> Getting instance Id from Hostname " + $idlestMachine)
    $instanceId = GetInstanceIdFromHostname -inputConfig $inputConfig `
                                            -hostName "$($idlestMachine)"
    
    if($instanceId -ne "") {
        Write-Host ("--> Unjoining instance from AD " + $instanceId)
        DomainUnJoinInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Host ("--> Terminating instance " + $instanceId)
        TerminateInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Host ("--> Remove Sessions for machine " + $idlestMachine)
        RemoveSessionsForMachine -inputConfig $inputConfig `
                                 -bearerToken "$($bearerToken)" `
                                 -hostName $idlestMachine -debug $debug
    }
    else {
        Write-Host ("--> ERROR XXX Could not retrieve the Instance Id for " + $idlestMachine)
    }
    
    $myDate = (date).ToString().Trim()
    Write-Host ("-> End Stop Machines > " + $myDate)
}

function SwapMachines([hashtable]$inputConfig, [string]$bearerToken, [bool]$debug = $false)
{
    $myDate = (date).ToString().Trim()
    Write-Host ("-> Starting Swap Machines > " + $myDate)
    
    Write-Host ("--> Setting up AMI target to " + $inputConfig.NewImageId + " instead of " + $inputConfig.ImageId)
    $inputConfig.ImageId = $inputConfig.NewImageId

    Write-Host ("-> Listing machines to swap")
    $machines = GetLicensedMachines -inputConfig $inputConfig -bearerToken $bearerToken -debug $debug
    
    if($debug) {
        Write-Host (ConvertTo-Json -InputObject $machines -Depth 5)
    }
    
    foreach($machine in $machines) {
        Write-Host ("===================== Starting processing $($machine) =====================")
        Write-Host ("--> Storing current job data on this machine to be able to resume later " + $machine)
        $job = GetLatestJobOnMachine -inputConfig $inputConfig `
                                     -bearerToken "$($bearerToken)" `
                                     -hostName "$($machine)" `
                                     -includeRunning $true `
                                     -debug $debug
        
        Write-Host ("--> Stopping jobs and removing license from machine and ensuring no more work for " + $machine)
        $successfullyStopped = StopJobsAndUnlicenseMachine -inputConfig $inputConfig `
                                                   -bearerToken "$($bearerToken)" `
                                                   -hostName "$($machine)" `
                                                   -debug $debug
        
        if($successfullyStopped) {
            Write-Host ("--> ERROR: Could not stop machine " + $machine)
        }
        
        Write-Host ("--> Getting instance Id from Hostname " + $machine)
        $instanceId = GetInstanceIdFromHostname -inputConfig $inputConfig `
                                                  -hostName "$($machine)"
        
        Write-Host ("--> Unjoining instance from AD " + $instanceId)
        DomainUnJoinInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Host ("--> Terminating instance " + $instanceId)
        TerminateInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Host ("--> Remove Sessions for machine " + $machine)
        RemoveSessionsForMachine -inputConfig $inputConfig `
                                 -bearerToken "$($bearerToken)" `
                                 -hostName $machine -debug $debug
        
        Write-Host ("--> Starting instance for " + $inputConfig.machineName)
        $instance = StartInstance -inputConfig $inputConfig
        $instanceId = $instance.InstanceId

        Write-Host ("--> Checking SSM agent is responsive")
        CheckSSMInstance -inputConfig $inputConfig -instanceId $instanceId

        Write-Host ("--> Domain joining instance")
        DomainJoinInstance -inputConfig $inputConfig -instanceId $instanceId

        Write-Host ("--> Wait for robot service to start")
        WaitForRobotServiceToStart -inputConfig $inputConfig -instanceId $instanceId

        Write-Host ("--> Connecting the robot to the Orchestrator")
        ConnectRobotToOrchestrator -inputConfig $inputConfig -instanceId $instanceId
        
        Write-Host ("--> Getting Hostname from instance Id " + $instanceId)
        $hostName = GetHostnameFromInstanceId -inputConfig $inputConfig `
                                              -instanceId $instanceId


        Write-Host ("--> Your new Robot is up and ready. Have a nice day!")
        if($job.Keys -contains "State") {
            if($job.State -eq "Running") {
                StartJob -inputConfig $inputConfig `
                         -bearerToken "$($bearerToken)" `
                         -job $job `
                         -hostName "$($hostName)" `
                         -debug $debug
            }
        }

        Write-Host ("===================== End processing $($machine) =====================")
    }
    
    $myDate = (date).ToString().Trim()
    Write-Host ("-> End Swap Machines > " + $myDate)
}

$inputConfig = @{ `
                    tenant = "UiPathDefault"; `
                    baseUrl = "https://cloud.uipath.com/uipatjuevqpo"; `
                    minMinutesSinceJobLaunch = 1; `
                    killMachinesAfterIdleMinutes = 1; `
                    minMachines = 1; `
                    maxMachines = 3; `
                    maxAttemptsAtUnlicense = 3; `
                    maxAttemptsAtStop = 30; `
                    maxAttemptsAtKill = 30; `
                    stopInterval = 5; `
                    killInterval = 5; `
                    machineName = "MyEROtemplate"; `
                    machineKey = "0049e89c-b1f4-4c71-83f1-04a01db4bc2d"; `
                    machineSecret = "WnhwZsVCBOs1aeWQ"; `
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
                    InstanceCreateTemplate = "InstanceCreate.json" `
                }

$bearerToken = AuthenticateToCloudAndGetBearerTokenClientCredentials -identityServer "https://cloud.uipath.com/identity_/connect/token" `
              -clientId "46e86435-b337-4309-95fe-bfe70d45ba88" `
              -clientSecret "8NKHjTOBr(lnebxt" `
              -scopes "OR.Assets OR.BackgroundTasks OR.Execution OR.Folders OR.Jobs OR.Machines OR.Monitoring OR.Robots OR.Settings.Read OR.TestSetExecutions OR.TestSets OR.TestSetSchedules OR.Users.Read OR.License" `
              -tenantName "$($tenant)"

#StopJobsAndUnlicenseMachine -inputConfig $inputConfig -bearerToken $bearerToken -hostName "EC2AMAZ-CUFEUOS"

#StartMachines -inputConfig $inputConfig -bearerToken $bearerToken -debug $false

#StopMachines -inputConfig $inputConfig -bearerToken $bearerToken -debug $false

SwapMachines -inputConfig $inputConfig -bearerToken $bearerToken

# EC2 
