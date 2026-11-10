#!/bin/bash

# Kaitiz MDM tools: mounted-volume discovery and experimental offline accounts.
# Based on the user's Kaitiz/Bypass-Mac-MDM script. The offline-account approach
# was reviewed against maclifevn/bypasmdm; account handling below is newly written.
# Recovery account creation on M1/macOS 26 still requires real-device validation.
# Compatible with the Bash 3.2 shipped with macOS and Recovery.
set -o pipefail
SCRIPT_VERSION=2026.11.11.4

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

run_checked() {
    local description=$1
    shift
    "$@" || { fail "$description failed. No further steps will run for this action."; return 1; }
}

plist_get() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null; }

system_directory_exists() { [ -d "$1" ]; }

boot_volume_name() {
    local info name status
    info=$(mktemp "${TMPDIR:-/tmp}/mdm-boot.XXXXXX") || return 1
    if ! diskutil info -plist / > "$info" 2>/dev/null; then
        rm -f "$info"
        return 1
    fi
    name=$(plist_get "$info" :VolumeName)
    status=$?
    rm -f "$info"
    [ "$status" -eq 0 ] || return 1
    printf '%s\n' "$name"
}

is_recovery() {
    local volume
    # A mounted target Data volume does NOT mean Recovery has become macOS.
    # Prefer positive Recovery components, then check the booted Base System.
    if system_directory_exists /System/Installation/CDIS ||
       system_directory_exists '/System/Library/CoreServices/Recovery Assistant.app'; then
        return 0
    fi
    volume=$(boot_volume_name) || return 1
    case "$volume" in
        'macOS Base System'|'OS X Base System'|'Mac OS X Base System'|'Base System') return 0;;
        *) return 1;;
    esac
}

