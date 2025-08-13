# **A Comprehensive Guide to Self-Hosting Frappe ERPNext with Docker and Fly.io**

## **Introduction: The Strategic Advantage of Self-Hosted, Containerized ERP**

In the landscape of modern enterprise resource planning, Frappe ERPNext stands out as a formidable open-source solution. Built upon the Frappe Framework, a powerful low-code web framework in Python and JavaScript, it offers a comprehensive suite of integrated business management tools covering accounting, inventory, sales, HR, and more.<sup>1</sup> The decision to self-host an ERP system is a strategic one, offering organizations unparalleled control over their data, extensive customization capabilities, and a predictable cost structure free from per-user licensing fees.

This report provides an exhaustive, expert-level guide to deploying Frappe ERPNext through a modern, container-native methodology. The approach detailed herein leverages the power of Docker to create a consistent, reproducible, and fully automated local development environment that mirrors a production setup.<sup>1</sup> This local-first validation is a cornerstone of contemporary DevOps practices, ensuring that what works on a developer's machine will work reliably in production.

Following a successful local deployment, the guide transitions to migrating the application to Fly.io, a next-generation global application platform. Fly.io is uniquely suited for this task as it is designed to run full-stack applications and databases packaged as Docker images close to users, effectively bridging the gap between infrastructure-as-a-service (IaaS) and platform-as-a-service (PaaS).<sup>2</sup> By converting Docker-based applications into lightweight, fast-booting virtual machines (VMs), Fly.io provides the flexibility of traditional servers with the deployment ease of a managed platform.<sup>6</sup>

This document is structured not as two separate tutorials, but as a single, unified deployment pipeline. It begins with a deep architectural analysis of the local environment, proceeds to a step-by-step implementation, and culminates in a detailed architectural translation and deployment to a robust, scalable production environment on Fly.io. The objective is to empower a technically astute practitioner not only to launch ERPNext but to understand, manage, and scale it with confidence.

## **Part I: Architecting the Local Environment: A Deep Dive into frappe_docker**

A successful deployment begins with a thorough understanding of the system's architecture. Before executing a single command, it is crucial to deconstruct the components of the local environment provided by the official frappe_docker project. This foundational knowledge is indispensable for effective troubleshooting and for planning the subsequent migration to a production platform.

### **Deconstructing the frappe_docker Stack: The pwd.yml Blueprint**

The official and canonical starting point for any containerized Frappe ERPNext deployment is the frappe/frappe_docker repository on GitHub.<sup>8</sup> Within this repository, the

pwd.yml file serves as a blueprint for a rapid, all-in-one development setup. The name, an acronym for "Play with Docker," belies the complexity and production-like nature of the environment it defines.<sup>8</sup>

Analyzing the pwd.yml file reveals that it does not define a simple, monolithic application. Instead, it orchestrates a sophisticated microservices architecture composed of numerous specialized, interconnected containers. Each container encapsulates a specific function required for the ERPNext ecosystem to operate. Understanding the role of each service is the first step toward mastering the deployment.

The architecture defined in pwd.yml can be broken down into several logical groups <sup>11</sup>:

- **Core Application Services:** These form the heart of the user-facing application.
  - backend: This service runs the core Frappe Framework application using Gunicorn, a Python WSGI HTTP server. It processes all business logic and API requests.
  - frontend: This service runs Nginx, which acts as a reverse proxy. It receives incoming HTTP requests on port 8080, serves static assets (like CSS, JS, and images), and forwards dynamic requests to the backend and websocket services.
- **Data and State Services:** These containers manage the persistent data of the system.
  - db: A MariaDB container (version 10.6 is common) that serves as the primary relational database for the entire system.
  - redis-queue: A Redis instance dedicated to managing the background job queues used by Frappe's worker processes.
  - redis-cache: A separate Redis instance used for application-level caching to improve performance.
- **Background and Asynchronous Services:** These handle tasks that occur outside the direct user request-response cycle.
  - websocket: A Node.js server that manages real-time communication using Socket.IO, enabling features like live notifications and chat.
  - scheduler: This container runs the bench schedule command, which periodically triggers scheduled tasks defined within ERPNext, such as automated emails and recurring document generation.
  - queue-long and queue-short: These are Frappe worker processes that consume jobs from the Redis queue. They are segregated to handle long-running tasks (e.g., data imports) and short, quick tasks separately, preventing long jobs from blocking shorter ones.
- **Initialization and Configuration Services:** These are one-off containers that run at startup to prepare the environment.
  - configurator: This container's purpose is to write the initial configuration files. It reads environment variables and uses the bench set-config command to populate the common_site_config.json file with database and Redis connection details.
  - create-site: This is the final initialization step. It contains logic (wait-for-it scripts) to ensure that the database and Redis services are available before it attempts to create the first ERPNext site using the bench new-site command. This service is responsible for installing the erpnext app into the newly created site.

This multi-container setup demonstrates a robust separation of concerns, which is beneficial for scalability and maintenance but also introduces complexity in configuration and inter-service communication.

| Service Name (pwd.yml) | Core Technology | Primary Role | Key Dependencies |
| --- | --- | --- | --- |
| frontend | Nginx | Reverse Proxy, Static Asset Serving | backend, websocket |
| --- | --- | --- | --- |
| backend | Python (Gunicorn) | Core Frappe/ERPNext Application Logic | db, redis-cache, redis-queue |
| --- | --- | --- | --- |
| db  | MariaDB | Primary Relational Database | (None within the stack) |
| --- | --- | --- | --- |
| redis-queue | Redis | Background Job & Socket.IO Message Broker | (None within the stack) |
| --- | --- | --- | --- |
| redis-cache | Redis | Application-level Caching | (None within the stack) |
| --- | --- | --- | --- |
| websocket | Node.js (Socket.IO) | Real-time Communication | redis-queue |
| --- | --- | --- | --- |
| scheduler | Python (Frappe Bench) | Executes Scheduled Cron-like Jobs | backend, db, redis-queue |
| --- | --- | --- | --- |
| queue-long / queue-short | Python (Frappe Bench) | Process Background Jobs | backend, db, redis-queue |
| --- | --- | --- | --- |
| configurator | Python (Frappe Bench) | Writes Initial common_site_config.json | db, redis-queue, redis-cache |
| --- | --- | --- | --- |
| create-site | Python (Frappe Bench) | Creates the Initial ERPNext Site | configurator, db, redis-queue |
| --- | --- | --- | --- |

