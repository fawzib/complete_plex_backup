#!/bin/bash

# Define variables
BACKUP_FOLDER="/mnt/user/appdata/binhex-plexpass/Plex Media Server"
REMOTE_SERVER="google"
REMOTE_DESTINATION="plex_app_data_zip"
TMP_FOLDER="/tmp/plex_backup"
BACKUP_DATE=$(date +%Y-%m-%d)
BACKUP_DESTINATION="$REMOTE_DESTINATION/$BACKUP_DATE"
RETENTION_COUNT=3
SPLIT_SIZE="10G"
ERROR_LOG="$TMP_FOLDER/error_log.txt"
DOCKER_CONTAINERS=("ollama" "open-webui" "Viseron" "CamViewerPlus" "chromadb" "faster-whisper" "whisper-asr-webservice" "openvscode-server")
# Create a list of folders to ignore
IGNORE_FOLDERS=("Logs" "Crash Reports" "Cache" "Codecs" "Diagnostics" "Drivers" "Updates")
LOCK_FILE="$TMP_FOLDER/plex.lock"
FLOCK_MAX_RETRIES=50
FLOCK_RETRY_INTERVAL=10

# Function to remove old backups
remove_old_backups() {
    BACKUP_PATH=$1
    RETAIN_COUNT=$2
    echo "Removing old backups, keeping only the last $RETAIN_COUNT..."
    # List backup folders, sort by date, and skip the latest $RETAIN_COUNT
    BACKUPS_TO_DELETE=$(rclone lsf "$REMOTE_SERVER:$BACKUP_PATH" --dirs-only | sort | head -n -"$RETAIN_COUNT")
    for BACKUP in $BACKUPS_TO_DELETE; do
        echo "Removing old backup: $BACKUP"
        rclone purge "$REMOTE_SERVER:$BACKUP_PATH/$BACKUP"
    done
}

# Function to acquire lock and run a command
run_with_lock() {
  local command="$1"
  local background="$2"
  local retries=0

  #echo "Starting run_with_lock with command: $command, background: $background"

  while [ $retries -lt $FLOCK_MAX_RETRIES ]; do
    (
      # Try to acquire the lock
      flock -n 200
      if [ $? -eq 0 ]; then
        #echo "Lock acquired, executing command: $command"
        
        # Lock acquired, execute the command
        if [ "$background" == "true" ]; then
          eval "$command" &
          pid=$!
          wait $pid
          command_status=$?
        else
          eval "$command"
          command_status=$?
        fi

        if [ $command_status -ne 0 ]; then
          echo "Command failed with status $command_status."
          exit $command_status
        fi

        echo "Command executed successfully and lock released."
        exit 0
      else
        # Failed to acquire the lock, increment the retry counter and sleep
        retries=$((retries + 1))
        echo "Failed to acquire lock. Attempt $retries/$FLOCK_MAX_RETRIES. Retrying in $FLOCK_RETRY_INTERVAL seconds..."
        sleep $FLOCK_RETRY_INTERVAL
      fi
    ) 200>"$LOCK_FILE"
  done

  echo "Failed to acquire lock after $FLOCK_MAX_RETRIES attempts."
  exit 1
}

# Function to stop containers gracefully
stop_containers() {
  for container in "${DOCKER_CONTAINERS[@]}"; do
    if [[ "$(docker ps -q -f name="^${container}$")" ]]; then
      echo "Stopping container: $container"
      docker stop "$container"
      stopped_containers+=("$container")
    else
      echo "Container $container is not running."
    fi
  done
}

# Function to start containers
start_containers() {
  for container in "${stopped_containers[@]}"; do
    echo "Starting container: $container"
    docker start "$container"
  done
}

# Function to check if a file is in the uploaded_files array
file_uploaded() {
    local file=$1
    for uploaded_file in "${uploaded_files_ref[@]}"; do
        if [[ "$uploaded_file" == "$file" ]]; then
            return 0
        fi
    done
    return 1
}

