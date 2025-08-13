#!/bin/bash
# ==============================================================================
# Generic Data Backup Script
# Version: 7.0 (Multi-Provider Notification Support)
#
# Description:
#   A professional-grade Bash script for backup, encryption, and cloud sync.
#   This version adds native support for multiple notification providers,
#   including WeCom, DingTalk, Feishu, Telegram, and generic webhooks.
#
# Features:
#   - Automated backup & encryption
#   - Cloud sync with Rclone & remote cleanup
#   - Advanced notification modes (all, failure, success, none)
#   - Native support for WeCom, DingTalk, Feishu, Telegram, and Generic webhooks
#   - Richly formatted, provider-specific notification messages
# ==============================================================================

# ------------------------------------------------------------------------------
# --- Safety Net ---
# ------------------------------------------------------------------------------
set -o pipefail


# ==============================================================================
# --- User Configuration Section (Modify the values below to fit your needs) ---
# ==============================================================================
### --- 1. Project & Path Configuration ---
readonly PROJECT_NAME="Moontv_PROD"
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

# --- NEW: Select your notification service provider ---
# Options: "wecom", "dingtalk", "feishu", "telegram", "generic", "none"
# "none" is another way to disable notifications.
# Make sure this matches the URL and other settings below.
readonly NOTIFICATION_PROVIDER="wecom"

# --- Provider-specific URLs and Settings ---
# - wecom: The webhook URL from the WeCom robot settings.
# - dingtalk: The webhook URL from the DingTalk robot settings.
#             IMPORTANT: Set a keyword like "Backup" in DingTalk's security settings.
# - feishu: The webhook URL from the Feishu robot settings.
# - generic: Your custom or other standard webhook URL.
# - telegram: For Telegram, this should be your Bot's API URL.
#             Example: "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/sendMessage"
readonly WEBHOOK_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_WECOM_BOT_KEY"

# --- Telegram Specific (only used if NOTIFICATION_PROVIDER is "telegram") ---
readonly TELEGRAM_CHAT_ID="<YOUR_CHAT_ID>"


# ==============================================================================
# --- Global Variables & Constants (Do not modify) ---
# ==============================================================================
# ... (此部分与之前版本完全相同) ...
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

# --- MODIFIED: Major rewrite to support multiple notification providers ---
send_notification() {
  local status="$1"
  local message="$2"
  local provider_lower
  provider_lower=$(echo "${NOTIFICATION_PROVIDER}" | tr '[:upper:]' '[:lower:]')

  if [[ "${provider_lower}" == "none" ]]; then
    log_message "Notifications are disabled via provider setting."
    return 0
  fi

  if [ -z "${WEBHOOK_URL}" ] || [[ "${WEBHOOK_URL}" == *"your."* ]]; then
    log_message "WARNING: Notification provider '${provider_lower}' is active, but WEBHOOK_URL is not configured. Skipping."
    return 1
  fi

  local json_payload=""
  local final_url="${WEBHOOK_URL}"
  local http_headers=("-H" "Content-Type: application/json")

  log_message "Formatting notification for provider: ${provider_lower}"

  case "${provider_lower}" in
    "wecom")
      local color="info"
      [[ "${status}" == "FAILURE" ]] && color="warning"
      json_payload=$(printf '{"msgtype": "markdown", "markdown": {"content": "### %s Backup Notification\n> **Project:** `%s`\n> **Server:** `%s`\n> **Status:** <font color=\\"%s\\">%s</font>\n> **Message:** %s"}}' \
        "${PROJECT_NAME}" "${PROJECT_NAME}" "$(hostname)" "${color}" "${status}" "${message}")
      ;;
    "dingtalk")
      # IMPORTANT: DingTalk robots often require a keyword in the text. "Backup" is used here.
      local color="#008000" # Green
      [[ "${status}" == "FAILURE" ]] && color="#ff0000" # Red
      local title="Backup Notification: ${PROJECT_NAME} ${status}"
      local text_content="### ${title}\n\n**Server:** $(hostname)\n\n**Status:** <font color='${color}'>${status}</font>\n\n**Details:** ${message}"
      json_payload=$(printf '{"msgtype": "markdown", "markdown": {"title": "%s", "text": "%s"}}' "${title}" "${text_content}")
      ;;
    "feishu")
      local title_emoji="✅"
      [[ "${status}" == "FAILURE" ]] && title_emoji="❌"
      local text_content="【${title_emoji} Backup Notification】\nProject: ${PROJECT_NAME}\nServer: $(hostname)\nStatus: ${status}\nMessage: ${message}"
      json_payload=$(printf '{"msg_type": "text", "content": {"text": "%s"}}' "${text_content}")
      ;;
    "telegram")
      if [ -z "${TELEGRAM_CHAT_ID}" ] || [[ "${TELEGRAM_CHAT_ID}" == *"<"* ]]; then
        log_message "WARNING: Telegram provider is active, but TELEGRAM_CHAT_ID is not configured. Skipping."
        return 1
      fi
      local title_emoji="✅"
      [[ "${status}" == "FAILURE" ]] && title_emoji="❌"
      local text_content="*${title_emoji} Backup Notification* (${PROJECT_NAME})\n\n*Host:* \`$(hostname)\`\n*Status:* *${status}*\n*Message:* ${message}"
      # For Telegram, we send data as URL parameters, not a JSON body for this simple method.
      # The payload here is just for logging/consistency.
      final_url=$(printf '%s?chat_id=%s&text=%s&parse_mode=Markdown' "${WEBHOOK_URL}" "${TELEGRAM_CHAT_ID}" "$(curl -s -o /dev/null -w %{url_effective} --get --data-urlencode "text=${text_content}" "")")
      final_url="${final_url//'text='/}" # Remove the dummy text= part from the encoded string
      json_payload="" # We don't send a JSON body
      http_headers=() # No special headers needed
      ;;
    "generic"|*)
      json_payload=$(printf '{"project": "%s", "server": "%s", "status": "%s", "message": "%s"}' \
        "${PROJECT_NAME}" "$(hostname)" "${status}" "${message}")
      ;;
  esac

  log_message "Sending ${status} notification..."
  # The actual sending logic
  if [ -n "${json_payload}" ]; then
      # For JSON-based providers
      curl --connect-timeout 10 --max-time 20 -X POST "${http_headers[@]}" -d "${json_payload}" "${final_url}" -sS || log_message "WARNING: Failed to send notification."
  elif [[ "${provider_lower}" == "telegram" ]]; then
       # For Telegram GET request
      curl --connect-timeout 10 --max-time 20 -s -X GET "${final_url}" -sS >/dev/null || log_message "WARNING: Failed to send Telegram notification."
  fi
}


