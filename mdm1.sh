#!/bin/bash

# Kaitiz MDM tools: mounted-volume discovery and experimental offline accounts.
# Based on the user's Kaitiz/Bypass-Mac-MDM script. The offline-account approach
# was reviewed against maclifevn/bypasmdm; account handling below is newly written.
# Offline login was tested by the user on M1/macOS 26; Secure Token/ownership
# and other device/OS configurations still require separate validation.
# Compatible with the Bash 3.2 shipped with macOS and Recovery.
set -o pipefail


# This is script text only. Never export LANG/LC_* or write macOS preferences
# when choosing the interface language. Raw output from Apple tools is unmodified.
UI_LANGUAGE=en
ui_text() {
    if [ "$UI_LANGUAGE" = vi ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# Used only by interactive screens, never by the command-line report options.
# Clear scrollback as well as the visible screen; do not depend on TERM or -t.
clear_screen() {
    printf '\033[3J\033[2J\033[H'
}

read_menu_choice() {
    printf '\n=============================================\n\n%s ' "$1"
    read -r "$2"
}

read_ui_input() {
    local input_status
    printf '\n=============================================\n\n%s' "$1"
    read -r "$2"
    input_status=$?
    printf '\n'
    return "$input_status"
}

select_ui_language() {
    local choice message=
    while true; do
        clear_screen
        printf '=============================================\n'
        printf '             MDM Tools by Kaitiz\n'
        printf '=============================================\n\n'
        printf 'Please select the script interface language:\n\n'
        printf '  1. English\n\n  2. Vietnamese\n\n'
        printf 'This changes script text only, not the macOS language.\n'
        if [ -n "$message" ]; then printf '\n%s\n' "$message"; fi
        read_menu_choice 'Select language [1]:' choice || return 1
        case "$choice" in
            1|'') UI_LANGUAGE=en; return 0;;
            2) UI_LANGUAGE=vi; return 0;;
            *) message='Invalid selection. Please enter 1 or 2.';;
        esac
    done
}

fail() { printf "$(ui_text 'ERROR: %s\n\n' 'LỖI: %s\n\n')" "$*" >&2; return 1; }

