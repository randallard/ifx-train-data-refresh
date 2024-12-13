use std::path::PathBuf;
use tempfile::TempDir;

pub fn setup_test_environment() -> (TempDir, PathBuf) {
    let temp_dir = TempDir::new().unwrap();
    let base_path = temp_dir.path().to_path_buf();
    
    // Create necessary test files and directories
    std::fs::create_dir_all(base_path.join("test_live.exp")).unwrap();
    std::fs::create_dir_all(base_path.join("temp_verify.exp")).unwrap();
    
    (temp_dir, base_path)
}
