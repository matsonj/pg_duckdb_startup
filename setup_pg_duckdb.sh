#!/bin/bash
# Enhanced setup script for PGDuckDB with MotherDuck on AWS m7g.xlarge (ARM Graviton3)

# Better error handling
set -e
set -o pipefail

# Function to handle errors
handle_error() {
  echo "ERROR: An error occurred at line $1, exit code $2"
  exit $2
}

# Set up error trap
trap 'handle_error ${LINENO} $?' ERR

# Script to install Docker and run PGDuckDB with MotherDuck on Amazon Linux EC2
# Usage: POSTGRES_PASSWORD=your_secure_password MOTHERDUCK_TOKEN=your_md_token ./setup_pgduckdb.sh

echo "Starting setup for PGDuckDB with MotherDuck on Ubuntu..."

# Check if required environment variables are set
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "Error: POSTGRES_PASSWORD environment variable is not set."
  echo "Usage: POSTGRES_PASSWORD=your_secure_password MOTHERDUCK_TOKEN=your_md_token ./setup_pgduckdb.sh"
  exit 1
fi

if [ -z "$MOTHERDUCK_TOKEN" ]; then
  echo "Error: MOTHERDUCK_TOKEN environment variable is not set."
  echo "Usage: POSTGRES_PASSWORD=your_secure_password MOTHERDUCK_TOKEN=your_md_token ./setup_pgduckdb.sh"
  exit 1
fi

# Update package lists - continue even if there are errors with some repositories
echo "Updating package lists..."
sudo yum update -y || true

# Check if Docker is already installed
if command -v docker &>/dev/null; then
  echo "Docker is already installed, skipping installation."
else
  # Install prerequisites
  echo "Installing prerequisites..."
  sudo yum install -y \
    amazon-linux-extras \
    yum-utils \
    device-mapper-persistent-data \
    lvm2 \
    ca-certificates \
    curl

  # Set up the Docker repository
  echo "Setting up Docker repository..."
  sudo amazon-linux-extras install docker -y || sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

  # Install Docker Engine
  echo "Installing Docker Engine..."
  sudo yum install -y docker-ce docker-ce-cli containerd.io
fi

# Start Docker service
echo "Starting Docker service..."
sudo systemctl start docker || sudo service docker start
sudo systemctl enable docker || sudo chkconfig docker on

# Add current user to docker group to avoid using sudo with docker commands
echo "Adding current user to docker group..."
sudo usermod -aG docker $USER
echo "Note: You may need to log out and back in for group changes to take effect"

# Verify Docker is installed correctly
echo "Verifying Docker installation..."
sudo docker --version

# Create a PostgreSQL configuration file
echo "Creating PostgreSQL configuration file..."
cat >pg_config.sql <<EOF
-- Memory configuration optimized for AWS m7g.xlarge (16GB RAM, 4 vCPUs, Graviton3)
ALTER SYSTEM SET work_mem = '64MB';                    -- Per-operation memory for sorts, joins, etc.
ALTER SYSTEM SET maintenance_work_mem = '1GB';        -- Memory for maintenance operations
ALTER SYSTEM SET shared_buffers = '4GB';               -- 25% of RAM for shared buffer cache
ALTER SYSTEM SET effective_cache_size = '10GB';        -- Estimate of available OS cache
ALTER SYSTEM SET max_connections = '150';              -- Limit concurrent connections

-- CPU configuration
ALTER SYSTEM SET max_worker_processes = '4';           -- Based on vCPUs
ALTER SYSTEM SET max_parallel_workers_per_gather = '2'; -- Workers per parallel operation
ALTER SYSTEM SET max_parallel_workers = '4';           -- Max parallel workers

-- Query logging configuration
ALTER SYSTEM SET log_destination = 'stderr';           -- Log to stderr (captured by Docker)
ALTER SYSTEM SET logging_collector = 'on';             -- Enable log collection
ALTER SYSTEM SET log_directory = 'pg_log';             -- Log directory
ALTER SYSTEM SET log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'; -- Log filename format
ALTER SYSTEM SET log_rotation_age = '1d';              -- Rotate logs daily
ALTER SYSTEM SET log_rotation_size = '100MB';          -- Or when they reach 100MB