### **Configuration as Code: Mastering the Flow of Variables**

The configuration of the frappe_docker environment is a dynamic, multi-stage process, not a simple static assignment of values. Understanding this flow is critical for both customization and troubleshooting. The system uses a combination of a .env file, Docker Compose variable injection, and an initialization container to translate high-level settings into the specific configuration files read by the Frappe framework.<sup>12</sup>

The process begins with the .env file. The frappe_docker repository includes a template file named example.env.<sup>8</sup> When this file is copied to

.env in the root of the project directory, Docker Compose automatically reads it and makes the defined variables available to the services in the pwd.yml file.

The configuration then proceeds in two distinct stages:

1. **Stage 1: Direct Container Environment Injection.** Some variables are consumed directly by the service containers themselves. The most prominent example is the db service. In pwd.yml, the environment block for the db service sets MYSQL_ROOT_PASSWORD: admin.<sup>11</sup> This value is read directly by the MariaDB image on its first startup to initialize the root user's password.
2. **Stage 2: Frappe Framework Configuration via the configurator Service.** Most application-specific settings follow a more indirect path. The pwd.yml file defines environment variables like DB_HOST, DB_PORT, REDIS_CACHE, and REDIS_QUEUE for the configurator service.<sup>11</sup> This service does not run the main application; its sole purpose is to execute a series of  
    bench set-config commands upon startup. These commands write the values of the environment variables into a JSON file located at the shared path sites/common_site_config.json. This file is the central source of truth for database and Redis connection details for all other Frappe services (backend, scheduler, workers).

This two-stage flow has a critical implication: the entire system is sensitive to the startup order. The create-site container explicitly waits for the common_site_config.json file to be created and populated by the configurator before it proceeds to create the site.<sup>11</sup> This dependency chain—from

.env to pwd.yml to the configurator container, which generates a file on a shared volume that other containers depend on—is fundamental to the system's operation. Any misconfiguration in this chain can cause the entire startup process to fail. For example, if the db container fails to start, the configurator will be unable to connect to it, the common_site_config.json will not be properly generated, and the create-site container will eventually time out.

| Variable Name | Consumed By | Mechanism | Ultimate Effect |
| --- | --- | --- | --- |
| MYSQL_ROOT_PASSWORD | db (MariaDB) | Direct environment variable injection in pwd.yml. | Sets the root password for the MariaDB database instance. |
| --- | --- | --- | --- |
| DB_HOST | configurator | Environment variable passed to a bench set-config command. | Written into common_site_config.json as the database hostname. |
| --- | --- | --- | --- |
| REDIS_CACHE | configurator | Environment variable passed to a bench set-config command. | Written into common_site_config.json as the Redis cache connection string. |
| --- | --- | --- | --- |
| REDIS_QUEUE | configurator | Environment variable passed to a bench set-config command. | Written into common_site_config.json as the Redis queue connection string. |
| --- | --- | --- | --- |
| BACKEND | frontend (Nginx) | Direct environment variable injection in pwd.yml. | Configures the Nginx upstream directive to proxy requests to the backend service. |
| --- | --- | --- | --- |
| SOCKETIO | frontend (Nginx) | Direct environment variable injection in pwd.yml. | Configures the Nginx upstream directive to proxy websocket connections. |
| --- | --- | --- | --- |

### **Data Persistence and State Management with Docker Volumes**

A critical aspect of any stateful application is data persistence. In the Docker ecosystem, this is achieved through volumes, which decouple the data's lifecycle from the container's lifecycle. The pwd.yml file defines several named volumes to manage the state of the ERPNext stack, ensuring that crucial information survives container restarts, updates, and recreation.<sup>11</sup>

The primary volumes defined are:

- db-data: This volume is mounted at /var/lib/mysql inside the db container. It stores all the physical files that constitute the MariaDB database, including tables, indexes, and logs. This is arguably the most critical piece of state.
- redis-queue-data: Mounted inside the redis-queue container, this volume allows Redis to persist its data to disk, enabling job recovery even if the Redis container restarts.
- sites: This is the central hub of shared state for the Frappe application itself. It is mounted inside every Frappe-related container (backend, frontend, scheduler, workers, configurator, create-site) at the path /home/frappe/frappe-bench/sites. This volume contains:
  - Site-specific configuration files (e.g., mysite/site_config.json).
  - The common_site_config.json file generated by the configurator.
  - All installed applications, including erpnext and any custom apps.
  - All user-uploaded files, such as document attachments and images within the assets subdirectory.
- logs: This volume is mounted at /home/frappe/frappe-bench/logs in the Frappe containers and is used to persist application and system logs, which is invaluable for debugging issues over time.

It is noteworthy that while a redis-cache-data volume is defined in the volumes section of pwd.yml, the redis-cache service itself does not have a volumes mapping.<sup>11</sup> This is a deliberate design choice: cache data is intended to be ephemeral. If the cache container restarts, the cache is simply rebuilt by the application, with a minor temporary performance impact.

