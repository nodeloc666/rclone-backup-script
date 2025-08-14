#!/bin/bash
# ==============================================================================
# Generic Data Backup Script
# Version: 8.14 (Remove Curl Progress Meter from Logs)
#
# Description:
#   Re-adds the '-sS' (silent, show errors) flag to curl commands within the
#   send_notification function to prevent curl's progress meter from appearing
#   in the log output, ensuring cleaner and more focused logging of webhook
#   responses.
# ==============================================================================

# ------------------------------------------------------------------------------
# --- Safety Net ---
# ------------------------------------------------------------------------------
set -o pipefail
# set -e # Partially controlled below


# ==============================================================================
# --- User Configuration Section (Modify the values below to fit your needs) ---
# ==============================================================================
### --- 1. Project & Path Configuration ---
readonly PROJECT_NAME="backups"
readonly SOURCE_DIR="/backups/archives" # Source directory to back up
readonly LOG_FILE="/backups/archives/${PROJECT_NAME,,}_backup.log" # Script log file
readonly TEMP_BACKUP_DIR="/backups/archives" # Temporary directory for local backups/archives

### --- 2. Backup Mode & Remote Storage & Retention Policy ---
# Select backup mode: "local_only", "remote_only", "local_and_remote"
readonly BACKUP_MODE="local_only" # <-- CRITICAL NEW SETTING

# Rclone remote target (e.g., "R2:/archive/projectName"). Required for remote modes.
readonly RCLONE_TARGET="R2:/archive/projectName" # Example: changed /backup/ to /archive/

# Number of backups to keep (applies to both local and remote based on mode)
readonly BACKUP_RETENTION_COUNT=3


### --- 3. Notification Configuration ---
# Options: "all", "failure", "success", "none"
readonly NOTIFICATION_MODE="all"

# Select your notification service provider
# Options: "wecom", "dingtalk", "feishu", "telegram", "generic", "none"
readonly NOTIFICATION_PROVIDER="wecom" # Changed to wecom for testing, change as needed.
# Provider-specific URLs and Settings
readonly WEBHOOK_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_WECOM_BOT_KEY" # YOUR_WECOM_BOT_KEY
# Telegram Specific (only used if NOTIFICATION_PROVIDER is "telegram")
readonly TELEGRAM_CHAT_ID="<YOUR_CHAT_ID>"


# ==============================================================================
# --- Global Variables & Constants (Do not modify) ---
# ==============================================================================
# IMPORTANT: Added 'jq' to the list of required dependencies for proper JSON escaping.
readonly REQUIRED_DEPS=("zip" "rclone" "curl" "jq")
readonly SCRIPT_START_TIMESTAMP=$(date +%s)
readonly SCRIPT_START_TIME_FORMATTED=$(date +"%Y-%m-%d %H:%M:%S")
readonly TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
readonly CURRENT_ZIP_FILE="${TEMP_BACKUP_DIR}/${PROJECT_NAME,,}_data_${TIMESTAMP}.zip"
readonly SCRIPT_NAME=$(basename "$0")

# Status tracking for multi-stage operations
SUCCESS_FLAG=0 # 0 for success, 1 for failure
PACK_STATUS_MESSAGE=""
UPLOAD_STATUS_MESSAGE=""
LOCAL_CLEANUP_STATUS_MESSAGE=""
REMOTE_CLEANUP_STATUS_MESSAGE=""
GLOBAL_FAILURE_REASON=""


# ==============================================================================
# --- Core Function Section ---
# ==============================================================================
log_message() { echo "$(date +"%Y-%m-%d %H:%M:%S.%3N") - ${1}"; }
format_duration() { local s=$1; if ((s<0)); then echo "0s"; return; fi; local m=$((s/60)); s=$((s%60)); if ((m>0)); then echo "${m}m ${s}s"; else echo "${s}s"; fi; }

handle_critical_failure() {
  GLOBAL_FAILURE_REASON="$1"
  log_message "CRITICAL ERROR: ${GLOBAL_FAILURE_REASON}"
  SUCCESS_FLAG=1
  exit 1
}

