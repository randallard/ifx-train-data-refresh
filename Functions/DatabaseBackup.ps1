# Backup and restore functions for Informix databases
function Backup-InformixDatabase {
    param(
        [string]$DSN,
        [string]$DatabaseName,
        [string]$BackupDir = ".\backups"
    )
    
    try {
        # Create backup directory if it doesn't exist
        if (-not (Test-Path $BackupDir)) {
            New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupFile = Join-Path $BackupDir "$($DatabaseName)_$timestamp.backup"
        
        Write-Log "Starting backup of database '$DatabaseName' to '$backupFile'" -Level INFO
        
        # Create backup using ontape
        $backupCmd = "ontape -s -L 0 -F $backupFile"
        Write-Log "Executing: $backupCmd" -Level DEBUG
        
        $result = Invoke-Expression $backupCmd
        if ($LASTEXITCODE -ne 0) {
            throw "Database backup failed with exit code $LASTEXITCODE"
        }
        
        Write-Log "Backup completed successfully" -Level INFO
        return $backupFile
    }
    catch {
        Write-Log "Backup failed: $_" -Level ERROR
        throw
    }
}

function Restore-InformixDatabase {
    param(
        [string]$DSN,
        [string]$DatabaseName,
        [string]$BackupFile
    )
    
    try {
        Write-Log "Starting restore of database '$DatabaseName' from '$BackupFile'" -Level INFO
        
        # Restore using ontape
        $restoreCmd = "ontape -p -F $BackupFile"
        Write-Log "Executing: $restoreCmd" -Level DEBUG
        
        $result = Invoke-Expression $restoreCmd
        if ($LASTEXITCODE -ne 0) {
            throw "Database restore failed with exit code $LASTEXITCODE"
        }
        
        Write-Log "Restore completed successfully: $result" -Level INFO
    }
    catch {
        Write-Log "Restore failed: $_" -Level ERROR
        throw
    }
}