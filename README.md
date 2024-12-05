# Informix Database Refresh Tool

A PowerShell-based tool for refreshing Informix test/train environments with sampled production data while maintaining referential integrity and data privacy.

## Features

- **Smart Data Sampling**: Sample production data while maintaining referential integrity
  - Configurable sampling percentage
  - Ability to specify "must-include" IDs for critical test cases
  - Automatic relationship traversal to ensure data consistency

- **Environment Management**
  - Live-to-Train transfers
  - Train-to-Test transfers
  - Single table transfers
  - Protected tables configuration

- **Data Privacy**
  - Automated data scrubbing
  - Configurable scrubbing rules
  - Random name generation for sensitive fields

- **Performance**
  - Parallel processing with configurable job limits
  - Smart dependency ordering for optimal transfer sequence
  - Progress tracking with ETA

- **Security**
  - FTP-based secure file transfers
  - Protected tables cannot be overwritten
  - Mandatory confirmation for production operations

## Prerequisites

- PowerShell 5.1 or higher
- Informix Client SDK
- FTP access between environments
- Appropriate database permissions

## Installation

1. Clone the repository:
```powershell
git clone [repository-url]
```

2. Copy the configuration template:
```powershell
Copy-Item config.template.json config.json
```

3. Update `config.json` with your environment settings

## Configuration

The tool uses a JSON configuration file with the following sections:

### Environment Configuration
```json
{
    "environments": {
        "Live": {
            "dsn": "PROD_DSN",
            "server": "prod-server.example.com",
            "database": "proddb",
            "ftp": {
                "host": "prod-ftp.example.com",
                "path": "/transfer"
            }
        }
    }
}
```

### Sampling Configuration
```json
{
    "sampling": {
        "enabled": true,
        "percentage": 10,
        "rootTables": [
            {
                "name": "customers",
                "mustIncludeIds": "1001,1002,1005",
                "relationships": [
                    {
                        "childTable": "orders",
                        "foreignKey": "customer_id"
                    }
                ]
            }
        ]
    }
}
```

### Data Scrubbing
```json
{
    "dataScrubbing": {
        "fieldsToRandomize": [
            {
                "table": "users",
                "field": "display_name"
            }
        ],
        "queries": [
            {
                "description": "Reset user passwords",
                "query": "UPDATE users SET password = 'test123' WHERE status = 'A'"
            }
        ]
    }
}
```

## Usage

### Basic Usage

1. Single Table Transfer:
```powershell
.\Refresh-InformixDb.ps1 -Mode SingleTableLiveToTrain -TableName customers
```

2. Full Environment Refresh:
```powershell
.\Refresh-InformixDb.ps1 -Mode LiveToTrain
```

### Advanced Usage

1. Custom Configuration File:
```powershell
.\Refresh-InformixDb.ps1 -Mode LiveToTrain -ConfigPath .\custom-config.json
```

2. Specify FTP Credentials:
```powershell
$creds = Get-Credential
.\Refresh-InformixDb.ps1 -Mode LiveToTrain -FtpCredential $creds
```

## Project Structure

```
├── Refresh-InformixDb.ps1    # Main script
├── config.json               # Configuration file
├── adjectives.txt           # Word list for name generation
├── nouns.txt               # Word list for name generation
└── logs/                   # Log directory
```

## Logging

- Logs are stored in the `logs` directory
- Format: `refresh_YYYYMMDD_HHMMSS.log`
- Contains detailed operation info and error messages
- Configurable retention period

## Common Tasks

### Adding a New Root Table
1. Identify the table and its relationships
2. Add to the `rootTables` section in config.json
3. Define child relationships
4. Specify any must-include IDs

### Modifying Scrubbing Rules
1. Update the `dataScrubbing` section in config.json
2. Add field randomization rules
3. Add custom scrubbing queries

## Troubleshooting

Common issues and solutions:

1. **Transfer Failed**
   - Check FTP credentials
   - Verify database permissions
   - Check log files for detailed error messages

2. **Missing Related Data**
   - Verify relationship configuration
   - Check foreign key definitions
   - Ensure must-include IDs exist

3. **Slow Performance**
   - Adjust parallel job count
   - Check network bandwidth
   - Review table dependencies

## Contributing

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

[Specify your license here]

## Support

For support, please:
1. Check the log files
2. Review troubleshooting section
3. Contact the development team

## Backup Configuration

The tool supports automatic database backups before refresh operations.

Add the following to your `config.json`:
```json
{
    "backup": {
        "enabled": true,
        "directory": ".\\backups",
        "retentionDays": 7
    }
}
```

- `enabled`: Enable/disable automatic backups
- `directory`: Location to store backup files
- `retentionDays`: Number of days to retain backup files

Backups are automatically restored if the refresh operation fails.