#!/bin/bash

set -e

# Database setup
dbaccess - << EOF
DROP DATABASE IF EXISTS test_live;
CREATE DATABASE test_live WITH LOG;
EOF

# Connect to test_live
dbaccess test_live << EOF

-- Create tables
CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    first_name VARCHAR(255),
    last_name VARCHAR(255),
    email VARCHAR(255),
    phone VARCHAR(20),
    address TEXT
);

CREATE TABLE employees (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    email VARCHAR(255),
    phone VARCHAR(20),
    address TEXT
);

CREATE TABLE projects (
    id SERIAL PRIMARY KEY,
    project_name VARCHAR(255),
    name1 VARCHAR(255),
    name2 VARCHAR(255),
    combo_name VARCHAR(255),
    customer_id INTEGER REFERENCES customers(id)
);

CREATE TABLE repositories (
    id SERIAL PRIMARY KEY,
    repo_name VARCHAR(255),
    owner_name VARCHAR(255),
    full_path VARCHAR(255),
    project_id INTEGER REFERENCES projects(id)
);

-- Create excluded tables
CREATE TABLE training_config (
    id SERIAL PRIMARY KEY,
    config_key VARCHAR(255),
    config_value TEXT
);

CREATE TABLE train_specific_data (
    id SERIAL PRIMARY KEY,
    data_key VARCHAR(255),
    data_value TEXT
);

-- Insert essential records (IDs 1001, 1002) with dependencies
INSERT INTO customers (id, first_name, last_name, email, phone, address) VALUES
(1001, 'John', 'Essential', 'john@example.com', '555-1001', '123 Main St'),
(1002, 'Jane', 'Critical', 'jane@example.com', '555-1002', '456 Oak Ave');

-- Projects for essential customers
INSERT INTO projects (id, project_name, name1, name2, customer_id) VALUES
(2001, 'Essential Project 1', 'Essential', 'Core', 1001),
(2002, 'Critical Project 1', 'Critical', 'Base', 1002);

-- Repositories for essential projects
INSERT INTO repositories (id, repo_name, owner_name, project_id) VALUES
(3001, 'core-repo', 'essential-team', 2001),
(3002, 'base-repo', 'critical-team', 2002);

-- Insert regular test data
-- Customers
INSERT INTO customers (first_name, last_name, email, phone, address)
SELECT 
    'User' || i::VARCHAR,
    'Test' || i::VARCHAR,
    'user' || i::VARCHAR || '@test.com',
    '555-' || LPAD(i::VARCHAR, 4, '0'),
    i || ' Test St, Test City, ST ' || LPAD(i::VARCHAR, 5, '0')
FROM (SELECT GENERATE_SERIES(1, 100) AS i) series;

-- Employees
INSERT INTO employees (name, email, phone, address)
SELECT 
    'Employee' || i::VARCHAR,
    'emp' || i::VARCHAR || '@company.com',
    '555-' || LPAD(i::VARCHAR, 4, '0'),
    i || ' Work St, Work City, ST ' || LPAD(i::VARCHAR, 5, '0')
FROM (SELECT GENERATE_SERIES(1, 50) AS i) series;

-- More projects
INSERT INTO projects (project_name, name1, name2, customer_id)
SELECT 
    'Project' || i::VARCHAR,
    'Name1_' || i::VARCHAR,
    'Name2_' || i::VARCHAR,
    (i % 100) + 1
FROM (SELECT GENERATE_SERIES(1, 200) AS i) series;

-- More repositories
INSERT INTO repositories (repo_name, owner_name, project_id)
SELECT 
    'repo' || i::VARCHAR,
    'owner' || i::VARCHAR,
    (i % 200) + 1
FROM (SELECT GENERATE_SERIES(1, 300) AS i) series;

-- Insert data into excluded tables
INSERT INTO training_config (config_key, config_value)
SELECT 
    'config_key_' || i::VARCHAR,
    'test_value_' || i::VARCHAR
FROM (SELECT GENERATE_SERIES(1, 50) AS i) series;

INSERT INTO train_specific_data (data_key, data_value)
SELECT 
    'data_key_' || i::VARCHAR,
    'specific_value_' || i::VARCHAR
FROM (SELECT GENERATE_SERIES(1, 50) AS i) series;

EOF

echo "Test database setup complete. Created:"
echo "- Essential records (IDs: 1001, 1002) with dependencies"
echo "- 100 customers"
echo "- 50 employees"
echo "- 200 projects"
echo "- 300 repositories"
echo "- 50 training configs (excluded)"
echo "- 50 training-specific data records (excluded)"