run_checked() {
    local description=$1
    shift
    "$@" || { fail "$(ui_text "$description failed. No further steps will run for this action." "Thao tác $description thất bại. Dừng các bước còn lại của tác vụ này.")"; return 1; }
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
    command -v diskutil >/dev/null 2>&1 || { fail "$(ui_text 'diskutil is unavailable.' 'Không tìm thấy diskutil.')"; return 1; }
    [ -x /usr/libexec/PlistBuddy ] || { fail "$(ui_text 'PlistBuddy is unavailable.' 'Không tìm thấy PlistBuddy.')"; return 1; }
    inventory=$(mktemp "${TMPDIR:-/tmp}/mdm-disks.XXXXXX") || return 1
    info=$(mktemp "${TMPDIR:-/tmp}/mdm-info.XXXXXX") || { rm -f "$inventory"; return 1; }
    if ! diskutil apfs list -plist > "$inventory"; then
        rm -f "$inventory" "$info"
        fail "$(ui_text 'Cannot list APFS volumes. Check Disk Utility and try again.' 'Không liệt kê được volume APFS. Kiểm tra Disk Utility rồi thử lại.')"; return 1
    fi
    if ! plist_get "$inventory" :Containers >/dev/null; then
        rm -f "$inventory" "$info"
        fail "$(ui_text 'Unexpected diskutil output: missing Containers array.' 'Dữ liệu diskutil không đúng định dạng: thiếu mảng Containers.')"; return 1
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
                    fail "$(ui_text 'Cannot inspect a Data volume; discovery stopped.' 'Không đọc được thông tin volume Data; dừng nhận diện.')"; return 1
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
                    printf "$(ui_text 'Skipping unmounted/locked Data volume: %s. Unlock/mount it in Disk Utility.\n\n' 'Bỏ qua Data chưa mount/đang khóa: %s. Mở khóa/mount bằng Disk Utility.\n\n')" "$device" >&2
                fi
            fi
            v=$((v + 1))
        done
        c=$((c + 1))
    done
    rm -f "$inventory" "$info"
    [ "${#candidates[@]}" -gt 0 ] || {
        fail "$(ui_text 'No mounted macOS Data volume found. Unlock/mount the installation in Disk Utility first.' 'Không tìm thấy Data của macOS đã mount. Mở khóa/mount bằng Disk Utility trước.')"; return 1;
    }
    index=0
    if [ "${#candidates[@]}" -gt 1 ]; then
        printf "$(ui_text 'Multiple macOS installations found:\n\n' 'Tìm thấy nhiều bản macOS:\n\n')"
        for ((index=0; index<${#candidates[@]}; index++)); do
            printf '%d. %s (%s)\n' "$((index + 1))" "${candidates[$index]}" "${devices[$index]}"
        done
        read_ui_input "$(ui_text 'Select installation number (Enter to cancel): ' 'Chọn số thứ tự bản macOS (Enter để hủy): ')" answer || return 1
        case "$answer" in ''|*[!0-9]*) fail "$(ui_text 'Selection cancelled or invalid.' 'Đã hủy hoặc lựa chọn không hợp lệ.')"; return 1;; esac
        # Compare strings to avoid evaluating untrusted input as shell arithmetic.
        index=0
        while [ "$index" -lt "${#candidates[@]}" ] && [ "$answer" != "$((index + 1))" ]; do
            index=$((index + 1))
        done
        [ "$index" -lt "${#candidates[@]}" ] || { fail "$(ui_text 'Selection is out of range.' 'Lựa chọn nằm ngoài danh sách.')"; return 1; }
    fi
    DATA_VOLUME=${candidates[$index]}
    HOSTS_FILE="$DATA_VOLUME/private/etc/hosts"
    DSLOCAL_PATH="$DATA_VOLUME/private/var/db/dslocal/nodes/Default"
    PROFILE_SETTINGS="$DATA_VOLUME/private/var/db/ConfigurationProfiles/Settings"
    printf "$(ui_text 'Selected macOS Data: %s (%s)\n\n' 'Đã chọn Data macOS: %s (%s)\n\n')" "$DATA_VOLUME" "${devices[$index]}"
}

validate_offline_layout() {
    local directory resolved
    [ -n "$DATA_VOLUME" ] && [ "$DATA_VOLUME" != / ] &&
        [ "$DSLOCAL_PATH" = "$DATA_VOLUME/private/var/db/dslocal/nodes/Default" ] || {
        fail "$(ui_text 'Invalid offline target paths.' 'Đường dẫn ổ đích ngoại tuyến không hợp lệ.')"; return 1;
    }
    for directory in "$DATA_VOLUME/private/var/db" "$DSLOCAL_PATH" "$DSLOCAL_PATH/users" "$DSLOCAL_PATH/groups" "$DATA_VOLUME/Users"; do
        resolved=$(cd "$directory" 2>/dev/null && pwd -P) || { fail "$(ui_text "Missing directory: $directory" "Thiếu thư mục: $directory")"; return 1; }
        [ "$resolved" = "$directory" ] || { fail "$(ui_text "Refusing redirected directory: $directory" "Từ chối thư mục bị chuyển hướng: $directory")"; return 1; }
    done
}

prepare_recovery_target() {
    [ "$EUID" -eq 0 ] || { fail "$(ui_text 'Run this action as root in macOS Recovery.' 'Chạy tác vụ này với quyền root trong macOS Recovery.')"; return 1; }
    is_recovery || { fail "$(ui_text 'This action requires macOS Recovery.' 'Tác vụ này cần macOS Recovery.')"; return 1; }
    select_macos_data || return 1
    validate_offline_layout || return 1
    [ -w "$DATA_VOLUME/private/var/db" ] && [ -w "$HOSTS_FILE" ] && [ -w "$DSLOCAL_PATH" ] || {
        fail "$(ui_text 'Selected Data volume is not writable. Check mount/lock status.' 'Data đã chọn không ghi được. Kiểm tra trạng thái mount/khóa.')"; return 1;
    }
}

# Snapshot the same four local markers used by the original script. This never
# deletes the ConfigurationProfiles directory or account/user-data records.
update_profile_settings() (
    marker_prefix=$1
    shift
    marker_privilege=("$@")
    marker_settings="$marker_prefix/private/var/db/ConfigurationProfiles/Settings"
    marker_backup= marker_modified=0 marker_committed=0
    marker_files=(.cloudConfigHasActivationRecord .cloudConfigRecordFound .cloudConfigProfileInstalled .cloudConfigRecordNotFound)
    "${marker_privilege[@]}" test -d "$marker_settings" && ! "${marker_privilege[@]}" test -L "$marker_settings" || {
        fail "$(ui_text 'Missing or redirected profile settings directory:' 'Thư mục profile thiếu hoặc bị chuyển hướng:') $marker_settings"; exit 1;
    }
    for marker_name in "${marker_files[@]}"; do
        ! "${marker_privilege[@]}" test -L "$marker_settings/$marker_name" &&
            { ! "${marker_privilege[@]}" test -e "$marker_settings/$marker_name" || "${marker_privilege[@]}" test -f "$marker_settings/$marker_name"; } || {
            fail "$(ui_text 'Unexpected profile marker type:' 'Marker profile có kiểu không hợp lệ:') $marker_settings/$marker_name"; exit 1;
        }
    done
    # Settings may reject new entries even when specific marker operations are
    # permitted. Keep the backup in the target installation's persistent var/tmp.
    marker_backup_root="$marker_prefix/private/var/tmp"
    "${marker_privilege[@]}" test -d "$marker_backup_root" && ! "${marker_privilege[@]}" test -L "$marker_backup_root" || {
        fail "$(ui_text 'Missing or redirected backup directory:' 'Thư mục sao lưu thiếu hoặc bị chuyển hướng:') $marker_backup_root"; exit 1;
    }
    marker_backup=$("${marker_privilege[@]}" mktemp -d "$marker_backup_root/kaitiz-mdm-markers.XXXXXX") || {
        fail "$(ui_text 'Cannot create marker backup in:' 'Không tạo được bản sao lưu marker tại:') $marker_backup_root"; exit 1;
    }
    marker_cleanup() {
        local status=$? rollback_failed=0 name
        trap - EXIT INT TERM
        if [ "$marker_modified" -eq 1 ] && [ "$marker_committed" -eq 0 ]; then
            for name in "${marker_files[@]}"; do
                if "${marker_privilege[@]}" test -f "$marker_backup/$name"; then
                    "${marker_privilege[@]}" cp -p "$marker_backup/$name" "$marker_settings/$name" || rollback_failed=1
                else
                    "${marker_privilege[@]}" rm -f "$marker_settings/$name" || rollback_failed=1
                fi
            done
            if [ "$rollback_failed" -ne 0 ]; then
                printf "$(ui_text 'Profile marker rollback incomplete. Backup: %s\n\n' 'Hoàn tác marker chưa đầy đủ. Bản sao lưu: %s\n\n')" "$marker_backup" >&2
                status=1
            fi
        fi
        exit "$status"
    }
    trap marker_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for marker_name in "${marker_files[@]}"; do
        if "${marker_privilege[@]}" test -f "$marker_settings/$marker_name"; then
            run_checked "$(ui_text 'Backing up profile marker' 'Sao lưu marker profile')" "${marker_privilege[@]}" cp -p "$marker_settings/$marker_name" "$marker_backup/$marker_name" || exit 1
        fi
    done
    printf "$(ui_text 'Profile marker backup: %s\n\n' 'Bản sao lưu marker profile: %s\n\n')" "$marker_backup"
    marker_modified=1
    run_checked "$(ui_text 'Removing activation marker' 'Xóa marker kích hoạt')" "${marker_privilege[@]}" rm -f "$marker_settings/.cloudConfigHasActivationRecord" || exit 1
    run_checked "$(ui_text 'Removing enrollment marker' 'Xóa marker đăng ký quản lý')" "${marker_privilege[@]}" rm -f "$marker_settings/.cloudConfigRecordFound" || exit 1
    run_checked "$(ui_text 'Updating profile markers' 'Cập nhật marker profile')" "${marker_privilege[@]}" touch "$marker_settings/.cloudConfigProfileInstalled" "$marker_settings/.cloudConfigRecordNotFound" || exit 1
    marker_committed=1
)

# Replace hosts via one checked write, keeping a backup before modification.
write_blocked_hosts() {
    local hosts=$1
    shift
    local temporary backup
    [ -f "$hosts" ] && [ ! -L "$hosts" ] || { fail "$(ui_text "Missing or symbolic-link hosts file: $hosts" "Hosts bị thiếu hoặc là symlink: $hosts")"; return 1; }
    temporary=$(mktemp "${TMPDIR:-/tmp}/mdm-hosts.XXXXXX") || return 1
    if ! sed -E '/^# MDM Servers$/d; /^# End$/d; /(^|[[:space:]])(deviceenrollment\.apple\.com|mdmenrollment\.apple\.com|iprofiles\.apple\.com|acmdm\.apple\.com|axm-adm-mdm\.apple\.com)([[:space:]]|$)/d' "$hosts" > "$temporary"; then
        rm -f "$temporary"; fail "$(ui_text 'Cannot read hosts file.' 'Không đọc được hosts.')"; return 1
    fi
    if ! printf '# MDM Servers\n0.0.0.0 deviceenrollment.apple.com\n0.0.0.0 mdmenrollment.apple.com\n0.0.0.0 iprofiles.apple.com\n0.0.0.0 acmdm.apple.com\n0.0.0.0 axm-adm-mdm.apple.com\n# End\n' >> "$temporary"; then
        rm -f "$temporary"; fail "$(ui_text 'Cannot prepare hosts update.' 'Không chuẩn bị được nội dung hosts.')"; return 1
    fi
    backup=$("$@" mktemp "${hosts}.backup.$(date +%Y%m%d-%H%M%S).XXXXXX") || {
        rm -f "$temporary"; fail "$(ui_text 'Cannot create hosts backup.' 'Không tạo được bản sao lưu hosts.')"; return 1;
    }
    if ! run_checked "$(ui_text 'Backing up hosts' 'Sao lưu hosts')" "$@" cp -p "$hosts" "$backup"; then
        "$@" rm -f "$backup"
        rm -f "$temporary"; return 1
    fi
    if ! run_checked "$(ui_text 'Writing hosts' 'Ghi hosts')" "$@" tee "$hosts" < "$temporary" > /dev/null; then
        run_checked "$(ui_text 'Restoring hosts after write failure' 'Khôi phục hosts sau lỗi ghi')" "$@" cp -p "$backup" "$hosts" || {
            printf "$(ui_text 'Restore hosts manually from: %s\n\n' 'Khôi phục hosts thủ công từ: %s\n\n')" "$backup" >&2;
        }
        rm -f "$temporary"; return 1
    fi
    rm -f "$temporary"
    printf "$(ui_text 'Hosts updated. Backup: %s\n\n' 'Đã cập nhật hosts. Bản sao lưu: %s\n\n')" "$backup"
}

apply_hosts_for_context() {
    local hosts_path count
    if [ "$1" = recovery ]; then
        [ -n "$DATA_VOLUME" ] || { fail "$(ui_text 'No target selected.' 'Chưa chọn ổ đích.')"; return 1; }
        hosts_path=$HOSTS_FILE
    else
        hosts_path=/private/etc/hosts
    fi
    [ ! -L "$hosts_path" ] || { fail "$(ui_text 'Refusing symbolic-link hosts file.' 'Từ chối file hosts là symlink.')"; return 1; }
    count=$(blocked_host_count "$hosts_path") || count=unknown
    if [ "$count" = 5 ]; then
        printf "$(ui_text 'Hosts already contains all 5 blocking entries; no changes needed.\n\n' 'Hosts đã có đủ 5 mục chặn; không cần ghi lại.\n\n')"
        return 0
    fi
    if [ "$1" = recovery ]; then write_blocked_hosts "$hosts_path";
    else write_blocked_hosts "$hosts_path" as_admin; fi
}


# -f with localonly exposes the external database as /Local/Target.
# Do not use the live /Local/Default node when editing an offline installation.
offline_dscl() {
    [ -n "$DSLOCAL_PATH" ] && [ -d "$DSLOCAL_PATH" ] || {
        fail "$(ui_text 'No offline directory database selected.' 'Chưa chọn cơ sở dữ liệu tài khoản ngoại tuyến.')"; return 1;
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
            printf "$(ui_text 'Diagnostics (no passwords/hashes): %s/admin-verification.txt\n\n' 'Chẩn đoán (không có mật khẩu/hash): %s/admin-verification.txt\n\n')" "$diagnostics" >&2
        else
            printf "$(ui_text 'Could not save group diagnostics; review the output above.\n\n' 'Không lưu được chẩn đoán nhóm; xem kết quả ở trên.\n\n')" >&2
        fi
    fi
    return 1
}

remove_created_group_value() {
    local attribute=$1 key=$2 expected=$3 mode=${4:-exact} output actual=
    output=$(offline_dscl -read /Groups/admin "$attribute") || {
        fail "$(ui_text "Cannot inspect $attribute during rollback; inspect the saved group backup." "Không đọc được $attribute khi hoàn tác; kiểm tra bản sao lưu nhóm.")"; return 1;
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
    [ -d "$DSLOCAL_PATH/users" ] || { fail "$(ui_text 'Missing local users directory.' 'Thiếu thư mục tài khoản cục bộ.')"; return 1; }
    for file in "$DSLOCAL_PATH/users/"*.plist; do
        [ -e "$file" ] || continue
        [ -f "$file" ] && [ ! -L "$file" ] || { fail "$(ui_text "Invalid user record: $file" "Bản ghi user không hợp lệ: $file")"; return 1; }
        uid=$(plist_get "$file" :uid:0) || { fail "$(ui_text "Unreadable UID: $file" "Không đọc được UID: $file")"; return 1; }
        case "$uid" in
            -1|-2) ;;
            *) [[ "$uid" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$uid))" -le 4294967295 ] || {
                fail "$(ui_text "Invalid UID in $file" "UID không hợp lệ trong $file")"; return 1;
            };;
        esac
        name=$(plist_get "$file" :name:0) || { fail "$(ui_text "Missing account name: $file" "Thiếu tên tài khoản: $file")"; return 1; }
        [ -n "$name" ] || { fail "$(ui_text "Empty account name: $file" "Tên tài khoản trống: $file")"; return 1; }
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
    [ "$count" -gt 0 ] || { fail "$(ui_text 'No user records found; refusing to modify an incomplete database.' 'Không có bản ghi user; từ chối sửa cơ sở dữ liệu không đầy đủ.')"; return 1; }
}

username_available() {
    local name=$1 alias
    valid_username "$name" || { fail "$(ui_text 'Username must be 1-31 lowercase ASCII letters/digits/_/-, start with a letter, and not be reserved.' 'Username dài 1–31 ký tự ASCII thường/số/_/-, bắt đầu bằng chữ và không dùng tên dành riêng.')"; return 1; }
    for alias in "${USER_ALIASES[@]}"; do
        [ "$alias" != "$name" ] || { fail "$(ui_text "Account name or alias already exists: $name" "Tên hoặc bí danh tài khoản đã tồn tại: $name")"; return 1; }
    done
    [ ! -e "$DSLOCAL_PATH/users/$name.plist" ] && [ ! -L "$DSLOCAL_PATH/users/$name.plist" ] || {
        fail "$(ui_text 'A user record already exists at the destination.' 'Ổ đích đã có bản ghi tài khoản này.')"; return 1;
    }
    [ ! -e "$DATA_VOLUME/Users/$name" ] && [ ! -L "$DATA_VOLUME/Users/$name" ] || {
        fail "$(ui_text 'A home folder already exists; it will not be reused or overwritten.' 'Home đã tồn tại; không dùng lại hoặc ghi đè.')"; return 1;
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
    fail "$(ui_text 'No unused UID between 501 and 60000.' 'Không còn UID trống từ 501 đến 60000.')"
}

find_offline_admins() {
    local group="$DSLOCAL_PATH/groups/admin.plist" i guid
    ADMIN_NAMES=()
    [ -f "$group" ] && [ ! -L "$group" ] || { fail "$(ui_text 'Missing or symbolic-link admin group record.' 'Bản ghi nhóm admin thiếu hoặc là symlink.')"; return 1; }
    guid=$(plist_get "$group" :gid:0) && [ "$guid" = 80 ] &&
        plist_array_contains "$group" name admin || { fail "$(ui_text 'Invalid admin group record.' 'Bản ghi nhóm admin không hợp lệ.')"; return 1; }
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
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9._-]{0,254}$ ]] || { fail "$(ui_text 'Unsupported account record name.' 'Tên bản ghi tài khoản không được hỗ trợ.')"; return 1; }
    [[ "$expected_uid" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$expected_uid))" -ge 501 ] &&
        [ "$((10#$expected_uid))" -le 60000 ] || { fail "$(ui_text 'Not a normal local account UID.' 'UID không thuộc tài khoản cục bộ thông thường.')"; return 1; }
    [[ "$expected_guid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        fail "$(ui_text 'Invalid account GeneratedUID.' 'GeneratedUID của tài khoản không hợp lệ.')"; return 1;
    }
    record="$DSLOCAL_PATH/users/$name.plist"
    group="$DSLOCAL_PATH/groups/admin.plist"
    home="$DATA_VOLUME/Users/$name"
    [ -f "$record" ] && [ ! -L "$record" ] || { fail "$(ui_text 'User record is missing or is a symlink.' 'Bản ghi user bị thiếu hoặc là symlink.')"; return 1; }
    actual=$(plist_get "$record" :uid:0) && [ "$actual" = "$expected_uid" ] || { fail "$(ui_text 'UID verification failed.' 'Xác minh UID thất bại.')"; return 1; }
    actual=$(plist_get "$record" :generateduid:0) && uuid_equal "$actual" "$expected_guid" || { fail "$(ui_text 'GeneratedUID verification failed.' 'Xác minh GeneratedUID thất bại.')"; return 1; }
    actual=$(plist_get "$record" :name:0) && [ "$actual" = "$name" ] || { fail "$(ui_text 'Username verification failed.' 'Xác minh username thất bại.')"; return 1; }
    actual=$(plist_get "$record" :home:0) && [ "$actual" = "/Users/$name" ] || { fail "$(ui_text 'Home path verification failed.' 'Xác minh đường dẫn home thất bại.')"; return 1; }
    gid=$(plist_get "$record" :gid:0) && [[ "$gid" =~ ^[0-9]{1,10}$ ]] || { fail "$(ui_text 'Primary group verification failed.' 'Xác minh nhóm chính thất bại.')"; return 1; }
    [ "$strict" -ne 1 ] || [ "$gid" = 20 ] || { fail "$(ui_text 'New account must use the staff primary group.' 'Tài khoản mới phải dùng staff làm nhóm chính.')"; return 1; }
    # Never print or export password hashes.
    plist_get "$record" :ShadowHashData:0 >/dev/null || { fail "$(ui_text 'No local password hash was found.' 'Không tìm thấy password hash cục bộ.')"; return 1; }
    verify_admin_group "$name" "$expected_guid" "$strict" "$diagnostics" || return 1
    [ -d "$home" ] && [ ! -L "$home" ] || { fail "$(ui_text 'Home folder is missing or is a symlink.' 'Home bị thiếu hoặc là symlink.')"; return 1; }
    owner=$(stat -f '%u:%g' "$home") || return 1
    [ "$owner" = "$expected_uid:$gid" ] || { fail "$(ui_text "Unexpected home ownership: $owner" "Chủ sở hữu home khác dự kiến: $owner")"; return 1; }
    if [ "$strict" -eq 1 ]; then
        mode=$(stat -f '%Lp' "$home") || return 1
        [ "$mode" = 700 ] || { fail "$(ui_text 'New home permissions must be 700.' 'Quyền home mới phải là 700.')"; return 1; }
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
        fail "$(ui_text 'Full name must be nonempty and occupy one line.' 'Full name không được trống hoặc có nhiều dòng.')"; exit 1;
    }
    validate_offline_layout || exit 1
    lock="$DATA_VOLUME/private/var/db/.kaitiz-mdm-account.lock"
    mkdir "$lock" || { fail "$(ui_text "Another operation may be active. Inspect lock: $lock" "Có thể một tác vụ khác đang chạy. Kiểm tra khóa: $lock")"; exit 1; }
    rollback_account() {
        local status=$? failed=0 user_removed=0 group="$DSLOCAL_PATH/groups/admin.plist"
        trap - EXIT INT TERM
        if [ "$committed" -eq 0 ]; then
            if [ "$group_started" -eq 1 ]; then
                remove_created_group_value GroupMembership users "$name" || failed=1
                remove_created_group_value GroupMembers groupmembers "$guid" uuid || failed=1
            fi
            if [ "$record_started" -eq 1 ]; then
                if [ -e "$record" ] || [ -L "$record" ]; then
                    if offline_dscl -delete "/Users/$name"; then
                        if [ ! -e "$record" ] && [ ! -L "$record" ]; then user_removed=1; else failed=1; fi
                    else
                        failed=1
                    fi
                else
                    user_removed=1
                fi
            fi
            if [ "$home_created" -eq 1 ]; then
                if [ "$user_removed" -eq 1 ]; then
                    # Never recursively delete a home folder: it may now contain data.
                    rmdir "$home" || failed=1
                else
                    printf "$(ui_text 'Preserving home: user record deletion failed or was not confirmed: %s\n\n' 'Giữ lại home vì chưa xác nhận xóa được bản ghi user: %s\n\n')" "$home" >&2
                    failed=1
                fi
            fi
            if [ "$failed" -ne 0 ]; then
                printf "$(ui_text 'Rollback incomplete. Inspect account %s, home %s and backup %s before retrying.\n\n' 'Hoàn tác chưa đầy đủ. Kiểm tra user %s, home %s và bản sao lưu %s trước khi thử lại.\n\n')" "$name" "$home" "$backup" >&2
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
    [[ "$guid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || { fail "$(ui_text 'uuidgen returned an invalid identifier.' 'uuidgen trả về mã định danh không hợp lệ.')"; exit 1; }
    home="$DATA_VOLUME/Users/$name"
    record="$DSLOCAL_PATH/users/$name.plist"
    [ -d "$DATA_VOLUME/Users" ] && [ ! -L "$DATA_VOLUME/Users" ] && [ -w "$DATA_VOLUME/Users" ] || {
        fail "$(ui_text 'Missing, symbolic-link or unwritable Users directory.' 'Thư mục Users thiếu, là symlink hoặc không ghi được.')"; exit 1;
    }
    find_offline_admins || exit 1
    backup=$(mktemp -d "$DATA_VOLUME/private/var/db/kaitiz-mdm-backup.XXXXXX") || exit 1
    chmod 700 "$backup" || exit 1
    run_checked "$(ui_text 'Backing up admin group' 'Sao lưu nhóm admin')" cp -p "$DSLOCAL_PATH/groups/admin.plist" "$backup/admin.plist" || exit 1
    printf "$(ui_text 'Creating %s (UID %s). Group backup: %s\n\n' 'Đang tạo %s (UID %s). Bản sao lưu nhóm: %s\n\n')" "$name" "$uid" "$backup"
    record_started=1
    run_checked "$(ui_text 'Creating user record' 'Tạo bản ghi user')" offline_dscl -create "/Users/$name" || exit 1
    for attribute in UserShell RealName UniqueID PrimaryGroupID GeneratedUID NFSHomeDirectory; do
        case "$attribute" in
            UserShell) value=/bin/zsh;;
            RealName) value=$full_name;;
            UniqueID) value=$uid;;
            PrimaryGroupID) value=20;;
            GeneratedUID) value=$guid;;
            NFSHomeDirectory) value="/Users/$name";;
        esac
        run_checked "$(ui_text "Setting $attribute" "Đặt $attribute")" offline_dscl -create "/Users/$name" "$attribute" "$value" || exit 1
    done
    printf "$(ui_text 'Set the NEW account password at the dscl prompts. No default password is used.\n\n' 'Đặt mật khẩu tài khoản MỚI theo lời nhắc dscl. Không có mật khẩu mặc định.\n\n')"
    # Let dscl prompt securely; never put the password in argv or a shell variable.
    run_checked "$(ui_text 'Setting account password' 'Đặt mật khẩu tài khoản')" offline_dscl -passwd "/Users/$name" || exit 1
    plist_get "$record" :ShadowHashData:0 >/dev/null || { fail "$(ui_text 'Password hash was not created.' 'Chưa tạo được password hash.')"; exit 1; }
    run_checked "$(ui_text 'Creating home folder' 'Tạo thư mục home')" mkdir -m 700 "$home" || exit 1
    home_created=1
    run_checked "$(ui_text 'Setting home ownership' 'Đặt chủ sở hữu home')" chown "$uid:20" "$home" || exit 1
    run_checked "$(ui_text 'Setting home permissions' 'Đặt quyền home')" chmod 700 "$home" || exit 1
    group_started=1
    run_checked "$(ui_text 'Adding admin membership' 'Thêm thành viên nhóm admin')" offline_dscl -merge /Groups/admin GroupMembership "$name" || exit 1
    run_checked "$(ui_text 'Adding admin UUID' 'Thêm UUID vào nhóm admin')" offline_dscl -merge /Groups/admin GroupMembers "$guid" || exit 1
    verify_offline_admin "$name" "$uid" "$guid" 1 "$backup" || exit 1
    committed=1
    printf "$(ui_text 'Offline admin created: %s (%s).\n\n' 'Đã tạo admin ngoại tuyến: %s (%s).\n\n')" "$full_name" "$name"
    printf "$(ui_text 'Login, Secure Token and volume ownership have NOT been verified.\n\n' 'Chưa xác minh đăng nhập, Secure Token và volume ownership.\n\n')"
    printf "$(ui_text 'The empty home folder is owned by the new user; GUI template initialization is not reproduced.\n\n' 'Home rỗng thuộc user mới; chưa tái tạo đầy đủ bước khởi tạo của giao diện Apple.\n\n')"
)