send_notification() {
  local status="$1"
  local message="$2"
  local provider_lower=$(echo "${NOTIFICATION_PROVIDER}" | tr '[:upper:]' '[:lower:]')

  if [[ "${provider_lower}" == "none" ]]; then
    log_message "Notifications are disabled via provider setting."
    return 0
  fi

  if [[ "${provider_lower}" != "telegram" ]] && { [ -z "${WEBHOOK_URL}" ] || [[ "${WEBHOOK_URL}" == *"your."* || "${WEBHOOK_URL}" == *"example.com"* ]]; }; then
    log_message "WARNING: Notification provider '${provider_lower}' is active, but WEBHOOK_URL is not configured optimally or is default. Skipping notification."
    return 1
  fi

  if [[ "${provider_lower}" == "telegram" ]] && { [ -z "${TELEGRAM_CHAT_ID}" ] || [[ "${TELEGRAM_CHAT_ID}" == *"<"* ]]; }; then
    log_message "WARNING: Telegram provider active, but TELEGRAM_CHAT_ID is not configured. Skipping Telegram notification."
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
      json_payload=$(printf '{"msgtype": "markdown", "markdown": {"content": "### %s Backup Notification\n> **Project:** `%s`\n> **Host:** `%s`\n> **Status:** <font color=\\"%s\\">%s</font>\n%s"}}' \
        "${PROJECT_NAME}" "${PROJECT_NAME}" "$(hostname)" "${color}" "${status}" "${message}")
      ;;
    "dingtalk")
      local color="#008000" # Green
      [[ "${status}" == "FAILURE" ]] && color="#ff0000" # Red
      local title="Backup Notification: ${PROJECT_NAME} ${status}"
      json_payload=$(printf '{"msgtype": "markdown", "markdown": {"title": "%s", "text": "### %s\n\n**Host:** $(hostname)\n\n**Status:** <font color=\\"%s\\">%s</font>\n%s"}}' \
        "${title}" "${title}" "${color}" "${status}" "${message}")
      ;;
    "feishu")
      local title_emoji="✅"
      [[ "${status}" == "FAILURE" ]] && title_emoji="❌"
      # Feishu has pure text msg. Remove markdown specific prefixes/suffixes for cleaner plain text.
      # Remove '>', '*' (italic), and '`' (inline code)
      local plain_text_message=$(echo "${message}" | sed 's/^> //g' | sed 's/\*//g' | sed 's/`//g')
      local text_content="【${title_emoji} Backup Notification】\nProject: ${PROJECT_NAME}\nHost: $(hostname)\nStatus: ${status}\nDetails:\n${plain_text_message}"
      json_payload=$(printf '{"msg_type": "text", "content": {"text": "%s"}}' "${text_content}")
      ;;
    "telegram")
      local title_emoji="✅"
      [[ "${status}" == "FAILURE" ]] && title_emoji="❌"
      # Telegram MarkdownV2 requires careful escaping. Remove standard blockquote '>' from our message.
      # Escape all problematic characters for MarkdownV2 that are NOT part of our desired Markdown syntax.
      # These are: _ * [ ] ( ) ~ ` > # + - = | { } . ! \
      # We will re-apply our intended '*' for italic/bold and '`' for inline code.
      local telegram_message_clean="${message}"
      telegram_message_clean=$(echo "${telegram_message_clean}" | sed 's/^> //g') # Remove the common blockquote marker `>`

      local telegram_message_escaped=$(echo "${telegram_message_clean}" | sed -E 's/([_`\[\]()~#+=\-|{}\.!])/\\\1/g')
      # Convert back our custom '*' to Telegram italic ('*') and '`' to inline code (` `)
      telegram_message_escaped=$(echo "${telegram_message_escaped}" | sed 's/\\\*/\*/g') # Convert escaped \* back to *
      telegram_message_escaped=$(echo "${telegram_message_escaped}" | sed 's/\\\`/`/g') # Convert escaped \` back to `
      
      local text_content_formatted="*${title_emoji} Backup Notification* (\`${PROJECT_NAME}\`)\n\n*Host:* \`$(hostname)\`\n*Status:* *${status}*\n\n*Details:*\n${telegram_message_escaped}"
      
      # Use --get and --data-urlencode to correctly produce URL-encoded string.
      # The resulting URL will have 'text=' prefix which we remove.
      final_url=$(printf '%s?chat_id=%s&text=%s&parse_mode=MarkdownV2' \
          "${WEBHOOK_URL}" "${TELEGRAM_CHAT_ID}" "$(curl -s -o /dev/null -w %{url_effective} --get --data-urlencode "text=${text_content_formatted}" "")")
      final_url="${final_url//'text='/}" # remove 'text=' that curl adds for --get --data-urlencode
      json_payload="" # Telegram uses GET, no JSON payload
      http_headers=() # No POST headers needed
      ;;
    "generic"|*)
      # For generic, we strip common markdown for a cleaner plain-text message.
      local plain_text_message=$(echo "${message}" | sed 's/^> //g' | sed 's/\*//g' | sed 's/`//g')
      
      # IMPORTANT: Use jq to properly escape the string for JSON.
      # jq -Rs '.' takes a raw string, slurp it, and output it as a JSON string literal (with quotes).
      # We then remove the outer quotes " caused by jq -Rs '.' because printf already adds them for %s.
      local escaped_json_string=$(echo -n "${plain_text_message}" | jq -Rs '.')
      escaped_json_string="${escaped_json_string:1:-1}" # Remove first and last char (the quotes)

      json_payload=$(printf '{"project": "%s", "server": "%s", "status": "%s", "message": "%s"}' \
        "${PROJECT_NAME}" "$(hostname)" "${status}" "${escaped_json_string}")
      ;;
  esac

  log_message "Sending ${status} notification to ${provider_lower}..."

  local curl_response_output=""
  local curl_exit_status=0

  if [ -n "${json_payload}" ]; then
      # Added -sS (silent, show errors) to suppress progress meter.
      curl_response_output=$(curl --connect-timeout 10 --max-time 20 -sS -X POST "${http_headers[@]}" -d "${json_payload}" "${final_url}" 2>&1)
      curl_exit_status=$?
  elif [[ "${provider_lower}" == "telegram" ]]; then
      # Added -sS (silent, show errors) to suppress progress meter.
      curl_response_output=$(curl --connect-timeout 10 --max-time 20 -sS -X GET "${final_url}" 2>&1)
      curl_exit_status=$?
  else
      log_message "WARNING: Unknown notification payload type or missing payload for '${provider_lower}'. Skipping sending attempt."
      return 1 # Indicate that notification sending logic failed
  fi

  if [ "${curl_exit_status}" -eq 0 ]; then
      log_message "Notification sent. ${provider_lower} response: ${curl_response_output}"
  else
      log_message "ERROR: Failed to send ${provider_lower} notification. Curl exited with code ${curl_exit_status}. Response/Error: ${curl_response_output}"
      return 1 # Indicate that notification sending failed
  fi
}

