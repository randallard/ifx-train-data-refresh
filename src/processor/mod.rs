mod copy;
mod sql;
mod unl;
mod random;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use rayon::prelude::*;
use indicatif::{ProgressBar, ProgressStyle};

use crate::config::Config;
use crate::error::Error;
use crate::processor::sql::{TableInfo};
use crate::processor::unl::{UnlProcessor, UnlRow};

pub struct DbExportProcessor {
    config: Config,
    source_path: PathBuf,
    target_path: PathBuf,
    table_info: Arc<HashMap<String, TableInfo>>,
    adjectives: Vec<String>,
    nouns: Vec<String>,
    progress_logger: ProgressLogger,
}
struct ProgressLogger {
    log_file: Arc<Mutex<File>>,
    log_path: PathBuf,
    start_time: Instant,
}

impl ProgressLogger {
    fn new(log_dir: &Path) -> Result<Self, Error> {
        // Ensure the log directory exists
        fs::create_dir_all(log_dir).map_err(Error::Io)?;
        
        // Create a log file name with timestamp
        let timestamp = chrono::Local::now().format("%Y%m%d_%H%M%S");
        let log_filename = format!("export_{}.log", timestamp);
        let log_path = log_dir.join(log_filename);
        
        // Create the log file with append mode
        let mut log_file = OpenOptions::new()
            .create(true)
            .write(true)
            .append(true)  // Add append mode
            .read(true)
            .open(&log_path)
            .map_err(Error::Io)?;
        
        // Initialize with file metadata
        writeln!(log_file, "=== Log started at {} ===", timestamp)
            .map_err(Error::Io)?;
        
        Ok(Self {
            log_file: Arc::new(Mutex::new(log_file)),
            log_path: log_path,
            start_time: Instant::now(),
        })
    }

    fn log(&self, message: &str) -> Result<(), Error> {
        let elapsed = self.start_time.elapsed();
        let timestamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
        let log_message = format!("[{} +{}s] {}\n", timestamp, elapsed.as_secs(), message);
        
        // Acquire lock and write with error context
        let mut file = self.log_file.lock().map_err(|e| 
            Error::Processing(format!("Failed to lock log file: {}", e)))?;
        
        // Write with better error handling
        file.write_all(log_message.as_bytes())
            .map_err(|e| Error::Processing(format!("Failed to write to log file: {}", e)))?;
        
        file.flush()
            .map_err(|e| Error::Processing(format!("Failed to flush log file: {}", e)))?;
        
        // Print to stdout for debugging
        print!("{}", log_message); // Using print! since message already contains newline
        
        Ok(())
    }

    fn get_log_path(&self) -> &Path {
        &self.log_path
    }
}

impl DbExportProcessor {
    pub fn new(
        config: Config, 
        source_path: PathBuf, 
        target_path: PathBuf
    ) -> Result<Self, Error> {
        // Create log directory and initialize progress logger
        let log_dir = PathBuf::from(&config.verification.logging.directory);
        let progress_logger = ProgressLogger::new(&log_dir)?;
        
        // Load word lists with error recovery
        let adjectives = Self::load_word_list("adjectives.txt")
            .or_else(|_| Self::load_fallback_words())?;
        let nouns = Self::load_word_list("nouns.txt")
            .or_else(|_| Self::load_fallback_words())?;

        // Parse SQL file for table information
        let sql_content = fs::read_to_string(source_path.join("test_live.sql"))?;
        let table_info = Arc::new(sql::parse_sql_file(&sql_content)?);

        Ok(Self {
            config,
            source_path,
            target_path,
            table_info,
            adjectives,
            nouns,
            progress_logger,
        })
    }

    fn load_word_list(filename: &str) -> Result<Vec<String>, Error> {
        fs::read_to_string(filename)?
            .lines()
            .map(String::from)
            .collect::<Vec<_>>()
            .into_iter()
            .filter(|s| !s.is_empty())
            .map(|s| Ok(s))
            .collect()
    }

    fn load_fallback_words() -> Result<Vec<String>, Error> {
        Ok(vec!["default".to_string(), "backup".to_string(), "fallback".to_string()])
    }

