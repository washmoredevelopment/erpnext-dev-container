#!/usr/bin/env bash

# Remove set -e to prevent script exit on errors
# We'll handle errors explicitly instead

# =============================================================================
# FRAPPE DEVELOPMENT CONTAINER ENTRYPOINT
# =============================================================================

# Health status tracking
HEALTH_STATUS_FILE="/tmp/container_health"
APP_INSTALL_LOG="/tmp/app_install.log"

# Initialize health status
echo "starting" > "$HEALTH_STATUS_FILE"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

update_health_status() {
    local status="$1"
    local message="$2"
    echo "$status" > "$HEALTH_STATUS_FILE"
    if [ -n "$message" ]; then
        echo "$message" >> "$HEALTH_STATUS_FILE"
    fi
    log_info "Health status updated: $status"
}

# Function to handle non-fatal errors
handle_non_fatal_error() {
    local operation="$1"
    local error_message="$2"
    log_error "Non-fatal error in $operation: $error_message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR in $operation: $error_message" >> "$APP_INSTALL_LOG"
    update_health_status "degraded" "Some operations failed but container is functional"
}

# Function to handle fatal errors
handle_fatal_error() {
    local operation="$1"
    local error_message="$2"
    log_error "Fatal error in $operation: $error_message"
    update_health_status "unhealthy" "Fatal error: $error_message"
    exit 1
}

# =============================================================================
# ENVIRONMENT SETUP
# =============================================================================

setup_environment() {
    log_info "Setting up environment..."
    
    # Source NVM for all commands
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

    # Ensure we're in the frappe user's home directory
    cd "$HOME" || handle_fatal_error "environment_setup" "Failed to change to home directory"

    # Determine Frappe/ERPNext version to use for bench initialization
    FRAPPE_VERSION="version-15"
    if [ -n "$APPS" ]; then
        first_app_line=$(echo "$APPS" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | head -n 1)
        if [[ "$first_app_line" =~ ^erpnext:(.+) ]]; then
            FRAPPE_VERSION="${BASH_REMATCH[1]%%:*}"
        fi
    fi
    
    log_info "Environment setup complete. Frappe version: $FRAPPE_VERSION"
}

# =============================================================================
# SSH SETUP
# =============================================================================

setup_ssh_key() {
    if [ -f "/tmp/ssh_key" ]; then
        log_info "Setting up SSH key..."
        
        # Create .ssh directory if it doesn't exist
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        
        # Copy the SSH key with strict perms (root does the copy to ensure success)
        if sudo install -m 600 /tmp/ssh_key "$HOME/.ssh/id_rsa"; then
            # Ensure correct ownership regardless of env $USER being unset
            sudo chown "$(id -un)":"$(id -gn)" "$HOME/.ssh/id_rsa"
            
            # Configure SSH to use the key and accept new host keys automatically
            cat > "$HOME/.ssh/config" << EOF
Host *
    IdentityFile ~/.ssh/id_rsa
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
EOF
            chmod 600 "$HOME/.ssh/config"
            
            # Create empty known_hosts file if it doesn't exist
            touch "$HOME/.ssh/known_hosts"
            chmod 644 "$HOME/.ssh/known_hosts"
            
            log_info "SSH key setup completed."
        else
            handle_non_fatal_error "ssh_setup" "Failed to install SSH key"
        fi
    fi
}

# =============================================================================
# DATABASE SETUP
# =============================================================================

