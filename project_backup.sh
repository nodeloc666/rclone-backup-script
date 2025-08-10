#!/bin/bash

# ==============================================================================
# Generic Data Backup Script
# Version: 3.0 (Project Adaptability)
# Description: Automates data backup, encryption, and sync to R2 storage via rclone.
#              Adaptable to different projects by changing the PROJECT_NAME variable.
# ==============================================================================

# --- Configuration Section ---
# Define the project name. This variable will be used for log file naming,
# backup file naming, Rclone target path, and customizable log messages.
# !!! IMPORTANT: Change this variable for each different project !!!
PROJECT_NAME="Moontv" # <--- CONFIGURE THIS FOR EACH PROJECT (e.g., "CRM", "ERP")

# Log file path. All script output will be appended here.
LOG_FILE="/var/log/${PROJECT_NAME,,}_backup.log" # Converts PROJECT_NAME to lowercase for log file name

# Source directory to be backed up.
SOURCE_DIR="/${PROJECT_NAME,,}" # Example: /moontv, /crm (adjust as needed if not lowercase project name)
                                 # !!! IMPORTANT: Adjust this if your source directory is not lowercase project name !!!

# Temporary directory for the encrypted zip file.
# Ensures this directory exists and has write permissions.
# The script will attempt to create it if it doesn't exist.
TEMP_BACKUP_DIR="/var/backups"

# Name and full path for the generated encrypted zip file.
CURRENT_ZIP_FILE="${TEMP_BACKUP_DIR}/${PROJECT_NAME,,}_data.zip" # Example: /var/backups/moontv_data.zip

# Rclone remote target. Format: <remote_name>:<path>
# Ensure Rclone is configured with a remote named 'R2'.
RCLONE_TARGET="R2:/backup/${PROJECT_NAME,,}" # Example: R2:/backup/moontv

# Array of required dependencies.
REQUIRED_DEPS=("zip" "rclone")

# ==============================================================================
# --- Utility Functions Section ---
# These functions handle logging, command execution, and dependency management.
# ==============================================================================

# Function: Logs a message to the specified LOG_FILE.
# Arguments: $1 - The message content to log.
log_message() {
  local msg="$1"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S.%3N")
  echo "${timestamp} - ${msg}"
}

# Function: Executes a command and logs its success or failure.
# Arguments:
#   $1 - A descriptive string for the operation.
#   $2 - The command string to execute.
#   $3 - A short error message to display if the command fails.
# Returns: 0 on success, 1 on failure.
execute_operation() {
  local description="$1"
  local command_to_run="$2"
  local error_on_fail="$3"

  log_message "Executing: ${description}..."

  # Use `eval` to allow complex commands with pipes/redirections.
  # Command output is captured by the global `exec` redirect.
  eval "${command_to_run}"
  local status=$?

  if [ "${status}" -eq 0 ]; then
    log_message "${description}: SUCCESS"
    return 0
  else
    log_message "${description}: FAILED (Exit Code: ${status})"
    log_message "Error: ${error_on_fail}"
    return 1
  fi
}

# Function: Handles script exit, logging a final status.
# Arguments:
#   $1 - The exit code (0 for success, non-zero for failure).
#   $2 - The status message (e.g., "SUCCESS", "FAILURE").
script_exit() {
  local exit_code="$1"
  local status_msg="$2"

  log_message "" # Add a blank line for readability
  log_message ">> ${PROJECT_NAME} Data Backup Script Finished"
  log_message ">> End Time: $(date +"%Y-%m-%d %H:%M:%S")"
  log_message ">> Status: ${status_msg}"
  # Print the final separator directly to the log file (via exec >>)
  echo "=========================================================================================\n"
  exit "${exit_code}"
}

