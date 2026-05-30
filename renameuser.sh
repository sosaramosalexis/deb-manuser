#!/usr/bin/env bash
set -euo pipefail

SCRIPT_REPO="sosramalex/deb-renameuser"
BTITLE="Debian Username Changer"

cleanup() {
    rm -f /tmp/renameuser_*.txt 2>/dev/null || true
}
trap cleanup EXIT

die() {
    whiptail --title "Error" --msgbox "$1" 8 50
    exit 1
}

ok() {
    whiptail --title "Info" --msgbox "$1" 8 50
}

# --- Must be root ---
[[ $EUID -ne 0 ]] && die "This script must be run as root (sudo)."
command -v whiptail &>/dev/null || { echo "whiptail required: apt install whiptail"; exit 1; }

# --- Welcome ---
whiptail --title "$BTITLE" --msgbox "\
This tool will rename a user account on your Debian system.

What it does:
  • Changes the login name
  • Renames the matching group
  • Moves the home directory
  • Updates file ownerships
  • Preserves UID/GID so permissions stay intact" 14 56 || exit 1

# --- Build user list (UID >= 1000, non-system) ---
USER_ENTRIES=()
USER_NAMES=()
while IFS=: read -r name _ uid _ _ _ _; do
    if [[ $uid -ge 1000 ]]; then
        USER_NAMES+=("$name")
    fi
done < /etc/passwd

