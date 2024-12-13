mod database;
mod export;
mod verification;
mod scrubbing;
mod combination;

use serde::Deserialize;
use std::fs;
use std::path::Path;
use crate::error::Error;

pub use self::database::DatabaseConfig;
pub use self::export::ExportConfig;
pub use self::verification::VerificationConfig;
pub use self::scrubbing::{ScrubbingConfig, StandardizeConfig};
pub use self::combination::CombinationFieldConfig;

#[derive(Debug, Deserialize, PartialEq)]
pub struct Config {
    pub databases: DatabaseConfig,
    pub excluded_tables: Vec<String>,
    pub export: ExportConfig,
    pub verification: VerificationConfig,
    pub scrubbing: ScrubbingConfig,
    pub standardize: StandardizeConfig,
    pub combination_fields: Vec<CombinationFieldConfig>,
}

impl Config {
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self, Error> {
        let content = fs::read_to_string(path)?;
        Self::from_str(&content)
    }

    pub fn from_str(content: &str) -> Result<Self, Error> {
        serde_yaml::from_str(content).map_err(Error::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_full_config_parsing() {
        let config = Config::from_str(include_str!("../../test_data/config.yml")).unwrap();
        
        // Test database config
        assert_eq!(config.databases.source.name, "test_live");
        assert_eq!(config.databases.target.name, "temp_verify");
        assert_eq!(config.databases.testing.verification_marker, "VERIFY_TEST_STRING_XYZ_");
        assert_eq!(config.databases.testing.cleanup_script, "remove_verify_db.sh");

        // Test export config
        assert_eq!(config.export.random_seed, 42);

        // Test excluded tables
        assert!(config.excluded_tables.contains(&"training_config".to_string()));
        assert!(config.excluded_tables.contains(&"train_specific_data".to_string()));

        // Test verification config
        assert_eq!(config.verification.logging.directory, "logs");
        assert_eq!(config.verification.logging.prefix, "verify_");
        assert!(config.verification.checksums.enabled);
        assert_eq!(config.verification.checksums.algorithm, "md5sum");
        assert!(config.verification.record_counts.enabled);
        assert_eq!(config.verification.record_counts.sample_tables.len(), 2);
        assert!(config.verification.record_counts.sample_tables.contains(&"customers".to_string()));
        assert!(config.verification.record_counts.sample_tables.contains(&"employees".to_string()));

        // Test scrubbing config
        let customers = config.scrubbing.random_names.iter()
            .find(|c| c.table == "customers")
            .unwrap();
        assert_eq!(customers.fields, vec!["first_name", "last_name"]);
        assert_eq!(customers.style, "github");

        // Test standardize config
        assert_eq!(config.standardize.address.value, "123 Training St, Test City, ST 12345");
        assert_eq!(config.standardize.phone.value, "555-0123");
        assert_eq!(config.standardize.email.value, "test@example.com");

        // Test combination fields
        let projects = config.combination_fields.iter()
            .find(|c| c.table == "projects")
            .unwrap();
        assert_eq!(projects.separator, " -&- ");
        assert_eq!(projects.target_field, "combo_name");

        let repos = config.combination_fields.iter()
            .find(|c| c.table == "repositories")
            .unwrap();
        assert_eq!(repos.separator, "/");
        assert_eq!(repos.target_field, "full_path");
    }

    #[test]
    fn test_missing_file() {
        let result = Config::from_file("nonexistent.yml");
        assert!(result.is_err());
    }

    #[test]
    fn test_invalid_yaml() {
        let result = Config::from_str("invalid: yaml: [");
        assert!(result.is_err());
    }
}