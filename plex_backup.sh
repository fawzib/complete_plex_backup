#!/bin/bash
# https://github.com/fawzib/complete_plex_backup

# Define variables
BACKUP_FOLDER="/mnt/user/appdata/binhex-plexpass/Plex Media Server"
#BACKUP_FOLDER="/tmp/test_data"
REMOTE_SERVER="google"
#REMOTE_DESTINATION="test_backup"
REMOTE_DESTINATION="plex_app_data"
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
COMPRESSION_LEVEL=7

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

 (
    # Attempt to acquire a lock on the folder
    exec 200>"$LOCK_FILE"
    retry_count=0

    while ! flock -n 200; do
        if [ "$retry_count" -ge "$FLOCK_MAX_RETRIES" ]; then
            echo "Max retries reached for $folder. Skipping..."
            break
        fi
        echo "Could not acquire lock. Retrying in $FLOCK_RETRY_INTERVAL seconds... ($((retry_count+1))/$FLOCK_MAX_RETRIES)"
        sleep "$FLOCK_RETRY_INTERVAL"
        retry_count=$((retry_count + 1))
    done

    if [ "$retry_count" -lt "$FLOCK_MAX_RETRIES" ]; then
        eval "$command"
        command_status=$?
		
		if [ $command_status -ne 0 ]; then
          echo "Command failed with status $command_status."
          exit $command_status
        fi
    fi
  ) 200>"$LOCK_FILE"
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


clean_filename() {
    local original_name="$1"
    local cleaned_name

    # Replace spaces with underscores
    cleaned_name=$(echo "$original_name" | tr ' ' '_')

    # Replace non-Latin characters with Latin equivalents using iconv
    cleaned_name=$(echo "$cleaned_name" | iconv -f UTF-8 -t ASCII//TRANSLIT)

    # Remove any characters that are not alphanumeric, underscores, or dashes
    cleaned_name=$(echo "$cleaned_name" | tr -cd '[:alnum:]_-')

    # Ensure the cleaned name is not empty
    if [[ -z "$cleaned_name" && -n "$original_name" ]]; then
        cleaned_name="default_filename"
    fi

    echo "$cleaned_name"
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
	
	cleaned_filename=$(clean_filename "$zip_base_name")

    # Start the zip process in the background

	full_file_path="$TMP_FOLDER/$cleaned_filename.zip"

	# Check if the file exists
	if [ -f "$full_file_path" ]; then
		echo "File $full_file_path already exists."
		rm "$full_file_path"
		echo "File $full_file_path has been deleted."
	fi
	
	command="zip -r -$COMPRESSION_LEVEL -q -s $SPLIT_SIZE \"$full_file_path\" \"$folder_to_backup\"/* 2>\"$ERROR_LOG\""
	echo $command
	run_with_lock "$command" &
    #(zip -r -0 -q -s $SPLIT_SIZE "$full_file_path" "$folder_to_backup"/* 2> "$ERROR_LOG") &
	zip_pid=$!

	echo $zip_pid
    # Loop to monitor the zip process and upload new 

    while kill -0 "$zip_pid" 2>/dev/null; do
        for file in $(ls "$TMP_FOLDER" | grep -E "${cleaned_filename}.zip|${cleaned_filename}.z[0-9]*"); do
		    #echo "Found file: $file"
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

	echo "Uploading leftovers..."
    # Final upload in case any parts were missed during parallel upload
    rclone move "$TMP_FOLDER/" "$REMOTE_SERVER:$BACKUP_DESTINATION/" \
        --include "${cleaned_filename}.zip" --include "${cleaned_filename}.z[0-9]*" \
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

BACKUP_FOLDER="${BACKUP_FOLDER%/}"
TMP_FOLDER="${TMP_FOLDER%/}"

# Ensure we are using bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script requires bash to run"
    exit 1
fi

shopt -s extglob


#if [ -f "$LOCK_FILE" ]; then
#  echo "Lock file exists. Exiting script."
#  exit 1
#fi

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

find "$BACKUP_FOLDER" -maxdepth 1 -type f | zip -r -"$COMPRESSION_LEVEL" -q "$TMP_FOLDER/$zip_base_name.zip" -@ 2>"$ERROR_LOG"
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

rm $LOCK_FILE
# Remove old backups, keeping only the last RETENTION_COUNT
remove_old_backups "$REMOTE_DESTINATION" "$RETENTION_COUNT"
echo "Backup and upload completed successfully, and old backups have been pruned."

start_containers
echo "Stopped containers have been started."