setup_mariadb() {
    log_info "Setting up MariaDB..."
    
    # Start MariaDB
    if ! sudo service mariadb start; then
        handle_fatal_error "mariadb_start" "Failed to start MariaDB service"
    fi

    # Initialize MariaDB if not already done
    if [ ! -f ~/.mysql_initialized ]; then
        log_info "Initializing MariaDB..."
        
        # Wait for MariaDB to be ready
        sleep 5
        
        # First try to connect without password (fresh install)
        if sudo mysql -e "SELECT 1" 2>/dev/null; then
            log_info "Setting up MariaDB root password..."
            # Use native authentication for better compatibility
            if sudo mysql << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD:-admin}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
            then
                touch ~/.mysql_initialized
                log_info "MariaDB initialized successfully."
            else
                handle_fatal_error "mariadb_init" "Failed to initialize MariaDB"
            fi
        else
            # Already has a password, try with the expected password
            if sudo mysql -u root -p"${DB_ROOT_PASSWORD:-admin}" -e "SELECT 1" 2>/dev/null; then
                log_info "MariaDB already configured with password."
                touch ~/.mysql_initialized
            else
                handle_fatal_error "mariadb_init" "Cannot connect to MariaDB. Password mismatch?"
            fi
        fi
    fi
}

# =============================================================================
# REDIS MANAGEMENT
# =============================================================================

# Function to wait for Redis instances to be ready
wait_for_redis() {
    log_info "Waiting for Redis services to be ready..."
    for port in 11000 12000 13000; do
        local retries=0
        local max_retries=30
        while ! redis-cli -p $port ping >/dev/null 2>&1; do
            if [ $retries -ge $max_retries ]; then
                handle_non_fatal_error "redis_wait" "Redis on port $port failed to start after $max_retries attempts"
                return 1
            fi
            log_info "Waiting for Redis on port $port... (attempt $((retries + 1))/$max_retries)"
            sleep 2
            retries=$((retries + 1))
        done
        log_info "Redis on port $port is ready"
    done
    log_info "All Redis services ready"
}

setup_redis_services() {
    if [ ! -f "$HOME/frappe-bench/.redis_setup" ]; then
        log_info "Setting up Redis services for version-15..."
        
        # Start additional Redis instances for ERPNext v15/develop
        log_info "Starting Redis instances for version-15 (queue, cache, and socketio)..."
        redis-server --port 11000 --daemonize yes --bind 127.0.0.1
        redis-server --port 12000 --daemonize yes --bind 127.0.0.1
        redis-server --port 13000 --daemonize yes --bind 127.0.0.1
        log_info "Redis instances started for version-15."
        
        # Wait for Redis instances to be ready before proceeding
        if wait_for_redis; then
            if bench setup redis; then
                touch "$HOME/frappe-bench/.redis_setup"
                log_info "Redis setup completed successfully"
            else
                handle_non_fatal_error "redis_setup" "bench setup redis failed"
            fi
        else
            handle_non_fatal_error "redis_setup" "Redis services failed to start properly"
        fi
    fi
}

# =============================================================================
# APP MANAGEMENT
# =============================================================================

