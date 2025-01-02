use std::path::{Path, PathBuf};
use std::env;
use ifx_train_data_refresh::{Config, DbExportProcessor, Error};

fn main() {
    if let Err(e) = run() {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

fn run() -> Result<(), Error> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 4 {
        eprintln!("Usage: {} <config.yml> <source_dir> <target_dir>", args[0]);
        return Ok(());
    }

    let config = Config::from_file(&args[1])?;
    let source_path = PathBuf::from(&args[2]);
    let target_path = PathBuf::from(&args[3]);

    let processor = DbExportProcessor::new(
        config,
        source_path,
        target_path,
    )?;

    processor.process()?;
    println!("Processing completed successfully");
    Ok(())
}