script_final_exit() {
  local end_timestamp=$(date +%s)
  local duration=$((end_timestamp - SCRIPT_START_TIMESTAMP))
  local formatted_duration=$(format_duration "${duration}")
  
  local overall_status_msg=""
  local final_notification_status="SUCCESS"
  local final_notification_message=""

  log_message ">> --- Backup Process Summary ---"
  log_message "Packing Status: ${PACK_STATUS_MESSAGE:-Not attempted}"
  log_message "Upload Status: ${UPLOAD_STATUS_MESSAGE:-Not attempted}"
  log_message "Local Cleanup Status: ${LOCAL_CLEANUP_STATUS_MESSAGE:-Not attempted}"
  log_message "Remote Cleanup Status: ${REMOTE_CLEANUP_STATUS_MESSAGE:-Not attempted}"

  if [ "${SUCCESS_FLAG}" -eq 0 ]; then
    overall_status_msg=">> Final Status: SUCCESS"
    final_notification_status="SUCCESS"
    
    local short_mode_desc=""
    case "${BACKUP_MODE}" in
      "local_only")
        short_mode_desc="Local only backup"
        ;;
      "remote_only")
        short_mode_desc="Remote only backup"
        ;;
      "local_and_remote"|*)
        short_mode_desc="Local and Remote backup"
        ;;
    esac
    
    read -r -d '' final_notification_message <<-EOF
