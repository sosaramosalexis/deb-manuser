#!/usr/bin/env bash
set -euo pipefail

BTITLE="Debian User Manager"
SCRIPT_REPO="sosramalex/deb-renameuser"

cleanup() { rm -f /tmp/usermgr_*.txt 2>/dev/null || true; }
trap cleanup EXIT

die()     { whiptail --title "Error"   --msgbox "$1" 8 50; exit 1; }
info()    { whiptail --title "Info"    --msgbox "$1" 8 50; }
confirm() { whiptail --title "Confirm" --yesno "$1" 10 60; }

must_root()   { [[ $EUID -eq 0 ]] || die "This must be run as root (sudo)."; }
need_whiptail() { command -v whiptail &>/dev/null || { echo "whiptail required: apt install whiptail"; exit 1; }; }

pick_user() {
    local prompt="$1" title="${2:-Select User}"
    local entries=()
    while IFS=: read -r name _ uid _ _ home shell; do
        [[ $uid -ge 1000 && "$name" != "nobody" ]] || continue
        local desc="UID $uid | $home | $shell"
        entries+=("$name" "$desc")
    done < /etc/passwd
    entries+=("__OTHER__" "Type a username manually")

    while true; do
        local choice
        choice=$(whiptail --title "$title" --menu "$prompt" 20 70 10 \
            "${entries[@]}" 3>&1 1>&2 2>&3) || return 1
        if [[ "$choice" == "__OTHER__" ]]; then
            choice=$(whiptail --title "$title" --inputbox "Enter username:" 8 56 "" 3>&1 1>&2 2>&3) || continue
        fi
        [[ -z "$choice" ]] && { info "Username cannot be empty."; continue; }
        echo "$choice"
        return 0
    done
}

valid_user() {
    local name="$1"
    echo "$name" | grep -qE '^[a-z_][a-z0-9_-]*$'
}

user_exists() { id "$1" &>/dev/null; }

require_user() {
    local name="$1"
    user_exists "$name" || die "User '$name' does not exist."
}

require_no_user() {
    local name="$1"
    user_exists "$name" && die "User '$name' already exists."
}

