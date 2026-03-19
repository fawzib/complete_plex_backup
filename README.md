# 🚀 Complete Plex Backup Script

[](https://www.google.com/search?q=%23)
[](https://www.google.com/search?q=%23)
[](https://www.google.com/search?q=%23)

A robust, highly concurrent bash utility designed to safely stop, compress, split, and upload Plex Media Server AppData (and other associated Docker containers) to remote cloud storage.

-----

## ✨ Key Features

  * 📦 **Automated Splitting & Compression:** Compresses backup directories at a customizable level (default `7`) and splits large archives into manageable volumes (default `10G`) for easier cloud handling.
  * 🛑 **Graceful Docker Management:** Safely stops specified Docker containers before the backup begins to guarantee data consistency, and automatically restarts them upon completion.
  * ☁️ **Concurrent Cloud Uploads:** Utilizes `rclone` to monitor the temporary directory and stream split zip files to the remote server in parallel while the zipping process is still running.
  * 🗑️ **Smart Retention Policy:** Automatically prunes legacy backups on the remote destination, preserving only a specified number of recent backups (default `3`).
  * 🚫 **Intelligent Exclusions:** Skips non-critical directories (like `Cache`, `Crash Reports`, and `Logs`) to dramatically reduce archive size and processing time.
  * 🔒 **Execution Locking:** Implements `flock` with a retry mechanism to prevent simultaneous executions and overlapping backup operations.
  * 🔤 **Path Sanitization:** Automatically scrubs and standardizes directory names by replacing spaces and non-Latin characters, ensuring maximum filesystem compatibility.

-----

## 🧠 How It Works

1.  **Initialization & Locking:** The script establishes a lock file in the temporary directory. If another instance is running, it retries at designated intervals.
2.  **Container Suspension:** Iterates through the `DOCKER_CONTAINERS` array and issues a `docker stop` to running instances.
3.  **Root File Backup:** Identifies standalone files in the root backup directory, compresses them, and moves them to the remote server.
4.  **Parallel Archiving & Uploading:** Iterates through subdirectories (excluding the `IGNORE_FOLDERS` list). It initiates a background `zip` process for each folder. A monitoring loop immediately uploads the `.z01`, `.z02`, etc., split files via `rclone` as soon as they are generated.
5.  **Cleanup & Pruning:** Removes old backup sets from the remote server based on the `RETENTION_COUNT` variable.
6.  **Container Restoration:** Issues a `docker start` to all previously suspended containers.

-----

## 🛠️ Prerequisites

Ensure the following dependencies are installed and accessible in your system's PATH:

  * `bash`
  * `docker` (with appropriate permissions)
  * `rclone` (configured with your remote destination)
  * `zip`
  * `flock`
  * `iconv` (for filename sanitization)

-----

## ⚙️ Configuration Variables

Open the script and modify the variables at the top to match your environment infrastructure:

| Variable | Description | Default Value |
| :--- | :--- | :--- |
| `BACKUP_FOLDER` | The absolute path to the data directory you want to back up. | `/mnt/user/appdata/binhex-plexpass/Plex Media Server` |
| `REMOTE_SERVER` | The name of your configured `rclone` remote. | `google` |
| `REMOTE_DESTINATION` | The target path on the remote storage. | `plex_app_data` |
| `TMP_FOLDER` | Local directory for staging compressed archives. | `/tmp/plex_backup` |
| `RETENTION_COUNT` | Number of historical backups to retain on the remote. | `3` |
| `SPLIT_SIZE` | Maximum size for individual zip archive chunks. | `10G` |
| `COMPRESSION_LEVEL` | Zip compression ratio (0-9). | `7` |
| `DOCKER_CONTAINERS` | Array of Docker containers to stop/start during backup. | `("ollama" "open-webui" "Viseron" ...)` |
| `IGNORE_FOLDERS` | Array of subdirectories to skip during the backup loop. | `("Logs" "Crash Reports" "Cache" ...)` |

-----

## 🚀 Usage

1.  Clone the repository or download the script.
2.  Make the script executable:
    ```bash
    chmod +x backup_script.sh
    ```
3.  Execute the script manually, or add it to your crontab for automated scheduling:
    ```bash
    ./backup_script.sh
    ```

-----
