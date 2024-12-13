mod common;

use db_export_processor::{Config, DbExportProcessor};
use std::fs;

#[test]
fn test_complete_processing() {
    let (temp_dir, base_path) = common::setup_test_environment();
    
    // Setup test files
    let config_str = include_str!("../test_data/config.yml");
    let config: Config = serde_yaml::from_str(config_str).unwrap();
    
    let source_path = base_path.join("test_live.exp");
    let target_path = base_path.join("temp_verify.exp");
    
    let processor = DbExportProcessor::new(
        config,
        source_path,
        target_path,
    ).unwrap();
    
    assert!(processor.process().is_ok());
}