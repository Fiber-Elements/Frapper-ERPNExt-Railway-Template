# Railway Environment Variables for ERPNext

## Required Variables (Set these in Railway dashboard)

### Database Configuration (for external MariaDB service)
- `DB_HOST` - MariaDB hostname (e.g., `containers-us-west-xxx.railway.app`)
- `DB_PORT` - MariaDB port (default: `3306`)
- `DB_PASSWORD` - MariaDB root password
- `MYSQL_ROOT_PASSWORD` - Same as DB_PASSWORD (for compatibility)
- `MARIADB_ROOT_PASSWORD` - Same as DB_PASSWORD (for compatibility)

### Redis Configuration (for external Redis services)
- `REDIS_CACHE_URL` - Redis cache URL (e.g., `redis://default:password@host:port`)
- `REDIS_QUEUE_URL` - Redis queue URL (e.g., `redis://default:password@host:port`) 
- `REDIS_SOCKETIO_URL` - Redis socketio URL (usually same as REDIS_CACHE_URL)

### ERPNext Site Configuration
- `FRAPPE_SITE_NAME_HEADER` - Site name (default: `frontend`)
- `BOOTSTRAP_ADMIN_PASSWORD` - Admin password for ERPNext (auto-generate secure password)

## Optional Variables (have sensible defaults)

### Nginx/Proxy Configuration
- `BACKEND` - Backend server (default: `127.0.0.1:8000`)
- `SOCKETIO` - Socket.IO server (default: `127.0.0.1:9000`) 
- `UPSTREAM_REAL_IP_ADDRESS` - Trusted IP (default: `127.0.0.1`)
- `UPSTREAM_REAL_IP_HEADER` - Real IP header (default: `X-Forwarded-For`)
- `UPSTREAM_REAL_IP_RECURSIVE` - Recursive IP lookup (default: `off`)
- `PROXY_READ_TIMEOUT` - Nginx timeout (default: `120`)
- `CLIENT_MAX_BODY_SIZE` - Max upload size (default: `50m`)

### Internal Service Ports (automatically configured)
- `PORT` - Railway auto-assigns this (frontend port)
- `BACKEND_PORT` - Internal backend port (default: `8000`)
- `SOCKETIO_PORT` - Internal socketio port (default: `9000`)

## Railway-Specific Variables (automatically set by Railway)
- `RAILWAY_ENVIRONMENT` - Environment name (production/staging)
- `RAILWAY_SERVICE_NAME` - Service name
- `RAILWAY_PROJECT_NAME` - Project name
- `RAILWAY_REPLICA_ID` - Replica identifier
- `RAILWAY_PUBLIC_DOMAIN` - Public domain for your service (e.g., `your-app-name.up.railway.app`)
- `RAILWAY_PRIVATE_DOMAIN` - Private internal domain

## Setup Instructions

### 1. Create MariaDB Service in Railway
```bash
# Add MariaDB service to your Railway project
# Set these variables in MariaDB service:
MYSQL_ROOT_PASSWORD=<secure-password>
MYSQL_DATABASE=erpnext
```

### 2. Create Redis Services in Railway
```bash
# Add two Redis services to your Railway project:
# 1. Redis Cache (with eviction enabled)
# 2. Redis Queue (with eviction disabled)
# Note the connection URLs from Railway dashboard
```

### 3. Set Environment Variables in ERPNext Service
Copy these into your Railway ERPNext service environment variables:

```bash
# Database (replace with your MariaDB service details)
DB_HOST=containers-us-west-xxx.railway.app
DB_PORT=3306
DB_PASSWORD=your-secure-mariadb-password

# Redis (replace with your Redis service URLs)
REDIS_CACHE_URL=redis://default:password@containers-us-west-yyy.railway.app:port
REDIS_QUEUE_URL=redis://default:password@containers-us-west-zzz.railway.app:port
REDIS_SOCKETIO_URL=redis://default:password@containers-us-west-yyy.railway.app:port

# ERPNext Configuration
FRAPPE_SITE_NAME_HEADER=frontend
BOOTSTRAP_ADMIN_PASSWORD=your-secure-admin-password

# Optional: Proxy Settings
PROXY_READ_TIMEOUT=300
CLIENT_MAX_BODY_SIZE=100m
```

### 4. Deploy Order
1. Deploy MariaDB service first
2. Deploy Redis services 
3. Deploy ERPNext service (will auto-create site on first run)

## Important Notes

⚠️ **Railway Volume Limitation**: Railway only supports ONE volume per service. Our setup uses `/home/frappe/frappe-bench/persistent` as the single mount point, with symbolic links to maintain the expected directory structure:
- `persistent/sites` → `sites` (site data and configurations)
- `persistent/logs` → `logs` (application logs)

🏗️ **Single-Container Architecture**: Uses supervisord to manage multiple ERPNext processes within one container since Railway doesn't support shared volumes between containers.

🔒 **Security**: Always use strong, unique passwords for database and admin accounts.

📊 **Monitoring**: Check Railway logs for each service during deployment to ensure proper startup sequence.

🔄 **Auto-Bootstrap**: The entrypoint script will automatically create the ERPNext site on first deployment if it doesn't exist.
