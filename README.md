# Complete Plex Backup
Fully backup your plex to the cloud. No script online was suitable for my case since I want to perform backup inside my ram directory and then move it to the cloud. I want to avoid using my local hard drive for the backup and thus "rclone move" was used. Backup process in general takes a while and I didn't want to stop Plex server during this process. I hope you find this script helpful

Features:
- Backups up the whole Plex folder and not just the database
- Zips each directory top directory at a time instead everything at once
  -  Splits large zip files 
- Support of skipping certain directories (ex: Logs)
- It locks the plex directory to avoid data corruption
  - Run the backup while Plex is still running!
- Backups to both local and cloud using rclone
- It starts uploading to the cloud during the zip process to quickly free disk space and reduce backup time
- Auto stops and starts predefined docker containers to free resources 