choose_setup_language() {
    local choice
    SETUP_LANGUAGE=keep
    printf "$(ui_text '\nmacOS account language (separate from the script interface):\n1. English\n2. Vietnamese\n0. Keep current (Enter)\n' '\nNgôn ngữ tài khoản macOS (tách biệt với giao diện script):\n1. English\n2. Tiếng Việt\n0. Giữ nguyên (Enter)\n')"
    while true; do
        read_ui_input "$(ui_text 'Select macOS account language: ' 'Chọn ngôn ngữ: ')" choice || return 0
        case "$choice" in
            1) SETUP_LANGUAGE=en; return 0;;
            2) SETUP_LANGUAGE=vi; return 0;;
            0|'') return 0;;
            *) printf "$(ui_text 'Invalid selection.\n\n' 'Lựa chọn không hợp lệ.\n\n')";;
        esac
    done
}

# Write the target account's AppleLanguages before its first macOS login.
# Never run defaults -g in Recovery: that would affect the Recovery environment.
# Only the language array changes; region/date formats and other keys are kept.
set_offline_user_language() (
    language_user=$1 language_code=$2 language_stage= language_backup=
    [ "$language_code" != keep ] || exit 0
    case "$language_code" in en|vi) ;; *) fail "$(ui_text 'Unsupported language.' 'Ngôn ngữ không được hỗ trợ.')"; exit 1;; esac
    [[ "$language_user" =~ ^[A-Za-z][A-Za-z0-9._-]{0,254}$ ]] || { fail "$(ui_text 'Invalid username.' 'Username không hợp lệ.')"; exit 1; }
    validate_offline_layout || exit 1
    language_record="$DSLOCAL_PATH/users/$language_user.plist"
    [ -f "$language_record" ] && [ ! -L "$language_record" ] || { fail "$(ui_text 'No valid user record found.' 'Không có bản ghi user hợp lệ.')"; exit 1; }
    language_uid=$(plist_get "$language_record" :uid:0) &&
        [[ "$language_uid" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$language_uid))" -ge 501 ] && [ "$((10#$language_uid))" -le 60000 ] || exit 1
    language_gid=$(plist_get "$language_record" :gid:0) &&
        [[ "$language_gid" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$language_gid))" -le 4294967295 ] || exit 1
    [ "$(plist_get "$language_record" :name:0)" = "$language_user" ] &&
        [ "$(plist_get "$language_record" :home:0)" = "/Users/$language_user" ] || {
        fail "$(ui_text 'User record does not match the home path.' 'Bản ghi user không khớp đường dẫn home.')"; exit 1;
    }
    language_home="$DATA_VOLUME/Users/$language_user"
    [ -d "$language_home" ] && [ ! -L "$language_home" ] &&
        [ "$(cd "$language_home" && pwd -P)" = "$language_home" ] &&
        [ "$(stat -f '%u:%g' "$language_home")" = "$language_uid:$language_gid" ] || {
        fail "$(ui_text 'Invalid home or unexpected home ownership.' 'Home không hợp lệ hoặc có chủ sở hữu khác dự kiến.')"; exit 1;
    }
    for language_directory in "$language_home/Library" "$language_home/Library/Preferences"; do
        if [ -L "$language_directory" ]; then
            fail "$(ui_text "Refusing to write through symlink: $language_directory" "Không ghi qua symlink: $language_directory")"; exit 1
        elif [ -e "$language_directory" ]; then
            [ -d "$language_directory" ] || { fail "$(ui_text "Not a directory: $language_directory" "Không phải thư mục: $language_directory")"; exit 1; }
        else
            run_checked "$(ui_text 'Creating user preferences directory' 'Tạo thư mục tùy chọn của user')" mkdir -m 700 "$language_directory" || exit 1
            run_checked "$(ui_text 'Setting preferences directory ownership' 'Đặt chủ sở hữu thư mục tùy chọn')" chown "$language_uid:$language_gid" "$language_directory" || exit 1
        fi
    done
    language_preferences="$language_home/Library/Preferences/.GlobalPreferences.plist"
    [ ! -L "$language_preferences" ] &&
        { [ ! -e "$language_preferences" ] || [ -f "$language_preferences" ]; } || {
        fail "$(ui_text 'Unexpected language preferences file type.' 'File tùy chọn ngôn ngữ có kiểu không hợp lệ.')"; exit 1;
    }
    language_stage=$(mktemp "$language_home/Library/Preferences/.kaitiz-language.XXXXXX") || exit 1
    trap 'if [ -n "$language_stage" ]; then rm -f "$language_stage"; fi' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ -f "$language_preferences" ]; then
        run_checked "$(ui_text 'Copying existing preferences' 'Sao chép tùy chọn hiện có')" cp -p "$language_preferences" "$language_stage" || exit 1
        /usr/libexec/PlistBuddy -c Print "$language_stage" >/dev/null || { fail "$(ui_text 'Existing preferences file is not a valid plist.' 'File preferences hiện có không phải plist hợp lệ.')"; exit 1; }
    else
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict/></plist>' > "$language_stage" || {
            fail "$(ui_text 'Cannot initialize the language preferences plist.' 'Không tạo được plist ngôn ngữ ban đầu.')"; exit 1;
        }
    fi
    if plist_get "$language_stage" :AppleLanguages >/dev/null; then
        run_checked "$(ui_text 'Replacing language list' 'Thay danh sách ngôn ngữ')" /usr/libexec/PlistBuddy -c 'Delete :AppleLanguages' "$language_stage" || exit 1
    fi
    run_checked "$(ui_text 'Creating language list' 'Tạo danh sách ngôn ngữ')" /usr/libexec/PlistBuddy -c 'Add :AppleLanguages array' "$language_stage" || exit 1
    run_checked "$(ui_text 'Setting preferred language' 'Đặt ngôn ngữ ưu tiên')" /usr/libexec/PlistBuddy -c "Add :AppleLanguages:0 string $language_code" "$language_stage" || exit 1
    if [ "$language_code" = vi ]; then
        run_checked "$(ui_text 'Setting fallback language' 'Đặt ngôn ngữ dự phòng')" /usr/libexec/PlistBuddy -c 'Add :AppleLanguages:1 string en' "$language_stage" || exit 1
    fi
    [ "$(plist_get "$language_stage" :AppleLanguages:0)" = "$language_code" ] || { fail "$(ui_text 'Language verification failed.' 'Xác minh ngôn ngữ thất bại.')"; exit 1; }
    run_checked "$(ui_text 'Setting preferences file ownership' 'Đặt chủ sở hữu file tùy chọn')" chown "$language_uid:$language_gid" "$language_stage" || exit 1
    run_checked "$(ui_text 'Setting preferences file permissions' 'Đặt quyền file tùy chọn')" chmod 600 "$language_stage" || exit 1
    if [ -f "$language_preferences" ]; then
        language_backup=$(mktemp "$language_home/Library/Preferences/.GlobalPreferences.backup.XXXXXX") || exit 1
        run_checked "$(ui_text 'Backing up existing preferences' 'Sao lưu tùy chọn hiện có')" cp -p "$language_preferences" "$language_backup" || exit 1
        printf "$(ui_text 'Preferences backup: %s\n\n' 'Bản sao lưu tùy chọn: %s\n\n')" "$language_backup"
    fi
    run_checked "$(ui_text 'Saving target user language' 'Lưu ngôn ngữ cho user đích')" mv -f "$language_stage" "$language_preferences" || exit 1
    language_stage=
    printf "$(ui_text 'Language set for %s: %s. Applies at macOS login.\n\n' 'Đã đặt ngôn ngữ cho %s: %s. Áp dụng khi đăng nhập macOS.\n\n')" "$language_user" "$language_code"
)