# Function to install apps from APPS env variable
install_apps() {
    if [ "$SKIP_APP_INSTALL" = "true" ]; then
        log_info "Skipping app installation (SKIP_APP_INSTALL=true)"
        return 0
    fi
    
    if [ -n "$APPS" ]; then
        log_info "Installing apps..."
        local failed_apps=()
        
        # Convert multiline APPS to array, removing empty lines
        while IFS= read -r app_spec; do
            # Skip empty lines and lines starting with #
            if [[ -z "$app_spec" || "$app_spec" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            
            # Trim whitespace
            app_spec=$(echo "$app_spec" | xargs)
            
            # Parse app specification (app_name:branch:git_url)
            IFS=':' read -ra APP_PARTS <<< "$app_spec"
            app_name="${APP_PARTS[0]}"
            app_branch=""
            app_git_url=""
            
            # Handle git URLs with colons properly
            if [ ${#APP_PARTS[@]} -gt 3 ]; then
                app_branch="${APP_PARTS[1]}"
                # Reconstruct the git URL from remaining parts
                app_git_url="${APP_PARTS[2]}"
                for ((i=3; i<${#APP_PARTS[@]}; i++)); do
                    app_git_url="${app_git_url}:${APP_PARTS[i]}"
                done
            elif [ ${#APP_PARTS[@]} -eq 3 ]; then
                app_branch="${APP_PARTS[1]}"
                app_git_url="${APP_PARTS[2]}"
            elif [ ${#APP_PARTS[@]} -eq 2 ]; then
                app_branch="${APP_PARTS[1]}"
            fi
            
            log_info "Processing app: $app_name"
            
            # Skip if app already exists
            if [ -d "$HOME/frappe-bench/apps/$app_name" ]; then
                log_info "App $app_name already exists, skipping..."
                continue
            fi
            
            # Construct bench get-app command with --skip-assets flag
            local bench_cmd="bench get-app"
            if [ -n "$app_git_url" ]; then
                # Custom repo with git URL
                if [ -n "$app_branch" ]; then
                    log_info "Installing $app_name from $app_git_url (branch: $app_branch)"
                    bench_cmd="$bench_cmd $app_git_url --branch $app_branch --skip-assets"
                else
                    log_info "Installing $app_name from $app_git_url"
                    bench_cmd="$bench_cmd $app_git_url --skip-assets"
                fi
            elif [ -n "$app_branch" ]; then
                # Frappe app with specific branch
                log_info "Installing Frappe app $app_name (branch: $app_branch)"
                bench_cmd="$bench_cmd $app_name --branch $app_branch --skip-assets"
            else
                # Frappe app with default branch
                log_info "Installing Frappe app $app_name"
                bench_cmd="$bench_cmd $app_name --skip-assets"
            fi
            
            # Execute the command with error handling
            if eval "$bench_cmd"; then
                log_info "✅ Successfully installed app: $app_name"
            else
                log_error "❌ Failed to install app: $app_name"
                failed_apps+=("$app_name")
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Failed to install app: $app_name" >> "$APP_INSTALL_LOG"
            fi
            
        done <<< "$APPS"
        
        # Build all assets after all apps are installed (only once)
        if [ ! -f "$HOME/frappe-bench/.assets_built" ]; then
            log_info "Building assets for all apps..."
            if bench build; then
                touch "$HOME/frappe-bench/.assets_built"
                log_info "✅ Assets built successfully"
            else
                handle_non_fatal_error "asset_build" "Failed to build assets"
            fi
        fi
        
        # Report any failed app installations
        if [ ${#failed_apps[@]} -gt 0 ]; then
            handle_non_fatal_error "app_installation" "Failed to install apps: ${failed_apps[*]}"
        fi
    fi
}

# Function to install apps on site
install_apps_on_site() {
    local site_name="$1"
    
    if [ "$SKIP_APP_INSTALL" = "true" ]; then
        log_info "Skipping site app installation (SKIP_APP_INSTALL=true)"
        return 0
    fi
    
    if [ -n "$APPS" ]; then
        log_info "Installing apps on site: $site_name"
        local failed_installs=()
        
        # Convert multiline APPS to array, removing empty lines
        while IFS= read -r app_spec; do
            # Skip empty lines and lines starting with #
            if [[ -z "$app_spec" || "$app_spec" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            
            # Trim whitespace
            app_spec=$(echo "$app_spec" | xargs)
            
            # Extract just the app name (first part before :)
            IFS=':' read -ra APP_PARTS <<< "$app_spec"
            app_name="${APP_PARTS[0]}"
            
            # Check if app exists and is not already installed on site
            if [ -d "$HOME/frappe-bench/apps/$app_name" ]; then
                if ! bench --site "$site_name" list-apps 2>/dev/null | awk '{print $1}' | grep -qx "$app_name"; then
                    log_info "Installing $app_name on site $site_name..."
                    if bench --site "$site_name" install-app "$app_name"; then
                        log_info "✅ Successfully installed $app_name on site $site_name"
                    else
                        log_error "❌ Failed to install $app_name on site $site_name"
                        failed_installs+=("$app_name")
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - Failed to install $app_name on site $site_name" >> "$APP_INSTALL_LOG"
                    fi
                else
                    log_info "App $app_name already installed on site $site_name"
                fi
            else
                log_warn "App $app_name directory not found, skipping site installation"
            fi
        done <<< "$APPS"
        
        # Report any failed site installations
        if [ ${#failed_installs[@]} -gt 0 ]; then
            handle_non_fatal_error "site_app_installation" "Failed to install apps on site: ${failed_installs[*]}"
        fi
    fi
}

# =============================================================================
# BENCH INITIALIZATION
# =============================================================================

initialize_bench() {
    log_info "Checking bench initialization..."
    
    if [ ! -f "$HOME/frappe-bench/sites/apps.txt" ]; then
        log_info "Bench not found or not properly initialized. Initializing..."
        log_info "This will take several minutes. Please be patient..."
        
        # Ensure we're in frappe home directory
        cd "$HOME" || handle_fatal_error "bench_init" "Failed to change to home directory"
        
        # Remove any existing frappe-bench directory if it's incomplete
        if [ -d frappe-bench ] && [ -z "$(ls -A frappe-bench/sites 2>/dev/null)" ]; then
            log_info "Removing incomplete bench directory..."
            rm -rf frappe-bench
        fi
        
        # Initialize bench as frappe user in home directory
        if [ ! -d frappe-bench ]; then
            if bench init frappe-bench --version "$FRAPPE_VERSION" --verbose; then
                log_info "✅ Bench initialized successfully"
            else
                handle_fatal_error "bench_init" "Failed to initialize bench"
            fi
        fi
        
        cd frappe-bench || handle_fatal_error "bench_init" "Failed to change to frappe-bench directory"
        
        # Install all configured apps
        install_apps
        
        # Mark bench as initialized
        touch ~/.bench_initialized
    else
        # Bench already initialized
        log_info "Bench already initialized. Using existing bench at $HOME/frappe-bench"
        cd "$HOME/frappe-bench" || handle_fatal_error "bench_navigation" "Failed to change to frappe-bench directory"
        
        # Install any apps that aren't already installed
        install_apps
    fi
}

# =============================================================================
# SITE MANAGEMENT
# =============================================================================

setup_site() {
    local site_name="${SITE_NAME:-development.localhost}"
    
    if [ "$SKIP_SITE_SETUP" = "true" ]; then
        log_info "Skipping site setup (SKIP_SITE_SETUP=true)"
        update_health_status "healthy" "Site setup skipped - manual configuration required"
        return 0
    fi
    
    # Check if site exists and create if it doesn't
    if [ ! -d "$HOME/frappe-bench/sites/$site_name" ]; then
        log_info "Site $site_name not found. Creating..."
        
        # Create new site
        if bench new-site "$site_name" \
            --db-root-username root \
            --db-root-password "${DB_ROOT_PASSWORD:-admin}" \
            --admin-password "${ADMIN_PASSWORD:-admin}" \
            --no-mariadb-socket; then
            log_info "✅ Site $site_name created successfully"
        else
            handle_fatal_error "site_creation" "Failed to create site $site_name"
        fi
        
        # Setup Redis services (once)
        setup_redis_services
        
        # Install all apps on site
        install_apps_on_site "$site_name"
        
        # Enable developer mode
        if bench --site "$site_name" set-config developer_mode 1; then
            log_info "✅ Developer mode enabled"
        else
            handle_non_fatal_error "config_setup" "Failed to enable developer mode"
        fi
        
        # Enable scheduler
        if bench --site "$site_name" scheduler enable; then
            log_info "✅ Scheduler enabled"
        else
            handle_non_fatal_error "config_setup" "Failed to enable scheduler"
        fi
        
        # Configure domain
        bench setup add-domain localhost --site "$site_name" || handle_non_fatal_error "config_setup" "Failed to add domain"
        bench --site "$site_name" set-config host_name "http://localhost:8000" || handle_non_fatal_error "config_setup" "Failed to set host name"
        
        # Clear cache
        bench --site "$site_name" clear-cache || handle_non_fatal_error "config_setup" "Failed to clear cache"
        
        # Build assets if not already built during app installation
        if [ ! -f "$HOME/frappe-bench/.assets_built" ]; then
            log_info "Building assets..."
            if bench build --force; then
                touch "$HOME/frappe-bench/.assets_built"
                log_info "✅ Assets built successfully"
            else
                handle_non_fatal_error "asset_build" "Failed to build assets"
            fi
        fi
    else
        log_info "Site $site_name already exists."
        
        # Setup Redis services (once)
        setup_redis_services
        
        # Install any apps that aren't already installed
        install_apps
        
        # Install any apps on the site that aren't already installed
        install_apps_on_site "$site_name"
    fi
    
    # Always set the site as default
    if bench use "$site_name"; then
        log_info "✅ Site $site_name set as default"
    else
        handle_non_fatal_error "config_setup" "Failed to set default site"
    fi
}

# =============================================================================
# BENCH STARTUP
# =============================================================================

cleanup_before_start() {
    log_info "Cleaning up before bench start..."
    
    # Stop any manually started Redis instances before bench start takes over
    log_info "Stopping manual Redis instances before bench start..."
    pkill -f "redis-server.*--port 11000" 2>/dev/null || true
    pkill -f "redis-server.*--port 12000" 2>/dev/null || true
    pkill -f "redis-server.*--port 13000" 2>/dev/null || true
    sleep 2
    
    log_info "Cleanup completed"
}

start_bench() {
    # Always ensure we're in the home directory
    cd "$HOME" || handle_fatal_error "startup" "Failed to change to home directory"
    
    # If no command is passed, start bench
    if [ $# -eq 0 ]; then
        if [ -d "$HOME/frappe-bench" ]; then
            cd "$HOME/frappe-bench" || handle_fatal_error "startup" "Failed to change to frappe-bench directory"
            
            cleanup_before_start
            
            update_health_status "healthy" "All services starting normally"
            log_info "Starting bench..."
            exec bench start
        else
            handle_fatal_error "startup" "Bench directory not found"
        fi
    else
        # Execute the passed command
        log_info "Executing custom command: $*"
        exec "$@"
    fi
}

# =============================================================================
# HEALTH CHECK ENDPOINT
# =============================================================================

# Create a simple health check that Docker can use
create_health_check() {
    # Create health check script with sudo since /usr/local/bin requires root
    sudo bash -c 'cat > /usr/local/bin/health-check << '\''EOF'\''
#!/bin/bash
if [ -f /tmp/container_health ]; then
    status=$(head -n1 /tmp/container_health)
    case "$status" in
        "healthy")
            exit 0
            ;;
        "degraded")
            exit 1
            ;;
        "unhealthy")
            exit 2
            ;;
        *)
            exit 3
            ;;
    esac
else
    exit 3
fi
EOF'
    sudo chmod +x /usr/local/bin/health-check
    log_info "Health check script created at /usr/local/bin/health-check"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log_info "=== Frappe Development Container Starting ==="
    
    # Initialize health check
    create_health_check
    update_health_status "initializing" "Container startup in progress"
    
    # Execute setup steps
    setup_environment
    setup_ssh_key
    setup_mariadb
    initialize_bench
    setup_site
    
    # Check if we have any critical errors
    if [ -f "$APP_INSTALL_LOG" ] && grep -q "ERROR" "$APP_INSTALL_LOG"; then
        log_warn "Some applications failed to install. Check $APP_INSTALL_LOG for details."
        log_warn "Container will start anyway - you can fix issues manually."
    fi
    
    log_info "=== Container Setup Complete ==="
    
    # Start bench (this will exec and replace the current process)
    start_bench "$@"
}

# Run main function with all arguments
main "$@"