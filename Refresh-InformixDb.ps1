# Informix Database Refresh Tool
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('LiveToTrain', 'TrainToTest', 'SingleTableLiveToTrain', 'SingleTableTrainToTest', 'FullRefresh')]
    [string]$Mode,
    
    [Parameter(Mandatory=$false)]
    [string]$TableName,
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = ".\config.json",
    
    [PSCredential]$FtpCredential
)

# Import helper functions
. .\Functions\Logging.ps1
. .\Functions\DataSampling.ps1
. .\Functions\TableTransfer.ps1
. .\Functions\NameGeneration.ps1
. .\Functions\DataScrubbing.ps1
. .\Functions\Progress.ps1

# Load configuration
try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    
    # Create working directory if it doesn't exist
    New-Item -ItemType Directory -Force -Path $config.workDirectory | Out-Null
} catch {
    Write-Host "ERROR: Failed to load configuration: $_" -ForegroundColor Red
    exit 1
}

# Main execution block
try {
    Initialize-Logging -LogDir $config.logging.directory
    $startTime = Get-Date
    Write-Log "Starting database refresh - Mode: $Mode" -Level INFO
    
    # Get dependency order
    $dependencyOrder = Get-TableDependencyOrder -DSN $config.environments.Live.dsn `
                                              -DatabaseName $config.environments.Live.database
    
    # Initialize progress tracking
    $progress = [TransferProgress]::new($dependencyOrder.Count)
    
    # Prompt for FTP credentials if not provided
    if (-not $FtpCredential) {
        $FtpCredential = Get-Credential -Message "Enter FTP credentials"
    }
    
    switch ($Mode) {
        'FullRefresh' {
            $confirm = Read-Host "You are about to refresh ALL environments. Type 'CONFIRM' to proceed"
            if ($confirm -ne "CONFIRM") { throw "Operation cancelled by user" }
            
            # Get relationships and sample data
            Write-Log "Getting database relationships..." -Level INFO
            $relationships = Get-TableRelationships -DSN $config.environments.Live.dsn `
                                                  -DatabaseName $config.environments.Live.database
            
            # Store sampled datasets for reuse
            $sampledDatasets = @{}
            
            foreach ($rootTable in $config.sampling.rootTables) {
                Write-Log "Sampling data from $($rootTable.name) and related tables..." -Level INFO
                $sampledTables = Get-SampledData -DSN $config.environments.Live.dsn `
                                                -DatabaseName $config.environments.Live.database `
                                                -RootTable $rootTable.name `
                                                -SamplePercentage $config.sampling.percentage `
                                                -Relationships $relationships `
                                                -MustIncludeIds $rootTable.mustIncludeIds
                
                $sampledDatasets[$rootTable.name] = $sampledTables
            }
            
            # Transfer to Train
            Write-Log "Beginning transfer to TRAIN environment..." -Level INFO
            foreach ($rootTable in $config.sampling.rootTables) {
                $sampledTables = $sampledDatasets[$rootTable.name]
                $trainResults = Invoke-ParallelTransfer -Tables $sampledTables `
                                                      -SourceEnv $config.environments.Live `
                                                      -DestEnv $config.environments.Train `
                                                      -MaxJobs $config.parallel.maxJobs `
                                                      -DependencyOrder $dependencyOrder `
                                                      -Progress $progress
            }
            
            # Apply scrubbing to Train
            Write-Log "Applying data scrubbing to TRAIN environment..." -Level INFO
            Invoke-DataScrubbing -DSN $config.environments.Train.dsn `
                                -DatabaseName $config.environments.Train.database `
                                -ScrubConfig $config.dataScrubbing
            
            # Reset progress for Test environment
            $progress = [TransferProgress]::new($dependencyOrder.Count)
            
            # Transfer to Test using same sampled data
            Write-Log "Beginning transfer to TEST environment..." -Level INFO
            foreach ($rootTable in $config.sampling.rootTables) {
                $sampledTables = $sampledDatasets[$rootTable.name]
                $testResults = Invoke-ParallelTransfer -Tables $sampledTables `
                                                     -SourceEnv $config.environments.Live `
                                                     -DestEnv $config.environments.Test `
                                                     -MaxJobs $config.parallel.maxJobs `
                                                     -DependencyOrder $dependencyOrder `
                                                     -Progress $progress
            }
            
            # Apply scrubbing to Test
            Write-Log "Applying data scrubbing to TEST environment..." -Level INFO
            Invoke-DataScrubbing -DSN $config.environments.Test.dsn `
                                -DatabaseName $config.environments.Test.database `
                                -ScrubConfig $config.dataScrubbing
            
            # Verify consistency
            Write-Log "Verifying data consistency between environments..." -Level INFO
            Test-EnvironmentConsistency -TrainEnv $config.environments.Train `
                                      -TestEnv $config.environments.Test `
                                      -SampledDatasets $sampledDatasets
        }
        
        'SingleTableLiveToTrain' {
            if (-not $TableName) { throw "TableName parameter is required for single table transfer" }
            $confirm = Read-Host "You are about to copy from PRODUCTION. Type 'CONFIRM' to proceed"
            if ($confirm -ne "CONFIRM") { throw "Operation cancelled by user" }
            
            Transfer-Table -SourceEnv $config.environments.Live `
                         -DestEnv $config.environments.Train `
                         -TableName $TableName
            
            # Run data scrubbing
            Invoke-DataScrubbing -DSN $config.environments.Train.dsn `
                                -DatabaseName $config.environments.Train.database `
                                -ScrubConfig $config.dataScrubbing `
                                -TableName $TableName
        }
        
        'SingleTableTrainToTest' {
            if (-not $TableName) { throw "TableName parameter is required for single table transfer" }
            
            Transfer-Table -SourceEnv $config.environments.Train `
                         -DestEnv $config.environments.Test `
                         -TableName $TableName
        }
        
        # Add other modes as needed
    }
    
    # Generate completion report
    $endTime = Get-Date
    $duration = $endTime - $startTime
    
    $emailBody = @"
    <h2>Database Refresh Complete</h2>
    <p>Duration: $($duration.ToString('hh\:mm\:ss'))</p>
    
    <h3>Summary:</h3>
    <ul>
        <li>Mode: $Mode</li>
        <li>Tables Processed: $($progress.CompletedTables)</li>
        <li>Total Rows Transferred: $($progress.ProcessedRows.ToString('N0'))</li>
        <li>Average Transfer Rate: $([math]::Round($progress.TotalRows / $duration.TotalSeconds, 1)) rows/second</li>
    </ul>
    
    <h3>Environment Details:</h3>
    <ul>
        <li>Source: $($config.environments.Live.server)</li>
        <li>Train: $($config.environments.Train.server)</li>
        <li>Test: $($config.environments.Test.server)</li>
    </ul>
"@
    
    Send-RefreshNotification -Subject "Database Refresh Complete - $Mode" `
                            -Body $emailBody `
                            -LogFile $script:LogPath `
                            -IsError $false
    
} catch {
    $errorBody = @"
    <h2>Database Refresh Failed</h2>
    <p>Error: $($_.Exception.Message)</p>
    <p>Please check attached log file for details.</p>
"@
    
    Send-RefreshNotification -Subject "Database Refresh Failed - $Mode" `
                            -Body $errorBody `
                            -LogFile $script:LogPath `
                            -IsError $true
    
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
} finally {
    # Cleanup
    Get-ChildItem -Path $config.workDirectory -Filter "*.unl" | Remove-Item -ErrorAction SilentlyContinue
    Get-ChildItem -Path $config.workDirectory -Filter "*.sql" | Remove-Item -ErrorAction SilentlyContinue
    
    Complete-Logging
}