The architectural decision to use the sites volume as a shared filesystem across multiple containers is a key design pattern. It works flawlessly in a single-host environment like the one created by Docker Compose, where all containers run on the same machine and can easily mount the same directory. However, this very design presents the single most significant architectural challenge when migrating to a distributed, multi-host platform like Fly.io, where a shared filesystem is not readily available. This fundamental mismatch between the local and production architectures must be addressed for a successful migration.

## **Part II: Step-by-Step Local Deployment Guide**

With a solid architectural understanding in place, the next phase is the practical implementation of the local Frappe ERPNext environment. This section provides a clear, step-by-step walkthrough of the commands required to launch, verify, and manage the local stack.

### **Prerequisites and System Preparation**

Before proceeding, it is essential to ensure the local machine is equipped with the necessary software tools. A misconfigured environment is a common source of initial deployment failures.

The required software includes <sup>3</sup>:

- **Git:** For cloning the frappe_docker repository.
- **Docker Engine:** The core containerization platform. It is strongly recommended to install Docker directly from the official Docker website. Certain installation methods, such as using Snap packages on Linux, are known to cause compatibility issues and should be avoided.<sup>16</sup>
- **Docker Compose:** The tool for defining and running multi-container Docker applications. Version 2 of Docker Compose, which is integrated into the Docker CLI as docker compose, is recommended.

For users on machines with **ARM64 architecture** (such as Apple Silicon Macs), specific adjustments are necessary due to differences in the underlying CPU architecture. The standard frappe/erpnext images may not be compatible out-of-the-box. The official documentation provides a workaround <sup>8</sup>:

1. Add the line platform: linux/arm64 to every service definition within the pwd.yml file. This instructs Docker to pull and run the ARM64-compatible variant of each image.
2. Alternatively, for some versions, it may be necessary to replace specific version tags (e.g., :v15.0.0) with :latest to ensure the correct multi-architecture image is selected.

### **Launching and Verifying the ERPNext Stack**

The process of launching the local ERPNext environment is streamlined into a series of command-line operations.

Step 1: Clone the Repository

Open a terminal and clone the official frappe_docker repository from GitHub. This command downloads all the necessary configuration files, including pwd.yml.

Bash

git clone <https://github.com/frappe/frappe_docker>  

<sup>3</sup>

Step 2: Navigate into the Directory

Change your current directory to the newly created frappe_docker folder. All subsequent commands must be run from within this directory.

Bash

cd frappe_docker  

Step 3: Launch the Stack

Execute the Docker Compose command to build and start all the services defined in pwd.yml. The -d flag runs the containers in detached mode, meaning they will run in the background.

Bash

docker compose -f pwd.yml up -d  

<sup>8</sup>

Step 4: Monitor the Installation

The initialization process is not instantaneous and can take approximately 5 minutes or more, depending on network speed and system performance.8 It is crucial to monitor the progress to ensure the site is created successfully. The most effective way to do this is by tailing the logs of the

create-site container:

Bash

docker compose -f pwd.yml logs -f create-site  

<sup>8</sup>

During the initial startup, it is normal to see error messages in the logs, such as connection refused errors. This happens because some services, like the configurator and create-site containers, start before their dependencies (like db and redis-queue) are fully initialized and ready to accept connections. These containers are designed to retry, and the errors should resolve themselves as the stack becomes healthy.<sup>8</sup> The process is complete when the logs show a success message indicating that the new site has been created and the

erpnext app has been installed.

Step 5: Access the Application

Once the create-site container has finished its job, the ERPNext instance will be accessible in a web browser. Navigate to <http://localhost:8080.8>

Step 6: Log In

The pwd.yml setup uses a default set of credentials for the initial administrator account 8:

- **Username:** Administrator
- **Password:** admin

Upon successful login, the ERPNext setup wizard will appear, guiding through the final configuration steps for country, currency, and company details.

### **Troubleshooting Common Local Issues**

Even with a streamlined process, issues can arise during the initial deployment. Understanding the common failure points can significantly reduce debugging time.

- **Database Connection Errors:** Errors in the logs containing pymysql.err.OperationalError: (1045, “Access denied for user...”) or (1049, “Unknown database...”) typically point to a problem with the MariaDB container or the configuration passed to it.<sup>16</sup>
  - **Diagnosis:** Check the logs of the db container (docker compose -f pwd.yml logs db). If it is failing to start, the other services will be unable to connect. Also, verify that the MYSQL_ROOT_PASSWORD in pwd.yml matches the --db-root-password argument in the create-site command.
- **File Permission/Ownership Errors:** Messages like docker_initialization_error can sometimes be related to file permissions on the host machine, particularly on Linux systems where Docker volume mounts can inherit restrictive host permissions. This can prevent containers from writing to the shared volumes.<sup>16</sup>
  - **Diagnosis:** Ensure the user running the docker command has appropriate permissions. In some cases, manually inspecting and adjusting the ownership of the Docker-managed volume directories on the host may be necessary.
- **Script Execution Errors:** An error message containing python\\r is a classic sign of incorrect line endings in script files.<sup>16</sup> This occurs if files from the git repository were modified on a Windows machine (which uses CRLF line endings) and are then executed in a Linux-based container (which expects LF endings).
  - **Diagnosis:** Re-clone the repository on a Linux or macOS machine, or use a tool to convert the line endings of the relevant files to LF format.
- **Stuck at Login Page:** If the login page at <http://localhost:8080> loads, but logging in fails or leads to a blank or broken page, it often indicates that the frontend (Nginx) service is running but cannot communicate properly with the backend service.<sup>10</sup>
  - **Diagnosis:** Check the logs of both the frontend and backend containers. Look for errors in the backend log that might indicate a crash or failure to start. Check the frontend log for 502 Bad Gateway errors, which confirm it cannot reach the upstream backend service.

### **Managing the Local Environment Lifecycle**

Effective management of the local environment requires familiarity with a few key Docker Compose commands.