-- Detailed query logging
ALTER SYSTEM SET log_min_duration_statement = '0';     -- Log all queries (0ms or longer)
ALTER SYSTEM SET log_statement = 'all';                -- Log all SQL statements
ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d '; -- Timestamp, process ID, user, database
ALTER SYSTEM SET log_checkpoints = 'on';               -- Log checkpoint information
ALTER SYSTEM SET log_connections = 'on';               -- Log connection attempts
ALTER SYSTEM SET log_disconnections = 'on';            -- Log session terminations
ALTER SYSTEM SET log_lock_waits = 'on';                -- Log lock wait events
ALTER SYSTEM SET log_temp_files = '0';                 -- Log all temp file usage

-- Apply configuration changes
SELECT pg_reload_conf();
EOF

# Check for ARM architecture
ARCH=$(uname -m)
if [[ $ARCH == "aarch64" || $ARCH == "arm64" ]]; then
  echo "Detected ARM architecture: $ARCH (Graviton3)"
else
  echo "Warning: This script is optimized for ARM architecture (m7g.xlarge), but detected $ARCH"
  echo "Proceeding anyway, but you may need to adjust settings..."
  sleep 3
fi

# Create a data directory for persistence
echo "Creating data directory for persistence..."
DATA_DIR="$HOME/pgduckdb_data"
sudo mkdir -p $DATA_DIR
sudo chmod 777 $DATA_DIR

# Run PGDuckDB container with volume mount for persistence
echo "Running PGDuckDB container..."
CONTAINER_ID=$(sudo docker run -d \
  -p 5432:5432 \
  -v $DATA_DIR:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e MOTHERDUCK_TOKEN="$MOTHERDUCK_TOKEN" \
  --restart unless-stopped \
  --name pgduckdb \
  pgduckdb/pgduckdb:17-main -c duckdb.motherduck_enabled=true)

echo "Container started with ID: $CONTAINER_ID"

# Wait for PostgreSQL to start up
echo "Waiting for PostgreSQL to start up..."
sleep 10

# Apply PostgreSQL configuration
echo "Applying PostgreSQL configuration..."
sudo docker exec -i $CONTAINER_ID psql -U postgres -f - <pg_config.sql

echo "Checking if container is running..."
sudo docker ps

# Create a simple monitoring script
echo "Creating monitoring script..."
cat >monitor_pg.sh <<EOF
#!/bin/bash

# Simple monitoring script for PostgreSQL
echo "=== PostgreSQL Container Status ==="
docker ps -f name=pgduckdb

echo "\n=== PostgreSQL Resource Usage ==="
docker stats --no-stream pgduckdb

echo "\n=== PostgreSQL Logs (last 20 lines) ==="
docker logs --tail 20 pgduckdb

echo "\n=== PostgreSQL Connection Test ==="
docker exec -i pgduckdb psql -U postgres -c \"SELECT version();\"
EOF

chmod +x monitor_pg.sh

# Create a simple startup script
echo "Creating startup script..."
cat >start_pg.sh <<EOF
#!/bin/bash

# Check if container exists but is stopped
if docker ps -a -f name=pgduckdb | grep -q pgduckdb; then
  echo "Starting existing pgduckdb container..."
  docker start pgduckdb
else
  echo "Container not found. Please run the full setup script."
fi
EOF

chmod +x start_pg.sh

echo "Setup complete! PGDuckDB with MotherDuck is now running with optimized settings."
echo "You can connect to PostgreSQL on port 5432"
echo "\nUseful commands:"
echo "  - Check status: ./monitor_pg.sh"
echo "  - Start after reboot: ./start_pg.sh"
echo "  - Connect to psql: docker exec -it pgduckdb psql -U postgres"
echo "  - View logs: docker logs pgduckdb"
