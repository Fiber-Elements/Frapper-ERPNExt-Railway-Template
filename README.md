Autocoder Instruction Set: All-in-One ERPNext DeploymentObjective: Deploy the self-contained, all-in-one ERPNext Docker image to a cloud hosting provider (e.g., Railway) using a GitHub repository as the source.Pre-computation Variables: The autocoder must define these variables before execution.# GitHub & Repository Configuration
GITHUB_USERNAME="<your-github-username>"
REPO_NAME="erpnext-all-in-one"
GIT_REPO_URL="https://github.com/${GITHUB_USERNAME}/${REPO_NAME}.git"

# Railway Project Configuration
RAILWAY_PROJECT_NAME="erpnext-production"
RAILWAY_SERVICE_NAME="erpnext"

# ERPNext Site Configuration
SITE_NAME="erp.your-company.com" # The public domain for the ERP
ADMIN_PASSWORD="<generate_a_secure_administrator_password>"
DB_ROOT_PASSWORD="<generate_a_secure_database_root_password>"
DB_PASSWORD="<generate_a_secure_frappe_database_password>"
Phase 1: Repository Initialization and PopulationCreate Local Directory Structure.mkdir -p ${REPO_NAME}/config ${REPO_NAME}/scripts
cd ${REPO_NAME}
Create Dockerfile.cat > Dockerfile << 'EOF'
# ==============================================================================
# All-in-One ERPNext Dockerfile
# ==============================================================================
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ENV SO_PINNED_APPS_BENCH_VERSION=5.18.1
RUN apt-get update && apt-get install -y \
    build-essential cron curl git libffi-dev libssl-dev mariadb-server \
    nginx nodejs npm python3-dev python3-pip python3-venv redis-server \
    supervisor sudo vim wkhtmltopdf && rm -rf /var/lib/apt/lists/*
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/nginx.conf /etc/nginx/sites-available/default
COPY scripts/backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh
COPY config/erpnext-backup-cron /etc/cron.d/erpnext-backup
RUN chmod 0644 /etc/cron.d/erpnext-backup
RUN useradd -m -s /bin/bash frappe
RUN echo "frappe ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
WORKDIR /home/frappe
RUN pip3 install frappe-bench==${SO_PINNED_APPS_BENCH_VERSION}
USER frappe
RUN bench init --skip-redis-config-generation --frappe-branch version-15 frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --branch version-15 erpnext
USER root
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 80
VOLUME [ "/home/frappe/frappe-bench/sites", "/var/lib/mysql", "/backups" ]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
EOF
Create config/supervisord.conf.cat > config/supervisord.conf << 'EOF'
[supervisord]
nodaemon=true
user=root

[program:mariadb]
command=/usr/bin/mysqld_safe
autostart=true
autorestart=true
user=mysql
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:redis-cache]
command=/usr/bin/redis-server --port 6379
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:redis-queue]
command=/usr/bin/redis-server --port 6380
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:redis-socketio]
command=/usr/bin/redis-server --port 6381
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:cron]
command=cron -f
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:frappe-bench]
command=bench start
directory=/home/frappe/frappe-bench
autostart=true
autorestart=true
user=frappe
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
Create config/nginx.conf.cat > config/nginx.conf << 'EOF'
upstream frappe-backend {
    server 127.0.0.1:8000;
}

server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://frappe-backend;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_connect_timeout 300s;
        proxy_read_timeout 300s;
    }
}
EOF
Create config/erpnext-backup-cron.cat > config/erpnext-backup-cron << 'EOF'
30 2 * * * root /usr/local/bin/backup.sh >> /var/log/cron.log 2>&1
EOF
Create scripts/entrypoint.sh.cat > scripts/entrypoint.sh << 'EOF'
#!/bin/bash
set -e

wait_for_db() {
  echo "Waiting for MariaDB to be available..."
  until mysqladmin ping -h"127.0.0.1" --silent; do
    echo "MariaDB not up yet, sleeping..."
    sleep 2
  done
  echo "MariaDB is up and running."
}

SITES_DIR="/home/frappe/frappe-bench/sites"
SENTINEL_FILE="$SITES_DIR/.setup_complete"

if [ ! -f "$SENTINEL_FILE" ]; then
  echo "--- FIRST RUN DETECTED ---"
  /usr/bin/supervisord -c /etc/supervisor/supervisord.conf &
  SUPERVISOR_PID=$!
  wait_for_db

  echo "1. Setting up MariaDB..."
  mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME:-frappe}\`;"
  mysql -u root -e "CREATE USER IF NOT EXISTS '${DB_USER:-frappe}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME:-frappe}\`.* TO '${DB_USER:-frappe}'@'localhost';"
  mysql -u root -e "FLUSH PRIVILEGES;"

  echo "2. Creating new ERPNext site..."
  cd /home/frappe/frappe-bench
  sudo -u frappe bench new-site "${SITE_NAME}" \
    --db-name "${DB_NAME:-frappe}" \
    --db-password "${DB_PASSWORD}" \
    --mariadb-root-username "root" \
    --mariadb-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --install-app erpnext \
    --set-default

  echo "3. Configuring site for production..."
  sudo -u frappe bench --site "${SITE_NAME}" set-config -g db_host 127.0.0.1
  sudo -u frappe bench --site "${SITE_NAME}" set-config -g redis_cache "redis://127.0.0.1:6379"
  sudo -u frappe bench --site "${SITE_NAME}" set-config -g redis_queue "redis://127.0.0.1:6380"
  sudo -u frappe bench --site "${SITE_NAME}" set-config -g redis_socketio "redis://127.0.0.1:6381"
  sudo -u frappe bench --site "${SITE_NAME}" enable-scheduler

  touch "$SENTINEL_FILE"
  chown frappe:frappe "$SENTINEL_FILE"
  echo "--- SETUP COMPLETE ---"
  kill $SUPERVISOR_PID
  wait $SUPERVISOR_PID
fi

chown -R frappe:frappe /home/frappe/frappe-bench
chown -R mysql:mysql /var/lib/mysql
mkdir -p /backups && chown -R frappe:frappe /backups

exec "$@"
EOF
Create scripts/backup.sh.cat > scripts/backup.sh << 'EOF'
#!/bin/bash
cd /home/frappe/frappe-bench
SITE=$(ls sites | grep -v "assets" | head -n 1)
if [ -z "$SITE" ]; then
    echo "No site found to back up."
    exit 1
fi
echo "Starting backup for site: $SITE at $(date)"
bench --site "$SITE" backup --with-files --backup-path /backups
echo "Backup complete."
echo "Pruning old backups, keeping the last 7..."
ls -tp /backups/${SITE}*.tar.gz | grep -v '/$' | tail -n +8 | xargs -I {} rm -- {}
echo "Pruning complete."
EOF
Initialize Git and Push to Remote.git init
git add .
git commit -m "Initial commit of All-in-One ERPNext configuration"
# The following command assumes a repository has been created on GitHub.
# An autocoder may need to use the GitHub API to create it first.
git remote add origin ${GIT_REPO_URL}
git branch -M main
git push -u origin main
Phase 2: Railway Infrastructure ProvisioningLogin to Railway CLI (Requires human interaction if not already authenticated).railway login
Create and Link Railway Project.railway project create --name "${RAILWAY_PROJECT_NAME}"
railway link --project <PROJECT_ID_RETURNED_FROM_PREVIOUS_COMMAND>
Create the Main Application Service from GitHub.railway add --service "${RAILWAY_SERVICE_NAME}" --repo "${GIT_REPO_URL}"
Create and Attach Persistent Volumes.# Note: Railway CLI does not currently support volume creation directly.
# This step would need to be done via the UI or an API call.
# The following are conceptual commands.
# railway volume create --name "erpnext-sites" --service "${RAILWAY_SERVICE_NAME}" --mount-path "/home/frappe/frappe-bench/sites"
# railway volume create --name "erpnext-db" --service "${RAILWAY_SERVICE_NAME}" --mount-path "/var/lib/mysql"
# railway volume create --name "erpnext-backups" --service "${RAILWAY_SERVICE_NAME}" --mount-path "/backups"
echo "ACTION_REQUIRED: Manually create and attach volumes in the Railway UI."
echo "Volume 1: Mount at /home/frappe/frappe-bench/sites"
echo "Volume 2: Mount at /var/lib/mysql"
echo "Volume 3: Mount at /backups"
Set Environment Variables.railway variables set --service "${RAILWAY_SERVICE_NAME}" \
  SITE_NAME="${SITE_NAME}" \
  ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
  DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
  DB_PASSWORD="${DB_PASSWORD}"
Deploy the Project.railway up
Configure Public Domain.# Note: Railway CLI does not currently support domain management.
# This is a conceptual command.
# railway domain add --service "${RAILWAY_SERVICE_NAME}" --domain "${SITE_NAME}"
echo "ACTION_REQUIRED: Manually add a custom domain or generate a public domain in the Railway UI for the '${RAILWAY_SERVICE_NAME}' service."
Execution Complete. The autocoder should monitor the deployment logs via railway logs and, once deployment is successful, verify the site is accessible at the configured public domain.