- **Stopping the Environment:** To stop all running containers associated with the project, use the down command. By default, this stops and removes the containers but leaves the named volumes (db-data, sites, etc.) intact, preserving all data.  
    Bash  
    docker compose -f pwd.yml down  

- **Stopping and Deleting All Data:** For a complete reset to a clean state, add the -v flag to the down command. This will stop and remove the containers _and_ delete all associated named volumes. This is essential when a fundamental configuration error requires a fresh initialization.  
    Bash  
    docker compose -f pwd.yml down -v  

- **Viewing Logs:** To view the aggregated, real-time logs from all services in the stack, use the logs -f command. This is the primary tool for observing the system's behavior.  
    Bash  
    docker compose -f pwd.yml logs -f  

- **Executing Commands in a Container:** To gain shell access to a running container for administrative tasks, use the exec command. Accessing the backend container is particularly useful as it allows for the use of the Frappe bench command-line interface.  
    Bash  
    docker compose -f pwd.yml exec backend bash  
    <br/>Once inside the container, commands like bench list-apps or bench backup can be executed.

## **Part III: Migrating to a Production Environment on Fly.io**

Transitioning from a local Docker Compose setup to a production-grade deployment on Fly.io is not a simple "lift and shift" operation. It requires a conceptual shift and an architectural translation. This section details the process of deconstructing the local setup and reconstructing it using the primitives and patterns of the Fly.io platform.

### **The Conceptual Bridge: From Docker Compose to fly.toml**

The foundational difference between the two environments is their orchestration model. The local environment uses a single docker-compose.yml file to define a multi-service application on a _single host_. Fly.io, conversely, does not directly interpret docker-compose.yml files.<sup>7</sup> Instead, it uses a

fly.toml configuration file to define and deploy an application, which can consist of multiple processes running on a distributed fleet of virtual machines across the globe.

The migration, therefore, is a process of mapping the concepts from Docker Compose to their equivalents in the Fly.io ecosystem.

- **Fly Machines:** These are the fundamental unit of compute on Fly.io. They are lightweight, fast-booting Firecracker micro-VMs that run the application's Docker image.<sup>20</sup> A Docker Compose  
    service is analogous to one or more Fly Machines.
- **Process Groups:** This is the core mechanism in fly.toml for running different types of services from a single application definition. The \[processes\] section in fly.toml allows one to define named processes (e.g., web, scheduler, worker) and the commands they should run. This is the direct replacement for defining multiple services in docker-compose.yml.<sup>22</sup> Each process group runs on its own set of one or more Fly Machines.
- **Fly Volumes:** These are persistent NVMe storage drives that can be attached to individual Fly Machines. They are local to the physical hardware where the machine runs and are not network-shared storage.<sup>6</sup> Fly Volumes are the production equivalent of Docker's named volumes.
- **Fly Secrets:** For managing sensitive information like database passwords, API keys, and other credentials, Fly.io provides a secure secret store. Secrets are injected into the machine's environment at runtime and are not stored in the fly.toml file or the Docker image. This is the secure replacement for using a plain-text .env file.<sup>24</sup>
- **Private Networking (6PN):** All machines within a Fly.io organization are connected via a private IPv6 network. They can communicate with each other using internal DNS names in the format &lt;app-name&gt;.internal or &lt;region&gt;.&lt;app-name&gt;.internal. This secure, private network replaces the default bridge network created by Docker Compose.<sup>21</sup>

This conceptual mapping is the key to a successful migration. The task is to deconstruct pwd.yml into its constituent processes, data stores, and configurations, and then reconstruct them using fly.toml process groups, Fly Volumes, and Fly Secrets.

| Local Component (pwd.yml) | fly.io Equivalent | Configuration File | Key Command/Concept |
| --- | --- | --- | --- |
| services: backend: | Process Group (\[processes.backend\]) | fly.toml | fly scale count backend=N |
| --- | --- | --- | --- |
| services: frontend: | Process Group (\[processes.web\]) | fly.toml | \[\[services\]\] block to expose ports |
| --- | --- | --- | --- |
| services: db: | Managed Fly Postgres App | fly.toml (\[env\]), Fly Secrets | fly postgres create, fly postgres attach |
| --- | --- | --- | --- |
| services: redis-\*: | Managed Upstash Redis | Fly Secrets | Create via Upstash dashboard, set URLs via fly secrets set |
| --- | --- | --- | --- |
| volumes: db-data: | Managed by Fly Postgres App | N/A | Data is persisted within the dedicated Postgres app's volumes. |
| --- | --- | --- | --- |
| volumes: sites: | Fly Volume | fly.toml (\[mounts\]) | fly volumes create frappe_sites |
| --- | --- | --- | --- |
| environment: MYSQL_ROOT_PASSWORD: admin | Fly Secret | N/A | fly secrets set DB_PASSWORD=... |
| --- | --- | --- | --- |
| create-site service | Manual bench command | N/A | Run via fly ssh console after first deploy |
| --- | --- | --- | --- |

### **Provisioning Production Dependencies: Database and Redis**

For a production environment, it is best practice to use managed services for stateful components like databases and Redis, rather than running them in containers alongside the application. This offloads the burden of management, backups, and high availability.

Prerequisites:

First, install the Fly.io command-line interface, flyctl, and authenticate it with a Fly.io account by running fly auth login.27

Provisioning a PostgreSQL Database:

While the local setup uses MariaDB, Fly.io's first-class support for PostgreSQL makes it an excellent choice for production. Frappe Framework supports PostgreSQL as a backend.

1. Execute the command to create a new, dedicated Fly App for the PostgreSQL database. The command will interactively prompt for an organization, an app name (e.g., my-erp-db), a region, and a cluster size.<sup>27</sup>  
    Bash  
    fly postgres create  