zip_and_upload() {
    local folder_path=$1
    local zip_base_name=$2
    local folder_to_backup="${folder_path}/${zip_base_name}"
    declare -n uploaded_files_ref=$3  # Create a name reference to the passed array

    # Check if folder_to_backup is empty
    if [ -z "$(ls -A "$folder_to_backup")" ]; then
        echo "Skipping empty folder: $folder_to_backup"
        return
    fi

    # Start the zip process in the background
	command="zip -r -0 -q -s $SPLIT_SIZE \"$TMP_FOLDER/$zip_base_name.zip\" \"$folder_to_backup\"/* 2>\"$ERROR_LOG\""
	run_with_lock "$command" true
    #(zip -r -0 -q -s $SPLIT_SIZE "$TMP_FOLDER/$zip_base_name.zip" "$folder_to_backup"/* 2> "$ERROR_LOG") &
	zip_pid=$!
	
    # Loop to monitor the zip process and upload new files
    while kill -0 "$zip_pid" 2>/dev/null; do
			
        # Find new files that have not been uploaded yet
        for file in $(ls "$TMP_FOLDER" | grep -E "${zip_base_name}.zip|${zip_base_name}.z[0-9]*"); do
            if ! file_uploaded "$file"; then
                echo "Uploading file: $file"
                rclone move "$TMP_FOLDER/$file" "$REMOTE_SERVER:$BACKUP_DESTINATION/" \
					--size-only \
                    --check-first \
                    --retries 20 \
                    --low-level-retries 60 \
                    --retries-sleep 10s \
                    --contimeout 60s \
                    --timeout 300s \
                    --stats 10m \
                    --multi-thread-streams=16 \
                    --transfers 4 \
                    --ignore-errors \
                    --quiet
                uploaded_files_ref+=("$file")  # Add the file to the array
            fi
        done
        sleep 10
    done

    # Final upload in case any parts were missed during parallel upload
    rclone move "$TMP_FOLDER/" "$REMOTE_SERVER:$BACKUP_DESTINATION/" \
        --include "${zip_base_name}.zip" --include "${zip_base_name}.z[0-9]*" \
		--size-only \
        --check-first \
        --retries 20 \
        --low-level-retries 60 \
        --retries-sleep 10s \
        --contimeout 60s \
        --timeout 300s \
        --stats 10m \
        --multi-thread-streams=16 \
        --transfers 4 \
        --ignore-errors \
        --quiet
}


if [ -f "$LOCK_FILE" ]; then
  echo "Lock file exists. Exiting script."
  exit 1
fi

mkdir -p "$TMP_FOLDER"
uploaded_files=()  # Initialize the array
# Debugging: Check if BACKUP_FOLDER exists
if [ ! -d "$BACKUP_FOLDER" ]; then
    echo "Backup folder does not exist: $BACKUP_FOLDER"
    exit 1
fi
cd "$BACKUP_FOLDER"
echo "backup folder:"
pwd
stopped_containers=()
stop_containers


# Create a backup for non-directory files inside the backup_folder
echo "Creating backup for non-directory files..."
zip_base_name="non_directory_files_backup"

find "$BACKUP_FOLDER" -maxdepth 1 -type f | zip -r -0 -q "$TMP_FOLDER/$zip_base_name.zip" -@ 2>"$ERROR_LOG"
#command="find \"$BACKUP_FOLDER\" -maxdepth 1 -type f | zip -r -0 -q \"$TMP_FOLDER/$zip_base_name.zip\" -@ 2>\"$ERROR_LOG\""
#run_with_lock "$command" false

# Upload the backup of non-directory files to the remote server
echo "Uploading non-directory files backup..."
rclone move "$TMP_FOLDER/" "$REMOTE_SERVER:$BACKUP_DESTINATION/" \
  --include "${zip_base_name}.zip" \
  --check-first \
  --size-only \
  --retries 8 \
  --low-level-retries 10 \
  --contimeout 60s \
  --timeout 300s \
  --quiet

# Iterate over each item in the backup_folder
for ITEM in "$BACKUP_FOLDER"/*; do
    if [ -d "$ITEM" ]; then
        FOLDER_NAME=$(basename "$ITEM")
        # Check if the folder is in the ignore list
        if [[ ! " ${IGNORE_FOLDERS[@]} " =~ " ${FOLDER_NAME} " ]]; then
            echo "Processing folder: $FOLDER_NAME"
            # Create and upload zip archive of the folder in parallel
            zip_and_upload "$BACKUP_FOLDER" "$FOLDER_NAME" uploaded_files
        else
            echo "Skipping ignored folder: $FOLDER_NAME"
        fi
    fi
done

echo "Removing lock"
rm $LOCK_FILE
# Remove old backups, keeping only the last 3
remove_old_backups "$REMOTE_DESTINATION" "$RETENTION_COUNT"
echo "Backup and upload completed successfully, and old backups have been pruned."

start_containers
echo "Stopped containers have been started."
