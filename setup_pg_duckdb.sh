#!/bin/bash

# Error handling function
handle_error() {
  local line_no=$1
  local exit_code=$2
  echo "ERROR: An error occurred at line ${line_no}, exit code ${exit_code}"
  exit ${exit_code}
}

# Set up error trap
trap 'handle_error ${LINENO} $?' ERR

# Script to install Docker and run PGDuckDB with MotherDuck on AWS EC2
# Usage: POSTGRES_PASSWORD=your_secure_password MOTHERDUCK_TOKEN=your_md_token ./setup_pgduckdb.sh

# Detect OS
if grep -q 'Amazon Linux release 2023' /etc/os-release; then
  OS_VERSION="Amazon Linux 2023"
elif grep -q 'Amazon Linux release 2' /etc/os-release; then
  OS_VERSION="Amazon Linux 2"
elif grep -q 'Ubuntu' /etc/os-release; then
  OS_VERSION="Ubuntu"
else
  OS_VERSION="Linux"
fi

echo "Starting setup for PGDuckDB with MotherDuck on $OS_VERSION..."

# Check if required environment variables are set
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "ERROR: POSTGRES_PASSWORD environment variable is not set."
  echo "Usage: POSTGRES_PASSWORD=your_secure_password MOTHERDUCK_TOKEN=your_md_token ./setup_pgduckdb.sh"
  exit 1
fi

if [ -z "$MOTHERDUCK_TOKEN" ]; then
  echo "ERROR: MOTHERDUCK_TOKEN environment variable is not set."
  echo "Usage: POSTGRES_PASSWORD=your_secure_password MOTHERDUCK_TOKEN=your_md_token ./setup_pgduckdb.sh"
  exit 1
fi

# Update package lists - continue even if there are errors with some repositories
echo "Updating package lists..."
if [[ "$OS_VERSION" == "Ubuntu" ]]; then
  sudo apt-get update -y || true
elif [[ "$OS_VERSION" == "Amazon Linux 2023" ]]; then
  sudo dnf update -y || true
else
  sudo yum update -y || true
fi

# Check if Docker is already installed
if command -v docker &>/dev/null; then
  echo "Docker is already installed, skipping installation."
else
  # Install prerequisites based on OS
  echo "Installing prerequisites..."
  if [[ "$OS_VERSION" == "Ubuntu" ]]; then
    sudo apt-get install -y \
      apt-transport-https \
      ca-certificates \
      curl \
      gnupg \
      lsb-release
  elif [[ "$OS_VERSION" == "Amazon Linux 2023" ]]; then
    # Use --allowerasing to handle curl package conflicts
    sudo dnf install -y --allowerasing \
      device-mapper-persistent-data \
      lvm2 \
      ca-certificates
  else
    sudo yum install -y \
      device-mapper-persistent-data \
      lvm2 \
      ca-certificates
  fi

  # Install Docker based on OS
  echo "Installing Docker..."
  if [[ "$OS_VERSION" == "Ubuntu" ]]; then
    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    # Set up the repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    # Update and install
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
  elif [[ "$OS_VERSION" == "Amazon Linux 2023" ]]; then
    # Amazon Linux 2023 - use the standard package
    sudo dnf install -y docker
  elif [[ "$OS_VERSION" == "Amazon Linux 2" ]]; then
    # Amazon Linux 2 - use extras
    sudo amazon-linux-extras install -y docker
  else
    # Fallback
    sudo yum install -y docker
  fi

  # Verify Docker was installed
  if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker installation failed."
    exit 1
  fi
fi

# Start Docker service
echo "Starting Docker service..."
sudo systemctl start docker || sudo service docker start
sudo systemctl enable docker || sudo chkconfig docker on

# Add current user to docker group to avoid using sudo with docker commands
echo "Adding current user to docker group..."
sudo usermod -aG docker "$USER"

# Create data directory if it doesn't exist
echo "Creating data directory..."
mkdir -p ~/pgduckdb_data

# Check architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
  echo "Using ARM64 architecture (Graviton3)..."
else
  echo "Using x86_64 architecture..."
fi

# Check if container already exists and remove it if necessary
if sudo docker ps -a | grep -q pgduckdb; then
  echo "Found existing pgduckdb container. Removing it..."
  sudo docker stop pgduckdb || true
  sudo docker rm pgduckdb || true
fi

# Pull the Docker image
echo "Pulling Docker image..."
sudo docker pull ankane/pgvector:latest

# Check available system memory
echo "Checking system memory..."
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
echo "Total system memory: ${TOTAL_MEM_MB}MB"