finish_recovery_setup() {
    local name=$1 uid guid record
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9._-]{0,254}$ ]] || { fail "$(ui_text 'Unsupported account name.' 'Tên tài khoản không được hỗ trợ.')"; return 1; }
    record="$DSLOCAL_PATH/users/$name.plist"
    uid=$(plist_get "$record" :uid:0) && guid=$(plist_get "$record" :generateduid:0) || {
        fail "$(ui_text 'Cannot read selected account.' 'Không đọc được tài khoản đã chọn.')"; return 1;
    }
    verify_offline_admin "$name" "$uid" "$guid" || return 1
    [ -d "$PROFILE_SETTINGS" ] && [ -w "$PROFILE_SETTINGS" ] || {
        fail "$(ui_text "Missing or unwritable profile settings: $PROFILE_SETTINGS" "Thiết lập profile thiếu hoặc không ghi được: $PROFILE_SETTINGS")"; return 1;
    }
    [ ! -L "$DATA_VOLUME/private/var/db/.AppleSetupDone" ] &&
        { [ ! -e "$DATA_VOLUME/private/var/db/.AppleSetupDone" ] || [ -f "$DATA_VOLUME/private/var/db/.AppleSetupDone" ]; } || {
        fail "$(ui_text 'Unexpected .AppleSetupDone file type.' 'Kiểu file .AppleSetupDone không hợp lệ.')"; return 1;
    }
    # SetupDone is last: an earlier failure must not prematurely skip setup.
    update_profile_settings "$DATA_VOLUME" || return 1
    apply_hosts_for_context recovery || return 1
    choose_setup_language || return 1
    set_offline_user_language "$name" "$SETUP_LANGUAGE" || return 1
    run_checked "$(ui_text 'Updating setup marker' 'Cập nhật marker hoàn tất thiết lập')" touch "$DATA_VOLUME/private/var/db/.AppleSetupDone" || return 1
    printf "$(ui_text 'Setup marked complete. Restart manually and test login before disabling any existing account.\n\n' 'Đã đánh dấu hoàn tất. Khởi động lại thủ công và thử đăng nhập trước khi vô hiệu hóa tài khoản hiện có.\n\n')"
}

