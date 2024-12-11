#!/bin/bash

check_dependencies() {
    local missing_tools=()

    # Check for essential Unix tools
    for cmd in sed grep awk tr tail mktemp chmod; do
        if ! command -v $cmd &> /dev/null; then
            missing_tools+=("$cmd")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo "Error: Missing essential tools: ${missing_tools[*]}"
        echo "These will need to be installed before verifying the data refresh scripts."
        exit 1
    fi

    # Create local bin directory if it doesn't exist
    mkdir -p ~/bin
    export PATH=$PATH:~/bin

    # Check for yq
    if ! command -v yq &> /dev/null; then
        echo "Installing yq to ~/bin..."
        if command -v curl &> /dev/null; then
            curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o ~/bin/yq
        elif command -v wget &> /dev/null; then
            wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O ~/bin/yq
        else
            echo "Error: Neither curl nor wget available. Please install yq manually."
            exit 1
        fi
        chmod +x ~/bin/yq
    fi
}

# Check and install dependencies
check_dependencies

dbaccess test_live << 'EOF'
-- Drop and recreate the database
DATABASE sysmaster;
DROP DATABASE IF EXISTS test_live;
CREATE DATABASE test_live;

DATABASE test_live;

-- Create tables with relationships
CREATE TABLE customers (
    id SERIAL,
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    email VARCHAR(100),
    address VARCHAR(200),
    phone VARCHAR(20)
);

CREATE TABLE employees (
    id SERIAL,
    customer_id INTEGER,  -- Foreign key to customers
    name VARCHAR(100),
    email VARCHAR(100),
    address VARCHAR(200),
    phone VARCHAR(20)
);

CREATE TABLE projects (
    id SERIAL,
    customer_id INTEGER,  -- Foreign key to customers
    project_name VARCHAR(100),
    name1 VARCHAR(50),
    name2 VARCHAR(50),
    combo_name VARCHAR(150)
);

CREATE TABLE repositories (
    id SERIAL,
    project_id INTEGER,  -- Foreign key to projects
    owner_name VARCHAR(50),
    repo_name VARCHAR(50),
    full_path VARCHAR(150)
);

CREATE TABLE training_config (
    id SERIAL,
    config_key VARCHAR(50),
    config_value VARCHAR(200)
);

CREATE TABLE train_specific_data (
    id SERIAL,
    data_key VARCHAR(50),
    data_value VARCHAR(255)
);

-- Insert essential records first (IDs 1001 and 1002)
INSERT INTO customers (id, first_name, last_name, email, address, phone)
    VALUES (1001, 'Essential1', 'User1', 'essential1@example.com', '123 Essential St', '555-1001');
INSERT INTO customers (id, first_name, last_name, email, address, phone)
    VALUES (1002, 'Essential2', 'User2', 'essential2@example.com', '456 Essential St', '555-1002');

-- Create related records for essential customers
-- Employees for essential customers
INSERT INTO employees (customer_id, name, email, address, phone)
    VALUES (1001, 'EssentialEmp1', 'emp1@essential.com', '789 Work St', '555-2001');
INSERT INTO employees (customer_id, name, email, address, phone)
    VALUES (1001, 'EssentialEmp2', 'emp2@essential.com', '790 Work St', '555-2002');
INSERT INTO employees (customer_id, name, email, address, phone)
    VALUES (1002, 'EssentialEmp3', 'emp3@essential.com', '791 Work St', '555-2003');

-- Projects for essential customers
INSERT INTO projects (customer_id, project_name, name1, name2)
    VALUES (1001, 'EssentialProj1', 'Essential', 'Project1');
INSERT INTO projects (customer_id, project_name, name1, name2)
    VALUES (1001, 'EssentialProj2', 'Essential', 'Project2');
INSERT INTO projects (customer_id, project_name, name1, name2)
    VALUES (1002, 'EssentialProj3', 'Essential', 'Project3');

-- Repositories for essential projects
INSERT INTO repositories (project_id, owner_name, repo_name)
    SELECT id, 'Essential', 'Repo' || CAST(id AS VARCHAR(10))
    FROM projects 
    WHERE customer_id IN (1001, 1002);

-- Create a temporary sequence table for generating test data
CREATE TEMP TABLE sequence_table (id SERIAL);