2. Carefully note the credentials (hostname, port, username, password, database name) that are displayed upon creation.
3. Once the main ERPNext Fly App is created (in a later step), attach the database to it. This command securely links the two apps and automatically sets a DATABASE_URL secret on the ERPNext app.  
    Bash  
    fly postgres attach --app &lt;erpnext-app-name&gt; &lt;postgres-app-name&gt;  
    <br/><sup>27</sup>

Provisioning Redis:

Fly.io partners with Upstash to provide managed Redis instances.18 Since the Frappe architecture uses two separate Redis instances for caching and queuing, two instances must be provisioned.

1. Navigate to the Upstash website and create a free account if necessary.
2. Create two new Redis databases. Name them descriptively, for example, erpnext-cache and erpnext-queue.
3. For each database, locate and copy its connection URL (e.g., redis://...). These URLs will be set as secrets in the ERPNext Fly App.

### **The fly.toml Master Configuration**

The fly.toml file is the heart of the Fly.io deployment. It defines the application, its processes, services, environment, and persistent storage mounts.

First, bootstrap a basic fly.toml file in the frappe_docker project directory. The --no-deploy flag prevents an immediate deployment, and the --name flag assigns a unique name to the new app.

Bash

fly launch --no-deploy --name my-erpnext-app  

<sup>24</sup>

Next, replace the contents of the generated fly.toml with the following comprehensive configuration. This file is heavily annotated to explain the purpose of each section and line.

Ini, TOML

\# fly.toml  
\# This is the master configuration file for deploying Frappe ERPNext on Fly.io.  
<br/>\# The unique name of your application on Fly.io.  
app = "my-erpnext-app"  
<br/>\# The primary region where machines will be deployed.  
primary_region = "iad" # Example: Ashburn, VA. Choose the region closest to your users.  
<br/>\# This section defines the command that will be run for each process group.  
\# These replace the 'command' and 'entrypoint' directives from docker-compose.yml.  
\[processes\]  
\# The 'web' process runs Nginx. It is the public-facing entrypoint.  
web = "nginx-entrypoint.sh"  
\# The 'backend' process runs the main Frappe/Gunicorn application.  
backend = "bench start"  
\# The 'scheduler' process runs scheduled tasks.  
scheduler = "bench schedule"  
\# A combined worker process for all queues. For higher loads, these could be split.  
worker = "bench worker --queue long,default,short"  
\# The 'websocket' process runs the Node.js Socket.IO server.  
websocket = "node /home/frappe/frappe-bench/apps/frappe/socketio.js"  
<br/>\# This section defines non-secret environment variables.  
\# These are visible in the Docker image and machine environment.  
\[env\]  
\# We point to the internal DNS name of the backend process group for Nginx.  
BACKEND = "app:8000"  
\# We point to the internal DNS name of the websocket process group for Nginx.  
SOCKETIO = "app:9000"  
\# The site name that Nginx will serve. This must match the site created with 'bench new-site'.  
FRAPPE_SITE_NAME_HEADER = "my-erpnext-app.fly.dev"  
\# Set the database type to postgres, as we are using Fly Postgres.  
DB_TYPE = "postgres"  
\# The host for the Fly Postgres database. It's the internal DNS name of the postgres app.  
DB_HOST = "my-erp-db.internal"  
\# Standard PostgreSQL port.  
DB_PORT = "5432"  
\# The name of the database created by 'fly postgres create'.  
DB_NAME = "my_erp_db"  
\# Set Redis connection details using the secrets that will be created.  
\# Note: Frappe bench commands will read these from secrets.  
REDIS_CACHE = "redis://:$REDIS_PASSWORD_CACHE@&lt;upstash-cache-host&gt;:&lt;port&gt;"  
REDIS_QUEUE = "redis://:$REDIS_PASSWORD_QUEUE@&lt;upstash-queue-host&gt;:&lt;port&gt;"  
<br/>\# This section defines how the application is exposed to the internet.  
\[\[services\]\]  
\# This service block applies ONLY to the 'web' process group (Nginx).  
processes = \["web"\]  
protocol = "tcp"  
internal_port = 8080 # The port Nginx listens on inside the container.  
<br/>\# Health checks to ensure the Nginx service is responsive.  
\[\[services.http_checks\]\]  
interval = "10s"  
timeout = "2s"  
grace_period = "5s"  
method = "get"  
path = "/api/method/ping" # A lightweight endpoint to check if the backend is alive.  
<br/>\# This maps external port 80 (HTTP) to the internal port.  
\[\[services.ports\]\]  
port = 80  
handlers = \["http"\]  
force_https = true # Automatically redirect HTTP to HTTPS.  
<br/>\# This maps external port 443 (HTTPS) to the internal port.  
\[\[services.ports\]\]  
port = 443  
handlers = \["tls", "http"\]  
<br/>\# This section defines the persistent volume mount for the application.  
\# It is critical for storing sites configuration, apps, and uploaded files.  
\[mounts\]  
source = "frappe_sites"  
destination = "/home/frappe/frappe-bench/sites"  

### **The Production Dockerfile and Deployment Pipeline**

With the infrastructure provisioned and the fly.toml configured, the final piece is the Docker image that will run on the Fly Machines and the sequence of commands to deploy it.

Addressing the Shared Storage Challenge:

As identified in Part I, the local architecture's reliance on a shared sites volume for all containers is not directly replicable in a distributed environment like Fly.io, where each machine has its own local volume. While mounting a Fly Volume provides persistence for a single machine, it doesn't solve the problem for scaled-out process groups (e.g., multiple backend workers) or for file access between different process groups (e.g., backend writing a file that frontend needs to serve).

The most robust and cloud-native solution is to externalize file storage to an S3-compatible object store. This makes the application's filesystem largely stateless, which is ideal for scalable, distributed deployments. Frappe Framework has built-in support for S3. This involves adding the boto3 Python library to the Docker image and configuring the site_config.json with S3 bucket details and credentials (set via Fly secrets). While a full S3 setup is beyond this guide's scope, it is the recommended production pattern. For this deployment, we will proceed with a single Fly Volume, which is sufficient for a single-machine-per-process-group setup.

The Production Dockerfile:

A custom Dockerfile is required to prepare the image for the Fly.io environment. It's best to start with the images/custom/Containerfile from the frappe_docker repository and modify it.3 The key modification is to install the PostgreSQL client libraries, which are required for the Python

psycopg2 driver (a Frappe dependency) to connect to the Fly Postgres database.

Create a file named Dockerfile in the frappe_docker root directory:

Dockerfile

\# Use the official Frappe image as a base  
FROM frappe/erpnext:v15.0.0  
<br/>\# Switch to root user to install packages  
USER root  
<br/>\# Install postgresql-client, which is needed for psycopg2 to connect to Fly Postgres  
RUN apt-get update && apt-get install -y postgresql-client && rm -rf /var/lib/apt/lists/\*  
<br/>\# Switch back to the non-root frappe user  
USER frappe  

**The Final Deployment Workflow:**

1. **Create the Fly App:** (If not already done)  
    Bash  
    fly launch --no-deploy --name my-erpnext-app  

2. **Provision and Attach Database:**  
    Bash  
    fly postgres create --name my-erp-db --region iad  
    fly postgres attach --app my-erpnext-app my-erp-db  

3. **Create the Persistent Volume:** Create a Fly Volume in the same region as your app. A size of 10 GB is a reasonable start.  
    Bash  
    fly volumes create frappe_sites --region iad --size 10  
    <br/><sup>6</sup>
4. **Set Secrets:** Securely store all credentials and sensitive configuration using fly secrets set. Retrieve the database password from the fly postgres attach command output or from the Fly.io dashboard. Retrieve Redis URLs from the Upstash dashboard.  
    Bash  
    fly secrets set DB_PASSWORD="&lt;your-fly-postgres-password&gt;"  
    fly secrets set REDIS_PASSWORD_CACHE="&lt;your-upstash-cache-password&gt;"  
    fly secrets set REDIS_PASSWORD_QUEUE="&lt;your-upstash-queue-password&gt;"  
    fly secrets set LETSENCRYPT_EMAIL="<your-email@example.com>"  

5. **Deploy the Application:** This command triggers the entire deployment process. flyctl will read the fly.toml, build the image using the local Dockerfile, push the image to Fly's registry, and then create and start a Fly Machine for each process group defined in \[processes\].  
    Bash  
    fly deploy  
    <br/><sup>24</sup>
6. **Manually Create the ERPNext Site:** This is the most critical manual step. The automated create-site container from the local setup does not exist in the Fly.io deployment. The site must be created by running the bench command inside one of the running machines.
    - First, SSH into the backend machine:  
        Bash  
        fly ssh console -p backend  

    - Once inside the shell, execute the bench new-site command. It is vital to provide the correct database credentials, which are available as environment variables inside the machine because they were set as secrets.  
        Bash  
        \# Inside the fly ssh console  
        bench new-site ${FRAPPE_SITE_NAME_HEADER} \\  
        \--db-type postgres \\  
        \--db-host ${DB_HOST} \\  
        \--db-port ${DB_PORT} \\  
        \--db-name ${DB_NAME} \\  
        \--db-password ${DB_PASSWORD} \\  
        \--admin-password &lt;choose-a-strong-password&gt; \\  
        \--install-app erpnext \\  
        \--set-default  

7. **Verify Deployment:** After the site is created, the application should be fully operational. Access it at <https://my-erpnext-app.fly.dev>. Check the application status and logs using fly status and fly logs.

## **Part IV: Advanced Topics and Operational Best Practices**

Deploying the application is the first step. Proper management, customization, and disaster recovery planning are essential for maintaining a healthy production system.

### **Customizing ERPNext with Custom Apps**

One of the greatest strengths of Frappe ERPNext is its extensibility through custom applications. Integrating these into a Docker-based production workflow requires building and deploying a custom container image.<sup>1</sup>

The process is as follows:

1. **Define Custom Apps in apps.json:** In your local frappe_docker directory, create a file named apps.json. This file lists the Git repositories of the custom apps to be included. For private repositories, a personal access token can be included in the URL.<sup>1</sup>  
    JSON  
    \[  
    {  
    "url": "<https://github.com/frappe/payments>",  
    "branch": "develop"  
    },  
    {  
    "url": "<https://github.com/my-org/my-custom-app.git>",  
    "branch": "main"  
    }  
    \]  

2. **Build the Custom Docker Image:** Use the docker build command to create a new image. The APPS_JSON_BASE64 build argument is used to pass the contents of apps.json into the build process. The build must be executed from the root of the frappe_docker repository, and it should use the images/custom/Containerfile as its definition.  
    Bash  
    \# First, encode the json file to base64  
    export APPS_JSON_BASE64=$(base64 -w 0 apps.json)  
    <br/>\# Then, build the image, tagging it for a container registry  
    docker build \\  
    \--build-arg FRAPPE_PATH=https://github.com/frappe/frappe \\  
    \--build-arg FRAPPE_BRANCH=version-15 \\  
    \--build-arg APPS_JSON_BASE64=$APPS_JSON_BASE64 \\  
    \--tag your-registry/my-custom-erpnext:1.0.0 \\  
    \--file images/custom/Containerfile.  
    <br/><sup>33</sup>
3. **Push the Image to a Registry:** The custom image must be accessible to the Fly.io remote builders. Push the newly tagged image to a container registry like Docker Hub or GitHub Container Registry (GHCR).  
    Bash  
    docker push your-registry/my-custom-erpnext:1.0.0  

4. **Update fly.toml:** In your fly.toml file, add a \[build\] section and specify the new custom image. This tells fly deploy to use your pre-built image instead of building from the local Dockerfile.  
    Ini, TOML  
    \# fly.toml  
    app = "my-erpnext-app"  

...

\[build\]

image = "your-registry/my-custom-erpnext:1.0.0"

...

\`\`\`

<sup>4</sup>

5\. Re-deploy and Install: Run fly deploy to roll out the new image. After deployment, SSH into the backend container (fly ssh console -p backend) and run bench --site &lt;site-name&gt; install-app &lt;custom-app-name&gt; to install the new app into your site.

### **Backup and Recovery Strategies**

A robust backup strategy is non-negotiable for a business-critical system like an ERP.

Local Environment Backups:

For the local Docker setup, backups can be created using the bench CLI inside the backend container.

1. Execute the backup command:  
    Bash  
    docker compose -f pwd.yml exec backend bench backup --with-files  

2. This creates a backup tarball inside the sites/your-site/private/backups directory, which resides on the sites Docker volume.
3. Copy the backup file from the Docker volume to the host machine for safekeeping.

Production (fly.io) Backups:

The production backup strategy should be multi-faceted, protecting both the database and the persistent file storage.

- **Database Backups:** The Fly Postgres service includes automated daily snapshots. These can be managed and restored via the Fly.io dashboard or flyctl commands. This provides a solid baseline for database disaster recovery.
- **Volume Backups:** Fly Volumes are also automatically snapshotted on a daily basis.<sup>20</sup> These snapshots can be used to restore the entire  
    sites volume in case of data corruption or accidental deletion.
- **Application-Level Backups (Recommended):** For the most comprehensive protection, an application-level backup should be performed regularly. This involves creating a new process group in fly.toml that runs a cron-like scheduler (e.g., supercronic). This process would execute a script at a scheduled interval (e.g., daily) that performs the following actions:
    1. Runs bench --site &lt;site-name&gt; backup --with-files.
    2. Uses a tool like s3cmd or aws-cli (installed in the Docker image) to upload the resulting backup tarball to an external, versioned S3 bucket.  
        This strategy ensures that a complete, point-in-time backup of both the database and all user files is stored securely off-site, independent of the Fly.io platform's own snapshots.

### **A-Z Troubleshooting Guide for Production**

When issues occur in the production environment, a systematic approach to debugging is required.

- **Deployment Failures:** If fly deploy fails, carefully examine the build logs provided in the terminal output. Common causes include:
  - Syntax errors in fly.toml.
  - Missing dependencies in the Dockerfile (e.g., forgetting to install postgresql-client).
  - The remote builder being unable to pull the base image.
- **Application Not Starting/Crashing:** If the deployment succeeds but the app is unavailable, use fly status to check the health of each machine and fly logs to view the runtime logs.<sup>27</sup>
  - fly logs -p &lt;process-group-name&gt; allows for filtering logs to a specific process (e.g., fly logs -p backend). Look for application errors or repeated crash loops.
- **Database/Redis Connectivity Issues:** If the application logs show errors connecting to Postgres or Redis:
  - Use fly ssh console to get a shell on a running machine.
  - From inside the shell, use tools like psql or redis-cli (if installed in the image) to attempt a manual connection to the service's .internal hostname. This can isolate network policy issues from application configuration problems.
  - Verify that the secrets (DB_PASSWORD, etc.) are set correctly using fly secrets list.
- **Scaling and Performance:** To scale a specific component, use the fly scale count command. For example, to scale the background workers to three machines:  
    Bash  
    fly scale count worker=3  
    <br/><sup>22</sup>  
    <br/>Monitor resource utilization (CPU, memory) for each machine in the Fly.io dashboard to determine if vertical scaling (e.g., fly scale vm performance-1x -p backend) is needed.

## **Conclusion**

The journey from a local concept to a globally deployed, production-ready ERP system is a complex but achievable endeavor. This report has detailed a robust, modern workflow for self-hosting Frappe ERPNext, beginning with the creation of a fully containerized local environment using frappe_docker and culminating in a scalable production deployment on Fly.io.

The analysis reveals several key principles for success. First, a deep architectural understanding of the local stack, particularly the microservices defined in pwd.yml and the flow of configuration, is not optional—it is a prerequisite for effective management and troubleshooting. Second, the migration from a single-host Docker Compose environment to a distributed platform like Fly.io is fundamentally an exercise in architectural translation. Concepts like services, volumes, and environment variables must be methodically mapped to their Fly.io equivalents: process groups, local persistent volumes, and a secure secret store.

The most critical architectural challenge identified is the local stack's reliance on a shared filesystem volume. The recommended cloud-native solution—externalizing file storage to an S3-compatible service—transforms the application into a more stateless and horizontally scalable system, aligning it with modern best practices for distributed applications.

By following the structured approach outlined—architectural deconstruction, local implementation and validation, and finally, a careful architectural migration to production—a practitioner can build more than just a running ERP instance. They can build a resilient, maintainable, and scalable system, gaining the operational maturity and full control that are the ultimate rewards of a self-hosted solution.

#### Works cited

1. How to Dockerize Frappe Applications | by Marcrinemm - Medium, accessed August 13, 2025, <https://medium.com/@marcrinemm/how-to-dockerize-frappe-applications-f3034be6d146>
2. Integrate the ERPNext API with the Fly.io API - Pipedream, accessed August 13, 2025, <https://pipedream.com/apps/erpnext/integrations/fly-io>
3. Dockerize Custom Application in Frappe Framework: Migration from VM to Container, accessed August 13, 2025, <https://medium.com/@yashwanthtss7/dockerize-custom-application-in-frappe-framework-migration-from-vm-to-container-bac073ec1040>
4. Deploy Docker images on Fly.io free tier | by Beppe Catanese | Geek Culture | Medium, accessed August 13, 2025, <https://medium.com/geekculture/deploy-docker-images-on-fly-io-free-tier-afbfb1d390b1>
5. Is Fly Still Pursuing One-click App Deployments? - Questions / Help - Fly.io Community, accessed August 13, 2025, <https://community.fly.io/t/is-fly-still-pursuing-one-click-app-deployments/2611>
6. Persistent Storage and Fast Remote Builds - Fly.io, accessed August 13, 2025, <https://fly.io/blog/persistent-storage-and-fast-remote-builds/>
7. Attaching a Fly.io (cloud) volume to ElasticSearch Dockerfile to maintain persistent storage. : r/docker - Reddit, accessed August 13, 2025, <https://www.reddit.com/r/docker/comments/15fga9a/attaching_a_flyio_cloud_volume_to_elasticsearch/>
8. frappe/frappe_docker: Docker images for production and development setups of the Frappe framework and ERPNext - GitHub, accessed August 13, 2025, <https://github.com/frappe/frappe_docker>
9. frappe/bench: CLI to manage Multi-tenant deployments for ... - GitHub, accessed August 13, 2025, <https://github.com/frappe/bench>
10. Successfully Installed ERPNext with pwd.yml, But Only Login Page Appears - Frappe Forum, accessed August 13, 2025, <https://discuss.frappe.io/t/successfully-installed-erpnext-with-pwd-yml-but-only-login-page-appears/142977>
11. pwd.yml · main · Christopher McKay / frappe_docker · GitLab, accessed August 13, 2025, <https://dev.egov.gy/christopher.mckay/frappe_docker/-/blob/main/pwd.yml>
12. docs/environment-variables.md · ffd6f58c6513c55f532db455e74ac3a60cbedb68 · Christopher McKay / frappe_docker · GitLab, accessed August 13, 2025, <https://dev.egov.gy/christopher.mckay/frappe_docker/-/blob/ffd6f58c6513c55f532db455e74ac3a60cbedb68/docs/environment-variables.md>
13. raw.githubusercontent.com, accessed August 13, 2025, <https://raw.githubusercontent.com/frappe/frappe_docker/main/docs/setup-options.md>
14. docs/environment-variables.md · main · Christopher McKay / frappe_docker - GitLab, accessed August 13, 2025, <https://dev.egov.gy/christopher.mckay/frappe_docker/-/blob/main/docs/environment-variables.md>
15. install-scripts/frappe/pwd.yml at main - GitHub, accessed August 13, 2025, <https://github.com/gavindsouza/install-scripts/blob/main/frappe/pwd.yml>
16. Overview Frappe, Docker, self-hosting - Deployment - Frappe Forum, accessed August 13, 2025, <https://discuss.frappe.io/t/overview-frappe-docker-self-hosting/110132>
17. raw.githubusercontent.com, accessed August 13, 2025, <https://raw.githubusercontent.com/frappe/frappe_docker/main/docs/setup_for_linux_mac.md>
18. Deploy docker-compose to Fly.io - Questions / Help, accessed August 13, 2025, <https://community.fly.io/t/deploy-docker-compose-to-fly-io/15679>
19. Migrate from docker-compose - Questions / Help - Fly.io Community, accessed August 13, 2025, <https://community.fly.io/t/migrate-from-docker-compose/12817>
20. Fly Volumes overview · Fly Docs - Fly.io, accessed August 13, 2025, <https://fly.io/docs/volumes/overview/>
21. Multiple processes inside a Fly.io app, accessed August 13, 2025, <https://fly.io/docs/app-guides/multiple-processes/>
22. Run multiple process groups in an app · Fly Docs - Fly.io, accessed August 13, 2025, <https://fly.io/docs/launch/processes/>
23. fly.toml for Complex Django App - Fly.io community, accessed August 13, 2025, <https://community.fly.io/t/fly-toml-for-complex-django-app/13927>
24. Deploy with a Dockerfile - Fly.io, accessed August 13, 2025, <https://fly.io/docs/languages-and-frameworks/dockerfile/>
25. Environment Configuration · Fly Docs - Fly.io, accessed August 13, 2025, <https://fly.io/docs/rails/the-basics/configuration/>
26. The Machine Runtime Environment - Fly.io, accessed August 13, 2025, <https://fly.io/docs/machines/runtime-environment/>
27. FastAPI Deployment Made Easy With Docker And Fly.io - Pybites, accessed August 13, 2025, <https://pybit.es/articles/fastapi-deployment-made-easy-with-docker-and-fly-io/>
28. Getting Started · Fly Docs - Fly.io, accessed August 13, 2025, <https://fly.io/docs/elixir/getting-started/>
29. Deploying Django to Production - Fly.io, accessed August 13, 2025, <https://fly.io/django-beats/deploying-django-to-production/>
30. Databases and storage · Fly Docs - Fly.io, accessed August 13, 2025, <https://fly.io/docs/database-storage-guides/>
31. Add volume storage to a Fly Launch app - Fly.io, accessed August 13, 2025, <https://fly.io/docs/launch/volume-storage/>
32. Deploy an app · Fly Docs, accessed August 13, 2025, <https://fly.io/docs/launch/deploy/>
33. How to frappe_docker install custom app? - Frappe Forum, accessed August 13, 2025, <https://discuss.frappe.io/t/how-to-frappe-docker-install-custom-app/111936>
34. How to add custom app to production docker setup? - ERPNext - Frappe Forum, accessed August 13, 2025, <https://discuss.frappe.io/t/how-to-add-custom-app-to-production-docker-setup/113283>
35. ERPNext installation issues \[docker\] - Frappe Forum, accessed August 13, 2025, <https://discuss.frappe.io/t/erpnext-installation-issues-docker/133109>