# ===== CREATE USER =====
cmd_create() {
    must_root
    local username="" fullname="" shell="/bin/bash" groups=""
    local create_home=true

    while true; do
        username=$(whiptail --title "$BTITLE — Create User" \
            --inputbox "Enter new username:" 8 56 "" 3>&1 1>&2 2>&3) || return
        [[ -z "$username" ]] && { info "Username cannot be empty."; continue; }
        valid_user "$username" || { info "Invalid username. Use [a-z_][a-z0-9_-]*"; continue; }
        require_no_user "$username"
        break
    done

    fullname=$(whiptail --title "$BTITLE — Create User" \
        --inputbox "Full name (optional):" 8 56 "" 3>&1 1>&2 2>&3) || fullname=""

    local shells=()
    while IFS= read -r s; do
        [[ -x "$s" ]] && shells+=("$s" "")
    done < /etc/shells 2>/dev/null
    [[ ${#shells[@]} -eq 0 ]] && shells=("/bin/bash" "" "/bin/sh" "")
    shell=$(whiptail --title "Shell" --menu "Select shell:" 16 50 6 \
        "${shells[@]}" 3>&1 1>&2 2>&3) || shell="/bin/bash"

    whiptail --title "Home Directory" --yesno "Create home directory (/home/$username)?" 7 50 && create_home=true || create_home=false

    local groups_input=""
    groups_input=$(whiptail --title "Groups" \
        --inputbox "Additional groups (comma-separated, e.g. sudo,docker):" 8 60 "" 3>&1 1>&2 2>&3) || groups_input=""

    local pass=""
    while true; do
        pass=$(whiptail --title "Password" --passwordbox "Set password:" 8 50 "" 3>&1 1>&2 2>&3) || return
        [[ ${#pass} -ge 1 ]] && break
        info "Password cannot be empty."
    done

    local flags=()
    $create_home && flags+=("-m") || flags+=("-M")
    [[ -n "$fullname" ]] && flags+=(-c "$fullname")
    flags+=(-s "$shell")
    [[ -n "$groups_input" ]] && flags+=(-G "$(echo "$groups_input" | tr -d ' ')")

    if whiptail --title "Confirm" --yesno "Create user '$username'?\nShell: $shell\nGroups: ${groups_input:-none}\nHome: $([ "$create_home" ] && echo '/home/'$username || echo 'no')" 12 60; then
        useradd "${flags[@]}" "$username" || die "Failed to create user."
        echo "$username:$pass" | chpasswd || die "Failed to set password."
        info "User '$username' created successfully."
    fi
}

# ===== DELETE USER =====
cmd_delete() {
    must_root
    local username
    username=$(pick_user "Select user to DELETE:" "Delete User") || return
    require_user "$username"

    local uid=$(id -u "$username")
    local home=$(eval echo "~$username")
    local proc=$(pgrep -u "$username" 2>/dev/null | wc -l)

    local warn=""
    [[ $proc -gt 0 ]] && warn+="\n⚠️  $proc process(es) still running."
    [[ -d "$home" && "$home" != "/" ]] && warn+="\n⚠️  Home dir exists: $home"

    confirm "Delete user '$username' (UID $uid)?$warn" || return

    local remove_home=false
    whiptail --title "Delete" --yesno "Also remove home directory (/home/$username)?" 7 50 && remove_home=true

    confirm "FINAL WARNING: This cannot be undone.\nDelete '$username'?" || return

    local flags=()
    $remove_home && flags+=("-r")
    userdel "${flags[@]}" "$username" || die "Failed to delete user."
    [[ -d "/var/mail/$username" ]] && rm -f "/var/mail/$username" 2>/dev/null || true

    info "User '$username' deleted."
}

# ===== RENAME USER =====
cmd_rename() {
    must_root
    local CURRENT
    CURRENT=$(pick_user "Select user to rename:" "Rename User") || return
    require_user "$CURRENT"

    local session=$(who -u 2>/dev/null | awk -v u="$CURRENT" '$1==u' | wc -l)
    [[ $session -gt 0 ]] && info "User '$CURRENT' has $session active session(s).\nThey should log out first."

    local proc=$(pgrep -u "$CURRENT" 2>/dev/null | wc -l)
    [[ $proc -gt 0 ]] && info "⚠️  $proc process(es) still running."

    local NEW=""
    while true; do
        NEW=$(whiptail --title "$BTITLE — Rename" \
            --inputbox "New username for '$CURRENT':" 8 56 "" 3>&1 1>&2 2>&3) || return
        [[ -z "$NEW" ]] && { info "Cannot be empty."; continue; }
        valid_user "$NEW" || { info "Invalid username."; continue; }
        require_no_user "$NEW"
        [[ "$CURRENT" == "$NEW" ]] && { info "Must be different."; continue; }
        break
    done

    local uid=$(id -u "$CURRENT") gid=$(id -g "$CURRENT")
    local home=$(eval echo "~$CURRENT") groups=$(id -nG "$CURRENT")

    local OPTIONS
    OPTIONS=$(whiptail --title "Options" --checklist "Extra options:" 12 60 3 \
        "MOVE_HOME" "Move /home/$CURRENT → /home/$NEW" ON \
        "RENAME_GROUP" "Rename group '$CURRENT' → '$NEW'" ON \
        "UPDATE_MAIL" "Update mail spool" ON \
        3>&1 1>&2 2>&3) || return

    local do_home=false; do_group=false; do_mail=false
    [[ "$OPTIONS" == *"MOVE_HOME"* ]] && do_home=true
    [[ "$OPTIONS" == *"RENAME_GROUP"* ]] && do_group=true
    [[ "$OPTIONS" == *"UPDATE_MAIL"* ]] && do_mail=true

    confirm "Rename '$CURRENT' → '$NEW'?" || return

    # Execute
    usermod -l "$NEW" "$CURRENT" || die "usermod -l failed."
    $do_group && getent group "$CURRENT" &>/dev/null && groupmod -n "$NEW" "$CURRENT" 2>/dev/null || true

    if $do_home; then
        if [[ -d "/home/$CURRENT" ]]; then
            usermod -d "/home/$NEW" -m "$NEW" 2>/dev/null || {
                mv "/home/$CURRENT" "/home/$NEW" 2>/dev/null || true
                usermod -d "/home/$NEW" "$NEW" 2>/dev/null || true
            }
        else
            usermod -d "/home/$NEW" "$NEW" 2>/dev/null || true
        fi
    fi

    [[ -d "/home/$NEW" ]] && chown -R "$NEW":"$NEW" "/home/$NEW" 2>/dev/null || true

    $do_mail && [[ -f "/var/mail/$CURRENT" ]] && {
        mv "/var/mail/$CURRENT" "/var/mail/$NEW" 2>/dev/null || true
        chown "$NEW:mail" "/var/mail/$NEW" 2>/dev/null || true
    }

    for grp in $groups; do
        [[ "$grp" != "$CURRENT" && "$grp" != "$NEW" ]] && gpasswd -a "$NEW" "$grp" &>/dev/null || true
    done

    info "Rename complete.\n\nOld: $CURRENT\nNew: $NEW\nUID: $uid (unchanged)"
}

# ===== SUDO MANAGEMENT =====
cmd_sudo() {
    must_root
    local username
    username=$(pick_user "Select user:" "Sudo Management") || return
    require_user "$username"

    local has_sudo=false
    groups "$username" 2>/dev/null | grep -qw "sudo" && has_sudo=true

    if $has_sudo; then
        if whiptail --title "Sudo" --yesno "User '$username' HAS sudo.\n\nRemove sudo access?" 9 60; then
            gpasswd -d "$username" sudo &>/dev/null || true
            info "Sudo removed from '$username'."
        fi
    else
        if whiptail --title "Sudo" --yesno "User '$username' does NOT have sudo.\n\nGrant sudo access?" 9 60; then
            gpasswd -a "$username" sudo &>/dev/null || true
            info "Sudo granted to '$username'.\n\nUser must log out and back in."
        fi
    fi
}

# ===== PATH PERMISSIONS =====
cmd_perms() {
    must_root
    local target
    local mode=""

    mode=$(whiptail --title "$BTITLE — Permissions" --menu "What to manage?" 12 50 3 \
        "USER" "Fix ownership/permissions for a user's home" \
        "PATH" "Set permissions on a specific path" \
        3>&1 1>&2 2>&3) || return

    if [[ "$mode" == "USER" ]]; then
        local username
        username=$(pick_user "Select user:" "User Permissions") || return
        require_user "$username"
        target=$(eval echo "~$username")
        [[ ! -d "$target" ]] && die "Home dir '$target' does not exist."

        local own=$(whiptail --title "Permissions" --radiolist "Set ownership on $target" 10 60 3 \
            "USER" "chown -R $username:$username" ON \
            "ROOT" "chown -R root:root" OFF \
            "KEEP" "Leave ownership as-is" OFF \
            3>&1 1>&2 2>&3) || return

        local perm=""
        perm=$(whiptail --title "Permissions" --menu "Set directory permissions on $target" 12 60 4 \
            "755" "drwxr-xr-x (default for home)" \
            "750" "drwxr-x--- (restrict group)" \
            "700" "drwx------ (private)" \
            "SKIP" "Leave as-is" \
            3>&1 1>&2 2>&3) || return

        confirm "Apply to $target?" || return

        [[ "$own" == "USER" ]] && chown -R "$username":"$username" "$target"
        [[ "$own" == "ROOT" ]] && chown -R root:root "$target"
        [[ "$perm" != "SKIP" ]] && chmod "$perm" "$target"

        info "Permissions applied to $target."
    else
        target=$(whiptail --title "Path" --inputbox "Enter full path:" 8 60 "" 3>&1 1>&2 2>&3) || return
        [[ ! -e "$target" ]] && die "Path does not exist."

        local username=""
        username=$(pick_user "Set owner (select user):" "Owner") || username=""
        local group=""
        group=$(whiptail --title "Group" --inputbox "Group (or leave blank):" 8 50 "" 3>&1 1>&2 2>&3) || group=""

        local perm=""
        perm=$(whiptail --title "Mode" --menu "Permission mode:" 12 50 4 \
            "755" "drwxr-xr-x" \
            "750" "drwxr-x---" \
            "700" "drwx------" \
            "SKIP" "Leave as-is" \
            3>&1 1>&2 2>&3) || return

        local recursive=false
        whiptail --title "Recursive" --yesno "Apply recursively?" 7 40 && recursive=true

        confirm "Apply to $target?" || return

        [[ -n "$username" && -n "$group" ]] && chown "$username":"$group" "$target"
        [[ -n "$username" && -z "$group" ]] && chown "$username" "$target"
        [[ -z "$username" && -n "$group" ]] && chgrp "$group" "$target"
        [[ "$perm" != "SKIP" ]] && chmod "$perm" "$target"
        $recursive && {
            [[ -n "$username" && -n "$group" ]] && chown -R "$username":"$group" "$target"
            [[ -n "$username" && -z "$group" ]] && chown -R "$username" "$target"
            [[ -z "$username" && -n "$group" ]] && chgrp -R "$group" "$target"
            [[ "$perm" != "SKIP" ]] && find "$target" -type d -exec chmod "$perm" {} +
        }

        info "Permissions applied to $target."
    fi
}

# ===== MAIN =====
need_whiptail
must_root

while true; do
    choice=$(whiptail --title "$BTITLE" --menu "\
Manage users, permissions, and sudo access." 18 60 6 \
        "1" "Create user" \
        "2" "Delete user" \
        "3" "Rename user" \
        "4" "Manage sudo (grant/remove)" \
        "5" "Manage path permissions" \
        "Q" "Quit" \
        3>&1 1>&2 2>&3) || break

    case "$choice" in
        1) cmd_create ;;
        2) cmd_delete ;;
        3) cmd_rename ;;
        4) cmd_sudo ;;
        5) cmd_perms ;;
        Q) break ;;
    esac

    if [[ -t 0 ]]; then
        whiptail --title "Done" --msgbox "Press OK to return to menu." 6 30 2>/dev/null || true
    fi
done

cleanup
