# Database Export Processing Tool - Project Status

## Project Goal
Create a configurable Rust project to process Informix database export files according to a config.yml specification. The tool should:

1. Copy Operations:
   - Copy [source].exp directory to [target].exp
   - Process the target directory according to configuration

2. File Management:
   - Remove .unl files for excluded tables
   - Use .sql file to map table names to .unl filenames
   - Parse CREATE statements to map field positions in .unl files
   - Remove original .sql file
   - Generate new .sql file for data loading

3. Data Processing:
   - Process pipe-delimited .unl files based on configuration
   - Implement three types of field updates:
     - Random name generation (using adjectives.txt and nouns.txt)
     - Field standardization
     - Field combinations with separators

4. SQL Generation:
   - Create new SQL file that:
     - Removes existing records from tables
     - Loads data from modified .unl files

## Current Status

### Completed Components
1. Project Structure:
   - Basic scaffolding
   - Error handling implementation
   - Config parsing system
   - Test environment setup
   - Initial documentation

2. Configuration:
   - Complete config structs defined
   - YAML parsing implemented
   - Support for all required config types:
     - Database settings
     - Table exclusions
     - Scrubbing rules
     - Standardization rules
     - Field combination rules

3. Utilities:
   - Random name generation
   - Directory copying functionality

### In Progress / Next Steps

1. SQL Parser Implementation (`sql.rs`):
   - Status: Needs Implementation
   - Priority: High
   - Requirements:
     - Parse CREATE TABLE statements
     - Extract table/unl file mappings
     - Generate field position mappings
     - Support for generating new SQL

2. UNL File Processor (`unl.rs`):
   - Status: Needs Implementation
   - Priority: High
   - Requirements:
     - Read/parse pipe-delimited files
     - Update specified fields
     - Support all update types
     - Handle file writing

3. Core Processor:
   - Status: Basic Structure Only
   - Priority: Medium
   - Requirements:
     - Implement main processing flow
     - Coordinate between components
     - Handle file operations
     - Apply configurations

### Remaining Work

1. Implementation Priorities:
   - SQL Parser (High Priority)
   - UNL File Processor (High Priority)
   - Core Processing Logic (Medium Priority)
   - Testing Framework (Medium Priority)
   - Documentation (Low Priority)

2. Testing Requirements:
   - Unit tests for each component
   - Integration tests
   - Test data generation
   - Verification system

3. Documentation Needs:
   - API documentation
   - Usage examples
   - Configuration guide
   - Testing guide

## Dependencies
- serde/serde_yaml: Config parsing
- rand: Random name generation
- anyhow: Error handling
- regex: SQL parsing
- tempfile: Testing support

## Timeline
1. Phase 1: Core Implementation
   - SQL Parser
   - UNL File Processor
   - Basic Processing Logic

2. Phase 2: Testing & Verification
   - Test Framework
   - Integration Tests
   - Verification System

3. Phase 3: Documentation & Cleanup
   - Documentation Updates
   - Code Cleanup
   - Performance Optimization