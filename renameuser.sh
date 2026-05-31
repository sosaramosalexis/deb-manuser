#!/usr/bin/env bash
# shellcheck disable=SC2312
BTITLE="Debian User Manager"
SCRIPT_REPO="sosramalex/deb-manuser"
LOG="/tmp/usermgr_debug.log"

cleanup() { rm -f /tmp/usermgr_*.txt 2>/dev/null || true; }
trap cleanup EXIT

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

die()     { log "DIE: $1"; whiptail --title "Error" --msgbox "$1" 8 50; exit 1; }
info()    { whiptail --title "Info" --msgbox "$1" 8 50; }
confirm() { whiptail --title "Confirm" --yesno "$1" 10 60; }

must_root()   { [[ $EUID -eq 0 ]] || die "This must be run as root (sudo)."; }
need_whiptail() { command -v whiptail &>/dev/null || { echo "whiptail required: apt install whiptail"; exit 1; }; }

# ─── Helpers ────────────────────────────────────────────
pick_user() {
    local prompt="$1" title="${2:-Select User}"
    local entries=() names=()
    while IFS=: read -r name _ uid _ gecos home shell; do
        [[ $uid -ge 1000 && "$name" != "nobody" ]] || continue
        names+=("$name")
    done < /etc/passwd

    for u in "${names[@]}"; do
        local uid=$(id -u "$u" 2>/dev/null || echo "?")
        local home=$(eval echo "~$u" 2>/dev/null || echo "?")
        entries+=("$u" "UID $uid  $home")
    done
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

valid_user()     { echo "$1" | grep -qE '^[a-z_][a-z0-9_-]*$'; }
user_exists()    { id "$1" &>/dev/null; }
has_sudo()       { groups "$1" 2>/dev/null | grep -qw "sudo"; }

require_user() {
    user_exists "$1" || die "User '$1' does not exist."
}

require_no_user() {
    user_exists "$1" || return 0
    info "User '$1' already exists.\nChoose a different name."
    return 1
}

# ─── SHELL CONFIG ───────────────────────────────────────
setup_user_shell_config() {
    local user="$1"
    local home
    home=$(eval echo "~$user" 2>/dev/null)
    [[ -z "$home" || "$home" == "/" ]] && { log "Invalid home for $user"; return 1; }

    # Ensure home directory exists and is owned by user
    mkdir -p "$home"
    chown "$user:$user" "$home"
    chmod 755 "$home"

    # Create .bashrc
    if [[ ! -f "$home/.bashrc" ]]; then
        cat > "$home/.bashrc" <<- 'SHELLEOF'
			[ -z "$PS1" ] && return
			HISTCONTROL=ignoreboth
			shopt -s histappend
			HISTSIZE=1000
			HISTFILESIZE=2000
			PS1='[\u@\h \W]\$ '
			if [ -x /usr/bin/dircolors ]; then
			    eval "$(dircolors -b)"
			fi
			alias ls='ls --color=auto'
			alias ll='ls -alF'
			alias la='ls -A'
			alias l='ls -CF'
			if ! shopt -oq posix; then
			    if [ -f /usr/share/bash-completion/bash_completion ]; then
			        . /usr/share/bash-completion/bash_completion
			    elif [ -f /etc/bash_completion ]; then
			        . /etc/bash_completion
			    fi
			fi
		SHELLEOF
        chown "$user:$user" "$home/.bashrc"
        log ".bashrc created for $user"
    fi

    # Create .profile
    if [[ ! -f "$home/.profile" ]]; then
        cat > "$home/.profile" <<- 'SHELLEOF'
			if [ -n "$BASH_VERSION" ]; then
			    if [ -f "$HOME/.bashrc" ]; then
			        . "$HOME/.bashrc"
			    fi
			fi
		SHELLEOF
        chown "$user:$user" "$home/.profile"
        log ".profile created for $user"
    fi

    # Switch to bash if shell is /bin/sh
    current_shell=$(getent passwd "$user" | cut -d: -f7)
    if [[ "$current_shell" == "/bin/sh" || "$current_shell" == "/bin/dash" ]]; then
        chsh -s /bin/bash "$user" &>/dev/null && log "Shell changed to /bin/bash for $user"
    fi
}

cmd_fixshell() {
    must_root
    local username
    username=$(pick_user "Select user to fix shell config:" "Fix Shell Config") || return
    require_user "$username"
    setup_user_shell_config "$username" && \
        info "Shell config set up for '$username'.\nPrompt: [user@host dir]$ " || \
        die "Failed to fix shell config for '$username'."
}

# ─── CREATE USER ────────────────────────────────────────
cmd_create() {
    must_root
    local username="" fullname="" shell="/bin/bash" groups_input="" pass=""
    local create_home=true

    while true; do
        username=$(whiptail --title "$BTITLE — Create" --inputbox "Enter new username:" 8 56 "" 3>&1 1>&2 2>&3) || return
        [[ -z "$username" ]] && { info "Cannot be empty."; continue; }
        valid_user "$username" || { info "Invalid: use [a-z_][a-z0-9_-]*"; continue; }
        require_no_user "$username" || continue
        break
    done

    fullname=$(whiptail --title "$BTITLE — Create" --inputbox "Full name (optional):" 8 56 "" 3>&1 1>&2 2>&3) || fullname=""

    local shells=() sh
    while IFS= read -r sh; do
        [[ -x "$sh" ]] && shells+=("$sh" "")
    done < /etc/shells 2>/dev/null
    [[ ${#shells[@]} -eq 0 ]] && shells=("/bin/bash" "" "/bin/sh" "")
    shell=$(whiptail --title "Shell" --menu "Select shell:" 16 50 6 \
        "${shells[@]}" 3>&1 1>&2 2>&3) || shell="/bin/bash"

    whiptail --title "Home" --yesno "Create /home/$username?" 7 50 && create_home=true || create_home=false

    groups_input=$(whiptail --title "Groups" --inputbox "Extra groups (comma-sep, e.g. sudo,docker):" 8 60 "" 3>&1 1>&2 2>&3) || groups_input=""

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

    confirm "Create user '$username'?\nShell: $shell\nHome: $([ "$create_home" = true ] && echo 'yes' || echo 'no')" || return

    log "Creating user $username"
    useradd "${flags[@]}" "$username" || die "useradd failed."
    echo "$username:$pass" | chpasswd || die "chpasswd failed."
    log "User $username created"

    # Set up shell config files
    setup_user_shell_config "$username"
    log "Shell config set up for $username"

    info "User '$username' created."
}

# ─── DELETE USER ────────────────────────────────────────
cmd_delete() {
    must_root
    local username
    username=$(pick_user "Select user to DELETE:" "Delete User") || return
    require_user "$username"

    local uid=$(id -u "$username")
    local home=$(eval echo "~$username")
    local proc=$(pgrep -u "$username" 2>/dev/null | wc -l)

    local warn=""
    [[ $proc -gt 0 ]] && warn+="\n⚠️  $proc process(es) running."
    [[ -d "$home" && "$home" != "/" ]] && warn+="\n⚠️  Home: $home"

    confirm "Delete '$username' (UID $uid)?$warn" || return

    local remove_home=false
    whiptail --title "Delete" --yesno "Remove /home/$username?" 7 50 && remove_home=true
    confirm "FINAL WARNING: Cannot undo.\nDelete '$username'?" || return

    local flags=()
    $remove_home && flags+=("-r")
    log "Deleting user $username"
    userdel "${flags[@]}" "$username" || die "userdel failed."
    rm -f "/var/mail/$username" 2>/dev/null || true
    log "User $username deleted"
    info "User '$username' deleted."
}

# ─── RENAME USER ────────────────────────────────────────
cmd_rename() {
    must_root
    local CURRENT
    CURRENT=$(pick_user "Select user to rename:" "Rename User") || return
    require_user "$CURRENT"

    local uid=$(id -u "$CURRENT")
    local cur_home=$(eval echo "~$CURRENT")
    local cur_groups
    cur_groups=$(id -nG "$CURRENT" 2>/dev/null || echo "")

    # Check sessions
    local session
    session=$(who -u 2>/dev/null | awk -v u="$CURRENT" '$1==u' | wc -l)
    if [[ $session -gt 0 ]]; then
        info "User '$CURRENT' has $session active session(s).\nThey must log out first,\nor the rename will fail."
        return
    fi

    # Check processes
    local proc
    proc=$(pgrep -u "$CURRENT" 2>/dev/null | wc -l)
    if [[ $proc -gt 0 ]]; then
        info "⚠️  $proc process(es) still running.\nStop them or the rename will fail."
        return
    fi

    local NEW=""
    while true; do
        NEW=$(whiptail --title "$BTITLE — Rename" \
            --inputbox "New username for '$CURRENT':" 8 56 "" 3>&1 1>&2 2>&3) || return
        [[ -z "$NEW" ]] && { info "Cannot be empty."; continue; }
        valid_user "$NEW" || { info "Invalid username."; continue; }
        require_no_user "$NEW" || continue
        [[ "$CURRENT" == "$NEW" ]] && { info "Must be different."; continue; }
        break
    done

    local OPTIONS
    OPTIONS=$(whiptail --title "Options" --checklist "Extra:" 12 60 3 \
        "MOVE_HOME" "Move home dir" ON \
        "RENAME_GROUP" "Rename group" ON \
        "UPDATE_MAIL" "Update mail spool" ON \
        3>&1 1>&2 2>&3) || return

    local do_home=false do_group=false do_mail=false
    [[ "$OPTIONS" == *"MOVE_HOME"* ]] && do_home=true
    [[ "$OPTIONS" == *"RENAME_GROUP"* ]] && do_group=true
    [[ "$OPTIONS" == *"UPDATE_MAIL"* ]] && do_mail=true

    confirm "Rename '$CURRENT' → '$NEW'?" || return

    log "Renaming $CURRENT → $NEW"

    # 1. Change login name
    if ! usermod -l "$NEW" "$CURRENT"; then
        log "usermod -l $NEW $CURRENT FAILED"
        die "usermod -l failed.\n\nCheck $LOG for details."
    fi
    log "Login name changed"

    # 2. Rename group
    if $do_group && getent group "$CURRENT" &>/dev/null; then
        groupmod -n "$NEW" "$CURRENT" 2>/dev/null && log "Group renamed" || log "Group rename skipped"
    fi

    # 3. Move home
    if $do_home && [[ -d "/home/$CURRENT" ]]; then
        if usermod -d "/home/$NEW" -m "$NEW" 2>/dev/null; then
            log "Home moved to /home/$NEW"
        else
            log "usermod -d -m failed, trying manual"
            mv "/home/$CURRENT" "/home/$NEW" 2>/dev/null || log "mv failed"
            usermod -d "/home/$NEW" "$NEW" 2>/dev/null || log "usermod -d failed"
        fi
    elif $do_home; then
        usermod -d "/home/$NEW" "$NEW" 2>/dev/null || true
    fi

    # 4. Fix ownership
    if [[ -d "/home/$NEW" ]]; then
        chown -R "$NEW":"$NEW" "/home/$NEW" 2>/dev/null && log "Ownership fixed" || log "chown failed"
    fi

    # 5. Mail spool
    if $do_mail && [[ -f "/var/mail/$CURRENT" ]]; then
        mv "/var/mail/$CURRENT" "/var/mail/$NEW" 2>/dev/null || true
        chown "$NEW:mail" "/var/mail/$NEW" 2>/dev/null || true
        log "Mail spool updated"
    fi

    # 6. Supplementary groups
    for grp in $cur_groups; do
        [[ "$grp" != "$CURRENT" && "$grp" != "$NEW" ]] && gpasswd -a "$NEW" "$grp" &>/dev/null || true
    done
    log "Supplementary groups updated"

    # Verify
    if user_exists "$NEW"; then
        log "Rename successful"
        info "✅ Rename complete!\n\nOld: $CURRENT\nNew: $NEW\nUID: $uid (unchanged)"
    else
        die "Rename appeared to succeed but user '$NEW' not found.\nCheck $LOG"
    fi
}

# ─── SUDO ───────────────────────────────────────────────
cmd_sudo() {
    must_root
    local username
    username=$(pick_user "Select user:" "Sudo") || return
    require_user "$username"

    if has_sudo "$username"; then
        confirm "User '$username' HAS sudo.\n\nRemove it?" || return
        deluser "$username" sudo &>/dev/null || gpasswd -d "$username" sudo &>/dev/null || true
        log "Sudo removed from $username"
        info "Sudo removed from '$username'."
    else
        confirm "User '$username' does NOT have sudo.\n\nGrant it?" || return
        adduser "$username" sudo &>/dev/null || gpasswd -a "$username" sudo &>/dev/null || true
        log "Sudo granted to $username"
        info "Sudo granted to '$username'.\nLog out and back in to use it."
    fi
}

# ─── PERMISSIONS ────────────────────────────────────────
cmd_perms() {
    must_root
    local mode
    mode=$(whiptail --title "Permissions" --menu "What to manage?" 12 50 3 \
        "USER" "Fix home directory ownership/perms" \
        "PATH" "Set permissions on a specific path" \
        3>&1 1>&2 2>&3) || return

    if [[ "$mode" == "USER" ]]; then
        local username
        username=$(pick_user "Select user:" "User Permissions") || return
        require_user "$username"
        local target
        target=$(eval echo "~$username")
        [[ ! -d "$target" ]] && die "Home '$target' does not exist."

        local own
        own=$(whiptail --title "Owner" --radiolist "Owner of $target" 10 60 3 \
            "USER" "chown -R $username:$username" ON \
            "ROOT" "chown -R root:root" OFF \
            "KEEP" "Leave as-is" OFF \
            3>&1 1>&2 2>&3) || return

        local perm
        perm=$(whiptail --title "Mode" --menu "Dir permissions on $target" 12 60 4 \
            "755" "drwxr-xr-x" \
            "750" "drwxr-x---" \
            "700" "drwx------" \
            "SKIP" "Leave as-is" \
            3>&1 1>&2 2>&3) || return

        confirm "Apply to $target?" || return
        log "Applying perms on $target: owner=$own mode=$perm"

        [[ "$own" == "USER" ]] && { chown -R "$username":"$username" "$target" && log "Owner set to $username"; }
        [[ "$own" == "ROOT" ]] && { chown -R root:root "$target" && log "Owner set to root"; }
        [[ "$perm" != "SKIP" ]] && { chmod "$perm" "$target" && log "Mode set to $perm"; }

        info "Permissions applied to $target."
    else
        local target
        target=$(whiptail --title "Path" --inputbox "Full path:" 8 60 "" 3>&1 1>&2 2>&3) || return
        [[ ! -e "$target" ]] && die "Path does not exist."

        local username="" group=""
        username=$(pick_user "Set owner:" "Owner") || username=""
        group=$(whiptail --title "Group" --inputbox "Group (or blank):" 8 50 "" 3>&1 1>&2 2>&3) || group=""

        local perm
        perm=$(whiptail --title "Mode" --menu "Permission mode:" 12 50 4 \
            "755" "drwxr-xr-x" \
            "750" "drwxr-x---" \
            "700" "drwx------" \
            "SKIP" "Leave as-is" \
            3>&1 1>&2 2>&3) || return

        local recursive=false
        whiptail --title "Recursive" --yesno "Apply recursively?" 7 40 && recursive=true

        confirm "Apply to $target?" || return
        log "Applying perms on $target"

        if $recursive; then
            [[ -n "$username" && -n "$group" ]] && chown -R "$username":"$group" "$target"
            [[ -n "$username" && -z "$group" ]] && chown -R "$username" "$target"
            [[ -z "$username" && -n "$group" ]] && chgrp -R "$group" "$target"
            [[ "$perm" != "SKIP" ]] && find "$target" -type d -exec chmod "$perm" {} +
        else
            [[ -n "$username" && -n "$group" ]] && chown "$username":"$group" "$target"
            [[ -n "$username" && -z "$group" ]] && chown "$username" "$target"
            [[ -z "$username" && -n "$group" ]] && chgrp "$group" "$target"
            [[ "$perm" != "SKIP" ]] && chmod "$perm" "$target"
        fi
        info "Permissions applied."
    fi
}

# ─── KILL PROCESSES ────────────────────────────────────
cmd_killprocs() {
    must_root
    local username
    username=$(pick_user "Select user to kill all processes:" "Kill Processes") || return
    require_user "$username"

    local procs
    procs=$(pgrep -u "$username" 2>/dev/null || true)
    local count
    count=$(echo "$procs" | grep -c . 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && { info "No processes running for '$username'."; return; }

    local psinfo
    psinfo=$(ps -u "$username" -o pid,comm --no-headers 2>/dev/null | head -30)
    confirm "Kill $count process(es) for '$username'?\n\n$psinfo" || return

    log "Killing $count processes for $username"
    pkill -KILL -u "$username" 2>/dev/null || killall -9 -u "$username" 2>/dev/null || \
        kill -9 $procs 2>/dev/null || true

    sleep 1
    local remaining
    remaining=$(pgrep -u "$username" 2>/dev/null | wc -l)
    if [[ "$remaining" -eq 0 ]]; then
        info "All processes killed for '$username'."
        log "All processes killed for $username"
    else
        info "$remaining process(es) still running for '$username'.\nTry again or use SIGKILL manually."
        log "$remaining processes remaining for $username after kill attempt"
    fi
}

# ═══════════════════ MAIN ═══════════════════════════════
need_whiptail
must_root
echo "Log: $LOG"
log "=== Session started ==="

while true; do
    choice=$(whiptail --title "$BTITLE" --menu "\
Manage users, permissions, and sudo access." 18 60 7 \
        "1" "Create user" \
        "2" "Delete user" \
        "3" "Rename user" \
        "4" "Manage sudo" \
        "5" "Path permissions" \
        "6" "Fix shell config" \
        "7" "Kill user processes" \
        "Q" "Quit" \
        3>&1 1>&2 2>&3) || break

    case "$choice" in
        1) cmd_create  ;;
        2) cmd_delete  ;;
        3) cmd_rename  ;;
        4) cmd_sudo    ;;
        5) cmd_perms   ;;
        6) cmd_fixshell ;;
        7) cmd_killprocs ;;
        Q) log "User quit"; break ;;
    esac

    if [[ -t 0 ]]; then
        whiptail --title "Done" --msgbox "Press OK to return to menu." 6 30 2>/dev/null || true
    fi
done

cleanup
