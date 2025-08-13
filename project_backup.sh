#!/bin/bash
# ==============================================================================
# Generic Data Backup Script
# Version: 6.7.1 (Syntax Fix for one-line functions)
#
# Description:
#   A robust and universal Bash script for automated data backup, encryption,
#   and synchronization to cloud storage. This version introduces advanced
#   notification control and fixes a syntax error from the previous compacted version.
#
# Features:
#   - Automated backup & encryption
#   - Cloud sync with Rclone & remote cleanup
#   - Detailed failure reasons and execution time in messages
#   - Advanced notification modes: all, failure, success, none
#   - Clean, non-duplicated logging and robust error handling
# ==============================================================================

# ------------------------------------------------------------------------------
# --- Safety Net ---
# ------------------------------------------------------------------------------
set -o pipefail


# ==============================================================================
# --- User Configuration Section (Modify the values below to fit your needs) ---
# ==============================================================================
### --- 1. Project & Path Configuration ---
readonly PROJECT_NAME="webapp"
readonly SOURCE_DIR="/${PROJECT_NAME,,}"
readonly LOG_FILE="/var/log/${PROJECT_NAME,,}_backup.log"
readonly TEMP_BACKUP_DIR="/var/backups"

### --- 2. Remote Storage & Retention Policy ---
readonly RCLONE_TARGET="R2:/backup/${PROJECT_NAME,,}"
readonly BACKUP_RETENTION_COUNT=3
readonly KEEP_LOCAL_BACKUP="false"

### --- 3. Notification Configuration ---
# Options: "all", "failure", "success", "none"
readonly NOTIFICATION_MODE="failure"
readonly WEBHOOK_URL="https://your.webhook.provider.com/path/to/your/hook"


# ==============================================================================
# --- Global Variables & Constants (Do not modify) ---
# ==============================================================================
readonly REQUIRED_DEPS=("zip" "rclone" "curl")
readonly SCRIPT_START_TIMESTAMP=$(date +%s)
readonly SCRIPT_START_TIME_FORMATTED=$(date +"%Y-%m-%d %H:%M:%S")
readonly TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
readonly CURRENT_ZIP_FILE="${TEMP_BACKUP_DIR}/${PROJECT_NAME,,}_data_${TIMESTAMP}.zip"
readonly SCRIPT_NAME=$(basename "$0")
GLOBAL_FAILURE_REASON=""


# ==============================================================================
# --- Core Function Section ---
# ==============================================================================
log_message() { local msg="$1"; echo "$(date +"%Y-%m-%d %H:%M:%S.%3N") - ${msg}"; }
format_duration() { local s=$1; if ((s<0)); then echo "0s"; return; fi; local m=$((s/60)); s=$((s%60)); if ((m>0)); then echo "${m}m ${s}s"; else echo "${s}s"; fi; }
handle_failure() { GLOBAL_FAILURE_REASON="$1"; log_message "FATAL ERROR: ${GLOBAL_FAILURE_REASON}"; exit 1; }

send_notification() {
  local status="$1"
  local message="$2"
  if [ -z "${WEBHOOK_URL}" ] || [[ "${WEBHOOK_URL}" == *"your.webhook.provider.com"* ]]; then
    log_message "WARNING: Notification requested, but WEBHOOK_URL is not configured. Skipping."
    return 1
  fi
  local json_payload
  json_payload=$(printf '{"project": "%s", "server": "%s", "status": "%s", "message": "%s"}' \
    "${PROJECT_NAME}" "$(hostname)" "${status}" "${message}")
  log_message "Sending ${status} notification..."
  curl --connect-timeout 5 --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -d "${json_payload}" \
    "${WEBHOOK_URL}" -sS || log_message "WARNING: Failed to send notification."
}

script_final_exit() {
  local exit_code=$?
  local end_timestamp=$(date +%s)
  local duration=$((end_timestamp - SCRIPT_START_TIMESTAMP))
  local formatted_duration=$(format_duration "${duration}")
  local time_meta="Start: ${SCRIPT_START_TIME_FORMATTED}, Duration: ${formatted_duration}."

  if [ "${exit_code}" -eq 0 ]; then
    log_message ">> Final Status: SUCCESS"
    log_message ">> Backup and cleanup tasks completed successfully."
    if [[ "${NOTIFICATION_MODE}" == "all" || "${NOTIFICATION_MODE}" == "success" ]]; then
      local success_message="Backup for '${PROJECT_NAME}' on host $(hostname) completed successfully. ${time_meta}"
      send_notification "SUCCESS" "${success_message}"
    else
      log_message "Notification on success is disabled by current mode ('${NOTIFICATION_MODE}')."
    fi
  else
    log_message ">> Final Status: FAILURE"
    log_message ">> Script was terminated due to an error."
    if [[ "${NOTIFICATION_MODE}" == "all" || "${NOTIFICATION_MODE}" == "failure" ]]; then
      local final_message="Backup for '${PROJECT_NAME}' on host $(hostname) failed."
      if [ -n "${GLOBAL_FAILURE_REASON}" ]; then
        final_message+=" Reason: ${GLOBAL_FAILURE_REASON}."
      else
        final_message+=" An unexpected error occurred. Please check log for details."
      fi
      final_message+=" ${time_meta}"
      send_notification "FAILURE" "${final_message}"
    else
      log_message "Notification on failure is disabled by current mode ('${NOTIFICATION_MODE}')."
    fi
  fi

  log_message ">> Total Execution Time: ${formatted_duration}"
  log_message ">> ${PROJECT_NAME} Backup Script Finished"
  log_message ">> End Time: $(date +"%Y-%m-%d %H:%M:%S")"
  echo -e "=========================================================================================\n"
}

