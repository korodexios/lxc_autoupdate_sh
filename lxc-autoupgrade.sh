#!/bin/bash

# ==========================================
# --- CONFIGURATION ---
# ==========================================
ENABLE_SNAPSHOTS="yes"
MAX_SNAPSHOTS=5

# Automatic detection of the script's directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
EXCLUDE_FILE="$SCRIPT_DIR/lxc_exclude.conf"

# Network test settings to verify connectivity
TEST_IP="1.1.1.1"
TEST_PORT="53"

# Log file path
LOG_FILE="$SCRIPT_DIR/lxc_autoupdate.log"

# ANSI Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color (Reset)

# Global arrays for menu handling
declare -a ct_ids
declare -A ct_names
declare -A ct_status
declare -A excluded_map

# ==========================================
# --- INTERACTIVE MENU FUNCTIONS ---
# ==========================================

# Retrieve all containers from Proxmox (handling empty Lock column)
load_all_containers() {
    ct_ids=()
    # NF==4 means the Lock column exists, Name is in $4. Otherwise, Name is in $3.
    while read -r ctid status name; do
        if [ -n "$ctid" ]; then
            ct_ids+=("$ctid")
            ct_names["$ctid"]="$name"
            ct_status["$ctid"]="$status"
        fi
    done < <(pct list | awk 'NR>1 {print $1, $2, (NF==4 ? $4 : $3)}')
}