continue_recovery_setup() {
    local full_name username
    prepare_recovery_target || return 1
    load_offline_users && find_offline_admins || return 1
    printf "$(ui_text 'Create a new offline admin account.\n\n' 'Tạo tài khoản admin ngoại tuyến mới.\n\n')"
    read_ui_input "$(ui_text 'Full name (Unicode allowed): ' 'Tên hiển thị (cho phép tiếng Việt): ')" full_name || return 1
    read_ui_input "$(ui_text 'Username (lowercase ASCII, 1-31 characters): ' 'Username (ASCII thường, 1–31 ký tự): ')" username || return 1
    username_available "$username" || return 1
    create_offline_admin "$username" "$full_name" || return 1
    finish_recovery_setup "$username"
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
        fail "$(ui_text 'Cannot identify macOS/Recovery; no action performed.' 'Không xác định được môi trường macOS/Recovery; chưa thực hiện tác vụ.')"
        return 1
    fi
}

find_sysadminctl() {
    SYSADMINCTL=
    [ -x /usr/sbin/sysadminctl ] || {
        fail "$(ui_text 'Missing /usr/sbin/sysadminctl. Recovery must use the offline workflow; no account created or data changed.' 'Không có /usr/sbin/sysadminctl. Nếu đang ở Recovery, script phải nhận diện là Recovery; chưa tạo tài khoản hay sửa dữ liệu.')"
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
remove_profiles_noninteractive() {
    /usr/bin/yes y | as_admin profiles remove -all
    local removal_status=${PIPESTATUS[1]}
    return "$removal_status"
}

handle_notifications() {
    local removal_result=0 marker_result=0 hosts_result=0
    detect_environment || return 1
    case "$CURRENT_ENV" in
        recovery)
            printf "$(ui_text 'Environment: Recovery — working on the selected macOS volume.\n\n' 'Môi trường: Recovery — thao tác trên volume macOS được chọn.\n\n')"
            prepare_recovery_target || return 1
            update_profile_settings "$DATA_VOLUME" || marker_result=1
            apply_hosts_for_context recovery || hosts_result=1
            ;;
        macos)
            printf "$(ui_text 'Environment: macOS — working on the running installation.\n\n' 'Môi trường: macOS — thao tác trên hệ điều hành đang chạy.\n\n')"
            printf "$(ui_text 'Removing all removable configuration profiles, including any Wi-Fi/VPN settings they contain.\n\n' 'Gỡ mọi configuration profile có thể gỡ, gồm cả cấu hình Wi-Fi/VPN bên trong.\n\n')"
            run_checked "$(ui_text 'Removing configuration profiles' 'Gỡ configuration profiles')" remove_profiles_noninteractive || removal_result=1
            printf '\n'
            apply_hosts_for_context live || hosts_result=1
            ;;
    esac
    if [ "$removal_result:$marker_result:$hosts_result" != 0:0:0 ]; then
        fail "$(ui_text 'Some steps did not complete. Review the errors above; do not assume all profiles were removed.' 'Một số bước chưa hoàn tất. Xem lỗi ở trên; chưa kết luận đã gỡ hết profile.')"
        return 1
    fi
    printf "$(ui_text 'Local processing completed.\n' 'Đã xử lý xong trên máy.\n')"
    printf '\n'
}

