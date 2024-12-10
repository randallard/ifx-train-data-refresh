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

echo "DATABASE sysmaster;
DROP DATABASE IF EXISTS test_live;
CREATE DATABASE test_live;" | dbaccess - 2>/dev/null

dbaccess test_live << 'EOF'
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