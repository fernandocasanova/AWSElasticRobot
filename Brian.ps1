$ErrorActionPreference = "Stop"

. .\OrchestratorFunctions.ps1
. .\CloudFunctions.ps1

function StartMachines([hashtable]$inputConfig, [string]$bearerToken)
{
    $myDate = (date).ToString().Trim()
    Write-Host ("-> Starting Start Machines > " + $myDate)
    $jobs = GetAllPendingJobs -inputConfig $inputConfig `
                       -bearerToken "$($bearerToken)"

    $machines = GetAllMachines -inputConfig $inputConfig `
                               -bearerToken "$($bearerToken)"

    if($machines.Count -lt $inputConfig.minMachines) {
        Write-Host ("--> Below minimum Machine threshold. Not enough machines found. Starting instance for " + $inputConfig.machineName + " / " + ($machines.Count) + " of " + $inputConfig.maxMachines)
        $jobs = @("FakeJob")
    }

    if($machines.Count -ge $inputConfig.maxMachines) {
        Write-Host ("--> Maximum number of machines reached for " + $inputConfig.machineName + " / " + ($machines.Count) + " of " + $inputConfig.maxMachines)
        $jobs = @()
    }

    if($jobs.Count -gt 0) {
        Write-Host ("--> Jobs found. Starting instance for " + $inputConfig.machineName + " / " + ($machines.Count + 1) + " of " + $inputConfig.maxMachines)
        
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
                               -bearerToken "$($bearerToken)" -debug $debug
    
    if($machines.Count -le $inputConfig.minMachines) {
        Write-Host ("--> Reached minimum Machine threshold. Cant't stop machine " + $inputConfig.machineName + " / " + ($machines.Count) + " of " + $inputConfig.maxMachines)
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
        Write-Host (ConvertTo-Json -InputObject $contextMachines -Depth 5)
    }
    
    Write-Host ("--> Removing license from machine and ensuring no more work for " + $idlestMachine)
    $machineActuallyStopped = StopAndUnlicenseMachine -inputConfig $inputConfig `
                                                      -bearerToken "$($bearerToken)" `
                                                      -hostName "$($idlestMachine)" `
                                                      -otherMachines $contextMachines
    if($idlestMachine -ne $machineActuallyStopped) {
        Write-Host ("--> The idlest machine wasn't available anymore, we had to remove " + $machineActuallyStopped)
    }
    
    Write-Host ("--> Getting instance Id from Hostname " + $machineActuallyStopped)
    $instanceId = GetInstanceNameFromHostname -inputConfig $inputConfig `
                                              -hostName "$($machineActuallyStopped)"
    
    if($instanceId -ne "") {
        Write-Host ("--> Unjoining instance from AD " + $instanceId)
        DomainUnJoinInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Host ("--> Terminating instance " + $instanceId)
        TerminateInstance -inputConfig $inputConfig -instanceId $instanceId -debug $debug
        
        Write-Host ("--> Remove Sessions for machine " + $machineActuallyStopped)
        RemoveSessionsForMachine -inputConfig $inputConfig `
                                 -bearerToken "$($bearerToken)" `
                                 -hostName $machineActuallyStopped -debug $debug
    }
    else {
        Write-Host ("--> ERROR XXX Could not retrieve the Instance Id for " + $machineActuallyStopped)
    }
    
    $myDate = (date).ToString().Trim()
    Write-Host ("-> End Stop Machines > " + $myDate)
}

$inputConfig = @{ `
                    tenant = "UiPathDefault"; `
                    baseUrl = "https://cloud.uipath.com/uipatjuevqpo"; `
                    minMinutesSinceJobLaunch = 1; `
                    startMachinesAfterIdleMinutes = 5; `
                    minMachines = 0; `
                    maxMachines = 3; `
                    machineName = "MyEROtemplate"; `
                    ImageId = "ami-073ee0a3e2607d777"; `
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

#StartMachines -inputConfig $inputConfig -bearerToken $bearerToken

StopMachines -inputConfig $inputConfig -bearerToken $bearerToken