> ✅ *${short_mode_desc}* for \`${PROJECT_NAME}\` on host \`$(hostname)\` *completed successfully*.
>
> **Processing Details:**
> Packing: *${PACK_STATUS_MESSAGE}*
> Upload: *${UPLOAD_STATUS_MESSAGE}*
> Remote Cleanup: *${REMOTE_CLEANUP_STATUS_MESSAGE}*
> Local Cleanup: *${LOCAL_CLEANUP_STATUS_MESSAGE}*
>
> **Start Time:** ${SCRIPT_START_TIME_FORMATTED}
> **Duration:** ${formatted_duration}
EOF

  else # FAILURE
    overall_status_msg=">> Final Status: FAILURE"
    final_notification_status="FAILURE"

    read -r -d '' final_notification_message <<-EOF
> ❌ *Backup for \`${PROJECT_NAME}\` on host \`$(hostname)\` FAILED*.
$(if [ -n "${GLOBAL_FAILURE_REASON}" ]; then
echo ">"
echo "> **Reason:** ${GLOBAL_FAILURE_REASON}"
fi)
>
> **Detailed Status:**
> Packing: *${PACK_STATUS_MESSAGE}*
> Upload: *${UPLOAD_STATUS_MESSAGE}*
> Local Cleanup: *${LOCAL_CLEANUP_STATUS_MESSAGE}*
> Remote Cleanup: *${REMOTE_CLEANUP_STATUS_MESSAGE}*
>
> **Start Time:** ${SCRIPT_START_TIME_FORMATTED}
> **Duration:** ${formatted_duration}
EOF
  fi

  log_message "${overall_status_msg}"
  log_message ">> Total Execution Time: ${formatted_duration}"
  log_message ">> ${PROJECT_NAME} Backup Script Finished"
  log_message ">> End Time: $(date +"%Y-%m-%d %H:%M:%S")"
  
  if [[ ("${final_notification_status}" == "SUCCESS" && ("${NOTIFICATION_MODE}" == "all" || "${NOTIFICATION_MODE}" == "success")) || \
        ("${final_notification_status}" == "FAILURE" && ("${NOTIFICATION_MODE}" == "all" || "${NOTIFICATION_MODE}" == "failure")) ]]; then
    send_notification "${final_notification_status}" "${final_notification_message}"
  elif [[ "${NOTIFICATION_MODE}" != "none" ]]; then
    log_message "Notification for '${final_notification_status}' status is disabled by current mode ('${NOTIFICATION_MODE}')."
  fi

  echo -e "=========================================================================================\n"

  exit "${SUCCESS_FLAG}"
}

check_dependencies() {
  log_message "Checking for required dependencies: ${REQUIRED_DEPS[*]}..."
  for dep in "${REQUIRED_DEPS[@]}"; do
    command -v "${dep}" &>/dev/null || handle_critical_failure "Dependency '${dep}' is not installed."
  done
  log_message "All required dependencies are installed."
}

cleanup_old_backups_on_remote() {
  log_message "Starting cleanup of old backups on remote: ${RCLONE_TARGET}"
  local backup_pattern="${PROJECT_NAME,,}_data_*.zip"
  local files_to_delete

  if ! files_to_delete=$(rclone lsf --include "${backup_pattern}" "${RCLONE_TARGET}" 2>&1); then
    if [[ "${files_to_delete}" == *"No objects found"* ]]; then
        log_message "No remote backup files found with pattern '${backup_pattern}'. Skipping cleanup."
        REMOTE_CLEANUP_STATUS_MESSAGE="Skipped (No remote files found)"
        return 0
    else
        log_message "ERROR: Failed to list remote files for cleanup. Is Rclone configured correctly or remote available? Error: ${files_to_delete}"
        REMOTE_CLEANUP_STATUS_MESSAGE="Failed to list remote files"
        return 1
    fi
  fi
  
  files_to_delete=$(echo "${files_to_delete}" | sort -r | tail -n +$((BACKUP_RETENTION_COUNT + 1)))

  if [ -z "${files_to_delete}" ]; then
    log_message "No old backups to delete on remote. The number of backups is within the retention limit (${BACKUP_RETENTION_COUNT})."
    REMOTE_CLEANUP_STATUS_MESSAGE="No old files to delete"
    return 0
  fi

  log_message "The following old remote backups will be deleted:"
  local cleanup_has_errors=0
  echo "${files_to_delete}" | while IFS= read -r file; do
    log_message "  - Preparing to delete: ${file}"
    if rclone deletefile "${RCLONE_TARGET}/${file}"; then
      log_message "    -> Deleted: ${file}"
    else
      log_message "    -> WARNING: Failed to delete remote file: ${file}"
      cleanup_has_errors=1
    fi
  done
  if [ "${cleanup_has_errors}" -eq 0 ]; then
    log_message "Remote cleanup process finished successfully."
    REMOTE_CLEANUP_STATUS_MESSAGE="Success"
    return 0
  else
    log_message "Remote cleanup process finished with warnings/errors"
    return 1
  fi
}

cleanup_old_backups_on_local() {
  log_message "Starting cleanup of old local backups in: ${TEMP_BACKUP_DIR}"
  local backup_pattern="${PROJECT_NAME,,}_data_*.zip"
  
  local local_files=()
  while IFS= read -r -d $'\0' file; do
    local_files+=("$(basename "$file")")
  done < <(find "${TEMP_BACKUP_DIR}" -maxdepth 1 -name "${backup_pattern}" -print0 | sort -rz)

  if [ "${#local_files[@]}" -le "${BACKUP_RETENTION_COUNT}" ]; then
    log_message "No old backups to delete locally. The number of local backups is within the retention limit (${BACKUP_RETENTION_COUNT})."
    LOCAL_CLEANUP_STATUS_MESSAGE="No old files to delete"
    return 0
  fi

  local files_to_delete_array=("${local_files[@]:${BACKUP_RETENTION_COUNT}}")

  log_message "The following old local backups will be deleted:"
  local cleanup_has_errors=0
  for file_basename in "${files_to_delete_array[@]}"; do
    local full_path="${TEMP_BACKUP_DIR}/${file_basename}"
    log_message "  - Preparing to delete: ${full_path}"
    if rm -f "${full_path}"; then
      log_message "    -> Deleted: ${full_path}"
    else
      log_message "    -> WARNING: Failed to remove local file: ${full_path}"
      cleanup_has_errors=1
    fi
  done

  if [ "${cleanup_has_errors}" -eq 0 ]; then
    log_message "Local cleanup process finished successfully."
    LOCAL_CLEANUP_STATUS_MESSAGE="Success"
    return 0
  else
    log_message "Local cleanup process finished with warnings/errors"
    return 1
  fi
}

initialize_status_messages_for_mode() {
  case "${BACKUP_MODE}" in
    "local_only")
      UPLOAD_STATUS_MESSAGE="Skipped (Local only mode)"
      REMOTE_CLEANUP_STATUS_MESSAGE="Skipped (Local only mode)"
      ;;
    "remote_only")
      ;;
  esac
}


# ==============================================================================
# --- Main Logic Section ---
# ==============================================================================
main() {
  trap script_final_exit EXIT
  exec >> "${LOG_FILE}" 2>&1

  log_message ">> ${PROJECT_NAME} Backup Script Started (Mode: ${BACKUP_MODE})"
  log_message ">> Start Time: ${SCRIPT_START_TIME_FORMATTED}"
  log_message ""

  log_message "--- Step 1: Environment Checks ---"
  check_dependencies
  if [ ! -d "${TEMP_BACKUP_DIR}" ]; then
    log_message "Local backup directory '${TEMP_BACKUP_DIR}' not found. Creating..."
    mkdir -p "${TEMP_BACKUP_DIR}" || handle_critical_failure "Could not create temp directory ${TEMP_BACKUP_DIR}."
  fi
  if [ -z "${ENCRYPTION_PASSWORD}" ]; then
      handle_critical_failure "Environment variable 'ENCRYPTION_PASSWORD' is not set. Please set it (e.g., export ENCRYPTION_PASSWORD='your_secret_password')."
  fi
  if [[ ("${BACKUP_MODE}" == "remote_only" || "${BACKUP_MODE}" == "local_and_remote") && -z "${RCLONE_TARGET}" ]]; then
      log_message "WARNING: Remote backup mode is enabled, but RCLONE_TARGET is empty. Remote operations will likely fail."
  fi
  log_message "Environment checks passed."

  initialize_status_messages_for_mode

  log_message "--- Step 2: Packing and Encryption ---"
  log_message "Source: '${SOURCE_DIR}', Target: '${CURRENT_ZIP_FILE}'"
  if zip -r -e -P "${ENCRYPTION_PASSWORD}" -q "${CURRENT_ZIP_FILE}" "${SOURCE_DIR}"; then
    PACK_STATUS_MESSAGE="Success"
    log_message "Packing and encryption completed successfully."
  else
    PACK_STATUS_MESSAGE="Failed"
    GLOBAL_FAILURE_REASON="Failed to pack or encrypt the source directory."
    SUCCESS_FLAG=1
    log_message "ERROR: Packing and encryption failed."
    exit 1
  fi
  unset ENCRYPTION_PASSWORD 

  log_message "--- Step 3: Remote Upload (if enabled) ---"
  if [[ ("${BACKUP_MODE}" == "remote_only" || "${BACKUP_MODE}" == "local_and_remote") && "${PACK_STATUS_MESSAGE}" == "Success" && -n "${RCLONE_TARGET}" ]]; then
    log_message "Uploading to Rclone remote: '${RCLONE_TARGET}'"
    if rclone copy "${CURRENT_ZIP_FILE}" "${RCLONE_TARGET}" --checksum --transfers=4 --buffer-size 16M; then
      UPLOAD_STATUS_MESSAGE="Success"
      log_message "File upload completed successfully."
    else
      UPLOAD_STATUS_MESSAGE="Failed"
      [[ -z "${GLOBAL_FAILURE_REASON}" ]] && GLOBAL_FAILURE_REASON="Failed to upload to Rclone remote."
      SUCCESS_FLAG=1
      log_message "ERROR: Failed to upload file to Rclone remote."
    fi
  else
    if [[ "${BACKUP_MODE}" == "remote_only" || "${BACKUP_MODE}" == "local_and_remote" ]]; then
      log_message "Remote upload skipped: PACK_STATUS is '${PACK_STATUS_MESSAGE}', or RCLONE_TARGET is empty. Current UPLOAD_STATUS_MESSAGE: '${UPLOAD_STATUS_MESSAGE}'."
    else
      log_message "Remote upload skipped as per BACKUP_MODE: ${BACKUP_MODE}. Current UPLOAD_STATUS_MESSAGE: '${UPLOAD_STATUS_MESSAGE}'."
    fi
  fi

  log_message "--- Step 4: Local File Management ---"
  if [ -f "${CURRENT_ZIP_FILE}" ]; then
    if [[ "${BACKUP_MODE}" == "local_only" || "${BACKUP_MODE}" == "local_and_remote" ]]; then
      log_message "Managing local backup files according to retention policy (${BACKUP_RETENTION_COUNT})."
      if [ "${PACK_STATUS_MESSAGE}" == "Success" ]; then
        if ! cleanup_old_backups_on_local; then
          SUCCESS_FLAG=1
        fi
      else
        LOCAL_CLEANUP_STATUS_MESSAGE="Skipped (Packing failed)"
        log_message "Local cleanup skipped because packing step failed."
      fi
    elif [[ "${BACKUP_MODE}" == "remote_only" ]]; then
      log_message "Removing current local temporary backup file: '${CURRENT_ZIP_FILE}' (remote_only mode)."
      if rm -f "${CURRENT_ZIP_FILE}"; then
        LOCAL_CLEANUP_STATUS_MESSAGE="Cleaned temporary file"
      else
        LOCAL_CLEANUP_STATUS_MESSAGE="Failed to clean temporary file"
        log_message "WARNING: Failed to remove local temporary backup file: ${CURRENT_ZIP_FILE}."
        SUCCESS_FLAG=1
      fi
    fi
  else
      LOCAL_CLEANUP_STATUS_MESSAGE="Not applicable (no local file generated)"
      log_message "No local backup file (${CURRENT_ZIP_FILE}) generated, skipping local management."
  fi

  log_message "--- Step 5: Remote Cleanup (if enabled) ---"
  if [[ ("${BACKUP_MODE}" == "remote_only" || "${BACKUP_MODE}" == "local_and_remote") && -n "${RCLONE_TARGET}" ]]; then
    if ! cleanup_old_backups_on_remote; then
      SUCCESS_FLAG=1
    fi
  else
      log_message "Remote cleanup skipped as per BACKUP_MODE: ${BACKUP_MODE} or RCLONE_TARGET is empty. Current REMOTE_CLEANUP_STATUS_MESSAGE: '${REMOTE_CLEANUP_STATUS_MESSAGE}'."
  fi

  log_message "--- All mode-specific tasks completed ---"
}

main "$@"
