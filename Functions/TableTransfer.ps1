# Table transfer functions

function Send-FtpFile {
    param(
        [string]$SourceFile,
        [string]$DestinationServer,
        [string]$DestinationPath,
        [PSCredential]$Credential
    )
    
    try {
        $ftpRequest = [System.Net.FtpWebRequest]::Create("ftp://$DestinationServer/$DestinationPath")
        $ftpRequest.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
        $ftpRequest.Credentials = New-Object System.Net.NetworkCredential($Credential.UserName, $Credential.Password)
        $ftpRequest.UseBinary = $true
        $ftpRequest.KeepAlive = $false

        $fileContents = [System.IO.File]::ReadAllBytes($SourceFile)
        $ftpRequest.ContentLength = $fileContents.Length

        $requestStream = $ftpRequest.GetRequestStream()
        $requestStream.Write($fileContents, 0, $fileContents.Length)
        $requestStream.Close()

        $response = $ftpRequest.GetResponse()
        Write-Log "Upload Status: $($response.StatusDescription)" -Level INFO
        $response.Close()
    }
    catch {
        throw "FTP upload failed: $_"
    }
}

function Get-TableSnapshot {
    param(
        $DSN,
        $TableName,
        $DatabaseName
    )
    
    $snapshot = @{}
    $conn = New-Object System.Data.Odbc.OdbcConnection
    $conn.ConnectionString = "DSN=$DSN;DATABASE=$DatabaseName"
    $conn.Open()
    
    try {
        $cmd = New-Object System.Data.Odbc.OdbcCommand
        $cmd.Connection = $conn
        
        # Get row count
        $cmd.CommandText = "SELECT COUNT(*) FROM $TableName"
        $snapshot.RowCount = [int]$cmd.ExecuteScalar()
        
        # Get table size
        $cmd.CommandText = @"
            SELECT SUM(size) FROM sysmaster:systabinfo 
            WHERE ti_partnum IN (SELECT partnum FROM systables WHERE tabname='$TableName')
"@
        $snapshot.TableSize = [math]::Round(($cmd.ExecuteScalar() / 1024 / 1024), 2) # Size in MB
        
        # Get sample first row
        $cmd.CommandText = "SELECT first 1 * FROM $TableName"
        $reader = $cmd.ExecuteReader()
        if ($reader.Read()) {
            $firstRow = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $firstRow[$reader.GetName($i)] = $reader.GetValue($i)
            }
            $snapshot.FirstRow = $firstRow
            $snapshot.Columns = @($reader.GetSchemaTable().Rows.ColumnName)
        }
        $reader.Close()
    }
    finally {
        $conn.Close()
    }
    
    return $snapshot
}

function Get-DatabaseTables {
    param($DSN)
    
    $tables = @()
    $conn = New-Object System.Data.Odbc.OdbcConnection
    $conn.ConnectionString = "DSN=$DSN"
    $conn.Open()
    
    try {
        $cmd = New-Object System.Data.Odbc.OdbcCommand(
            "SELECT tabname FROM systables WHERE tabtype = 'T' AND owner != 'informix'", 
            $conn
        )
        
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $tables += $reader.GetString(0)
        }
    }
    finally {
        $conn.Close()
    }
    
    return $tables
}

