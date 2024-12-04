# Logging functions
function Initialize-Logging {
    param(
        [string]$LogDir = ".\logs",
        [string]$LogFile = "refresh_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    )
    
    # Create log directory if it doesn't exist
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    }
    
    $script:LogPath = Join-Path $LogDir $LogFile
    $script:LogStream = [System.IO.StreamWriter]::new($script:LogPath, $true)
    
    Write-Log "=== Database Refresh Started ===" -Level INFO
    Write-Log "Mode: $Mode" -Level INFO
    if ($TableName) {
        Write-Log "Table: $TableName" -Level INFO
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',
        [bool]$Console = $true
    )
    
    # Create timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to log file
    $script:LogStream.WriteLine($logMessage)
    $script:LogStream.Flush()
    
    # Write to console with appropriate color
    if ($Console) {
        $color = switch ($Level) {
            'ERROR' { 'Red' }
            'WARNING' { 'Yellow' }
            'INFO' { 'White' }
            'DEBUG' { 'Gray' }
        }
        Write-Host $logMessage -ForegroundColor $color
    }
}

function Complete-Logging {
    if ($script:LogStream) {
        Write-Log "=== Database Refresh Completed ===" -Level INFO
        $script:LogStream.Close()
        $script:LogStream.Dispose()
    }
}

function Remove-OldLogs {
    param(
        [string]$LogDir,
        [int]$RetentionDays
    )
    
    Write-Log "Cleaning up logs older than $RetentionDays days" -Level DEBUG
    Get-ChildItem -Path $LogDir -Filter "*.log" | 
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        ForEach-Object {
            Write-Log "Removing old log file: $($_.Name)" -Level DEBUG
            Remove-Item $_.FullName -Force
        }
}

# Email notification function
function Send-RefreshNotification {
    param(
        [string]$Subject,
        [string]$Body,
        [bool]$IsError = $false,
        [string]$LogFile
    )
    
    try {
        $emailConfig = $config.email
        if (-not $emailConfig.enabled) { return }

        $recipients = if ($IsError) { $emailConfig.errorTo } else { $emailConfig.to }
        $smtp = New-Object Net.Mail.SmtpClient($emailConfig.smtp.server, $emailConfig.smtp.port)
        $smtp.EnableSsl = $emailConfig.smtp.useSsl
        
        $message = New-Object Net.Mail.MailMessage
        $message.From = $emailConfig.from
        foreach ($recipient in $recipients) {
            $message.To.Add($recipient)
        }
        $message.Subject = $Subject
        $message.Body = $Body
        $message.IsBodyHtml = $true
        
        # Attach log file if it exists
        if ($LogFile -and (Test-Path $LogFile)) {
            $attachment = New-Object Net.Mail.Attachment($LogFile)
            $message.Attachments.Add($attachment)
        }
        
        $smtp.Send($message)
        Write-Log "Email notification sent to $($recipients -join ', ')" -Level INFO
    }
    catch {
        Write-Log "Failed to send email notification: $_" -Level ERROR
    }
}