# Select only mounted APFS Data volumes; never rename, mount or unlock disks.
# All mutable paths below belong to Data, not to the sealed System volume.
select_macos_data() {
    DATA_VOLUME= HOSTS_FILE= DSLOCAL_PATH= PROFILE_SETTINGS=
    local inventory info c v r device role mountpoint canonical answer index
    local candidates=() devices=()
    command -v diskutil >/dev/null 2>&1 || { fail 'diskutil is unavailable.'; return 1; }
    [ -x /usr/libexec/PlistBuddy ] || { fail 'PlistBuddy is unavailable.'; return 1; }
    inventory=$(mktemp "${TMPDIR:-/tmp}/mdm-disks.XXXXXX") || return 1
    info=$(mktemp "${TMPDIR:-/tmp}/mdm-info.XXXXXX") || { rm -f "$inventory"; return 1; }
    if ! diskutil apfs list -plist > "$inventory"; then
        rm -f "$inventory" "$info"
        fail 'Cannot list APFS volumes. Check Disk Utility and try again.'; return 1
    fi
    if ! plist_get "$inventory" :Containers >/dev/null; then
        rm -f "$inventory" "$info"
        fail 'Unexpected diskutil output: missing Containers array.'; return 1
    fi
    c=0
    while plist_get "$inventory" ":Containers:$c" >/dev/null; do
        v=0
        while plist_get "$inventory" ":Containers:$c:Volumes:$v" >/dev/null; do
            r=0; role=
            while answer=$(plist_get "$inventory" ":Containers:$c:Volumes:$v:Roles:$r"); do
                [ "$answer" != Data ] || role=Data
                r=$((r + 1))
            done
            if [ "$role" = Data ]; then
                device=$(plist_get "$inventory" ":Containers:$c:Volumes:$v:DeviceIdentifier") || device=
                if [ -z "$device" ] || ! diskutil info -plist "$device" > "$info"; then
                    rm -f "$inventory" "$info"
                    fail 'Cannot inspect a Data volume; discovery stopped.'; return 1
                fi
                mountpoint=$(plist_get "$info" :MountPoint) || mountpoint=
                if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
                    canonical=$(cd "$mountpoint" && pwd -P) || canonical=
                    if [ -n "$canonical" ] &&
                       [ -d "$canonical/private/var/db/dslocal/nodes/Default" ] &&
                       [ -f "$canonical/private/etc/hosts" ]; then
                        candidates[${#candidates[@]}]=$canonical
                        devices[${#devices[@]}]=$device
                    fi
                else
                    printf 'Skipping unmounted/locked Data volume: %s. Unlock/mount it in Disk Utility.\n' "$device" >&2
                fi
            fi
            v=$((v + 1))
        done
        c=$((c + 1))
    done
    rm -f "$inventory" "$info"
    [ "${#candidates[@]}" -gt 0 ] || {
        fail 'No mounted macOS Data volume found. Unlock/mount the installation in Disk Utility first.'; return 1;
    }
    index=0
    if [ "${#candidates[@]}" -gt 1 ]; then
        printf 'Multiple macOS installations found:\n'
        for ((index=0; index<${#candidates[@]}; index++)); do
            printf '%d. %s (%s)\n' "$((index + 1))" "${candidates[$index]}" "${devices[$index]}"
        done
        read -r -p 'Select installation number (Enter to cancel): ' answer || return 1
        case "$answer" in ''|*[!0-9]*) fail 'Selection cancelled or invalid.'; return 1;; esac
        # Compare strings to avoid evaluating untrusted input as shell arithmetic.
        index=0
        while [ "$index" -lt "${#candidates[@]}" ] && [ "$answer" != "$((index + 1))" ]; do
            index=$((index + 1))
        done
        [ "$index" -lt "${#candidates[@]}" ] || { fail 'Selection is out of range.'; return 1; }
    fi
    DATA_VOLUME=${candidates[$index]}
    HOSTS_FILE="$DATA_VOLUME/private/etc/hosts"
    DSLOCAL_PATH="$DATA_VOLUME/private/var/db/dslocal/nodes/Default"
    PROFILE_SETTINGS="$DATA_VOLUME/private/var/db/ConfigurationProfiles/Settings"
    printf 'Selected macOS Data: %s (%s)\n' "$DATA_VOLUME" "${devices[$index]}"
}

validate_offline_layout() {
    local directory resolved
    [ -n "$DATA_VOLUME" ] && [ "$DATA_VOLUME" != / ] &&
        [ "$DSLOCAL_PATH" = "$DATA_VOLUME/private/var/db/dslocal/nodes/Default" ] || {
        fail 'Invalid offline target paths.'; return 1;
    }
    for directory in "$DATA_VOLUME/private/var/db" "$DSLOCAL_PATH" "$DSLOCAL_PATH/users" "$DSLOCAL_PATH/groups" "$DATA_VOLUME/Users"; do
        resolved=$(cd "$directory" 2>/dev/null && pwd -P) || { fail "Missing directory: $directory"; return 1; }
        [ "$resolved" = "$directory" ] || { fail "Refusing redirected directory: $directory"; return 1; }
    done
}

prepare_recovery_target() {
    [ "$EUID" -eq 0 ] || { fail 'Run this action as root in macOS Recovery.'; return 1; }
    is_recovery || { fail 'This action requires macOS Recovery.'; return 1; }
    select_macos_data || return 1
    validate_offline_layout || return 1
    [ -w "$DATA_VOLUME/private/var/db" ] && [ -w "$HOSTS_FILE" ] && [ -w "$DSLOCAL_PATH" ] || {
        fail 'Selected Data volume is not writable. Check mount/lock status.'; return 1;
    }
}

update_profile_settings() {
    local prefix=$1
    shift
    local settings="$prefix/private/var/db/ConfigurationProfiles/Settings" marker
    "$@" test -d "$settings" && ! "$@" test -L "$settings" || { fail "Missing or redirected profile settings directory: $settings"; return 1; }
    for marker in .cloudConfigHasActivationRecord .cloudConfigRecordFound .cloudConfigProfileInstalled .cloudConfigRecordNotFound; do
        ! "$@" test -L "$settings/$marker" && { ! "$@" test -e "$settings/$marker" || "$@" test -f "$settings/$marker"; } || {
            fail "Unexpected profile marker type: $settings/$marker"; return 1;
        }
    done
    # -f handles absent marker files; unlike -rf it will not delete directories.
    run_checked 'Removing activation marker' "$@" rm -f "$settings/.cloudConfigHasActivationRecord" || return 1
    run_checked 'Removing enrollment marker' "$@" rm -f "$settings/.cloudConfigRecordFound" || return 1
    run_checked 'Updating profile markers' "$@" touch "$settings/.cloudConfigProfileInstalled" "$settings/.cloudConfigRecordNotFound"
}

# Replace hosts via one checked write, keeping a backup before modification.
write_blocked_hosts() {
    local hosts=$1
    shift
    local temporary backup
    [ -f "$hosts" ] && [ ! -L "$hosts" ] || { fail "Missing or symbolic-link hosts file: $hosts"; return 1; }
    temporary=$(mktemp "${TMPDIR:-/tmp}/mdm-hosts.XXXXXX") || return 1
    if ! sed -E '/^# MDM Servers$/d; /^# End$/d; /(^|[[:space:]])(deviceenrollment\.apple\.com|mdmenrollment\.apple\.com|iprofiles\.apple\.com|acmdm\.apple\.com|axm-adm-mdm\.apple\.com)([[:space:]]|$)/d' "$hosts" > "$temporary"; then
        rm -f "$temporary"; fail 'Cannot read hosts file.'; return 1
    fi
    if ! printf '# MDM Servers\n0.0.0.0 deviceenrollment.apple.com\n0.0.0.0 mdmenrollment.apple.com\n0.0.0.0 iprofiles.apple.com\n0.0.0.0 acmdm.apple.com\n0.0.0.0 axm-adm-mdm.apple.com\n# End\n' >> "$temporary"; then
        rm -f "$temporary"; fail 'Cannot prepare hosts update.'; return 1
    fi
    backup=$("$@" mktemp "${hosts}.backup.$(date +%Y%m%d-%H%M%S).XXXXXX") || {
        rm -f "$temporary"; fail 'Cannot create hosts backup.'; return 1;
    }
    if ! run_checked 'Backing up hosts' "$@" cp -p "$hosts" "$backup"; then
        "$@" rm -f "$backup"
        rm -f "$temporary"; return 1
    fi
    if ! run_checked 'Writing hosts' "$@" tee "$hosts" < "$temporary" > /dev/null; then
        run_checked 'Restoring hosts after write failure' "$@" cp -p "$backup" "$hosts" || {
            printf 'Restore hosts manually from: %s\n' "$backup" >&2;
        }
        rm -f "$temporary"; return 1
    fi
    rm -f "$temporary"
    printf 'Hosts updated. Backup: %s\n' "$backup"
}

ask_block_hosts() {
    local mode=${1:-live} answer hosts
    while true; do
        read -r -p 'Do you want to block hosts? (Y/N): ' answer || return 1
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                if [ "$mode" = recovery ]; then
                    [ -n "$DATA_VOLUME" ] || { fail 'No target selected.'; return 1; }
                    write_blocked_hosts "$HOSTS_FILE"
                else
                    write_blocked_hosts /private/etc/hosts sudo
                fi
                return $?;;
            [Nn]|[Nn][Oo]) echo 'Skipping host blocking.'; return 0;;
            *) echo 'Please enter Y or N.';;
        esac
    done
}

ask_block_hosts_recovery() { ask_block_hosts recovery; }


# -f with localonly exposes the external database as /Local/Target.
# Do not use the live /Local/Default node when editing an offline installation.
offline_dscl() {
    [ -n "$DSLOCAL_PATH" ] && [ -d "$DSLOCAL_PATH" ] || {
        fail 'No offline directory database selected.'; return 1;
    }
    local operation=$1 record=$2
    shift 2
    dscl -f "$DSLOCAL_PATH" localonly "$operation" "/Local/Target$record" "$@"
}

valid_username() {
    # Conservative ASCII short names; full display names may contain Unicode.
    [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] &&
        [ "$1" != root ] && [ "$1" != daemon ] && [ "$1" != nobody ] && [ "$1" != guest ]
}

plist_array_contains() {
    local file=$1 key=$2 expected=$3 mode=${4:-exact} value i=0
    MATCHED_ARRAY_VALUE=
    while value=$(plist_get "$file" ":$key:$i"); do
        if [ "$value" = "$expected" ] || { [ "$mode" = uuid ] && uuid_equal "$value" "$expected"; }; then
            MATCHED_ARRAY_VALUE=$value
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# Parse only the requested dscl group attribute, never account/password data.
directory_attribute_contains() {
    local attribute=$1 output=$2 expected=$3 mode=${4:-exact} value
    local values=()
    MATCHED_DIRECTORY_VALUE=
    case "$output" in "$attribute:"*) output=${output#"$attribute:"};; *) return 1;; esac
    while IFS=$' \t' read -r -a values; do
        for value in "${values[@]}"; do
            if [ "$value" = "$expected" ] ||
               { [ "$mode" = uuid ] && uuid_equal "$value" "$expected"; }; then
                MATCHED_DIRECTORY_VALUE=$value
                return 0
            fi
        done
    done <<< "$output"
    return 1
}

uuid_equal() {
    local left right
    left=$(printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]') || return 1
    right=$(printf '%s' "$2" | LC_ALL=C tr '[:lower:]' '[:upper:]') || return 1
    [ "$left" = "$right" ]
}

verify_admin_group() {
    local name=$1 guid=$2 strict=$3 diagnostics=${4:-} group attempt
    local names uuids node_name node_uuid disk_name disk_uuid read_name read_uuid report
    group="$DSLOCAL_PATH/groups/admin.plist"
    for attempt in 1 2 3; do
        names=$(offline_dscl -read /Groups/admin GroupMembership 2>&1); read_name=$?
        uuids=$(offline_dscl -read /Groups/admin GroupMembers 2>&1); read_uuid=$?
        node_name=no; node_uuid=no; disk_name=no; disk_uuid=no
        if [ "$read_name" -eq 0 ] && directory_attribute_contains GroupMembership "$names" "$name"; then node_name=yes; fi
        if [ "$read_uuid" -eq 0 ] && directory_attribute_contains GroupMembers "$uuids" "$guid" uuid; then node_uuid=yes; fi
        if plist_array_contains "$group" users "$name"; then disk_name=yes; fi
        if plist_array_contains "$group" groupmembers "$guid" uuid; then disk_uuid=yes; fi
        if [ "$strict" -eq 1 ]; then
            [ "$node_name:$node_uuid:$disk_name:$disk_uuid" != yes:yes:yes:yes ] || return 0
        else
            if { [ "$node_name" = yes ] && [ "$disk_name" = yes ]; } ||
               { [ "$node_uuid" = yes ] && [ "$disk_uuid" = yes ]; }; then
                return 0
            fi
        fi
        # Give pending record updates a bounded opportunity to become visible.
        # Do not flush or restart the machine's directory services.
        [ "$attempt" -eq 3 ] || sleep 1
    done
    report=$(printf 'Admin group verification failed.\nUser: %s\nExpected UUID: %s\nGroup file: %s\nDirectory service: username=%s UUID=%s\nOn disk: username=%s UUID=%s\nGroupMembership read exit: %s\n%s\nGroupMembers read exit: %s\n%s\n' \
        "$name" "$guid" "$group" "$node_name" "$node_uuid" "$disk_name" "$disk_uuid" "$read_name" "$names" "$read_uuid" "$uuids")
    printf '%s\n' "$report" >&2
    if [ -n "$diagnostics" ] && [ -d "$diagnostics" ] && [ ! -L "$diagnostics" ]; then
        if (umask 077; printf '%s\n' "$report" > "$diagnostics/admin-verification.txt"); then
            printf 'Diagnostics (no passwords/hashes): %s/admin-verification.txt\n' "$diagnostics" >&2
        else
            printf 'Could not save group diagnostics; review the output above.\n' >&2
        fi
    fi
    return 1
}

remove_created_group_value() {
    local attribute=$1 key=$2 expected=$3 mode=${4:-exact} output actual=
    output=$(offline_dscl -read /Groups/admin "$attribute") || {
        fail "Cannot inspect $attribute during rollback; inspect the saved group backup."; return 1;
    }
    if directory_attribute_contains "$attribute" "$output" "$expected" "$mode"; then
        actual=$MATCHED_DIRECTORY_VALUE
    elif plist_array_contains "$DSLOCAL_PATH/groups/admin.plist" "$key" "$expected" "$mode"; then
        actual=$MATCHED_ARRAY_VALUE
    fi
    [ -n "$actual" ] || return 0
    offline_dscl -delete /Groups/admin "$attribute" "$actual"
}

# Read every local user's UID and aliases. Fail closed on malformed records.
# Empty users directories are also unexpected, since system users should exist.
load_offline_users() {
    local file uid name alias folded i count=0
    USER_FILES=(); USER_IDS=(); USER_NAMES=(); USER_ALIASES=()
    [ -d "$DSLOCAL_PATH/users" ] || { fail 'Missing local users directory.'; return 1; }
    for file in "$DSLOCAL_PATH/users/"*.plist; do
        [ -e "$file" ] || continue
        [ -f "$file" ] && [ ! -L "$file" ] || { fail "Invalid user record: $file"; return 1; }
        uid=$(plist_get "$file" :uid:0) || { fail "Unreadable UID: $file"; return 1; }
        case "$uid" in
            -1|-2) ;;
            *) [[ "$uid" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$uid))" -le 4294967295 ] || {
                fail "Invalid UID in $file"; return 1;
            };;
        esac
        name=$(plist_get "$file" :name:0) || { fail "Missing account name: $file"; return 1; }
        [ -n "$name" ] || { fail "Empty account name: $file"; return 1; }
        USER_FILES[$count]=$file
        case "$uid" in
            -1|-2) USER_IDS[$count]=$uid;;
            *) USER_IDS[$count]=$((10#$uid));;
        esac
        USER_NAMES[$count]=$name
        i=0
        while alias=$(plist_get "$file" ":name:$i"); do
            folded=$(printf '%s' "$alias" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 1
            USER_ALIASES[${#USER_ALIASES[@]}]=$folded
            i=$((i + 1))
        done
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || { fail 'No user records found; refusing to modify an incomplete database.'; return 1; }
}

username_available() {
    local name=$1 alias
    valid_username "$name" || { fail 'Username must be 1-31 lowercase ASCII letters/digits/_/-, start with a letter, and not be reserved.'; return 1; }
    for alias in "${USER_ALIASES[@]}"; do
        [ "$alias" != "$name" ] || { fail "Account name or alias already exists: $name"; return 1; }
    done
    [ ! -e "$DSLOCAL_PATH/users/$name.plist" ] && [ ! -L "$DSLOCAL_PATH/users/$name.plist" ] || {
        fail 'A user record already exists at the destination.'; return 1;
    }
    [ ! -e "$DATA_VOLUME/Users/$name" ] && [ ! -L "$DATA_VOLUME/Users/$name" ] || {
        fail 'A home folder already exists; it will not be reused or overwritten.'; return 1;
    }
}

allocate_uid() {
    local candidate=501 existing collision
    while [ "$candidate" -le 60000 ]; do
        collision=0
        for existing in "${USER_IDS[@]}"; do
            [ "$existing" != "$candidate" ] || { collision=1; break; }
        done
        if [ "$collision" -eq 0 ]; then
            NEW_UID=$candidate
            return 0
        fi
        candidate=$((candidate + 1))
    done
    fail 'No unused UID between 501 and 60000.'
}

find_offline_admins() {
    local group="$DSLOCAL_PATH/groups/admin.plist" i guid
    ADMIN_NAMES=()
    [ -f "$group" ] && [ ! -L "$group" ] || { fail 'Missing or symbolic-link admin group record.'; return 1; }
    guid=$(plist_get "$group" :gid:0) && [ "$guid" = 80 ] &&
        plist_array_contains "$group" name admin || { fail 'Invalid admin group record.'; return 1; }
    for ((i=0; i<${#USER_NAMES[@]}; i++)); do
        [ "${USER_IDS[$i]}" -ge 501 ] && [ "${USER_IDS[$i]}" -le 60000 ] || continue
        [[ "${USER_NAMES[$i]}" != _* ]] || continue
        guid=$(plist_get "${USER_FILES[$i]}" :generateduid:0) || guid=
        if plist_array_contains "$group" users "${USER_NAMES[$i]}" ||
           { [ -n "$guid" ] && plist_array_contains "$group" groupmembers "$guid" uuid; }; then
            ADMIN_NAMES[${#ADMIN_NAMES[@]}]=${USER_NAMES[$i]}
        fi
    done
}

verify_offline_admin() {
    local name=$1 expected_uid=$2 expected_guid=$3 strict=${4:-0} diagnostics=${5:-} record group home actual gid owner mode
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9._-]{0,254}$ ]] || { fail 'Unsupported account record name.'; return 1; }
    [[ "$expected_uid" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$expected_uid))" -ge 501 ] &&
        [ "$((10#$expected_uid))" -le 60000 ] || { fail 'Not a normal local account UID.'; return 1; }
    [[ "$expected_guid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        fail 'Invalid account GeneratedUID.'; return 1;
    }
    record="$DSLOCAL_PATH/users/$name.plist"
    group="$DSLOCAL_PATH/groups/admin.plist"
    home="$DATA_VOLUME/Users/$name"
    [ -f "$record" ] && [ ! -L "$record" ] || { fail 'User record is missing or is a symlink.'; return 1; }
    actual=$(plist_get "$record" :uid:0) && [ "$actual" = "$expected_uid" ] || { fail 'UID verification failed.'; return 1; }
    actual=$(plist_get "$record" :generateduid:0) && uuid_equal "$actual" "$expected_guid" || { fail 'GeneratedUID verification failed.'; return 1; }
    actual=$(plist_get "$record" :name:0) && [ "$actual" = "$name" ] || { fail 'Username verification failed.'; return 1; }
    actual=$(plist_get "$record" :home:0) && [ "$actual" = "/Users/$name" ] || { fail 'Home path verification failed.'; return 1; }
    gid=$(plist_get "$record" :gid:0) && [[ "$gid" =~ ^[0-9]{1,10}$ ]] || { fail 'Primary group verification failed.'; return 1; }
    [ "$strict" -ne 1 ] || [ "$gid" = 20 ] || { fail 'New account must use the staff primary group.'; return 1; }
    # Never print or export password hashes.
    plist_get "$record" :ShadowHashData:0 >/dev/null || { fail 'No local password hash was found.'; return 1; }
    verify_admin_group "$name" "$expected_guid" "$strict" "$diagnostics" || return 1
    [ -d "$home" ] && [ ! -L "$home" ] || { fail 'Home folder is missing or is a symlink.'; return 1; }
    owner=$(stat -f '%u:%g' "$home") || return 1
    [ "$owner" = "$expected_uid:$gid" ] || { fail "Unexpected home ownership: $owner"; return 1; }
    if [ "$strict" -eq 1 ]; then
        mode=$(stat -f '%Lp' "$home") || return 1
        [ "$mode" = 700 ] || { fail 'New home permissions must be 700.'; return 1; }
    fi
}

# Account creation is isolated in a subshell so EXIT/INT/TERM traps are scoped.
# Rollback removes only this operation's memberships, user and empty home folder.
create_offline_admin() (
    # Bash 3.2 unwinds function-local variables before a subshell EXIT trap.
    # Subshell-scoped assignments keep rollback state alive without leaking it.
    name=$1 full_name=$2 uid= guid= home= record= lock= backup= attribute= value=
    committed=0 record_started=0 home_created=0 group_started=0
    [ -n "$full_name" ] && [[ "$full_name" != *$'\n'* ]] && [[ "$full_name" != *$'\r'* ]] || {
        fail 'Full name must be nonempty and occupy one line.'; exit 1;
    }
    validate_offline_layout || exit 1
    lock="$DATA_VOLUME/private/var/db/.kaitiz-mdm-account.lock"
    mkdir "$lock" || { fail "Another operation may be active. Inspect lock: $lock"; exit 1; }
    rollback_account() {
        local status=$? failed=0 group="$DSLOCAL_PATH/groups/admin.plist"
        trap - EXIT INT TERM
        if [ "$committed" -eq 0 ]; then
            if [ "$group_started" -eq 1 ]; then
                remove_created_group_value GroupMembership users "$name" || failed=1
                remove_created_group_value GroupMembers groupmembers "$guid" uuid || failed=1
            fi
            if [ "$record_started" -eq 1 ] && [ -e "$record" ]; then
                offline_dscl -delete "/Users/$name" || failed=1
            fi
            if [ "$home_created" -eq 1 ]; then
                # Never recursively delete a home folder: it may now contain data.
                rmdir "$home" || failed=1
            fi
            if [ "$failed" -ne 0 ]; then
                printf 'Rollback incomplete. Inspect account %s, home %s and backup %s before retrying.\n' "$name" "$home" "$backup" >&2
                status=1
            fi
        fi
        rmdir "$lock" || status=1
        exit "$status"
    }
    trap rollback_account EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    load_offline_users && username_available "$name" && allocate_uid || exit 1
    uid=$NEW_UID
    guid=$(uuidgen) || exit 1
    [[ "$guid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || { fail 'uuidgen returned an invalid identifier.'; exit 1; }
    home="$DATA_VOLUME/Users/$name"
    record="$DSLOCAL_PATH/users/$name.plist"
    [ -d "$DATA_VOLUME/Users" ] && [ ! -L "$DATA_VOLUME/Users" ] && [ -w "$DATA_VOLUME/Users" ] || {
        fail 'Missing, symbolic-link or unwritable Users directory.'; exit 1;
    }
    find_offline_admins || exit 1
    backup=$(mktemp -d "$DATA_VOLUME/private/var/db/kaitiz-mdm-backup.XXXXXX") || exit 1
    chmod 700 "$backup" || exit 1
    run_checked 'Backing up admin group' cp -p "$DSLOCAL_PATH/groups/admin.plist" "$backup/admin.plist" || exit 1
    printf 'Creating %s (UID %s). Group backup: %s\n' "$name" "$uid" "$backup"
    record_started=1
    run_checked 'Creating user record' offline_dscl -create "/Users/$name" || exit 1
    for attribute in UserShell RealName UniqueID PrimaryGroupID GeneratedUID NFSHomeDirectory; do
        case "$attribute" in
            UserShell) value=/bin/zsh;;
            RealName) value=$full_name;;
            UniqueID) value=$uid;;
            PrimaryGroupID) value=20;;
            GeneratedUID) value=$guid;;
            NFSHomeDirectory) value="/Users/$name";;
        esac
        run_checked "Setting $attribute" offline_dscl -create "/Users/$name" "$attribute" "$value" || exit 1
    done
    printf 'Set the NEW account password at the dscl prompts. No default password is used.\n'
    # Let dscl prompt securely; never put the password in argv or a shell variable.
    run_checked 'Setting account password' offline_dscl -passwd "/Users/$name" || exit 1
    plist_get "$record" :ShadowHashData:0 >/dev/null || { fail 'Password hash was not created.'; exit 1; }
    run_checked 'Creating home folder' mkdir -m 700 "$home" || exit 1
    home_created=1
    run_checked 'Setting home ownership' chown "$uid:20" "$home" || exit 1
    run_checked 'Setting home permissions' chmod 700 "$home" || exit 1
    group_started=1
    run_checked 'Adding admin membership' offline_dscl -merge /Groups/admin GroupMembership "$name" || exit 1
    run_checked 'Adding admin UUID' offline_dscl -merge /Groups/admin GroupMembers "$guid" || exit 1
    verify_offline_admin "$name" "$uid" "$guid" 1 "$backup" || exit 1
    committed=1
    printf 'Offline admin created: %s (%s).\n' "$full_name" "$name"
    printf 'Login, Secure Token and volume ownership have NOT been verified.\n'
    printf 'The empty home folder is owned by the new user; GUI template initialization is not reproduced.\n'
)

choose_existing_admin() {
    local i answer
    WORKFLOW_USER=
    [ "${#ADMIN_NAMES[@]}" -gt 0 ] || return 1
    printf 'Existing local admin records (not proof of successful login):\n'
    for ((i=0; i<${#ADMIN_NAMES[@]}; i++)); do
        printf '%d. %s\n' "$((i + 1))" "${ADMIN_NAMES[$i]}"
    done
    read -r -p 'Select admin number (Enter cancels): ' answer || return 1
    for ((i=0; i<${#ADMIN_NAMES[@]}; i++)); do
        if [ "$answer" = "$((i + 1))" ]; then
            WORKFLOW_USER=${ADMIN_NAMES[$i]}
            return 0
        fi
    done
    fail 'Selection cancelled or invalid.'
}

finish_recovery_setup() {
    local name=$1 answer uid guid record
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9._-]{0,254}$ ]] || { fail 'Unsupported account name.'; return 1; }
    record="$DSLOCAL_PATH/users/$name.plist"
    uid=$(plist_get "$record" :uid:0) && guid=$(plist_get "$record" :generateduid:0) || {
        fail 'Cannot read selected account.'; return 1;
    }
    verify_offline_admin "$name" "$uid" "$guid" || return 1
    printf '\nFinishing marks Apple Setup Done so the next boot can reach the login screen.\n'
    printf 'This experimental Recovery account has not been tested on your M1/macOS 26.\n'
    printf 'Offline checks do not verify login, Secure Token, FileVault unlock or volume ownership.\n'
    printf 'Only continue if you intend to test this account at the next boot.\n'
    read -r -p "Type FINISH $name to finish, or Enter to leave setup unchanged: " answer || return 1
    [ "$answer" = "FINISH $name" ] || { printf 'Setup markers left unchanged.\n'; return 0; }
    [ -d "$PROFILE_SETTINGS" ] && [ -w "$PROFILE_SETTINGS" ] || {
        fail "Missing or unwritable profile settings: $PROFILE_SETTINGS"; return 1;
    }
    [ ! -L "$DATA_VOLUME/private/var/db/.AppleSetupDone" ] &&
        { [ ! -e "$DATA_VOLUME/private/var/db/.AppleSetupDone" ] || [ -f "$DATA_VOLUME/private/var/db/.AppleSetupDone" ]; } || {
        fail 'Unexpected .AppleSetupDone file type.'; return 1;
    }
    # SetupDone is last: an earlier failure must not prematurely skip setup.
    update_profile_settings "$DATA_VOLUME" || return 1
    ask_block_hosts_recovery || return 1
    run_checked 'Updating setup marker' touch "$DATA_VOLUME/private/var/db/.AppleSetupDone" || return 1
    printf 'Setup marked complete. Restart manually and test login before disabling any existing account.\n'
}

continue_recovery_setup() {
    local full_name username
    prepare_recovery_target || return 1
    load_offline_users && find_offline_admins || return 1
    if [ "${#ADMIN_NAMES[@]}" -gt 0 ]; then
        choose_existing_admin || return 1
    else
        printf 'No direct local admin record found. Create an experimental offline admin.\n'
        read -r -p 'Full name (Unicode allowed): ' full_name || return 1
        read -r -p 'Username (lowercase ASCII, 1-31 characters): ' username || return 1
        username_available "$username" || return 1
        LAST_ATTEMPT_USERNAME=$username
        create_offline_admin "$username" "$full_name" || return 1
        WORKFLOW_USER=$username
    fi
    finish_recovery_setup "$WORKFLOW_USER"
}

is_macos() {
    [ "$(uname -s)" = Darwin ] &&
        system_directory_exists /System/Library/CoreServices/Finder.app &&
        system_directory_exists /System/Volumes/Data
}

detect_environment() {
    CURRENT_ENV=unknown
    if is_recovery; then
        CURRENT_ENV=recovery
    elif is_macos; then
        CURRENT_ENV=macos
    else
        fail 'Không xác định được môi trường macOS/Recovery; chưa thực hiện tác vụ.'
        return 1
    fi
}

find_sysadminctl() {
    SYSADMINCTL=
    [ -x /usr/sbin/sysadminctl ] || {
        fail 'Không có /usr/sbin/sysadminctl. Nếu đang ở Recovery, script phải nhận diện là Recovery; chưa tạo tài khoản hay sửa dữ liệu.'
        return 1
    }
    SYSADMINCTL=/usr/sbin/sysadminctl
}

as_admin() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Do not infer whether a specific operation is allowed from SIP status.
# Attempt the operation with the required privileges and preserve its real error.
handle_notifications() {
    detect_environment || return 1
    case "$CURRENT_ENV" in
        recovery)
            printf 'Môi trường: Recovery — thao tác trên volume macOS được chọn.\n'
            prepare_recovery_target || return 1
            update_profile_settings "$DATA_VOLUME" || return 1
            ask_block_hosts_recovery || return 1
            ;;
        macos)
            printf 'Môi trường: macOS — thao tác trên hệ điều hành đang chạy.\n'
            update_profile_settings "" as_admin || {
                fail 'Không sửa được marker; xem lỗi ở trên. Có thể thử lại mục này trong Recovery.'
                return 1
            }
            ask_block_hosts live || return 1
            ;;
    esac
    printf 'Đã xử lý các marker cục bộ. Đây không phải xác nhận thiết bị đã được gỡ khỏi MDM.\n'
}

show_hosts_auto() {
    detect_environment || return 1
    if [ "$CURRENT_ENV" = recovery ]; then
        select_macos_data || return 1
        run_checked 'Reading hosts on selected volume' cat "$HOSTS_FILE"
    else
        run_checked 'Reading hosts on booted macOS' cat /private/etc/hosts
    fi
}

check_enrollment_auto() {
    local settings marker
    detect_environment || return 1
    if [ "$CURRENT_ENV" = recovery ]; then
        select_macos_data || return 1
        settings="$DATA_VOLUME/private/var/db/ConfigurationProfiles/Settings"
        [ -d "$settings" ] && [ ! -L "$settings" ] && [ -r "$settings" ] && [ -x "$settings" ] || {
            fail 'Không đọc được thư mục profile trên ổ đã chọn.'; return 1;
        }
        printf 'Recovery: chỉ xem dấu vết cục bộ trên volume đã chọn.\n'
        printf 'Không thể kết luận trạng thái enrollment đang hoạt động bằng các file này.\n'
        for marker in .cloudConfigHasActivationRecord .cloudConfigRecordFound .cloudConfigProfileInstalled .cloudConfigRecordNotFound; do
            if [ -L "$settings/$marker" ]; then
                fail "Marker là liên kết tượng trưng: $marker"; return 1
            elif [ -e "$settings/$marker" ]; then
                printf 'Có: %s\n' "$marker"
            else
                printf 'Không có: %s\n' "$marker"
            fi
        done
        printf 'Để xem trạng thái thực tế, khởi động vào macOS rồi chọn lại mục này.\n'
    else
        run_checked 'Checking enrollment status' as_admin profiles status -type enrollment || return 1
        run_checked 'Reading enrollment configuration' as_admin profiles show -type enrollment || return 1
        printf 'Đã lấy báo cáo. Hãy đọc nội dung; lỗi lệnh không đồng nghĩa với đã gỡ MDM.\n'
    fi
}

set_root_password_auto() {
    detect_environment || return 1
    if [ "$CURRENT_ENV" = recovery ]; then
        prepare_recovery_target || return 1
        run_checked 'Setting offline root password' offline_dscl -passwd /Users/root || return 1
    else
        run_checked 'Setting live root password' as_admin dscl . -passwd /Users/root || return 1
    fi
    printf 'Đã đặt mật khẩu root; đây không phải xác minh tài khoản admin thông thường.\n'
}

disable_root_auto() {
    detect_environment || return 1
    if [ "$CURRENT_ENV" = recovery ]; then
        fail 'Vô hiệu hóa root cần chạy trong macOS. Hãy khởi động vào macOS rồi chọn lại mục này.'
        return 1
    fi
    run_checked 'Disabling root user' as_admin dsenableroot -d
}

# Live creation uses macOS account services, not offline plist modification.
# No automatic deletion/rollback of a live account is attempted if verification
# or a later notification step fails; report the created account explicitly.
continue_live_setup() {
    local full_name username names name folded home uid groups
    # Creating a live admin does not require disabling SIP.
    find_sysadminctl || return 1
    printf 'macOS: tạo admin bằng sysadminctl trên hệ điều hành đang chạy.\n'
    read -r -p 'Full name (Unicode allowed): ' full_name || return 1
    read -r -p 'Username (lowercase ASCII, 1-31 characters): ' username || return 1
    valid_username "$username" || { fail 'Username không hợp lệ.'; return 1; }
    [ -n "$full_name" ] && [[ "$full_name" != *$'\r'* ]] || { fail 'Full name không hợp lệ.'; return 1; }
    names=$(dscl . -list /Users) || { fail 'Không đọc được danh sách tài khoản.'; return 1; }
    while IFS= read -r name; do
        folded=$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 1
        [ "$folded" != "$username" ] || { fail 'Username đã tồn tại.'; return 1; }
    done <<< "$names"
    home="/Users/$username"
    [ ! -e "$home" ] && [ ! -L "$home" ] || { fail 'Home folder đã tồn tại; không ghi đè.'; return 1; }
    LAST_ATTEMPT_USERNAME=$username
    run_checked 'Creating live admin account' as_admin "$SYSADMINCTL" interactive -addUser "$username" -fullName "$full_name" -password - -admin || {
        printf 'Nếu lệnh tạo tài khoản đã thay đổi một phần dữ liệu, hãy kiểm tra Users & Groups trước khi thử lại.\n' >&2
        return 1;
    }
    uid=$(id -u "$username") && groups=$(id -Gn "$username") || {
        fail "Không xác minh được tài khoản $username. Hãy kiểm tra Users & Groups."; return 1;
    }
    case " $groups " in
        *' admin '*) ;;
        *) fail "Tài khoản $username chưa được xác minh là admin. Chưa xử lý marker."; return 1;;
    esac
    printf 'Đã tạo admin %s (UID %s). Secure Token và đăng nhập chưa được xác minh.\n' "$username" "$uid"
    update_profile_settings "" as_admin && ask_block_hosts live || {
        fail "Tài khoản $username vẫn tồn tại; bước xử lý thông báo chưa hoàn tất."; return 1;
    }
    printf 'Đã hoàn thành luồng trong macOS; không sửa AppleSetupDone của hệ điều hành đang chạy.\n'
}

create_admin_auto() {
    detect_environment || return 1
    if [ "$CURRENT_ENV" = recovery ]; then
        continue_recovery_setup
    else
        continue_live_setup
    fi
}

# These diagnostics read only public identity/group attributes and home metadata.
# Continue after a failed query: missing records are useful evidence after rollback.
# The only file created is the report in the temporary directory, never on Data.
diagnose_user_auto() {
    local username=$1 environment home report logfile
    [[ "$username" =~ ^[A-Za-z][A-Za-z0-9._-]{0,254}$ ]] || {
        fail 'Username không hợp lệ; chưa chạy lệnh kiểm tra.'; return 1;
    }
    detect_environment || return 1
    environment=$CURRENT_ENV
    if [ "$environment" = recovery ]; then
        select_macos_data || return 1
        home="$DATA_VOLUME/Users/$username"
    else
        home="/Users/$username"
    fi
    report=$(
        printf 'MDM DIAGNOSTICS — version %s\nEnvironment: %s\nUsername: %s\n' "$SCRIPT_VERSION" "$environment" "$username"
        if [ "$environment" = recovery ]; then
            printf 'Selected Data volume: %s\n' "$DATA_VOLUME"
        fi
        printf '\n[1] Account: RecordName, UniqueID, GeneratedUID, NFSHomeDirectory\n'
        if [ "$environment" = recovery ]; then
            offline_dscl -read "/Users/$username" RecordName UniqueID GeneratedUID NFSHomeDirectory
        else
            dscl . -read "/Users/$username" RecordName UniqueID GeneratedUID NFSHomeDirectory
        fi
        printf 'Account query exit: %s\n' "$?"
        printf '\n[2] Admin group: GroupMembership, GroupMembers\n'
        if [ "$environment" = recovery ]; then
            offline_dscl -read /Groups/admin GroupMembership GroupMembers
        else
            dscl . -read /Groups/admin GroupMembership GroupMembers
        fi
        printf 'Admin group query exit: %s\n' "$?"
        printf '\n[3] Home folder: %s\n' "$home"
        ls -ld "$home"
        printf 'Home query exit: %s\n' "$?"
        printf '\nEND DIAGNOSTICS — không sửa tài khoản/nhóm/home; không đọc mật khẩu hoặc password hash.\n'
    2>&1)
    printf '\n%s\n' "$report"
    logfile=$(mktemp "${TMPDIR:-/tmp}/mdm-diagnostic.XXXXXX") || {
        fail 'Không tạo được file báo cáo tạm; kết quả vẫn có ở trên.'; return 1;
    }
    if ! printf '%s\n' "$report" > "$logfile"; then
        rm -f "$logfile"
        fail 'Không lưu được báo cáo tạm; kết quả vẫn có ở trên.'; return 1
    fi
    LAST_DIAGNOSTIC_FILE=$logfile
    printf '\nFile báo cáo: %s\nBạn có thể chụp phần kết quả hoặc chuyển file này sang máy đang chạy Codex.\n' "$logfile"
}

diagnose_account_prompt() {
    local username default_username=${LAST_ATTEMPT_USERNAME:-kaitiz} answer
    read -r -p "Username cần kiểm tra [${default_username}]: " username || return 1
    username=${username:-$default_username}
    diagnose_user_auto "$username" || return 1
    read -r -p 'Nhấn Enter để quay lại menu...' answer || :
}

credit() {
    echo '============================================='
    echo '             MDM Tools by Kaitiz'
    printf 'Phiên bản: %s\n' "$SCRIPT_VERSION"
    echo '============================================='
    if detect_environment; then
        case "$CURRENT_ENV" in
            recovery) echo 'Môi trường: Recovery';;
            macos) echo 'Môi trường: macOS';;
        esac
    else
        echo 'Môi trường: không xác định — các tác vụ sẽ bị từ chối.'
    fi
}

show_menu() {
    credit
    echo ''
    echo '1. Tạo tài khoản mới với quyền Admin và bypass tự động'
    echo '2. Xử lý thông báo MDM'
    echo '3. Kiểm tra trạng thái MDM'
    echo '4. Xem file hosts'
    echo '5. Quản lý tài khoản root'
    echo '6. Chẩn đoán tài khoản / lỗi rollback (chỉ đọc)'
    echo '0. Thoát'
    echo ''
}

handle_root_menu() {
    local choice
    while true; do
        printf '\n1. Đặt mật khẩu root\n2. Vô hiệu hóa root\n0. Quay lại\n'
        read -r -p 'Chọn chức năng: ' choice || return 0
        case "$choice" in
            1) set_root_password_auto;;
            2) disable_root_auto;;
            0) return 0;;
            *) printf 'Lựa chọn không hợp lệ.\n';;
        esac
    done
}