# ... (script_final_exit, check_dependencies, cleanup_old_backups_on_remote, main and other functions remain UNCHANGED) ...
# --- They will work correctly with the new send_notification function.
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
check_dependencies() { log_message "Checking for required dependencies: ${REQUIRED_DEPS[*]}..."; for dep in "${REQUIRED_DEPS[@]}"; do command -v "${dep}" &>/dev/null || handle_failure "Dependency '${dep}' is not installed."; done; log_message "All required dependencies are installed."; }
cleanup_old_backups_on_remote() { log_message "Starting cleanup of old backups on remote: ${RCLONE_TARGET}"; local backup_pattern="${PROJECT_NAME,,}_data_*.zip"; log_message "Searching for remote files with pattern: '${backup_pattern}'..."; local files_to_delete; files_to_delete=$(rclone lsf --include "${backup_pattern}" "${RCLONE_TARGET}" | sort -r | tail -n +$((BACKUP_RETENTION_COUNT + 1))); if [ -z "${files_to_delete}" ]; then log_message "No old backups to delete. The number of backups is within the retention limit (${BACKUP_RETENTION_COUNT})."; return 0; fi; log_message "The following old backups will be deleted:"; echo "${files_to_delete}" | while IFS= read -r file; do log_message "  - Preparing to delete: ${file}"; rclone deletefile "${RCLONE_TARGET}/${file}" || log_message "    -> WARNING: Failed to delete remote file: ${file}"; done; log_message "Remote cleanup process finished."; }
main() { trap script_final_exit EXIT; exec >> "${LOG_FILE}" 2>&1; log_message "========================================================================================="; log_message ">> ${PROJECT_NAME} Backup Script Started"; log_message ">> Start Time: ${SCRIPT_START_TIME_FORMATTED}"; log_message ""; log_message "--- Step 1: Environment Checks ---"; check_dependencies; if [ ! -d "${TEMP_BACKUP_DIR}" ];then log_message "Local backup directory '${TEMP_BACKUP_DIR}' not found. Creating...";mkdir -p "${TEMP_BACKUP_DIR}"||handle_failure "Could not create temp directory ${TEMP_BACKUP_DIR}.";fi; if [[ "${NOTIFICATION_MODE}" != "none" ]] && { [ -z "${WEBHOOK_URL}" ] || [[ "${WEBHOOK_URL}" == *"your.webhook.provider.com"* ]]; }; then log_message "WARNING: Notifications are enabled, but WEBHOOK_URL is not configured. No notifications will be sent."; fi; if [ -z "${ENCRYPTION_PASSWORD}" ];then handle_failure "Environment variable 'ENCRYPTION_PASSWORD' is not set.";fi; log_message "Environment checks passed."; log_message "--- Step 2: Packing and Encryption ---"; log_message "Source: '${SOURCE_DIR}', Target: '${CURRENT_ZIP_FILE}'"; zip -r -e -P "${ENCRYPTION_PASSWORD}" -q "${CURRENT_ZIP_FILE}" "${SOURCE_DIR}"||handle_failure "Failed to pack or encrypt the source directory."; unset ENCRYPTION_PASSWORD; log_message "Packing and encryption completed successfully."; log_message "--- Step 3: Uploading to Cloud Storage ---"; log_message "Uploading to Rclone remote: '${RCLONE_TARGET}'"; rclone copy "${CURRENT_ZIP_FILE}" "${RCLONE_TARGET}" --checksum --transfers=4 --buffer-size 16M --verbose||handle_failure "Failed to upload to Rclone remote."; log_message "File upload completed successfully."; log_message "--- Step 4: Local Cleanup ---"; if [ "${KEEP_LOCAL_BACKUP}" != "true" ];then log_message "Cleaning up local backup file: '${CURRENT_ZIP_FILE}'";rm -f "${CURRENT_ZIP_FILE}"||log_message "WARNING: Failed to remove local backup file.";else log_message "Keeping local backup file as configured.";fi; log_message "--- Step 5: Remote Cleanup ---"; cleanup_old_backups_on_remote; log_message "--- All tasks completed successfully ---"; }

# --- Script Execution Entry Point ---
main "$@"
