#!/bin/bash

# DigitalOcean Ubuntu 22.04 Server Setup Script for Lounge Coin
# Run as root

set -e  # Exit on error

echo "=== Starting Lounge Coin Server Setup ==="

# Update system
echo "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
echo "Installing required packages..."
apt install -y python3-pip python3-dev python3-venv \
    postgresql postgresql-contrib \
    nginx \
    supervisor \
    git \
    certbot python3-certbot-nginx \
    build-essential \
    libpq-dev \
    ufw

# Configure firewall
echo "Configuring firewall..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw allow 5432/tcp  # PostgreSQL
ufw --force enable

# Create application user
echo "Creating application user..."
useradd -m -s /bin/bash loungecoin || echo "User already exists"
usermod -aG sudo loungecoin

# Create directory structure
echo "Creating directory structure..."
mkdir -p /home/loungecoin/{app,logs,backups}
chown -R loungecoin:loungecoin /home/loungecoin

# Setup PostgreSQL
echo "Setting up PostgreSQL..."
sudo -u postgres psql <<EOF
CREATE USER loungecoin WITH PASSWORD 'changethispassword';
CREATE DATABASE loungecoin_db OWNER loungecoin;
GRANT ALL PRIVILEGES ON DATABASE loungecoin_db TO loungecoin;
EOF

echo "Database created. Remember to change the password!"

# Configure PostgreSQL for local connections
echo "Configuring PostgreSQL..."
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" /etc/postgresql/14/main/postgresql.conf

# Restart PostgreSQL
systemctl restart postgresql
systemctl enable postgresql

# Create swap file (helpful for 1GB droplets)
echo "Creating swap file..."
if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
fi

# Install global Python packages
echo "Installing global Python packages..."
pip3 install virtualenv gunicorn

# Create initial Nginx configuration
echo "Creating Nginx configuration..."
cat > /etc/nginx/sites-available/loungecoin <<'NGINX'
server {
    listen 80;
    server_name loungecoin.trade www.loungecoin.trade;
    
    location = /favicon.ico { access_log off; log_not_found off; }
    
    location /static/ {
        root /home/loungecoin/app;
    }
    
    location /media/ {
        root /home/loungecoin/app;
    }
    
    location / {
        include proxy_params;
        proxy_pass http://unix:/home/loungecoin/app/gunicorn.sock;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }
    
    client_max_body_size 10M;
}
NGINX

# Enable the site
ln -sf /etc/nginx/sites-available/loungecoin /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test and reload Nginx
nginx -t
systemctl reload nginx
systemctl enable nginx

# Create Supervisor configuration
echo "Creating Supervisor configuration..."
cat > /etc/supervisor/conf.d/loungecoin.conf <<'SUPERVISOR'
[program:loungecoin]
command=/home/loungecoin/app/venv/bin/gunicorn --workers 3 --bind unix:/home/loungecoin/app/gunicorn.sock lounge_coin_project.wsgi:application
directory=/home/loungecoin/app
user=loungecoin
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/home/loungecoin/logs/gunicorn.log
environment="PATH=/home/loungecoin/app/venv/bin"
SUPERVISOR

# Create systemd service for supervisor
systemctl enable supervisor
systemctl start supervisor

# Set up log rotation
echo "Setting up log rotation..."
cat > /etc/logrotate.d/loungecoin <<'LOGROTATE'
/home/loungecoin/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    notifempty
    create 0640 loungecoin loungecoin
    sharedscripts
    postrotate
        systemctl reload supervisor
    endscript
}
LOGROTATE

# Create media directory
mkdir -p /home/loungecoin/app/media/profile_pics
chown -R loungecoin:loungecoin /home/loungecoin/app/media

echo "=== Server Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Switch to loungecoin user: su - loungecoin"
echo "2. Clone your application to /home/loungecoin/app"
echo "3. Run the deploy_app.sh script"
echo "4. Update PostgreSQL password in .env file"
echo ""
echo "PostgreSQL Database: loungecoin_db"
echo "PostgreSQL User: loungecoin"
echo "PostgreSQL Password: changethispassword (CHANGE THIS!)"