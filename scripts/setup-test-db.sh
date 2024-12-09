#!/bin/bash

echo "DATABASE sysmaster;
DROP DATABASE IF EXISTS test_db;
CREATE DATABASE test_db;" | dbaccess - 2>/dev/null

dbaccess test_db << 'EOF'
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
    name VARCHAR(100),
    email VARCHAR(100),
    address VARCHAR(200),
    phone VARCHAR(20)
);

CREATE TABLE projects (
    id SERIAL,
    project_name VARCHAR(100),
    name1 VARCHAR(50),
    name2 VARCHAR(50),
    combo_name VARCHAR(150)
);

CREATE TABLE repositories (
    id SERIAL,
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

INSERT INTO train_specific_data VALUES (0, 'sample_data', 'test_value_1');
INSERT INTO train_specific_data VALUES (0, 'test_case', 'scenario_1');

INSERT INTO customers VALUES (0, 'John1', 'Doe1', 'test1@example.com', '123 Test St', '555-0101');
INSERT INTO customers VALUES (0, 'John2', 'Doe2', 'test2@example.com', '123 Test St', '555-0102');
INSERT INTO customers VALUES (0, 'John3', 'Doe3', 'test3@example.com', '123 Test St', '555-0103');

INSERT INTO employees VALUES (0, 'Employee1', 'emp1@example.com', '456 Work St', '555-0201');
INSERT INTO employees VALUES (0, 'Employee2', 'emp2@example.com', '456 Work St', '555-0202');
INSERT INTO employees VALUES (0, 'Employee3', 'emp3@example.com', '456 Work St', '555-0203');

INSERT INTO projects VALUES (0, 'Project1', 'Name1_1', 'Name2_1', NULL);
INSERT INTO projects VALUES (0, 'Project2', 'Name1_2', 'Name2_2', NULL);

INSERT INTO repositories VALUES (0, 'Owner1', 'Repo1', NULL);
INSERT INTO repositories VALUES (0, 'Owner2', 'Repo2', NULL);

INSERT INTO training_config VALUES (0, 'test_mode', 'true');
INSERT INTO training_config VALUES (0, 'debug_level', 'info');
EOF

echo "Database setup complete."