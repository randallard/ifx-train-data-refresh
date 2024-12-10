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

-- Insert essential records first (IDs 1001 and 1002)
INSERT INTO customers (id, first_name, last_name, email, address, phone)
    VALUES (1001, 'Essential1', 'User1', 'essential1@example.com', '123 Essential St', '555-1001');
INSERT INTO customers (id, first_name, last_name, email, address, phone)
    VALUES (1002, 'Essential2', 'User2', 'essential2@example.com', '456 Essential St', '555-1002');

-- Insert regular test data
INSERT INTO customers (first_name, last_name, email, address, phone)
    VALUES ('John1', 'Doe1', 'test1@example.com', '123 Test St', '555-0101');
INSERT INTO customers (first_name, last_name, email, address, phone)
    VALUES ('John2', 'Doe2', 'test2@example.com', '123 Test St', '555-0102');
INSERT INTO customers (first_name, last_name, email, address, phone)
    VALUES ('John3', 'Doe3', 'test3@example.com', '123 Test St', '555-0103');

INSERT INTO employees (name, email, address, phone)
    VALUES ('Employee1', 'emp1@example.com', '456 Work St', '555-0201');
INSERT INTO employees (name, email, address, phone)
    VALUES ('Employee2', 'emp2@example.com', '456 Work St', '555-0202');
INSERT INTO employees (name, email, address, phone)
    VALUES ('Employee3', 'emp3@example.com', '456 Work St', '555-0203');

INSERT INTO projects (project_name, name1, name2)
    VALUES ('Project1', 'Name1_1', 'Name2_1');
INSERT INTO projects (project_name, name1, name2)
    VALUES ('Project2', 'Name1_2', 'Name2_2');

INSERT INTO repositories (owner_name, repo_name)
    VALUES ('Owner1', 'Repo1');
INSERT INTO repositories (owner_name, repo_name)
    VALUES ('Owner2', 'Repo2');

INSERT INTO training_config (config_key, config_value)
    VALUES ('test_mode', 'true');
INSERT INTO training_config (config_key, config_value)
    VALUES ('debug_level', 'info');

INSERT INTO train_specific_data (data_key, data_value)
    VALUES ('sample_data', 'test_value_1');
INSERT INTO train_specific_data (data_key, data_value)
    VALUES ('test_case', 'scenario_1');
EOF

echo "Database setup complete."