# Load existing exclusions from config file
load_excludes() {
    excluded_map=()
    if [ -f "$EXCLUDE_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}" # Remove comments
            read -r -a tokens <<< "$line"
            if [ ${#tokens[@]} -gt 0 ]; then
                excluded_map["${tokens[0]}"]=1
            fi
        done < "$EXCLUDE_FILE"
    fi
}

# Save current exclusion map to file
save_excludes() {
    echo "# Automatically generated exclude list" > "$EXCLUDE_FILE"
    echo "# Updated on: $(date)" >> "$EXCLUDE_FILE"
    for ctid in "${!excluded_map[@]}"; do
        echo "$ctid" >> "$EXCLUDE_FILE"
    done
}

# Draw menu in terminal
display_menu() {
    clear
    echo -e "${YELLOW}=========================================================${NC}"
    echo -e "⚙️  LXC CONTAINER UPDATE MANAGER"
    echo -e "${YELLOW}=========================================================${NC}"
    echo "Enter row numbers to toggle status (exclude / include)."
    echo "Multiple entries are allowed (e.g., 1,2,3,4 or 1 2 3):"
    echo ""

    local index=1
    for ctid in "${ct_ids[@]}"; do
        local marker="${GREEN}[   UPDATE   ]${NC}"
        if [ "${excluded_map[$ctid]}" == "1" ]; then
            marker="${RED}[  EXCLUDED  ]${NC}"
        fi
        
        # Aligned formatting for clean CLI output
        printf " %2d) ID: %-8s %-22s (%-8s) %b\n" \
            "$index" "$ctid" "${ct_names[$ctid]}" "${ct_status[$ctid]}" "$marker"
        
        index=$((index + 1))
    done

    echo ""
    echo -e "${YELLOW}=========================================================${NC}"
    echo " 👉 Enter row number(s) (e.g., 1,2,5) to toggle status."
    echo " 👉 Enter 's' to SAVE and RUN the updates."
    echo " 👉 Enter 'q' to QUIT without saving."
    echo -e "${YELLOW}=========================================================${NC}"
}

# Main menu loop
interactive_menu() {
    load_all_containers
    load_excludes

    if [ ${#ct_ids[@]} -eq 0 ]; then
        echo "❌ No LXC containers found on this system."
        exit 1
    fi

    while true; do
        display_menu
        read -p "Your choice: " choice
        
        # Convert commas to spaces to process both "1,2,3" and "1 2 3" formats
        local clean_choice=$(echo "$choice" | tr ',' ' ')
        local processed_any=false

        for token in $clean_choice; do
            # Validate if token is a number within available menu range
            if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#ct_ids[@]}" ]; then
                local selected_ctid="${ct_ids[$((token - 1))]}"
                
                # Toggle exclude status
                if [ "${excluded_map[$selected_ctid]}" == "1" ]; then
                    unset "excluded_map[$selected_ctid]"
                else
                    excluded_map["$selected_ctid"]=1
                fi
                processed_any=true
            fi
        done

        # Handle save or quit commands
        if [[ "$choice" == "s" || "$choice" == "S" ]]; then
            save_excludes
            echo "💾 Exclusions successfully saved to lxc_exclude.conf."
            echo ""
            break
        elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            echo "🛑 Script terminated without changes."
            exit 0
        fi

        # If no valid option was entered
        if [ "$processed_any" = false ]; then
            read -p "⚠️ Invalid choice. Press [Enter] to try again..." temp
        fi
    done
}

# ==========================================
# --- LXC ACTIONS ---
# ==========================================

log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

wait_for_network() {
    local CTID="$1"
    local MAX_RETRIES=12
    local WAIT_TIME=2
    
    echo "⏳ Verifying network connection for $CTID..."
    for ((i=1; i<=MAX_RETRIES; i++)); do
        if pct exec "$CTID" -- bash -c "timeout 1 bash -c '</dev/tcp/$TEST_IP/$TEST_PORT' 2>/dev/null"; then
            echo "🌐 Network connectivity confirmed."
            return 0
        fi
        sleep "$WAIT_TIME"
    done
    
    echo "⚠️ Warning: Network in $CTID is not fully ready."
    return 1
}

rotate_snapshots() {
    local CTID="$1"
    
    if [ "$ENABLE_SNAPSHOTS" != "yes" ]; then
        return 0
    fi

    local PREFIX="autoupdate"
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local NEW_SNAP="${PREFIX}_${TIMESTAMP}"
    
    echo "🔍 Attempting snapshot for LXC $CTID..."
    
    if pct snapshot "$CTID" "$NEW_SNAP" --description "Auto-backup $TIMESTAMP" >/dev/null 2>&1; then
        echo "✅ Snapshot $NEW_SNAP created."
        
        local SNAPS=$(pct listsnapshot "$CTID" | grep "$PREFIX" | awk '{print $1}')
        local COUNT=$(echo "$SNAPS" | wc -l)

        if [ "$COUNT" -gt "$MAX_SNAPSHOTS" ]; then
            local TO_DELETE_COUNT=$((COUNT - MAX_SNAPSHOTS))
            local TO_DELETE=$(echo "$SNAPS" | head -n "$TO_DELETE_COUNT")
            for OLD_SNAP in $TO_DELETE; do
                echo "🗑️ Deleting old snapshot: $OLD_SNAP"
                pct delsnapshot "$CTID" "$OLD_SNAP" >/dev/null 2>&1
            done
        fi
    else
        echo "⚠️ Storage for LXC $CTID does not support snapshots. Proceeding without snapshots."
    fi
}

wait_for_shutdown() {
    local CTID="$1"
    local MAX_WAIT=30
    
    echo "🔌 Shutting down container $CTID..."
    pct shutdown "$CTID" >/dev/null 2>&1
    
    for ((i=1; i<=MAX_WAIT; i++)); do
        if [ "$(pct status "$CTID" | awk '{print $2}')" == "stopped" ]; then
            echo "✅ Container $CTID is safely stopped."
            return 0
        fi
        sleep 1
    done
    
    echo "⚠️ Container $CTID did not shut down in time, forcing stop..."
    pct stop "$CTID" >/dev/null 2>&1
}

# ==========================================
# --- MAIN PROGRAM EXECUTION ---
# ==========================================

# Start interactive user menu
interactive_menu

# Reload final exclusions
load_excludes

echo "=======================================" | tee -a "$LOG_FILE"
log_action "Starting manual LXC update process."

CTIDS=$(pct list | awk 'NR>1 {print $1}')

for CTID in $CTIDS; do
    echo "---------------------------------------"
    
    # Skip if marked excluded
    if [ "${excluded_map[$CTID]}" == "1" ]; then
        echo -e "⏭️  Skipping LXC $CTID (${RED}excluded by user${NC})."
        log_action "Skipped LXC $CTID (on exclude list)."
        continue
    fi

    STATUS=$(pct status "$CTID" | awk '{print $2}')
    OS_TYPE=$(pct config "$CTID" | grep "^ostype" | awk '{print $2}')

    # Process Debian/Ubuntu based containers
    if [[ "$OS_TYPE" == "debian" || "$OS_TYPE" == "ubuntu" ]]; then
        echo "🔄 Processing LXC $CTID ($STATUS)..."
        log_action "Processing LXC $CTID ($STATUS)"

        WAS_STOPPED=false

        if [ "$STATUS" == "stopped" ]; then
            echo "🚀 Starting container $CTID..."
            if ! pct start "$CTID" >/dev/null 2>&1; then
                echo "❌ Failed to start $CTID. Skipping."
                log_action "Error: Failed to start LXC $CTID."
                continue
            fi
            WAS_STOPPED=true
        fi

        # Network validation
        if ! wait_for_network "$CTID"; then
            echo "❌ Skipping update for $CTID (network unavailable)."
            log_action "Error: Network unavailable for LXC $CTID."
            [ "$WAS_STOPPED" == true ] && wait_for_shutdown "$CTID"
            continue
        fi

        # Snapshot logic
        rotate_snapshots "$CTID"

        echo "📦 Updating LXC $CTID (output redirected to log file)..."
        
        # Run upgrade inside container
        pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; \
            apt-get update -y && \
            apt-get dist-upgrade -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" && \
            apt-get autoremove -y && \
            apt-get clean" >> "$LOG_FILE" 2>&1

        if [ $? -eq 0 ]; then
            echo "✅ LXC $CTID update completed successfully."
            log_action "LXC $CTID - Update SUCCESSFUL."
        else
            echo "❌ LXC $CTID encountered an error during update. Check lxc_autoupdate.log"
            log_action "LXC $CTID - Update FAILED."
        fi

        # Restore original state (shutdown if it was stopped)
        if [ "$WAS_STOPPED" == true ]; then
            wait_for_shutdown "$CTID"
        fi
        
    else
        echo "⏭️  LXC $CTID skipped (unsupported OS: $OS_TYPE)."
    fi
done

echo "---------------------------------------"
echo -e "🎉 ${GREEN}All selected LXC containers have been processed.${NC}"
log_action "Update process finished."