    pub fn process(&self) -> Result<(), Error> {
        self.progress_logger.log("Starting export processing")?;

        // Copy source directory to target
        self.copy_directory()?;
        self.progress_logger.log("Copied source directory to target")?;

        // Process UNL files in parallel
        let unl_processor = Arc::new(UnlProcessor::new(
            self.config.clone(),
            (*self.table_info).clone(),
            self.adjectives.clone(),
            self.nouns.clone(),
        ));

        let tables: Vec<_> = self.table_info.keys()
            .filter(|table| !self.config.excluded_tables.contains(&table.to_string()))
            .collect();

        let progress_bar = ProgressBar::new(tables.len() as u64);
        progress_bar.set_style(ProgressStyle::default_bar()
            .template("[{elapsed_precise}] {bar:40.cyan/blue} {pos}/{len} {msg}")
            .map_err(|e| Error::Processing(format!("Failed to set progress bar style: {}", e)))?);

        let results: Vec<Result<(), Error>> = tables.par_iter()
            .map(|table| {
                let result = self.process_table(table, &unl_processor);
                progress_bar.inc(1);
                if let Err(ref e) = result {
                    self.progress_logger.log(&format!("Error processing table {}: {}", table, e))?;
                }
                result
            })
            .collect();

        progress_bar.finish_with_message("Processing complete");

        // Check for any errors
        let errors: Vec<_> = results.into_iter()
            .filter_map(|r| r.err())
            .collect();

        if !errors.is_empty() {
            self.progress_logger.log(&format!("Completed with {} errors", errors.len()))?;
            for error in &errors {
                self.progress_logger.log(&format!("Error: {}", error))?;
            }
            return Err(Error::Processing(format!("Failed to process {} tables", errors.len())));
        }

        self.progress_logger.log("Successfully completed processing")?;
        self.generate_sql()?;
        Ok(())
    }

    fn process_table(&self, table: &str, processor: &UnlProcessor) -> Result<(), Error> {
        let table_info = self.table_info.get(table)
            .ok_or_else(|| Error::Processing(format!("Table info not found for {}", table)))?;

        let source_unl = self.source_path.join(&table_info.unl_file);
        let target_unl = self.target_path.join(&table_info.unl_file);

        // Process with retry logic
        let mut attempts = 0;
        let max_attempts = 3;
        let mut last_error = None;

        while attempts < max_attempts {
            match processor.process_file(table, &source_unl, &target_unl) {
                Ok(_) => return Ok(()),
                Err(e) => {
                    attempts += 1;
                    last_error = Some(e);
                    if attempts < max_attempts {
                        self.progress_logger.log(&format!(
                            "Retry {} of {} for table {}", 
                            attempts, 
                            max_attempts, 
                            table
                        ))?;
                        std::thread::sleep(Duration::from_secs(1));
                    }
                }
            }
        }

        Err(last_error.unwrap_or_else(|| 
            Error::Processing(format!("Failed to process table {}", table))))
    }

    fn copy_directory(&self) -> Result<(), Error> {
        if self.target_path.exists() {
            fs::remove_dir_all(&self.target_path)?;
        }
        fs::create_dir_all(&self.target_path)?;

        for entry in fs::read_dir(&self.source_path)? {
            let entry = entry?;
            let path = entry.path();
            
            // Skip excluded UNL files
            if let Some(file_name) = path.file_name().and_then(|n| n.to_str()) {
                if file_name.ends_with(".unl") {
                    let table_name = file_name.trim_end_matches(".unl");
                    if self.config.excluded_tables.iter().any(|t| table_name.starts_with(t)) {
                        continue;
                    }
                }
            }

            let target = self.target_path.join(path.file_name().unwrap());
            if path.is_file() {
                fs::copy(&path, &target)?;
            }
        }
        Ok(())
    }

