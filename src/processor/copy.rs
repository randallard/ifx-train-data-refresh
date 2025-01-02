use std::fs;
use std::path::Path;
use crate::error::Error;

pub fn copy_directory(source: &Path, target: &Path) -> Result<(), Error> {
    if !source.exists() {
        return Err(Error::Processing(format!(
            "Source directory does not exist: {}",
            source.display()
        )));
    }

    if !source.is_dir() {
        return Err(Error::Processing(format!(
            "Source path is not a directory: {}",
            source.display()
        )));
    }

    // Create target directory if it doesn't exist
    fs::create_dir_all(target).map_err(Error::from)?;

    // Read source directory entries
    for entry in fs::read_dir(source).map_err(Error::from)? {
        let entry = entry.map_err(Error::from)?;
        let source_path = entry.path();
        let target_path = target.join(entry.file_name());

        if source_path.is_dir() {
            copy_directory(&source_path, &target_path)?;
        } else {
            fs::copy(&source_path, &target_path).map_err(Error::from)?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    use std::fs::File;
    use std::io::Write;

    #[test]
    fn test_directory_copying() {
        // Create temporary directory for testing
        let temp_dir = TempDir::new().unwrap();
        let source_dir = temp_dir.path().join("source");
        let target_dir = temp_dir.path().join("target");
        
        // Create source directory and test file
        fs::create_dir(&source_dir).unwrap();
        let test_file_path = source_dir.join("test.txt");
        let mut file = File::create(&test_file_path).unwrap();
        write!(file, "test content").unwrap();
        
        // Create a subdirectory with a file
        let sub_dir = source_dir.join("subdir");
        fs::create_dir(&sub_dir).unwrap();
        let sub_file_path = sub_dir.join("subtest.txt");
        let mut sub_file = File::create(&sub_file_path).unwrap();
        write!(sub_file, "subdir test content").unwrap();
        
        // Test copying
        assert!(copy_directory(&source_dir, &target_dir).is_ok());
        
        // Verify target directory exists
        assert!(target_dir.exists());
        assert!(target_dir.is_dir());
        
        // Verify files were copied
        let copied_file = target_dir.join("test.txt");
        assert!(copied_file.exists());
        assert_eq!(fs::read_to_string(copied_file).unwrap(), "test content");
        
        // Verify subdirectory and its contents were copied
        let copied_sub_dir = target_dir.join("subdir");
        assert!(copied_sub_dir.exists());
        assert!(copied_sub_dir.is_dir());
        
        let copied_sub_file = copied_sub_dir.join("subtest.txt");
        assert!(copied_sub_file.exists());
        assert_eq!(fs::read_to_string(copied_sub_file).unwrap(), "subdir test content");
    }

    #[test]
    fn test_copy_nonexistent_directory() {
        let temp_dir = TempDir::new().unwrap();
        let source_dir = temp_dir.path().join("nonexistent");
        let target_dir = temp_dir.path().join("target");
        
        let result = copy_directory(&source_dir, &target_dir);
        assert!(result.is_err());
        if let Err(Error::Processing(msg)) = result {
            assert!(msg.contains("Source directory does not exist"));
        } else {
            panic!("Expected Processing error");
        }
    }

    #[test]
    fn test_copy_to_existing_directory() {
        let temp_dir = TempDir::new().unwrap();
        let source_dir = temp_dir.path().join("source");
        let target_dir = temp_dir.path().join("target");
        
        // Create both directories
        fs::create_dir(&source_dir).unwrap();
        fs::create_dir(&target_dir).unwrap();
        
        // Create test file in source
        let test_file_path = source_dir.join("test.txt");
        let mut file = File::create(&test_file_path).unwrap();
        write!(file, "test content").unwrap();
        
        // Test copying to existing directory
        assert!(copy_directory(&source_dir, &target_dir).is_ok());
        
        // Verify file was copied
        let copied_file = target_dir.join("test.txt");
        assert!(copied_file.exists());
        assert_eq!(fs::read_to_string(copied_file).unwrap(), "test content");
    }
    
}