handle_choice() {
    case "$1" in
        1) create_admin_auto;;
        2) handle_notifications;;
        3) check_enrollment_auto;;
        4) show_hosts_auto;;
        5) handle_root_menu;;
        6) diagnose_account_prompt;;
        *) fail 'Lựa chọn không hợp lệ.';;
    esac
}

check_live_user() {
    local name=$1
    detect_environment || return 1
    [ "$CURRENT_ENV" = macos ] || { fail 'Run --check-user after booting into the installed macOS.'; return 1; }
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9._-]{0,254}$ ]] || { fail 'Invalid account name.'; return 1; }
    find_sysadminctl || return 1
    printf 'Read-only diagnostics for the currently booted macOS: %s\n' "$name"
    run_checked 'Reading user identity' id "$name" || return 1
    run_checked 'Reading user UUID' dscl . -read "/Users/$name" GeneratedUID || return 1
    run_checked 'Reading admin membership' dsmemberutil checkmembership -U "$name" -G admin || return 1
    run_checked 'Reading Secure Token status' "$SYSADMINCTL" -secureTokenStatus "$name" || return 1
    printf 'Match the GeneratedUID above with a Volume Owner entry below:\n'
    run_checked 'Reading APFS users' diskutil apfs listUsers / || return 1
    printf 'These reports do not test password login or FileVault unlock. Review their contents; exit status alone is insufficient.\n'
}