function Transfer-Table {
    param(
        $SourceEnv,
        $DestEnv,
        $TableName,
        $SampledIds = $null,
        $TotalRows = 0
    )
    
    Write-Log "Starting transfer of table '$TableName' from $($SourceEnv.server) to $($DestEnv.server)" -Level INFO
    
    # Check if table is protected
    if ($config.protectedTables -contains $TableName.ToLower()) {
        Write-Log "Skipping protected table '$TableName'" -Level WARNING
        return
    }
    
    try {
        # Get pre-transfer snapshot
        Write-Log "Getting pre-transfer snapshot of '$TableName'" -Level DEBUG
        $sourceSnapshot = Get-TableSnapshot -DSN $SourceEnv.dsn -TableName $TableName -DatabaseName $SourceEnv.database
        
        # Export the table
        $exportFile = Join-Path $config.workDirectory "$TableName.unl"
        $schemaFile = Join-Path $config.workDirectory "$TableName.sql"
        
        Write-Log "Exporting table to '$exportFile'" -Level DEBUG
        
        if ($SampledIds) {
            $idsFile = Join-Path $config.workDirectory "$TableName.ids"
            $SampledIds | Out-File $idsFile
            
            $exportCmd = "dbexport -d $($SourceEnv.database) -t $TableName -o $exportFile WHERE id IN ($(Get-Content $idsFile -Raw))"
        }
        else {
            $exportCmd = "dbexport -d $($SourceEnv.database) -t $TableName -o $exportFile"
        }
        
        Write-Log "Executing: $exportCmd" -Level DEBUG
        $result = Invoke-Expression $exportCmd
        if ($LASTEXITCODE -ne 0) {
            throw "dbexport failed with exit code $LASTEXITCODE"
        }
        
        # Transfer via FTP
        Write-Log "Transferring file to $($DestEnv.server)" -Level INFO
        $destFtpPath = "$($DestEnv.ftp.path)/$TableName.unl"
        Send-FtpFile -SourceFile $exportFile `
                    -DestinationServer $DestEnv.ftp.host `
                    -DestinationPath $destFtpPath `
                    -Credential $FtpCredential
        
        # Import at destination
        Write-Log "Importing table at destination" -Level INFO
        $importCmd = "dbimport -d $($DestEnv.database) -t $TableName -i $destFtpPath"
        Write-Log "Executing: $importCmd" -Level DEBUG
        $result = Invoke-Expression $importCmd
        if ($LASTEXITCODE -ne 0) {
            throw "dbimport failed with exit code $LASTEXITCODE"
        }
        
        # Verify transfer
        $destSnapshot = Get-TableSnapshot -DSN $DestEnv.dsn -TableName $TableName -DatabaseName $DestEnv.database
        
        # Compare counts
        if ($destSnapshot.RowCount -ne $sourceSnapshot.RowCount) {
            Write-Log "Row count mismatch for $TableName. Source: $($sourceSnapshot.RowCount), Destination: $($destSnapshot.RowCount)" -Level WARNING
        }
        
        Write-Log "Transfer complete for $TableName" -Level INFO
    }
    catch {
        Write-Log "Failed to transfer table '$TableName': $_" -Level ERROR
        throw $_
    }
    finally {
        # Cleanup temporary files
        Remove-Item $exportFile, $schemaFile, $idsFile -ErrorAction SilentlyContinue
    }
}

function Test-EnvironmentConsistency {
    param(
        $TrainEnv,
        $TestEnv,
        $SampledDatasets
    )
    
    $inconsistencies = @()
    
    foreach ($rootTable in $SampledDatasets.Keys) {
        $sampledTables = $SampledDatasets[$rootTable]
        foreach ($table in $sampledTables.Keys) {
            $trainSnapshot = Get-TableSnapshot -DSN $TrainEnv.dsn -TableName $table -DatabaseName $TrainEnv.database
            $testSnapshot = Get-TableSnapshot -DSN $TestEnv.dsn -TableName $table -DatabaseName $TestEnv.database
            
            if ($trainSnapshot.RowCount -ne $testSnapshot.RowCount) {
                $inconsistencies += @{
                    Table = $table
                    TrainCount = $trainSnapshot.RowCount
                    TestCount = $testSnapshot.RowCount
                }
            }
        }
    }
    
    if ($inconsistencies.Count -gt 0) {
        Write-Log "Found inconsistencies between Train and Test environments:" -Level WARNING
        foreach ($inc in $inconsistencies) {
            Write-Log "Table $($inc.Table): Train($($inc.TrainCount)) vs Test($($inc.TestCount))" -Level WARNING
        }
    }
    else {
        Write-Log "All tables are consistent between Train and Test environments" -Level INFO
    }
}