# --- FIX: Restored to standard multi-line format for robustness ---
check_dependencies() {
  log_message "Checking for required dependencies: ${REQUIRED_DEPS[*]}..."
  for dep in "${REQUIRED_DEPS[@]}"; do
    command -v "${dep}" &>/dev/null || handle_failure "Dependency '${dep}' is not installed."
  done
  log_message "All required dependencies are installed."
}

# --- FIX: Restored to standard multi-line format for robustness ---
cleanup_old_backups_on_remote() {
  log_message "Starting cleanup of old backups on remote: ${RCLONE_TARGET}"
  local backup_pattern="${PROJECT_NAME,,}_data_*.zip"
  log_message "Searching for remote files with pattern: '${backup_pattern}'..."

  # Get list of files to delete (all except the newest N)
  local files_to_delete
  files_to_delete=$(rclone lsf --include "${backup_pattern}" "${RCLONE_TARGET}" | sort -r | tail -n +$((BACKUP_RETENTION_COUNT + 1)))

  if [ -z "${files_to_delete}" ]; then
    log_message "No old backups to delete. The number of backups is within the retention limit (${BACKUP_RETENTION_COUNT})."
    return 0
  fi

  log_message "The following old backups will be deleted:"
  echo "${files_to_delete}" | while IFS= read -r file; do
    log_message "  - Preparing to delete: ${file}"
    rclone deletefile "${RCLONE_TARGET}/${file}" || log_message "    -> WARNING: Failed to delete remote file: ${file}"
  done
  log_message "Remote cleanup process finished."
}


# ==============================================================================
# --- Main Logic Section ---
# ==============================================================================
main() {
  trap script_final_exit EXIT
  exec >> "${LOG_FILE}" 2>&1
  log_message "========================================================================================="
  log_message ">> ${PROJECT_NAME} Backup Script Started"
  log_message ">> Start Time: ${SCRIPT_START_TIME_FORMATTED}"
  log_message ""
  log_message "--- Step 1: Environment Checks ---"
  check_dependencies
  if [ ! -d "${TEMP_BACKUP_DIR}" ];then log_message "Local backup directory '${TEMP_BACKUP_DIR}' not found. Creating...";mkdir -p "${TEMP_BACKUP_DIR}"||handle_failure "Could not create temp directory ${TEMP_BACKUP_DIR}.";fi
  if [[ "${NOTIFICATION_MODE}" != "none" ]] && { [ -z "${WEBHOOK_URL}" ] || [[ "${WEBHOOK_URL}" == *"your.webhook.provider.com"* ]]; }; then
      log_message "WARNING: Notifications are enabled ('${NOTIFICATION_MODE}'), but WEBHOOK_URL is not configured. No notifications will be sent."
  fi
  if [ -z "${ENCRYPTION_PASSWORD}" ];then handle_failure "Environment variable 'ENCRYPTION_PASSWORD' is not set.";fi
  log_message "Environment checks passed."
  log_message "--- Step 2: Packing and Encryption ---"
  log_message "Source: '${SOURCE_DIR}', Target: '${CURRENT_ZIP_FILE}'"
  zip -r -e -P "${ENCRYPTION_PASSWORD}" -q "${CURRENT_ZIP_FILE}" "${SOURCE_DIR}"||handle_failure "Failed to pack or encrypt the source directory."
  unset ENCRYPTION_PASSWORD
  log_message "Packing and encryption completed successfully."
  log_message "--- Step 3: Uploading to Cloud Storage ---"
  log_message "Uploading to Rclone remote: '${RCLONE_TARGET}'"
  rclone copy "${CURRENT_ZIP_FILE}" "${RCLONE_TARGET}" --checksum --transfers=4 --buffer-size 16M --verbose||handle_failure "Failed to upload to Rclone remote."
  log_message "File upload completed successfully."
  log_message "--- Step 4: Local Cleanup ---"
  if [ "${KEEP_LOCAL_BACKUP}" != "true" ];then log_message "Cleaning up local backup file: '${CURRENT_ZIP_FILE}'";rm -f "${CURRENT_ZIP_FILE}"||log_message "WARNING: Failed to remove local backup file.";else log_message "Keeping local backup file as configured.";fi
  log_message "--- Step 5: Remote Cleanup ---"
  cleanup_old_backups_on_remote
  log_message "--- All tasks completed successfully ---"
}

# --- Script Execution Entry Point ---
main "$@"
