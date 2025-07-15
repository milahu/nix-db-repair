#!/usr/bin/env bash

set -uo pipefail

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Path to the SQLite cleanup script
CLEANUP_SCRIPT="./nix-db-cleanup.sh"
# Path to the Nix store (without trailing slash!)
NIX_STORE_PATH="/nix/store"

# Check if the database path is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <database_path>"
    exit 1
fi

# Path to the SQLite database, usually "/nix/var/nix/db/db.sqlite"
DB_PATH="$1"
PREV_HASH=""

# Extract HASH from the error message
# Hash format: `nix32Chars`
# https://github.com/NixOS/nix/blob/master/src/libutil/hash.cc#L80
# Charset: 0123456789abcdfghijklmnpqrsvwxyz; omitted: E O U T
extract_hash() {
    local error_msg="$1"
    local HASH=$(echo "$error_msg" | sed -n "s|.*$NIX_STORE_PATH/\([0-9a-fg-np-sv-z]*\)-.*|\1|p")
    echo "$HASH"
}

# Main loop
while true; do
    # Run nix-store --verify --repair and capture stderr while discarding stdout
    error_output=$(nix-store --verify --repair 2>&1 >/dev/null)

    # Check if the error output is empty (meaning no errors occurred)
    if [ -z "$error_output" ]; then
        echo "nix-store --verify --repair completed successfully."
        break
    fi

    found_paths=false
    while read -r line; do
        if [ "${line:0:27}" = 'warning: cannot repair path' ]; then
            # warning: cannot repair path '/nix/store/6d93r9s14q9rx980w4w8zqg88cf6i33w-system-path.drv'
            path=${line#*\'}; path=${path%%\'*}
        elif [ "${line:0:68}" = "error: executing SQLite statement 'delete from ValidPaths where path" ]; then
            # error: executing SQLite statement 'delete from ValidPaths where path = '/nix/store/f2w0m2d36xmpj827qs4q6qs97nmzv205-unit-dbus.service.drv';': constraint failed, FOREIGN KEY constraint failed (in '/nix/var/nix/db/db.sqlite')
            path=${line#*\'*\'}; path=${path%%\'*}
        else
            continue
        fi
        found_paths=true
        echo "$line"
        echo "broken path: ${path@Q}"
        HASH=$(extract_hash "$path")
        if [ -n "$HASH" ]; then
            echo "Found problematic HASH: $HASH"
            # Avoid reprocessing the same hash
            if [ "$HASH" == "$PREV_HASH" ]; then
                echo "Loop detected with hash $HASH. Exiting."
                exit 1
            fi
            # Run the cleanup script
            if [ -x "$CLEANUP_SCRIPT" ]; then
                echo "Running cleanup script for $HASH"
                "$CLEANUP_SCRIPT" "$DB_PATH" "$HASH"
                cleanup_exit_code=$?
                if [ $cleanup_exit_code -ne 0 ]; then
                    echo "Cleanup script failed with exit code $cleanup_exit_code"
                    exit $cleanup_exit_code
                fi
            else
                echo "Error: Cleanup script not found or not executable: $CLEANUP_SCRIPT"
                exit 1
            fi
        else
            echo "Failed to extract HASH from error message"
            exit 1
        fi
    done <<<"$error_output"

    if $found_paths; then break; fi
done

echo "All 'nix-store --verify --repair' operations completed."
