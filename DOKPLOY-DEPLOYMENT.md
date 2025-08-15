# ERPNext Dokploy Deployment Instructions

## Prerequisites
1. A VPS/server running Ubuntu 24.04
2. Dokploy installed and running
3. Domain name pointed to your server IP (optional but recommended)

## Deployment Steps

### 1. Install Dokploy on your server:
`ash
ssh root@100.100.0.100
curl -sSL https://dokploy.com/install.sh | sh
`

### 2. Access Dokploy UI:
Open: http://

### 3. Create Project:
- Click "+ Create Project"
- Name: erpnext-project

### 4. Deploy using Docker Compose:
- Click "+ Create Service" → "Compose"
- Name: erpnext-stack
- Copy the contents from dokploy-docker-compose.yml
- Configure domain (if using custom domain):
  - Go to Domains tab
  - Update Host field to your domain
  - Enable HTTPS with Let's Encrypt

### 5. Deploy:
- Click "Deploy" button
- Wait for deployment to complete (5-10 minutes)

## Post-Deployment

### Access your ERPNext:
- URL: http://100.100.0.100.traefik.me (or https:// if SSL configured)
- Username: Administrator  
- Password: seenu8Q443H5HabA

### Monitor deployment:
- Check Logs tab in Dokploy for any issues
- Look for "create-site" container logs for site creation progress

## Services Created:
- **Database**: MariaDB 10.6 with automatic setup
- **Cache**: Redis for caching
- **Queue**: Redis for background jobs
- **Application**: ERPNext with all required services

## Backup:
Add these services to your docker-compose.yml for automated backups:
- Database backup to external storage
- Site files backup
- Automated backup scheduling via cron

## Troubleshooting:
- Check container logs in Dokploy UI
- Verify all containers are running
- Ensure domain DNS is properly configured
- Check firewall rules (ports 80, 443, 3000)