# Function: Checks for required commands and attempts to install them if missing.
# Requires root privileges for installation.
check_and_install_dependencies() {
  log_message "Checking mandatory dependencies: ${REQUIRED_DEPS[*]}..."

  local package_manager=""

  if command -v apt &>/dev/null; then
    package_manager="apt"
  elif command -v yum &>/dev/null; then
    package_manager="yum"
  elif command -v dnf &>/dev/null; then
    package_manager="dnf"
  else
    log_message "ERROR: No supported package manager (apt, yum, dnf) found."
    log_message "Please install 'zip' and 'rclone' manually. Exiting."
    script_exit 1 "FAILED (No package manager)"
  fi

  for dep in "${REQUIRED_DEPS[@]}"; do
    if ! command -v "${dep}" &>/dev/null; then
      log_message "Dependency '${dep}' not found. Attempting to install using ${package_manager}..."

      if [ "${package_manager}" == "apt" ]; then
        execute_operation "Updating apt repositories" "apt update -y" "apt update failed." || script_exit 1 "FAILED (Dependency Install)"
        execute_operation "Installing '${dep}' via apt" "apt install -y \"${dep}\"" "apt install '${dep}' failed." || script_exit 1 "FAILED (Dependency Install)"
      elif [ "${package_manager}" == "yum" ] || [ "${package_manager}" == "dnf" ]; then
        execute_operation "Installing '${dep}' via ${package_manager}" "${package_manager} install -y \"${dep}\"" "${package_manager} install '${dep}' failed." || script_exit 1 "FAILED (Dependency Install)"
      fi
    fi
  done
  log_message "All required dependencies are confirmed installed."
}

# ==============================================================================
# --- Main Logic Section ---
# This is the primary execution flow of the backup script.
# ==============================================================================

# Redirect all standard output and standard error from the entire script
# to the LOG_FILE, appending to it for each execution.
exec >> "${LOG_FILE}" 2>&1

# Initial script start messages.
log_message ""
log_message ">> ${PROJECT_NAME} Data Backup Script Started"
log_message ">> Start Time: $(date +"%Y-%m-%d %H:%M:%S")"
log_message ""

# Step 1: Check and install required dependencies (zip, rclone).
check_and_install_dependencies

# Step 2: Ensure the temporary backup directory exists.
if [ ! -d "${TEMP_BACKUP_DIR}" ]; then
  log_message "Temporary backup directory '${TEMP_BACKUP_DIR}' for ${PROJECT_NAME} does not exist. Creating it now."
  execute_operation "Creating temporary backup directory" \
    "mkdir -p \"${TEMP_BACKUP_DIR}\"" \
    "Failed to create temporary backup directory. Check permissions or path." || script_exit 1 "FAILED (Dir Creation)"
fi

# Step 3: Verify the encryption password environment variable is set.
log_message "Verifying encryption password for ${PROJECT_NAME} backup..."
if [ -z "${ENCRYPTION_PASSWORD}" ]; then
  log_message "ERROR: ENCRYPTION_PASSWORD environment variable is not set."
  log_message "${PROJECT_NAME} Backup FAILED: Encryption password not provided."
  script_exit 1 "FAILED (No Password)"
fi
log_message "Encryption key found for ${PROJECT_NAME}."

# Step 4: Pack and encrypt the data.
execute_operation "Packing and encrypting ${PROJECT_NAME} data from '${SOURCE_DIR}'" \
  "zip -r -e -P \"${ENCRYPTION_PASSWORD}\" -q \"${CURRENT_ZIP_FILE}\" \"${SOURCE_DIR}\"" \
  "Packing and encryption failed for ${PROJECT_NAME} data. Check if '${SOURCE_DIR}' exists and is readable. (Exit Code: $?)" || script_exit 1 "FAILED (Packing/Encryption)"

# Clear the password variable from memory for security.
unset ENCRYPTION_PASSWORD

# Step 5: Sync the encrypted backup file to R2 storage using rclone.
execute_operation "Syncing ${PROJECT_NAME} backup to R2 storage ('${RCLONE_TARGET}')" \
  "rclone sync \"${CURRENT_ZIP_FILE}\" \"${RCLONE_TARGET}\" --checksum --transfers=4 --buffer-size 16M --verbose" \
  "Rclone sync failed for ${PROJECT_NAME} data. Ensure Rclone is configured correctly for '${RCLONE_TARGET}'. (Exit Code: $?)" || script_exit 1 "FAILED (Rclone Sync)"

# Step 6: Clean up the local temporary backup file.
log_message "Starting cleanup of local temporary backup file for ${PROJECT_NAME}."
execute_operation "Cleaning up local temporary backup file '${CURRENT_ZIP_FILE}'" \
  "rm -f \"${CURRENT_ZIP_FILE}\"" \
  "Failed to remove local temporary backup file for ${PROJECT_NAME}. Manual cleanup may be required." || log_message "WARNING: Local file cleanup failed, but ${PROJECT_NAME} backup completed."

# Step 7: Final success message and script exit.
script_exit 0 "SUCCESS"