    fn generate_sql(&self) -> Result<(), Error> {
        let mut sql_content = String::new();
        sql_content.push_str("-- Generated SQL for loading processed data\n\n");

        for (table, info) in self.table_info.iter() {
            if !self.config.excluded_tables.contains(table) {
                sql_content.push_str(&format!(
                    "DELETE FROM {};\nLOAD FROM {} INSERT INTO {};\n\n",
                    table, info.unl_file, table
                ));
            }
        }

        let sql_path = self.target_path.join("load_data.sql");
        fs::write(sql_path, sql_content)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::{TempDir, tempdir};
    use std::io::Write;

    fn setup_test_environment() -> Result<(TempDir, DbExportProcessor), Error> {
        let temp_dir = tempdir().map_err(|e| Error::Io(std::io::Error::new(
            std::io::ErrorKind::Other,
            format!("Failed to create temp dir: {}", e)
        )))?;
        
        let source_dir = temp_dir.path().join("source");
        let target_dir = temp_dir.path().join("target");
        let log_dir = temp_dir.path().join("logs");

        // Create directories
        fs::create_dir_all(&source_dir).map_err(Error::Io)?;
        fs::create_dir_all(&log_dir).map_err(Error::Io)?;

        // Create test SQL file
        let sql_content = r#"
            { DATABASE test_live  delimiter | }

            { TABLE "informix".customers row size = 429 number of columns = 6 index size = 0 }
            { unload file name = custo00100.unl number of rows = 73 }
            create table "informix".customers 
            (
                id serial not null,
                first_name varchar(50),
                last_name varchar(50),
                email varchar(100),
                address varchar(200),
                phone varchar(20)
            ) extent size 16 next size 16 lock mode row;
        "#;
        fs::write(source_dir.join("test_live.sql"), sql_content).map_err(Error::Io)?;

        // Create test UNL file
        let unl_content = "1001|John|Doe|john@example.com|123 Main St|555-1234|\n\
                          1002|Jane|Smith|jane@example.com|456 Oak St|555-5678|";
        fs::write(source_dir.join("custo00100.unl"), unl_content).map_err(Error::Io)?;

        // Create test word lists
        fs::write("adjectives.txt", "happy\nquick\nclever\n").map_err(Error::Io)?;
        fs::write("nouns.txt", "fox\ndog\ncat\n").map_err(Error::Io)?;

        // Create test configuration with all required fields
        let config = Config::from_str(r#"
            databases:
                source:
                    name: test_live
                target:
                    name: temp_verify
                testing:
                    test_live: test_live
                    temp_verify: temp_verify
                    verification_marker: "VERIFY_TEST_STRING_XYZ_"
                    cleanup_script: remove_verify_db.sh

            export:
                random_seed: 42

            excluded_tables:
                - training_config

            verification:
                logging:
                    directory: logs
                    prefix: verify_
                checksums:
                    enabled: true
                    algorithm: md5sum
                record_counts:
                    enabled: true
                    sample_tables: ["customers"]

            scrubbing:
                random_names:
                    - table: customers
                      fields: [first_name, last_name]
                      style: github

            standardize:
                address:
                    value: "123 Training St"
                    fields:
                        - table: customers
                          field: address
                phone:
                    value: "555-0000"
                    fields:
                        - table: customers
                          field: phone
                email:
                    value: "test@example.com"
                    fields:
                        - table: customers
                          field: email

            combination_fields:
                - table: projects
                  fields:
                    - source_field: name1
                      random_style: github
                    - source_field: name2
                      random_style: github
                  separator: " -&- "
                  target_field: combo_name
        "#)?;

        let processor = DbExportProcessor::new(
            config,
            source_dir,
            target_dir,
        )?;

        Ok((temp_dir, processor))
    }

    #[test]
    fn test_processor_creation() -> Result<(), Error> {
        let (_temp_dir, processor) = setup_test_environment()?;
        assert!(!processor.adjectives.is_empty());
        assert!(!processor.nouns.is_empty());
        assert!(!processor.table_info.is_empty());
        Ok(())
    }

    #[test]
    fn test_directory_copying() -> Result<(), Error> {
        let (_temp_dir, processor) = setup_test_environment()?;
        processor.copy_directory()?;

        // Verify target directory exists
        assert!(processor.target_path.exists());
        
        // Verify SQL file was copied
        assert!(processor.target_path.join("test_live.sql").exists());
        
        // Verify UNL file was copied
        assert!(processor.target_path.join("custo00100.unl").exists());
        
        // Verify excluded files were not copied
        assert!(!processor.target_path.join("train00104.unl").exists());
        
        Ok(())
    }

    #[test]
    fn test_full_processing() -> Result<(), Error> {
        let (_temp_dir, processor) = setup_test_environment()?;
        processor.process()?;

        // Verify target files exist
        assert!(processor.target_path.join("custo00100.unl").exists());
        assert!(processor.target_path.join("load_data.sql").exists());

        // Read processed UNL file
        let processed_content = fs::read_to_string(processor.target_path.join("custo00100.unl"))?;
        let lines: Vec<&str> = processed_content.lines().collect();

        // Verify record count
        assert_eq!(lines.len(), 2);

        // Verify data was scrubbed
        for line in lines {
            let fields: Vec<&str> = line.split('|').collect();
            
            // Check standardized fields
            assert_eq!(fields[4], "123 Training St");
            assert_eq!(fields[5], "555-0000");
            
            // Verify name fields were randomized (not equal to original values)
            assert_ne!(fields[1], "John");
            assert_ne!(fields[1], "Jane");
            assert_ne!(fields[2], "Doe");
            assert_ne!(fields[2], "Smith");
        }

        Ok(())
    }

    #[test]
    fn test_error_recovery() -> Result<(), Error> {
        let (temp_dir, processor) = setup_test_environment()?;
    
        // Log initial message
        processor.progress_logger.log("Starting error recovery test")?;
        
        // Corrupt the source UNL file
        fs::write(
            processor.source_path.join("custo00100.unl"),
            "corrupted|data|without|enough|fields|\n"
        ).map_err(Error::Io)?;
        
        // Processing should fail but not panic
        let process_result = processor.process();
        assert!(process_result.is_err());
        
        // Give filesystem time to sync
        std::thread::sleep(std::time::Duration::from_millis(100));
        
        // Read log content
        let log_content = fs::read_to_string(processor.progress_logger.get_log_path())
            .map_err(|e| Error::Processing(format!("Failed to read log file: {}", e)))?;
        
        // Debug output
        println!("Log file path: {:?}", processor.progress_logger.get_log_path());
        println!("Log content:\n{}", log_content);
        
        // Verify error was logged
        assert!(
            log_content.contains("Starting error recovery test"),
            "Log missing initial test message"
        );
        assert!(
            log_content.contains("Error processing table customers"),
            "Log missing error message"
        );
        
        Ok(())
    }
    
    #[test]
    fn test_sql_generation() -> Result<(), Error> {
        let (_temp_dir, processor) = setup_test_environment()?;
        processor.process()?;

        // Read generated SQL file
        let sql_content = fs::read_to_string(processor.target_path.join("load_data.sql"))?;
        
        // Verify SQL content
        assert!(sql_content.contains("DELETE FROM customers;"));
        assert!(sql_content.contains("LOAD FROM custo00100.unl INSERT INTO customers;"));
        
        // Verify excluded tables are not in SQL
        assert!(!sql_content.contains("training_config"));
        
        Ok(())
    }

    #[test]
    fn test_progress_logging() -> Result<(), Error> {
        let (_temp_dir, processor) = setup_test_environment()?;
        
        // Process the files
        processor.process()?;
        
        // Give filesystem a moment to sync
        std::thread::sleep(std::time::Duration::from_millis(100));
        
        // Read the actual log file
        let log_path = processor.progress_logger.get_log_path();
        let log_content = fs::read_to_string(log_path)
            .map_err(|e| Error::Processing(format!("Failed to read log file: {}", e)))?;
        
        // Debug output
        println!("Log file path: {:?}", log_path);
        println!("Log content:\n{}", log_content);
        
        // Verify log contains expected entries
        assert!(
            log_content.contains("Starting export processing"),
            "Log should contain 'Starting export processing'"
        );
        assert!(
            log_content.contains("Copied source directory to target"),
            "Log should contain 'Copied source directory to target'"
        );
        assert!(
            log_content.contains("Successfully completed processing"),
            "Log should contain 'Successfully completed processing'"
        );
        
        Ok(())
    }

    #[test]
    fn test_fallback_word_lists() -> Result<(), Error> {
        // Rename existing word lists to simulate missing files
        fs::rename("adjectives.txt", "adjectives.txt.bak")?;
        fs::rename("nouns.txt", "nouns.txt.bak")?;

        let (_temp_dir, processor) = setup_test_environment()?;

        // Verify fallback words were loaded
        assert!(!processor.adjectives.is_empty());
        assert!(!processor.nouns.is_empty());

        // Restore word lists
        fs::rename("adjectives.txt.bak", "adjectives.txt")?;
        fs::rename("nouns.txt.bak", "nouns.txt")?;

        Ok(())
    }
}