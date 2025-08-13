FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install basic dependencies and create frappe user with sudo privileges
RUN apt-get update && apt-get install -y \
    sudo \
    software-properties-common \
    git \
    curl \
    openssh-client \
    whiptail \
    build-essential \
    zlib1g-dev \
    libncurses5-dev \
    libgdbm-dev \
    libnss3-dev \
    libssl-dev \
    libreadline-dev \
    libffi-dev \
    libsqlite3-dev \
    wget \
    libbz2-dev \
    python3-dev \
    python3-setuptools \
    python3-venv \
    python3-pip \
    redis-server \
    fontconfig \
    libxrender1 \
    xfonts-75dpi \
    xfonts-base \
    xvfb \
    libfontconfig \
    pkg-config \
    default-libmysqlclient-dev \
    mariadb-server \
    mariadb-client \
    cron \
    zsh \
    file \
    && rm -rf /var/lib/apt/lists/*

# Create frappe user with sudo privileges
RUN useradd -m -s /bin/bash frappeuser && \
    echo 'frappeuser ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Install wkhtmltopdf (architecture-aware)
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb"; \
    elif [ "$ARCH" = "arm64" ]; then \
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_arm64.deb"; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    wget "$WKHTML_URL" -O wkhtmltox.deb && \
    dpkg -i wkhtmltox.deb || apt-get install -f -y && \
    cp /usr/local/bin/wkhtmlto* /usr/bin/ || true && \
    chmod a+x /usr/bin/wk* || true && \
    rm -f wkhtmltox.deb

# Configure MariaDB character set
RUN echo "[mysqld]\n\
character-set-client-handshake = FALSE\n\
character-set-server = utf8mb4\n\
collation-server = utf8mb4_unicode_ci\n\
\n\
[mysql]\n\
default-character-set = utf8mb4" >> /etc/mysql/my.cnf

# Switch to frappe user
USER frappeuser
WORKDIR /home/frappeuser

# Install NVM and Node.js
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash && \
    echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ~/.bashrc && \
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> ~/.bashrc

# Install Node.js (default to 18 for Frappe v15) and yarn
ARG NODE_VERSION=18
ENV NODE_VERSION=${NODE_VERSION}
SHELL ["/bin/bash", "-c"]
RUN source ~/.nvm/nvm.sh && \
    nvm install ${NODE_VERSION} && \
    nvm alias default ${NODE_VERSION} && \
    npm install -g yarn@1.22.19

# Ensure NVM is sourced in all shell types (including non-interactive shells)
RUN echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.profile && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ~/.profile && \
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> ~/.profile

# Install bench
RUN source ~/.nvm/nvm.sh && \
    pip3 install --user frappe-bench --break-system-packages

USER root
# Create symlinks for node, npm, yarn to make them globally available
RUN export NVM_DIR=/home/frappeuser/.nvm && \
    bash -lc 'export NVM_DIR=/home/frappeuser/.nvm; source "$NVM_DIR/nvm.sh" && VER=$(nvm version default) && \
    ln -sf "/home/frappeuser/.nvm/versions/node/$VER/bin/node" /usr/local/bin/node && \
    ln -sf "/home/frappeuser/.nvm/versions/node/$VER/bin/npm" /usr/local/bin/npm && \
    ln -sf "/home/frappeuser/.nvm/versions/node/$VER/bin/yarn" /usr/local/bin/yarn'

# Install Oh My Zsh for frappeuser and set zsh as default shell
USER frappeuser
RUN RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" && \
    echo '\n# NVM and local bin for zsh' >> ~/.zshrc && \
    echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.zshrc && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ~/.zshrc && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && \
    echo 'ZSH_DISABLE_COMPFIX=true' >> ~/.zshrc

USER root
RUN chsh -s /usr/bin/zsh frappeuser

# Provide a no-op supervisorctl so "bench restart" doesn't kill the container
RUN printf '#!/bin/sh\necho "supervisorctl is disabled in this dev container; ignoring: $*"\nexit 0\n' > /usr/local/bin/supervisorctl && \
    chmod +x /usr/local/bin/supervisorctl

# Switch to root to install entrypoint with proper permissions
USER root

# Add bench to PATH for all users
ENV PATH="/home/frappeuser/.local/bin:$PATH"

# Copy entrypoint script to a non-volume path and set permissions
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && chown frappeuser:frappeuser /usr/local/bin/docker-entrypoint.sh

# Switch back to frappe user
USER frappeuser

# Expose ports
EXPOSE 8000 9000 3306 6379

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD [] 