# **A Comprehensive Guide to Self-Hosting Frappe ERPNext with Docker and Fly.io**

## **Local Quick Start Guide**

This section provides a streamlined set of instructions to get a local instance of Frappe ERPNext running quickly.

### **Prerequisites**

*   [Git](https://git-scm.com/downloads)
*   [Docker Desktop](https://www.docker.com/products/docker-desktop/)

### **Setup Steps**

1.  **Clone the `frappe_docker` repository:**
    ```bash
    git clone https://github.com/frappe/frappe_docker
    cd frappe_docker
    ```

2.  **Create the environment configuration file:**
    Copy the example environment file to a new `.env` file. This file contains the default settings for your local instance.
    ```bash
    # For Windows (PowerShell)
    Copy-Item example.env .env

    # For macOS / Linux
    cp example.env .env
    ```

3.  **Start Docker Desktop:**
    Ensure that Docker Desktop is running on your machine before proceeding.

4.  **Launch the ERPNext Stack:**
    Use Docker Compose to start all the required services in the background. This command uses the `pwd.yml` file, which is designed for a "Play with Docker" setup.
    ```bash
    docker compose -f pwd.yml up -d
    ```
    The initial startup may take several minutes as Docker downloads the necessary images and runs the setup for the first time.

5.  **Set the Administrator Password:**
    After a few minutes, the site will be created. To log in, you need to set the Administrator password. Run the following command:
    ```bash
    docker compose -f pwd.yml exec backend bench --site frontend set-admin-password admin
    ```
    You can replace `admin` with any password you choose.

6.  **Access Your ERPNext Site:**
    Your local ERPNext instance is now ready. Open your web browser and navigate to:
    [http://localhost:8080](http://localhost:8080)

    Log in with the following credentials:
    *   **Username:** `Administrator`
    *   **Password:** The password you set in the previous step (e.g., `admin`).

---