# Calculate 75% of system memory for Docker container limit
DOCKER_MEM_LIMIT=$((TOTAL_MEM_MB * 75 / 100))
echo "Setting Docker container memory limit to: ${DOCKER_MEM_LIMIT}MB"

# Run the Docker container with memory limit
echo "Starting PostgreSQL container..."
sudo docker run -d \
  --name pgduckdb \
  -p 5432:5432 \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e MOTHERDUCK_TOKEN="$MOTHERDUCK_TOKEN" \
  -v ~/pgduckdb_data:/var/lib/postgresql/data \
  --restart unless-stopped \
  --memory=${DOCKER_MEM_LIMIT}m \
  ankane/pgvector:latest

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
sleep 10

# Create the extension
echo "Creating DuckDB extension..."
sudo docker exec -i pgduckdb psql -U postgres << EOF
-- Create DuckDB extension
CREATE EXTENSION IF NOT EXISTS duckdb;

-- Memory configuration optimized for AWS m7g.xlarge with more conservative settings
ALTER SYSTEM SET work_mem = '32MB';                    -- Per-operation memory for sorts, joins, etc.
ALTER SYSTEM SET maintenance_work_mem = '512MB';       -- Memory for maintenance operations
ALTER SYSTEM SET shared_buffers = '2GB';               -- ~12.5% of RAM for shared buffer cache
ALTER SYSTEM SET effective_cache_size = '6GB';         -- Conservative estimate of OS cache
ALTER SYSTEM SET max_connections = '100';              -- Reduced maximum concurrent connections

-- Detailed query logging
ALTER SYSTEM SET log_min_duration_statement = '0';     -- Log all queries
ALTER SYSTEM SET log_statement = 'all';                -- Log all SQL statements
ALTER SYSTEM SET log_duration = 'on';                  -- Log duration of each SQL statement
ALTER SYSTEM SET log_line_prefix = '%t [%p]: [%l-1] db=%d,user=%u '; -- Prefix format

-- Apply changes
SELECT pg_reload_conf();
EOF

# Create monitoring script
echo "Creating monitoring script..."
cat > ~/monitor_pg.sh << 'EOF'
#!/bin/bash
echo "=== PostgreSQL Container Status ==="
docker ps -a -f name=pgduckdb

echo -e "\n=== Resource Usage ==="
docker stats --no-stream pgduckdb

echo -e "\n=== Recent Logs ==="
docker logs --tail 10 pgduckdb

echo -e "\n=== Connection Test ==="
docker exec -it pgduckdb pg_isready -U postgres
if [ $? -eq 0 ]; then
  echo "PostgreSQL is accepting connections."
else
  echo "PostgreSQL is not accepting connections."
fi
EOF
chmod +x ~/monitor_pg.sh

# Create startup script
echo "Creating startup script..."
cat > ~/start_pg.sh << 'EOF'
#!/bin/bash
echo "Starting PostgreSQL container..."
docker start pgduckdb
echo "Container status:"
docker ps -a -f name=pgduckdb
EOF
chmod +x ~/start_pg.sh

# Check if container is running or restarting
echo "Checking container status..."
CONTAINER_STATUS=$(sudo docker inspect -f '{{.State.Status}}' pgduckdb 2>/dev/null || echo "not_found")

if [[ "$CONTAINER_STATUS" == "restarting" ]]; then
  echo "WARNING: Container is restarting. Checking logs for errors..."
  sudo docker logs pgduckdb
  echo "
Try reducing the memory settings in the PostgreSQL configuration if the container keeps restarting."
  echo "You can manually adjust settings by connecting to the container once it's stable."
elif [[ "$CONTAINER_STATUS" != "running" && "$CONTAINER_STATUS" != "not_found" ]]; then
  echo "WARNING: Container is not running (status: $CONTAINER_STATUS). Checking logs for errors..."
  sudo docker logs pgduckdb
fi

# Final status check
echo "=== Setup Complete ==="
echo "PostgreSQL with DuckDB is now running."
echo "Container status:"
sudo docker ps -a -f name=pgduckdb

echo -e "\n=== Connection Information ==="
echo "Host: localhost"
echo "Port: 5432"
echo "User: postgres"
echo "Password: [The password you provided]"
echo "Database: postgres"

echo -e "\n=== Useful Commands ==="
echo "Monitor status: ./monitor_pg.sh"
echo "Start after reboot: ./start_pg.sh"
echo "Connect to PostgreSQL: docker exec -it pgduckdb psql -U postgres"
echo "View logs: docker logs pgduckdb"

echo -e "\n=== Note ==="
echo "You may need to log out and log back in for the docker group changes to take effect."
echo "After that, you can run docker commands without sudo."