show_hosts_auto() {
    detect_environment || return 1
    if [ "$CURRENT_ENV" = recovery ]; then
        if [ "${1:-}" != selected ]; then select_macos_data || return 1; fi
        run_checked "$(ui_text 'Reading hosts on selected volume' 'Đọc hosts trên ổ đã chọn')" cat "$HOSTS_FILE"
    else
        run_checked "$(ui_text 'Reading hosts on booted macOS' 'Đọc hosts của macOS đang chạy')" cat /private/etc/hosts
    fi
}

check_enrollment_auto() {
    local settings marker status_text status_rc config_text config_rc count
    detect_environment || return 1
    if [ "$CURRENT_ENV" = recovery ]; then
        if [ "${1:-}" != selected ]; then select_macos_data || return 1; fi
        printf '\n- Enrolled via DEP: Unknown\n- MDM enrollment: Unknown\n- Config profile: Offline (Recovery)\n\n'
        printf "$(ui_text '→ Conclusion: Cannot determine blocking effectiveness in Recovery.\n\n' '→ Kết luận: Chưa thể xác nhận hiệu quả chặn trong Recovery.\n\n')"
    else
        status_text=$(LC_ALL=C as_admin profiles status -type enrollment 2>&1); status_rc=$?
        config_text=$(LC_ALL=C as_admin profiles show -type enrollment 2>&1); config_rc=$?
        summarize_mdm_status "$status_text" "$status_rc" "$config_text" "$config_rc" /private/etc/hosts
        [ "$status_rc" -eq 0 ] || return 1

    fi
}

