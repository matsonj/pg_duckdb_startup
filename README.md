# Setting up PGDuckDB on AWS m7g.xlarge EC2 Instance

## Overview
This repository contains a script to set up PostgreSQL with DuckDB integration (PGDuckDB) on an AWS m7g.xlarge instance (ARM-based Graviton3, 16GB RAM, 4 vCPUs) in the us-east-1b region. The script installs Docker, configures PostgreSQL with optimized settings, and sets up detailed query logging.

## Installation

1. Copy the `setup_pg_duckdb.sh` script to your EC2 instance via SSH:
   ```bash
   scp setup_pg_duckdb.sh ec2-user@your-instance-ip:~
   ```

2. SSH into your EC2 instance:
   ```bash
   ssh ec2-user@your-instance-ip
   ```

3. Make the script executable:
   ```bash
   chmod +x setup_pg_duckdb.sh
   ```

4. Run the script with your credentials:
   ```bash
   POSTGRES_PASSWORD=your_secure_password MOTHERDUCK_TOKEN=your_md_token ./setup_pg_duckdb.sh
   ```

## Features

### Optimized PostgreSQL Configuration
The script configures PostgreSQL with settings optimized for an a1.xlarge instance:

```sql
-- Memory configuration optimized for AWS m7g.xlarge (16GB RAM, 4 vCPUs, Graviton3)
ALTER SYSTEM SET work_mem = '64MB';                    -- Per-operation memory
ALTER SYSTEM SET maintenance_work_mem = '1GB';         -- Maintenance operations
ALTER SYSTEM SET shared_buffers = '4GB';               -- 25% of RAM
ALTER SYSTEM SET effective_cache_size = '10GB';        -- OS cache estimate
```

### Detailed Query Logging
All SQL queries are logged with detailed information:

```sql
-- Detailed query logging
ALTER SYSTEM SET log_min_duration_statement = '0';     -- Log all queries
ALTER SYSTEM SET log_statement = 'all';                -- Log all SQL statements
ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d '; -- Timestamp, process ID, etc.
```

### Data Persistence
The script sets up a data directory that persists across container restarts and system reboots.

### Monitoring and Management
The installation includes two utility scripts:

1. **monitor_pg.sh**: A monitoring script that shows:
   - Container status
   - Resource usage
   - Recent logs
   - Connection test
   
   Run it with: `./monitor_pg.sh`

2. **start_pg.sh**: A startup script to easily restart the container after system reboots
   
   Run it with: `./start_pg.sh`

## Common Commands

```bash
# Check status
./monitor_pg.sh

# Start after reboot
./start_pg.sh

# Connect to PostgreSQL
docker exec -it pgduckdb psql -U postgres

# View logs
docker logs pgduckdb
```

## Notes
- The container is configured to restart automatically after system reboots
- All PostgreSQL data is stored in `~/pgduckdb_data` for persistence
- The script includes error handling and architecture detection for ARM-based instances
- Optimized specifically for AWS m7g.xlarge instances with Graviton3 processors
- Available in the us-east-1b region

## Performance Benefits of m7g.xlarge
- Uses the latest AWS Graviton3 processors (faster than Graviton1/Graviton2)
- DDR5 memory with 50% more bandwidth than DDR4
- 16GB RAM allows for larger buffer caches and better query performance
- Excellent price-performance ratio for database workloads