-- Insert 100 rows to generate sequence
INSERT INTO sequence_table (id) 
SELECT 0 FROM sysmaster:'informix'.systables WHERE tabid < 100;

-- Insert regular test records
-- 100 regular test customers
INSERT INTO customers (first_name, last_name, email, address, phone)
    SELECT 
        'TestFirst' || CAST(id AS VARCHAR(10)),
        'TestLast' || CAST(id AS VARCHAR(10)),
        'test' || CAST(id AS VARCHAR(10)) || '@example.com',
        CAST(id AS VARCHAR(10)) || ' Test Street',
        '555-' || LPAD(CAST(id AS VARCHAR(10)), 4, '0')
    FROM sequence_table WHERE id <= 100;

-- 50 test employees with random customer assignments
INSERT INTO employees (customer_id, name, email, address, phone)
    SELECT 
        1002 + MOD(id, 100), -- Assign to random customers after essential ones
        'Employee' || CAST(id AS VARCHAR(10)),
        'emp' || CAST(id AS VARCHAR(10)) || '@example.com',
        CAST(id AS VARCHAR(10)) || ' Work Avenue',
        '555-' || LPAD(CAST(id AS VARCHAR(10)), 4, '0')
    FROM sequence_table WHERE id <= 50;

-- 200 test projects with customer assignments
INSERT INTO projects (customer_id, project_name, name1, name2)
    SELECT 
        1002 + MOD(id, 100), -- Assign to random customers after essential ones
        'Project' || CAST(id AS VARCHAR(10)),
        'FirstName' || CAST(id AS VARCHAR(10)),
        'LastName' || CAST(id AS VARCHAR(10))
    FROM sequence_table WHERE id <= 200;

-- First verify our project range
SELECT MIN(id), MAX(id), COUNT(*) FROM projects;

-- Create sequence for repositories
CREATE TEMP TABLE repo_sequence (
    id SERIAL,
    project_id INTEGER
);

-- Generate sequence numbers up to desired repo count
INSERT INTO repo_sequence (id) 
SELECT 0 FROM sysmaster:'informix'.systables WHERE tabid < 100;

-- Update project_ids to cycle through available projects
UPDATE repo_sequence 
SET project_id = (SELECT MIN(id) FROM projects) + MOD((id - 1), 
    (SELECT COUNT(*) FROM projects));

-- Simple insert from sequence
INSERT INTO repositories (project_id, owner_name, repo_name)
SELECT 
    project_id,
    'Owner' || id,
    'Repo' || id
FROM repo_sequence 
WHERE id <= 300;

-- Clean up
DROP TABLE repo_sequence;

-- Verify counts
SELECT COUNT(*) FROM repositories;

-- Training config - single insert per record for simplicity
INSERT INTO training_config (config_key, config_value) VALUES ('database_mode', 'training');
INSERT INTO training_config (config_key, config_value) VALUES ('log_level', 'debug');
INSERT INTO training_config (config_key, config_value) VALUES ('cache_enabled', 'true');
INSERT INTO training_config (config_key, config_value) VALUES ('max_connections', '500');
INSERT INTO training_config (config_key, config_value) VALUES ('timeout_seconds', '3600');
INSERT INTO training_config (config_key, config_value) VALUES ('debug_mode', 'verbose');
INSERT INTO training_config (config_key, config_value) VALUES ('api_version', '2.0.1');
INSERT INTO training_config (config_key, config_value) VALUES ('environment', 'test');
INSERT INTO training_config (config_key, config_value) VALUES ('region', 'us-east');
INSERT INTO training_config (config_key, config_value) VALUES ('cluster_size', 'medium');

-- Train specific data - single insert per record
INSERT INTO train_specific_data (data_key, data_value) VALUES ('model_type', 'classification');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('dataset_version', '2023.1');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('feature_set', 'extended');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('algorithm', 'random_forest');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('batch_size', '256');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('learning_rate', '0.001');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('optimizer', 'adam');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('loss_function', 'categorical_crossentropy');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('metrics', 'accuracy,precision,recall');
INSERT INTO train_specific_data (data_key, data_value) VALUES ('validation_split', '0.2');

-- Clean up
DROP TABLE sequence_table;
EOF

echo "Database setup complete."