# Parse only the explicit native fields. Conflicting/unrecognized output stays
# unknown; command failures and cloud errors are never treated as unenrollment.
enrollment_field() {
    printf '%s\n' "$1" | awk -F: -v field="$2" '
        { key=tolower($1); gsub(/^[ \t]+|[ \t]+$/, "", key)
          if (key==field || (field=="enrolled via dep" && key=="enrolled via ade")) {
            v=tolower($2); sub(/^[ \t]+/, "", v)
            if(v ~ /^yes([ \t(]|$)/) nextvalue="yes"; else if(v ~ /^no([ \t(]|$)/) nextvalue="no"; else nextvalue="unknown"
            if(seen && value!=nextvalue) conflict=1; value=nextvalue;seen=1
          }
        } END { if(!seen || conflict) print "unknown"; else print value }'
}

blocked_host_count() {
    [ -f "$1" ] && [ -r "$1" ] || return 1
    awk '
        BEGIN { wanted["deviceenrollment.apple.com"]=1;wanted["mdmenrollment.apple.com"]=1;wanted["iprofiles.apple.com"]=1;wanted["acmdm.apple.com"]=1;wanted["axm-adm-mdm.apple.com"]=1 }
        { sub(/#.*/, ""); if($1=="0.0.0.0" || $1=="127.0.0.1" || $1=="::1")
            for(i=2;i<=NF;i++) if(tolower($i) in wanted) found[tolower($i)]=1 }
        END { for(k in found) count++; print count+0 }' "$1"
}

summarize_mdm_status() {
    local status_text=$1 status_rc=$2 config_text=$3 config_rc=$4 hosts=$5 mdm dep count config_state=unknown mdm_label dep_label config_label
    mdm=$(enrollment_field "$status_text" 'mdm enrollment')
    dep=$(enrollment_field "$status_text" 'enrolled via dep')
    [ "$status_rc" -eq 0 ] || { mdm=unknown; dep=unknown; }
    count=$(blocked_host_count "$hosts") || count=unknown
    if printf '%s\n' "$config_text" | grep -Eiq 'rate.?limit|too many requests|429|limit.*(23|24).*hours'; then
        config_state=limited
    elif printf '%s\n' "$config_text" | grep -Eiq 'cloud|device enrollment|DEP'; then
        if printf '%s\n' "$config_text" | grep -Eiq 'fail|error|unable|cannot'; then config_state=unavailable;
        elif [ "$config_rc" -eq 0 ] && [ -n "$config_text" ]; then config_state=available; fi
    elif [ "$config_rc" -eq 0 ] && [ -n "$config_text" ]; then config_state=available;
    fi
    case "$mdm" in yes) mdm_label=Yes;; no) mdm_label=No;; *) mdm_label=Unknown;; esac
    case "$dep" in yes) dep_label=Yes;; no) dep_label=No;; *) dep_label=Unknown;; esac
    case "$config_state" in
        unavailable) config_label='Fail to request configuration from cloud';;
        available) config_label='Retrieved (possibly cached)';;
        limited) config_label='Rate limited';;
        *) config_label='Unknown / query failed';;
    esac
    printf '\n- Enrolled via DEP: %s\n- MDM enrollment: %s\n- Config profile: %s\n\n' "$dep_label" "$mdm_label" "$config_label"
    if [ "$mdm" = yes ]; then
        printf "$(ui_text '→ Conclusion: Not blocked completely — MDM is still enrolled.\n\n' '→ Kết luận: Chưa chặn hoàn toàn — máy vẫn enrolled MDM.\n\n')"
    elif [ "$mdm" = no ] && [ "$config_state" = unavailable ] && [ "$count" = 5 ]; then
        printf "$(ui_text '→ Conclusion: Local blocking appears effective based on these checks.\n\n' '→ Kết luận: Chặn cục bộ có dấu hiệu thành công theo kết quả kiểm tra.\n\n')"
    else
        printf "$(ui_text '→ Conclusion: Blocking success is not confirmed.\n\n' '→ Kết luận: Chưa đủ cơ sở xác nhận chặn thành công.\n\n')"
    fi
}

handle_inspection_menu() {
    local inspection_choice pause
    while true; do
        clear_screen
        credit
        printf "$(ui_text '\n1. View MDM notification blocking status\n\n2. View hosts file\n\n0. Back\n' '\n1. Xem trạng thái chặn thông báo MDM\n\n2. Xem file hosts\n\n0. Quay lại\n')"
        read_menu_choice "$(ui_text 'Select an option:' 'Chọn chức năng:')" inspection_choice || return 0
        [ "$inspection_choice" != 0 ] || return 0
        clear_screen
        credit
        printf '\n'
        case "$inspection_choice" in
            1) check_enrollment_auto;;
            2) show_hosts_auto;;
            *) fail "$(ui_text 'Invalid selection.' 'Lựa chọn không hợp lệ.')";;
        esac
        printf '\n'
        read_ui_input "$(ui_text 'Press Enter to return...' 'Nhấn Enter để quay lại...')" pause || return 0
    done
}

interactive_input() { [ -t 0 ]; }

