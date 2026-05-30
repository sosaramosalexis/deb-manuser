#!/usr/bin/env bash
set -euo pipefail

SCRIPT_REPO="sosramalex/deb-renameuser"
BTITLE="Debian Username Changer"

cleanup() {
    rm -f /tmp/renameuser_input.txt /tmp/renameuser_confirm.txt 2>/dev/null || true
}
trap cleanup EXIT

die() {
    whiptail --title "Error" --msgbox "$1" 8 50
    exit 1
}

# --- Must be root ---
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo)."
fi

# --- whiptail check ---
if ! command -v whiptail &>/dev/null; then
    echo "whiptail is required. Install it: apt install whiptail"
    exit 1
fi

# --- Welcome ---
whiptail --title "$BTITLE" --msgbox "\
This tool will rename a user account on your Debian system.

What it does:
  • Changes the login name
  • Renames the matching group
  • Moves the home directory
  • Updates file ownerships
  • Preserves UID/GID so permissions stay intact" 14 56 || exit 1

# --- Get current username ---
CURRENT=""
while true; do
    CURRENT=$(whiptail --title "$BTITLE" --inputbox "\
Enter the CURRENT username to rename:" 8 56 "" 3>&1 1>&2 2>&3)
    exitcode=$?
    [[ $exitcode -ne 0 ]] && exit 1
    if [[ -z "$CURRENT" ]]; then
        whiptail --title "Invalid" --msgbox "Username cannot be empty." 6 40
        continue
    fi
    if ! id "$CURRENT" &>/dev/null; then
        whiptail --title "Invalid" --msgbox "User '$CURRENT' does not exist.\nCheck /etc/passwd and try again." 8 50
        continue
    fi
    if id "$CURRENT" &>/dev/null && [[ $(id -u "$CURRENT") -lt 1000 ]]; then
        whiptail --title "Warning" --msgbox "\
$CURRENT is a system user (UID < 1000).

Renaming system users can break services.
Proceed at your own risk." 10 56
    fi
    break
done

# --- Get new username ---
NEW=""
while true; do
    NEW=$(whiptail --title "$BTITLE" --inputbox "\
Enter the NEW username for '$CURRENT':" 8 56 "" 3>&1 1>&2 2>&3)
    exitcode=$?
    [[ $exitcode -ne 0 ]] && exit 1
    if [[ -z "$NEW" ]]; then
        whiptail --title "Invalid" --msgbox "Username cannot be empty." 6 40
        continue
    fi
    if ! echo "$NEW" | grep -qE '^[a-z_][a-z0-9_-]*$'; then
        whiptail --title "Invalid" --msgbox "\
Username must start with a letter or underscore\nand contain only letters, digits, - and _." 9 56
        continue
    fi
    if id "$NEW" &>/dev/null; then
        whiptail --title "Invalid" --msgbox "User '$NEW' already exists.\nChoose a different name." 7 50
        continue
    fi
    if [[ "$CURRENT" == "$NEW" ]]; then
        whiptail --title "Same" --msgbox "New username is identical to current one." 6 44
        continue
    fi
    break
done

# --- Gather info ---
CURRENT_UID=$(id -u "$CURRENT")
CURRENT_GID=$(id -g "$CURRENT")
CURRENT_HOME=$(eval echo "~$CURRENT")
CURRENT_GROUPS=$(id -nG "$CURRENT")
HAS_GROUP=false
if getent group "$CURRENT" &>/dev/null; then
    HAS_GROUP=true
fi

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
    echo "  • usermod -l $NEW $CURRENT"
    $RENAME_GROUP && echo "  • groupmod -n $NEW $CURRENT"
    $MOVE_HOME && echo "  • usermod -d /home/$NEW -m $NEW"
    echo "  • chown -R $NEW:$NEW /home/$NEW"
    $UPDATE_MAIL && echo "  • mv /var/mail/$CURRENT /var/mail/$NEW"
    echo "  • Update supplementary groups"
} > /tmp/renameuser_confirm.txt

whiptail --title "Confirm Changes" --textbox /tmp/renameuser_confirm.txt 18 56 \
    --ok-button "Continue" --cancel-button "Cancel" || exit 1

whiptail --title "Confirm" --yesno "\
⚠️  This will rename '$CURRENT' to '$NEW'.

The user will need to log out and back in.
Are you SURE you want to proceed?" 10 56 || exit 1

# --- Execute ---
(
    echo "10"; echo "XXX\nStep 1/6: Changing login name...\nXXX"
    usermod -l "$NEW" "$CURRENT" 2>/dev/null || {
        echo "XXX\nERROR: Failed to change login name.\nXXX"; sleep 2; exit 1
    }

    echo "25"; echo "XXX\nStep 2/6: Renaming primary group...\nXXX"
    if $RENAME_GROUP && getent group "$CURRENT" &>/dev/null; then
        groupmod -n "$NEW" "$CURRENT" 2>/dev/null || true
    fi

    echo "40"; echo "XXX\nStep 3/6: Moving home directory...\nXXX"
    if $MOVE_HOME; then
        usermod -d "/home/$NEW" -m "$NEW" 2>/dev/null || true
    fi

    echo "60"; echo "XXX\nStep 4/6: Fixing file ownership...\nXXX"
    chown -R "$NEW":"$NEW" "/home/$NEW" 2>/dev/null || true
    chown -R "$NEW":"$NEW" "/home/$NEW/." 2>/dev/null || true

    echo "75"; echo "XXX\nStep 5/6: Updating mail spool...\nXXX"
    if $UPDATE_MAIL && [[ -f "/var/mail/$CURRENT" ]]; then
        mv "/var/mail/$CURRENT" "/var/mail/$NEW" 2>/dev/null || true
        chown "$NEW:mail" "/var/mail/$NEW" 2>/dev/null || true
    fi

    echo "90"; echo "XXX\nStep 6/6: Checking supplementary groups...\nXXX"
    for grp in $CURRENT_GROUPS; do
        if [[ "$grp" != "$CURRENT" ]] && [[ "$grp" != "$NEW" ]]; then
            gpasswd -a "$NEW" "$grp" &>/dev/null || true
        fi
    done

    echo "100"; echo "XXX\nDone! All steps completed.\nXXX"
    sleep 1
) | whiptail --title "$BTITLE" --gauge "\
Renaming $CURRENT → $NEW ..." 8 56 0

# --- Final report ---
NEW_HOME=$(eval echo "~$NEW" 2>/dev/null || echo "/home/$NEW")
{
    echo "✅ Rename complete!"
    echo ""
    echo "Old:  $CURRENT"
    echo "New:  $NEW"
    echo "UID:  $CURRENT_UID (unchanged)"
    echo "Home: $NEW_HOME"
    echo ""
    echo "User info:"
    id "$NEW" 2>/dev/null || echo "(verify manually)"
    echo ""
    echo "⚠️  Reminders:"
    echo "• Log out and back in to use the new name"
    echo "• Update any scripts/services that reference '$CURRENT'"
    echo "• Update SSH keys in /home/$NEW/.ssh/authorized_keys if needed"
    echo "• Check processes still owned by old UID: ps -u $CURRENT"
} > /tmp/renameuser_final.txt

whiptail --title "Success" --textbox /tmp/renameuser_final.txt 20 60 --ok-button "Done"

# --- Ask about pushing to GitHub ---
if whiptail --title "$BTITLE" --yesno "\
This script is also available as a GitHub repo:

  https://github.com/$SCRIPT_REPO

Would you like to open the repo in your browser?" 10 56; then
    echo "Visit: https://github.com/$SCRIPT_REPO"
fi
