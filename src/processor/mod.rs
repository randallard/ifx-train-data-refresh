mod copy;
mod sql;
mod unl;
mod random;

use std::path::PathBuf;
use crate::config::Config;
use crate::error::Error;

pub struct DbExportProcessor {
    config: Config,
    source_path: PathBuf,
    target_path: PathBuf,
    adjectives: Vec<String>,
    nouns: Vec<String>,
}

impl DbExportProcessor {
    pub fn new(config: Config, source_path: PathBuf, target_path: PathBuf) -> Result<Self, Error> {
        let adjectives = std::fs::read_to_string("adjectives.txt")?
            .lines()
            .map(String::from)
            .collect();
        let nouns = std::fs::read_to_string("nouns.txt")?
            .lines()
            .map(String::from)
            .collect();
            
        Ok(Self {
            config,
            source_path,
            target_path,
            adjectives,
            nouns,
        })
    }

    pub fn process(&self) -> Result<(), Error> {
        // Implementation will come later
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup_test_environment() -> (TempDir, PathBuf) {
        let temp_dir = TempDir::new().unwrap();
        let base_path = temp_dir.path().to_path_buf();
        (temp_dir, base_path)
    }

    #[test]
    fn test_processor_creation() {
        let (temp_dir, base_path) = setup_test_environment();
        let config_str = include_str!("../../test_data/config.yml");
        let config: Config = serde_yaml::from_str(config_str).unwrap();
        
        let source_path = base_path.join("test_live.exp");
        let target_path = base_path.join("temp_verify.exp");
        
        let result = DbExportProcessor::new(
            config,
            source_path,
            target_path,
        );
        
        assert!(result.is_ok());
    }
}