reboot_countdown() {
    local seconds reply input_status
    REBOOT_CANCELLED=0
    if ! interactive_input; then
        REBOOT_CANCELLED=1
        return 0
    fi
    printf '\n=============================================\n\n'
    for ((seconds=10; seconds>0; seconds--)); do
        printf '\r\033[K'
        printf "$(ui_text 'Restarting in %s seconds. Press Enter to cancel.' 'Khởi động lại sau %s giây. Nhấn Enter để hủy.')" "$seconds"
        if read -r -t 1 reply; then
            printf '\n\n'
            REBOOT_CANCELLED=1
            return 0
        else
            input_status=$?
            if [ "$input_status" -le 128 ]; then
                printf '\n'
                REBOOT_CANCELLED=1
                return 0
            fi
        fi
    done
    printf '\n\n'
    run_checked "$(ui_text 'Restarting' 'Khởi động lại')" as_admin /sbin/reboot
}

create_admin_auto() {
    detect_environment || return 1
    if [ "$CURRENT_ENV" = recovery ]; then
        continue_recovery_setup || return 1
        reboot_countdown
    else
        fail "$(ui_text 'This action is only available in Recovery. Restart into macOS Recovery, open Terminal, and run the script again.' 'Chức năng này chỉ chạy trong Recovery. Hãy khởi động vào macOS Recovery, mở Terminal và chạy lại script.')"
        return 1
    fi
}

credit() {
    echo '============================================='
    echo '             MDM Tools by Kaitiz'
    echo '============================================='
    echo ''
    if detect_environment; then
        case "$CURRENT_ENV" in
            recovery) echo "$(ui_text 'Environment: Recovery' 'Môi trường: Recovery')";;
            macos) echo "$(ui_text 'Environment: macOS' 'Môi trường: macOS')";;
        esac
    else
        echo "$(ui_text 'Environment: unknown — actions will be refused.' 'Môi trường: không xác định — các tác vụ sẽ bị từ chối.')"
    fi
}

show_menu() {
    credit
    echo ''
    echo "$(ui_text '1. Create an Admin account and automatically bypass MDM (Recovery)' '1. Tạo tài khoản quyền Admin và bypass MDM tự động (Recovery)')"
    echo ''
    echo "$(ui_text '2. Reapply MDM bypass and handle notifications' '2. Bypass lại và xử lý thông báo MDM')"
    echo ''
    echo "$(ui_text '3. Check MDM status and hosts file' '3. Kiểm tra trạng thái MDM và file hosts')"
    echo ''
    echo "$(ui_text '0. Exit' '0. Thoát')"
    echo ''
}

handle_choice() {
    case "$1" in
        1) create_admin_auto;;
        2) handle_notifications;;
        3) handle_inspection_menu;;
        *) fail "$(ui_text 'Invalid selection.' 'Lựa chọn không hợp lệ.')";;
    esac
}

check_live_user() {
    local name=$1
    detect_environment || return 1
    [ "$CURRENT_ENV" = macos ] || { fail "$(ui_text 'Run --check-user after booting into the installed macOS.' 'Chạy --check-user sau khi khởi động vào macOS đã cài.')"; return 1; }
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9._-]{0,254}$ ]] || { fail "$(ui_text 'Invalid account name.' 'Tên tài khoản không hợp lệ.')"; return 1; }
    find_sysadminctl || return 1
    printf "$(ui_text 'Read-only diagnostics for the currently booted macOS: %s\n\n' 'Báo cáo chỉ đọc trên macOS đang chạy: %s\n\n')" "$name"
    run_checked "$(ui_text 'Reading user identity' 'Đọc danh tính user')" id "$name" || return 1
    run_checked "$(ui_text 'Reading user UUID' 'Đọc UUID của user')" dscl . -read "/Users/$name" GeneratedUID || return 1
    run_checked "$(ui_text 'Reading admin membership' 'Đọc thành viên nhóm admin')" dsmemberutil checkmembership -U "$name" -G admin || return 1
    run_checked "$(ui_text 'Reading Secure Token status' 'Đọc trạng thái Secure Token')" "$SYSADMINCTL" -secureTokenStatus "$name" || return 1
    printf "$(ui_text 'Match the GeneratedUID above with a Volume Owner entry below:\n\n' 'Đối chiếu GeneratedUID ở trên với Volume Owner ở dưới:\n\n')"
    run_checked "$(ui_text 'Reading APFS users' 'Đọc danh sách user APFS')" diskutil apfs listUsers / || return 1
    printf "$(ui_text 'These reports do not test password login or FileVault unlock. Review their contents; exit status alone is insufficient.\n\n' 'Báo cáo không thử mật khẩu đăng nhập hoặc mở khóa FileVault. Cần đọc nội dung thay vì chỉ dựa vào mã thoát.\n\n')"
}

main() {
    case "${1:-}" in
        --environment)
            detect_environment || return 1
            printf "$(ui_text 'Environment: %s\n\n' 'Môi trường: %s\n\n')" "$CURRENT_ENV"
            return 0;;
        --detect)
            # Read-only discovery: no changes to the selected installation.
            select_macos_data
            return $?;;
        --check-user)
            [ "$#" -eq 2 ] || { fail "$(ui_text 'Usage: bash mdm1.sh --check-user USER' 'Cách dùng: bash mdm1.sh --check-user USER')"; return 1; }
            check_live_user "$2"
            return $?;;
        --help|-h)
            printf "$(ui_text 'Usage: bash mdm1.sh [--environment | --detect | --check-user USER | --help]\n\n' 'Cách dùng: bash mdm1.sh [--environment | --detect | --check-user USER | --help]\n\n')"
            printf "$(ui_text 'Unlock/mount the macOS Data volume in Disk Utility first.\n\n' 'Mở khóa/mount volume Data của macOS bằng Disk Utility trước.\n\n')"
            printf '%s\n' "$(ui_text '--environment reports the detected environment without changing the installation.' '--environment hiển thị môi trường nhận diện được, không sửa bản macOS.')"
            printf '%s\n' "$(ui_text '--detect only lists/selects a mounted macOS Data volume.' '--detect chỉ liệt kê/chọn volume Data macOS đã mount.')"
            printf '%s\n' "$(ui_text '--check-user USER prints account/token/APFS reports in the installed macOS.' '--check-user USER in báo cáo tài khoản/token/APFS trong macOS đã cài.')"
            return 0;;
        '') ;;
        *) fail "$(ui_text "Unknown option: $1" "Tùy chọn không hợp lệ: $1")"; return 1;;
    esac
    select_ui_language || return 0
    while true; do
        clear_screen
        show_menu
        read_menu_choice "$(ui_text 'Select an option:' 'Chọn chức năng:')" choice || break
        [ "$choice" != 0 ] || { printf "$(ui_text 'Exited.\n\n' 'Đã thoát.\n\n')"; break; }
        if [ "$choice" = 3 ]; then handle_inspection_menu; continue; fi
        clear_screen
        credit
        printf '\n'
        handle_choice "$choice"
        if [ "${REBOOT_CANCELLED:-0}" = 1 ]; then REBOOT_CANCELLED=0; continue; fi
        printf '\n\n'
        read_ui_input "$(ui_text 'Press Enter to return to the menu...' 'Nhấn Enter để quay lại menu...')" menu_return || break
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
