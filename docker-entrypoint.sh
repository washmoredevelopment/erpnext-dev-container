#!/usr/bin/env bash
set -e

# Source NVM for all commands
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Ensure we're in the frappe user's home directory
cd "$HOME"

# Determine Frappe/ERPNext version to use for bench initialization
FRAPPE_VERSION="version-15"
if [ -n "$APPS" ]; then
    first_app_line=$(echo "$APPS" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | head -n 1)
    if [[ "$first_app_line" =~ ^erpnext:(.+) ]]; then
        FRAPPE_VERSION="${BASH_REMATCH[1]%%:*}"
    fi
fi



# Setup SSH key if provided
if [ -f "/tmp/ssh_key" ]; then
    echo "Setting up SSH key..."
    
    # Create .ssh directory if it doesn't exist
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    
    # Copy the SSH key with strict perms (root does the copy to ensure success)
    sudo install -m 600 /tmp/ssh_key "$HOME/.ssh/id_rsa"
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
    
    echo "SSH key setup completed."
fi

# Function to install apps from APPS env variable
install_apps() {
    if [ -n "$APPS" ]; then
        echo "Installing apps..."
        
        # Convert multiline APPS to array, removing empty lines
        while IFS= read -r app_spec; do
            # Skip empty lines and lines starting with #
            if [[ -z "$app_spec" || "$app_spec" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            
            # Trim whitespace
            app_spec=$(echo "$app_spec" | xargs)
            
            # Parse app specification (app_name:branch:git_url)
            # Handle git URLs with colons properly
            IFS=':' read -ra APP_PARTS <<< "$app_spec"
            app_name="${APP_PARTS[0]}"
            app_branch=""
            app_git_url=""
            
            # If we have more than 3 parts, it's likely a git URL with colons
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
            
            echo "Processing app: $app_name"
            
            # Skip if app already exists
            if [ -d "$HOME/frappe-bench/apps/$app_name" ]; then
                echo "App $app_name already exists, skipping..."
                continue
            fi
            
            # Construct bench get-app command with --skip-assets flag
            if [ -n "$app_git_url" ]; then
                # Custom repo with git URL
                if [ -n "$app_branch" ]; then
                    echo "Installing $app_name from $app_git_url (branch: $app_branch)"
                    bench get-app "$app_git_url" --branch "$app_branch" --skip-assets
                else
                    echo "Installing $app_name from $app_git_url"
                    bench get-app "$app_git_url" --skip-assets
                fi
            elif [ -n "$app_branch" ]; then
                # Frappe app with specific branch
                echo "Installing Frappe app $app_name (branch: $app_branch)"
                bench get-app "$app_name" --branch "$app_branch" --skip-assets
            else
                # Frappe app with default branch
                echo "Installing Frappe app $app_name"
                bench get-app "$app_name" --skip-assets
            fi
        done <<< "$APPS"
        
        # Build all assets after all apps are installed (only once)
        if [ ! -f "$HOME/frappe-bench/.assets_built" ]; then
            echo "Building assets for all apps..."
            bench build
            touch "$HOME/frappe-bench/.assets_built"
        fi
    fi
}

# Wait for Redis instances to be ready
wait_for_redis() {
    echo "Waiting for Redis services to be ready..."
    for port in 11000 12000 13000; do
        while ! redis-cli -p $port ping >/dev/null 2>&1; do
            echo "Waiting for Redis on port $port..."
            sleep 2
        done
        echo "Redis on port $port is ready"
    done
    echo "All Redis services ready"
}

# Function to install apps on site
install_apps_on_site() {
    local site_name="$1"
    
    if [ -n "$APPS" ]; then
        echo "Installing apps on site: $site_name"
        
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
                    echo "Installing $app_name on site $site_name..."
                    bench --site "$site_name" install-app "$app_name"
                else
                    echo "App $app_name already installed on site $site_name"
                fi
            fi
        done <<< "$APPS"
    fi
}

# Start services
sudo service mariadb start
# Let bench start handle Redis - don't start it manually

# Initialize MariaDB if not already done
if [ ! -f ~/.mysql_initialized ]; then
    echo "Initializing MariaDB..."
    
    # Wait for MariaDB to be ready
    sleep 5
    
    # First try to connect without password (fresh install)
    if sudo mysql -e "SELECT 1" 2>/dev/null; then
        echo "Setting up MariaDB root password..."
        # Use native authentication for better compatibility
        sudo mysql << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD:-admin}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    else
        # Already has a password, try with the expected password
        if sudo mysql -u root -p"${DB_ROOT_PASSWORD:-admin}" -e "SELECT 1" 2>/dev/null; then
            echo "MariaDB already configured with password."
        else
            echo "ERROR: Cannot connect to MariaDB. Password mismatch?"
            exit 1
        fi
    fi
    
    touch ~/.mysql_initialized
    echo "MariaDB initialized successfully."
fi

# Initialize bench if not already done (following bare_metal.sh pattern)
if [ ! -f "$HOME/frappe-bench/sites/apps.txt" ]; then
    echo "Bench not found or not properly initialized. Initializing..."
    echo "This will take several minutes. Please be patient..."
    
    # Ensure we're in frappe home directory (like bare_metal.sh line 366)
    cd "$HOME"
    
    # Remove any existing frappe-bench directory if it's incomplete
    if [ -d frappe-bench ] && [ -z "$(ls -A frappe-bench/sites 2>/dev/null)" ]; then
        echo "Removing incomplete bench directory..."
        rm -rf frappe-bench
    fi
    
    # Initialize bench as frappe user in home directory (like bare_metal.sh lines 572-573)
    if [ ! -d frappe-bench ]; then
        bench init frappe-bench --version "$FRAPPE_VERSION" --verbose
    fi
    
    cd frappe-bench
    
    # Install all configured apps
    install_apps
    
    # Mark bench as initialized
    touch ~/.bench_initialized
else
    # Bench already initialized
    echo "Bench already initialized. Using existing bench at $HOME/frappe-bench"
    cd "$HOME/frappe-bench"
    
    # Install any apps that aren't already installed
    install_apps
fi

# Check if site exists and create if it doesn't
if [ ! -d "$HOME/frappe-bench/sites/${SITE_NAME:-development.localhost}" ]; then
    echo "Site ${SITE_NAME:-development.localhost} not found. Creating..."
    
    # Create new site
    bench new-site "${SITE_NAME:-development.localhost}" \
        --db-root-username root \
        --db-root-password "${DB_ROOT_PASSWORD:-admin}" \
        --admin-password "${ADMIN_PASSWORD:-admin}" \
        --no-mariadb-socket
    
    # Setup Redis services (once) - following bare_metal.sh lines 599-601
    if [ ! -f "$HOME/frappe-bench/.redis_setup" ]; then
        echo "Setting up Redis services for version-15..."
        
        # Start additional Redis instances for ERPNext v15/develop (like bare_metal.sh)
        echo "Starting Redis instances for version-15 (queue, cache, and socketio)..."
        redis-server --port 11000 --daemonize yes --bind 127.0.0.1
        redis-server --port 12000 --daemonize yes --bind 127.0.0.1
        redis-server --port 13000 --daemonize yes --bind 127.0.0.1
        echo "Redis instances started for version-15."
        
        # Wait for Redis instances to be ready before proceeding
        wait_for_redis
        
        bench setup redis
        touch "$HOME/frappe-bench/.redis_setup"
    fi
    
    # Install all apps on site
    install_apps_on_site "${SITE_NAME:-development.localhost}"
    
    # Enable developer mode
    bench --site "${SITE_NAME:-development.localhost}" set-config developer_mode 1
    
    # Enable scheduler
    bench --site "${SITE_NAME:-development.localhost}" scheduler enable
    
    # Configure domain
    bench setup add-domain localhost --site "${SITE_NAME:-development.localhost}"
    bench --site "${SITE_NAME:-development.localhost}" set-config host_name "http://localhost:8000"
    
    # Clear cache
    bench --site "${SITE_NAME:-development.localhost}" clear-cache
    
    # Build assets if not already built during app installation
    if [ ! -f "$HOME/frappe-bench/.assets_built" ]; then
        echo "Building assets..."
        bench build --force
        touch "$HOME/frappe-bench/.assets_built"
    fi
else
    echo "Site ${SITE_NAME:-development.localhost} already exists."
    
    # Setup Redis services (once) - following bare_metal.sh lines 599-601
    if [ ! -f "$HOME/frappe-bench/.redis_setup" ]; then
        echo "Setting up Redis services for version-15..."
        
        # Start additional Redis instances for ERPNext v15/develop (like bare_metal.sh)
        echo "Starting Redis instances for version-15 (queue, cache, and socketio)..."
        redis-server --port 11000 --daemonize yes --bind 127.0.0.1
        redis-server --port 12000 --daemonize yes --bind 127.0.0.1
        redis-server --port 13000 --daemonize yes --bind 127.0.0.1
        echo "Redis instances started for version-15."
        
        # Wait for Redis instances to be ready before proceeding
        wait_for_redis
        
        bench setup redis
        touch "$HOME/frappe-bench/.redis_setup"
    fi
    
    # Install any apps that aren't already installed
    install_apps
    
    # Install any apps on the site that aren't already installed
    install_apps_on_site "${SITE_NAME:-development.localhost}"
fi

# Always set the site as default
bench use "${SITE_NAME:-development.localhost}"

# Always ensure we're in the home directory
cd "$HOME"

# If no command is passed, start bench
if [ $# -eq 0 ]; then
    if [ -d "$HOME/frappe-bench" ]; then
        cd "$HOME/frappe-bench"
        exec bench start
    else
        echo "Bench not initialized yet. Please wait..."
        sleep 10
        exit 1
    fi
else
    # Execute the passed command
    exec "$@"
fi 