if [[ ${#USER_NAMES[@]} -gt 0 ]]; then
    for u in "${USER_NAMES[@]}"; do
        desc="$(id -u "$u") | $(getent passwd "$u" | cut -d: -f5 | head -c 40)"
        [[ -z "$desc" ]] && desc="UID $(id -u "$u")"
        USER_ENTRIES+=("$u" "$desc")
    done
fi
USER_ENTRIES+=("__OTHER__" "Type a username manually")

# --- Get current username ---
CURRENT=""
while true; do
    choice=$(whiptail --title "$BTITLE" --menu "\
Select the user to rename, or choose 'Type manually':" 20 60 10 \
        "${USER_ENTRIES[@]}" 3>&1 1>&2 2>&3) || exit 1

    if [[ "$choice" == "__OTHER__" ]]; then
        CURRENT=$(whiptail --title "$BTITLE" --inputbox "\
Enter the CURRENT username to rename:" 8 56 "" 3>&1 1>&2 2>&3) || exit 1
    else
        CURRENT="$choice"
    fi

    [[ -z "$CURRENT" ]] && { ok "Username cannot be empty."; continue; }
    if ! id "$CURRENT" &>/dev/null; then
        ok "User '$CURRENT' does not exist."
        continue
    fi
    if [[ $(id -u "$CURRENT") -lt 1000 ]]; then
        whiptail --title "Warning" --yesno "\
$CURRENT is a system user (UID < 1000).

Renaming system users can break services.
Proceed anyway?" 10 56 || continue
    fi
    break
done

# --- Check for active sessions ---
SESSION_COUNT=$(who -u 2>/dev/null | awk -v u="$CURRENT" '$1==u' | wc -l)
if [[ $SESSION_COUNT -gt 0 ]]; then
    whiptail --title "Active Sessions" --yesno "\
⚠️  User '$CURRENT' has $SESSION_COUNT active session(s).

$(who -u 2>/dev/null | awk -v u="$CURRENT" '$1==u')

Renaming a logged-in user can fail or leave processes orphaned.
It is strongly recommended to log out all sessions first.

Proceed anyway?" 14 60 || exit 1
fi

# --- Check running processes ---
PROC_COUNT=$(pgrep -u "$CURRENT" 2>/dev/null | wc -l)
if [[ $PROC_COUNT -gt 0 ]]; then
    whiptail --title "Running Processes" --yesno "\
⚠️  User '$CURRENT' has $PROC_COUNT process(es) running.

These may become orphaned or misowned after the rename.
Consider stopping them first (e.g. killall -u $CURRENT).

Proceed anyway?" 12 60 || exit 1
fi

# --- Get new username ---
NEW=""
while true; do
    NEW=$(whiptail --title "$BTITLE" --inputbox "\
Enter the NEW username for '$CURRENT':" 8 56 "" 3>&1 1>&2 2>&3) || exit 1
    [[ -z "$NEW" ]] && { ok "Username cannot be empty."; continue; }
    echo "$NEW" | grep -qE '^[a-z_][a-z0-9_-]*$' || {
        ok "Username must start with a letter or underscore\nand contain only letters, digits, - and _."
        continue
    }
    id "$NEW" &>/dev/null && { ok "User '$NEW' already exists."; continue; }
    [[ "$CURRENT" == "$NEW" ]] && { ok "New username is identical to current one."; continue; }
    break
done

# --- Gather info ---
CURRENT_UID=$(id -u "$CURRENT")
CURRENT_GID=$(id -g "$CURRENT")
CURRENT_HOME=$(eval echo "~$CURRENT")
CURRENT_GROUPS=$(id -nG "$CURRENT")

# --- Extra options ---
OPTIONS=$(whiptail --title "$BTITLE" --checklist "\
Extra options for '$CURRENT' → '$NEW':" 12 60 3 \
    "MOVE_HOME" "Move /home/$CURRENT → /home/$NEW" ON \
    "RENAME_GROUP" "Rename group '$CURRENT' → '$NEW'" ON \
    "UPDATE_MAIL" "Update mail spool if present" ON \
    3>&1 1>&2 2>&3) || exit 1

MOVE_HOME=false; RENAME_GROUP=false; UPDATE_MAIL=false
[[ "$OPTIONS" == *"MOVE_HOME"* ]] && MOVE_HOME=true
[[ "$OPTIONS" == *"RENAME_GROUP"* ]] && RENAME_GROUP=true
[[ "$OPTIONS" == *"UPDATE_MAIL"* ]] && UPDATE_MAIL=true

# --- Summary ---
{
    echo "Current user:  $CURRENT (UID $CURRENT_UID)"
    echo "New username:  $NEW"
    echo "Home:          $CURRENT_HOME"
    echo "Primary GID:  $CURRENT_GID"
    echo "Groups:        $CURRENT_GROUPS"
    echo ""
    echo "Actions:"
    echo "  • usermod -l $NEW $CURRENT  (rename login)"
    $RENAME_GROUP && echo "  • groupmod -n $NEW $CURRENT  (rename group)"
    $MOVE_HOME && echo "  • usermod -d /home/$NEW -m $NEW  (move home)"
    echo "  • chown -R $NEW:$NEW /home/$NEW  (fix ownership)"
    $UPDATE_MAIL && echo "  • mv /var/mail/$CURRENT /var/mail/$NEW  (mail spool)"
    echo "  • Update supplementary groups"
} > /tmp/renameuser_confirm.txt

whiptail --title "Confirm Changes" --textbox /tmp/renameuser_confirm.txt 18 60 \
    --ok-button "Continue" --cancel-button "Cancel" || exit 1

whiptail --title "Confirm" --yesno "\
⚠️  This will rename '$CURRENT' to '$NEW'.

The user must log out for the change to fully take effect.
After reboot, log in as '$NEW'.

Are you SURE you want to proceed?" 10 60 || exit 1

# --- Execute ---
(
    echo "10"; echo "XXX\nStep 1/5: Changing login name...\nXXX"
    if ! usermod -l "$NEW" "$CURRENT"; then
        echo "XXX\nERROR: usermod failed.\nCheck if user has active processes.\nXXX"
        sleep 3; exit 1
    fi

    echo "30"; echo "XXX\nStep 2/5: Renaming primary group...\nXXX"
    if $RENAME_GROUP && getent group "$CURRENT" &>/dev/null; then
        groupmod -n "$NEW" "$CURRENT" || true
    fi

    echo "45"; echo "XXX\nStep 3/5: Moving home directory...\nXXX"
    if $MOVE_HOME; then
        if [[ -d "/home/$CURRENT" ]]; then
            usermod -d "/home/$NEW" -m "$NEW" || {
                echo "XXX\nWARNING: Home dir move failed, trying manual...\nXXX"
                sleep 1
                mv "/home/$CURRENT" "/home/$NEW" 2>/dev/null || true
                usermod -d "/home/$NEW" "$NEW" 2>/dev/null || true
            }
        else
            usermod -d "/home/$NEW" "$NEW" 2>/dev/null || true
        fi
    fi

    echo "65"; echo "XXX\nStep 4/5: Fixing file ownership...\nXXX"
    if [[ -d "/home/$NEW" ]]; then
        chown -R "$NEW":"$NEW" "/home/$NEW" 2>/dev/null || true
    fi
    if $UPDATE_MAIL && [[ -f "/var/mail/$CURRENT" ]]; then
        mv "/var/mail/$CURRENT" "/var/mail/$NEW" 2>/dev/null || true
        chown "$NEW:mail" "/var/mail/$NEW" 2>/dev/null || true
    fi

    echo "85"; echo "XXX\nStep 5/5: Updating supplementary groups...\nXXX"
    for grp in $CURRENT_GROUPS; do
        if [[ "$grp" != "$CURRENT" ]] && [[ "$grp" != "$NEW" ]]; then
            gpasswd -a "$NEW" "$grp" &>/dev/null || true
        fi
    done

    echo "100"; echo "XXX\nDone! All steps completed.\nXXX"
    sleep 1
) | whiptail --title "$BTITLE" --gauge "\
Renaming $CURRENT → $NEW ..." 8 56 0

EXITCODE=${PIPESTATUS[0]}
if [[ $EXITCODE -ne 0 ]]; then
    die "Rename failed. Check errors above.\nYou may need to revert manually."
fi

# --- Final report ---
NEW_HOME=$(eval echo "~$NEW" 2>/dev/null || echo "/home/$NEW")
VERIFY=$(id "$NEW" 2>&1)
{
    echo "✅ Rename complete!"
    echo ""
    echo "Old login:  $CURRENT"
    echo "New login:  $NEW"
    echo "UID:        $CURRENT_UID (unchanged)"
    echo "Home:       $NEW_HOME"
    echo "Primary GID: $(id -g "$NEW" 2>/dev/null || echo '?')"
    echo ""
    echo "Verification:"
    echo "$VERIFY"
    echo ""
    echo "📋 Post-rename checklist:"
    echo "  • Log out completely, then log in as '$NEW'"
    echo "  • Update SSH authorized_keys if needed:"
    echo "    chown -R $NEW:$NEW ~$NEW/.ssh"
    echo "  • Fix cron/at jobs belonging to old user:"
    echo "    crontab -u $NEW -l"
    echo "  • Check for orphaned processes:"
    echo "    ps -u $CURRENT_UID"
    echo "  • Update any scripts/services that hardcode '$CURRENT'"
} > /tmp/renameuser_final.txt

whiptail --title "Success" --textbox /tmp/renameuser_final.txt 22 66 --ok-button "Done"

whiptail --title "$BTITLE" --yesno "\
This script is available on GitHub:

  https://github.com/$SCRIPT_REPO

Star it if you found it useful!" 10 56 || true