main() {
    case "${1:-}" in
        --environment)
            detect_environment || return 1
            printf 'Phiên bản: %s\nMôi trường: %s\n' "$SCRIPT_VERSION" "$CURRENT_ENV"
            return 0;;
        --detect)
            # Read-only discovery: no changes to the selected installation.
            select_macos_data
            return $?;;
        --diagnose-user)
            [ "$#" -eq 2 ] || { fail 'Usage: bash mdm1.sh --diagnose-user USER'; return 1; }
            diagnose_user_auto "$2"
            return $?;;
        --check-user)
            [ "$#" -eq 2 ] || { fail 'Usage: bash mdm1.sh --check-user USER'; return 1; }
            check_live_user "$2"
            return $?;;
        --help|-h)
            printf 'Usage: bash mdm1.sh [--environment | --detect | --diagnose-user USER | --check-user USER | --help]\n'
            printf 'Unlock/mount the macOS Data volume in Disk Utility first.\n'
            printf '%s\n' '--environment reports the detected environment without changing the installation.'
            printf '%s\n' '--detect only lists/selects a mounted macOS Data volume.'
            printf '%s\n' '--check-user USER prints account/token/APFS reports in the installed macOS.'
            printf '%s\n' '--diagnose-user USER reads account/group/home state in Recovery or macOS and saves a temporary report.'
            return 0;;
        '') ;;
        *) fail "Unknown option: $1"; return 1;;
    esac
    while true; do
        show_menu
        read -r -p 'Chọn chức năng: ' choice || break
        [ "$choice" != 0 ] || { printf 'Đã thoát.\n'; break; }
        handle_choice "$choice"
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
