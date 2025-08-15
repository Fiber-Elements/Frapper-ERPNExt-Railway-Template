# Deploying to Railway

This guide provides step-by-step instructions for deploying the Frappe/ERPNext application to Railway.

## Prerequisites

- A Railway account.
- The [Railway CLI](https://docs.railway.app/develop/cli) installed and authenticated.

## 1. Project Setup

First, create a new project on Railway from your Git repository.

1.  Go to your Railway dashboard and click **New Project**.
2.  Select **Deploy from GitHub repo** and choose your repository.
3.  Railway will detect the `Dockerfile` and create a service. You may need to configure the deployment settings later.

## 2. Add Services

Your application requires a MariaDB database and a Redis instance. Add them as services to your Railway project.

1.  In your project dashboard, click **New**.
2.  Select **Database** and then choose **MySQL** (Railway uses MySQL 8 which is compatible, or you can use a Docker image for MariaDB if needed).
3.  Repeat the process, but this time select **Database** and then **Redis**.

Railway will automatically provision these services and make their connection details available as environment variables.

## 3. Configure Volume

Your application requires a persistent volume to store site-specific data, such as uploaded files and configuration.

1.  In your application's service settings on Railway, go to the **Volumes** tab.
2.  Add a new volume and set the **Mount Path** to `/home/frappe/frappe-bench/sites`.

**This step is critical.** Without a correctly mounted volume, your site data will be lost on every deployment, and the application will fail to start correctly.

## 4. Configure Environment Variables

Your Frappe/ERPNext service needs to connect to the database and Redis. Railway exposes service variables automatically. You will need to reference them in your application's service configuration.

In your application's service settings on Railway, go to the **Variables** tab and add the following:

-   `DATABASE_URL`: This should be automatically linked to the MySQL/MariaDB service. Frappe doesn't use this directly, but our entrypoint script will parse it.
-   `REDIS_URL`: This will be linked to the Redis service.
-   `FRAPPE_SITE_NAME_HEADER`: Set this to the public domain Railway provides for your service (e.g., `my-app-production.up.railway.app`).
-   `AUTO_BOOTSTRAP`: Set to `1` to automatically create the Frappe site on the first boot.
-   `BOOTSTRAP_ADMIN_PASSWORD`: Set a secure password for the Administrator user.

Our Docker entrypoint script is designed to read these variables and configure Frappe accordingly.

## 4. Deployment Configuration (`railway.toml`)

This repository includes a `railway.toml` file to define the deployment configuration as code. This makes the deployment process more reliable and reproducible.

The configuration specifies:

-   **Builder**: Uses the `Dockerfile` in the repository root.
-   **Restart Policy**: Automatically restarts the service if it fails.
-   **Health Check**: Pings a Frappe endpoint (`/api/method/frappe.utils.ping`) to verify the application is healthy before marking the deployment as successful.

No changes are needed for this file to work, but you can learn more in the [official Railway documentation](https://docs.railway.com/reference/config-as-code).

## 5. Triggering a Deployment

With the services and environment variables configured, you can trigger a deployment.

-   Railway automatically deploys when you push new commits to your linked GitHub repository branch.
-   You can also trigger a manual deployment from the Railway dashboard.

Monitor the deployment logs in the Railway dashboard to ensure the services start correctly and the Frappe site is bootstrapped.
