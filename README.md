# Frappe/ERPNext Development Container

This Docker setup provides a complete development environment for Frappe/ERPNext v15 on Ubuntu 24.04 LTS. This container is loosely based on [erpnext_quick_install](https://github.com/flexcomng/erpnext_quick_install), make sure to check it out for production installations.

Frappe provides an [official dev container example](https://github.com/frappe/frappe_docker/blob/main/docs/development.md), so why make this? We wanted a quick, reliable, and repeatable way to spin up development environments for Frappe v15. The container handles all dependencies, app installations, and permissions on first startup. By default, the container installs with ERPNext and HRMS as configured in `docker-compose.yml`. 

## Features

- Single container setup for easy development
- Ubuntu 24.04 LTS base image
- Flexible app configuration - easily add or remove Frappe apps
- Support for both public Frappe apps and private repositories with an optional SSH key
- All required dependencies (MariaDB, Redis, Python, Node.js, etc.)
- Developer mode and `bench watch` enabled by default
- Persistent data volumes
- Environment variable configuration
- Supports ARM & AMD64 architecture

## Prerequisites

- Docker + Compose installed
- At least 4GB of RAM available for Docker
- 10GB+ of free disk space

## Quick Start

1. Clone this repository:
```bash
git clone <your-repo-url>
cd frappe-dev-container
```

2. Copy the example environment file:
```bash
cp env.example .env
```

3. (Optional) Edit `.env` to customize:
   - `SITE_NAME`: Your site name (default: development.localhost)
   - `DB_ROOT_PASSWORD`: MariaDB root password
   - `ADMIN_PASSWORD`: ERPNext Administrator password
   - `SSH_KEY_PATH`: Path to SSH key for private repos

4. Build and start the container:
```bash
docker compose build
docker compose up
```

5. Wait for initialization (first run takes 10-15 minutes). The system will automatically:
   - Initialize MariaDB with your configured password
   - Create a new Frappe bench
   - Install ERPNext application
   - Create your site with ERPNext
   - Enable developer mode
   - Configure localhost access
   - Build all frontend assets

6. After install has completed, restart the container:
```bash
docker compose down
docker compose up
```

7. Access ERPNext at: http://localhost:8000
   - Username: `Administrator`
   - Password: Your `ADMIN_PASSWORD` from `.env` (default: `admin`)

## What Happens on First Run

The container automatically handles the complete setup:

1. **Service Initialization**:
   - Starts MariaDB and Redis services
   - Configures MariaDB with the specified root password

2. **Bench Setup**:
   - Initializes a new Frappe bench (version determined by first app in the list)
   - Installs all apps specified in the `APPS` configuration in `docker-compose.yml`

3. **Site Creation**:
   - Creates a new site with your specified name
   - Installs all configured apps on the site
   - Enables developer mode
   - Enables the scheduler
   - Configures domain access for localhost
   - Builds all frontend assets

4. **Subsequent Runs**:
   - Services start automatically
   - Existing bench and site are used
   - No re-initialization needed

## Container Management

#### Start the container:
```bash
docker compose up
```

#### Start in background:
```bash
docker compose up -d
```

#### Stop the container:
```bash
docker compose down
```

#### View logs:
```bash
docker compose logs -f
```

#### Access container shell:
```bash
docker compose exec frappe zsh
```

#### Run bench commands:
```bash
docker compose exec frappe zsh -lc "cd /home/frappeuser/frappe-bench && bench <command>"
```

Note: NVM is auto-sourced in zsh. For bash:
```bash
docker compose exec frappe bash -lc "source ~/.nvm/nvm.sh && cd /home/frappeuser/frappe-bench && bench build"
```

## Data Persistence

The setup uses Docker volumes to persist:
- Frappe user home directory (including frappe-bench): `frappe-data` volume (mounted at `/home/frappeuser`)
- MariaDB databases: `frappe-mysql` volume

To completely reset and start fresh:
```bash
docker compose down -v
docker compose build --no-cache
docker compose up
```

## Development Workflow

1. **Make code changes**: The frappe-bench directory is mounted as a volume, so changes are reflected immediately

2. **Clear cache after backend changes**:
```bash
docker compose exec frappe zsh -lc "cd /home/frappeuser/frappe-bench && bench --site development.localhost clear-cache"
```

3. **Build assets after frontend changes**:
```bash
docker compose exec frappe zsh -lc "cd /home/frappeuser/frappe-bench && bench build"
```

4. **Watch for frontend changes** (auto-rebuild):
```bash
docker compose exec frappe zsh -lc "cd /home/frappeuser/frappe-bench && bench watch"
```

## Installing Apps

Apps are configured in the `docker-compose.yml` file under the `APPS` environment variable.

### Default Configuration:

```yaml
environment:
  APPS: |
    erpnext:version-15
    hrms:version-15
```

### Adding or Removing Apps:

Simply edit the `APPS` list in `docker-compose.yml`. You can also add comments using `#`:

```yaml
APPS: |
  # Core apps
  erpnext:version-15
  hrms:version-15
  
  # Optional Frappe apps
  payments:version-15   # Specific branch
  insights              # Defaults to main branch        
  
  # Custom + private apps
  custom_app:version-15:git@github.com:username/custom_app.git
```

## SSH Keys

The setup can copy your SSH key into the container for accessing private repositories if `SSH_KEY_PATH` is provided. You can customize this path in your `.env` file:
```env
SSH_KEY_PATH=/path/to/your/.ssh/key
```

The key is copied into the container at startup, ensuring:
- Your host SSH key remains read-only and protected
- The container can manage its own `known_hosts` file
- New Git hosts are automatically accepted (StrictHostKeyChecking=accept-new)
- Private repository access works seamlessly
### Development Workflow with Custom Apps:

If you're developing a custom app, you can:
1. Mount your local app directory as a volume
2. Or specify it in `ADDITIONAL_APPS` to clone from a repository

Example with local development:
```yaml
# In docker-compose.yml
volumes:
  - ./my-custom-app:/home/frappeuser/frappe-bench/apps/my-custom-app
```

Example with remote, private development:
```yaml
APPS: |
  ... existing apps
  your_app:branch:git@github.com:username/custom_app.git
```

## Ports

The following ports are exposed:
- `8000`: Frappe/ERPNext web interface
- `9000`: Frappe/ERPNext socketio service
- `3306`: MariaDB (optional; commented out by default)
- `6379`: Redis (optional; commented out by default)
- `3010`: Misc use (optional; commented out by default)

## Troubleshooting

### Container exits immediately
Check logs with `docker compose logs`. Common issues:
- Port conflicts (especially 8000, 3306, 6379)
- Insufficient memory
- Volume permission issues

### Site not accessible
- Ensure the container is running: `docker compose ps`
- Check if services are running: `docker compose exec frappe bash -c "sudo service mariadb status && sudo service redis-server status"`
- Verify site exists: `docker compose exec frappe zsh -lc "cd /home/frappeuser/frappe-bench && bench list-sites"`

### "Module not found" errors
This typically means one of your apps isn't properly installed. The container handles this automatically, but if you encounter issues, you can manually install an app:

```bash
# For Frappe apps (e.g., payments, insights)
docker compose exec frappe bash -lc "source ~/.nvm/nvm.sh && cd /home/frappeuser/frappe-bench && bench get-app APP_NAME && bench --site development.localhost install-app APP_NAME"

# For private repositories
docker compose exec frappe bash -lc "source ~/.nvm/nvm.sh && cd /home/frappeuser/frappe-bench && bench get-app git@github.com:username/custom_app.git --branch main && bench --site development.localhost install-app app"
```

### Reset everything
To completely start over:
```bash
docker compose down -v # DESTRUCTIVE - ensure your data is backed up
rm -rf frappe-data frappe-mysql  # If volumes are stored locally
docker compose build --no-cache
docker compose up
```