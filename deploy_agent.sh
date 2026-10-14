#!/usr/bin/env bash
# Deploys, runs and archives the Student Attendance Tracker.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Please run this script with bash: bash deploy_agent.sh (or ./deploy_agent.sh)" >&2
    exit 1
fi

set -u

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$BASE_DIR/templates"
PREFIX="attendance_tracker_"
ROSTER_HEADER="Email,Names,Attendance Count,Absence Count"

# Names for option B. 11 x 10 lists -> 110 unique first/last pairs.
FIRST_NAMES=(Aline Brian Claudine David Esther Fabrice Grace Herve Ines Jean Kevin)
LAST_NAMES=(Uwase Mugisha Niyonzima Ishimwe Habimana Mukamana Nshuti Iradukunda Kamanzi Tuyisenge)

DEPLOYING=no
CREATED_DIR=no
PROJECT_NAME=""
PROJECT_DIR=""

# Output and input helpers

if [ -t 1 ]; then
    RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m'
    BOLD=$'\033[1m' RESET=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

info()   { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()     { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2; }
header() { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RESET"; }

die() {
    error "$*"
    if [ "$DEPLOYING" = yes ]; then
        trap '' INT TSTP
        DEPLOYING=no
        save_partial_project
    fi
    exit 1
}

ask() {
    if ! IFS= read -r -p "$2" "$1"; then
        echo
        [ "$DEPLOYING" = yes ] && on_deploy_interrupt "end of input (Ctrl+D)" 1
        die "No more input - exiting."
    fi
}

ask_yes_no() {
    local reply
    while :; do
        ask reply "$1"
        case "$reply" in
            [Yy] | [Yy][Ee][Ss]) return 0 ;;
            [Nn] | [Nn][Oo]) return 1 ;;
        esac
        warn "Please answer y or n."
    done
}

is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ ${#1} -le 9 ]
}

ask_number() {
    local reply
    while :; do
        ask reply "$2"
        [ -z "$reply" ] && [ $# -ge 5 ] && reply=$5
        if is_number "$reply" && [ $((10#$reply)) -ge "$3" ] && [ $((10#$reply)) -le "$4" ]; then
            printf -v "$1" '%d' "$((10#$reply))"
            return 0
        fi
        warn "Please enter a whole number from $3 to $4."
    done
}

is_valid_name() {
    case "$1" in
        '' | *[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

json_number() {
    sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p" "$2" | head -n 1
}

# -i.bak so it works with both Linux and macOS sed
set_json_number() {
    sed -i.bak -E "s/(\"$1\"[[:space:]]*:[[:space:]]*)[0-9]+/\1$2/" "$3" && rm -f "$3.bak"
}

file_mode() {
    ls -ld "$1" | awk '{ print substr($1, 1, 10) }'
}

# Signal handling (Feature 1 only)

save_partial_project() {
    [ "$CREATED_DIR" = yes ] && [ -d "$PROJECT_DIR" ] || return 1

    local zip_file="${PROJECT_NAME}_archive.zip"
    rm -f "$BASE_DIR/$zip_file"
    if ! (cd "$BASE_DIR" && zip -rq "$zip_file" "$PROJECT_NAME"); then
        error "Could not create $zip_file - leaving $PROJECT_NAME/ in place for inspection."
        return 0
    fi
    ok "Incomplete project archived to $zip_file:"
    (cd "$BASE_DIR" && zip -sf "$zip_file" | sed -n 's/^  /         /p')

    rm -rf "$PROJECT_DIR"
    CREATED_DIR=no
    ok "Removed the incomplete $PROJECT_NAME/ directory."
}

on_deploy_interrupt() {
    trap '' INT TSTP    # don't let a second Ctrl+C stop the cleanup
    DEPLOYING=no
    echo
    warn "Deployment interrupted by $1 - the project was not finished."
    save_partial_project || info "No project files had been created yet, so there is nothing to archive."
    info "Deployment session closed."
    exit "$2"
}

enable_deploy_traps() {
    DEPLOYING=yes
    trap 'on_deploy_interrupt "Ctrl+C (SIGINT)" 130' INT
    trap "on_deploy_interrupt 'Ctrl+Z (SIGTSTP)' $((128 + $(kill -l TSTP)))" TSTP
}

disable_deploy_traps() {
    DEPLOYING=no
    trap - INT TSTP
}

# Feature 1: deploy

preflight_checks() {
    header "Step 1/6: Pre-flight checks"
    local failed=0 file

    if command -v python3 >/dev/null 2>&1; then
        ok "python3 found: $(python3 --version 2>&1)"
    else
        error "python3 is not installed (Ubuntu: sudo apt install python3)."
        failed=1
    fi
    if command -v zip >/dev/null 2>&1; then
        ok "zip found: $(command -v zip)"
    else
        error "zip is not installed (Ubuntu: sudo apt install zip)."
        failed=1
    fi
    for file in attendance_checker.py assets.csv config.json; do
        if [ -f "$TEMPLATES_DIR/$file" ]; then
            ok "templates/$file found"
        else
            error "templates/$file is missing."
            failed=1
        fi
    done

    [ "$failed" -eq 0 ] || die "Pre-flight checks failed - fix the items above and run the script again."
}

choose_project_name() {
    header "Step 2/6: Name the project"
    local name
    while :; do
        ask name "Project name (creates ${PREFIX}<name>/, e.g. v1): "
        name=${name#"$PREFIX"}
        is_valid_name "$name" && break
        warn "Use letters, numbers, '-' or '_' only."
    done
    PROJECT_NAME="$PREFIX$name"
    PROJECT_DIR="$BASE_DIR/$PROJECT_NAME"

    if [ -e "$PROJECT_DIR" ]; then
        warn "$PROJECT_NAME/ already exists."
        if ask_yes_no "Overwrite it? Everything inside will be deleted [y/n]: "; then
            rm -rf "$PROJECT_DIR" || die "Could not remove the existing $PROJECT_NAME/."
            info "Removed the old $PROJECT_NAME/."
        else
            die "Deployment aborted: $PROJECT_NAME/ already exists and was left untouched."
        fi
    fi

    mkdir -p "$PROJECT_DIR/Helpers" "$PROJECT_DIR/reports" || die "Could not create $PROJECT_NAME/."
    CREATED_DIR=yes
    ok "Created $PROJECT_NAME/ with Helpers/ and reports/"
}

generate_roster() {
    local count=$1 file=$2 i first last email
    local n_first=${#FIRST_NAMES[@]} n_last=${#LAST_NAMES[@]}

    echo "$ROSTER_HEADER" > "$file"
    for ((i = 0; i < count; i++)); do
        first=${FIRST_NAMES[i % n_first]}
        last=${LAST_NAMES[i % n_last]}
        email=$(echo "$first.$last@example.com" | tr '[:upper:]' '[:lower:]')
        echo "$email,$first $last,0,0" >> "$file"
    done
}

populate_files() {
    header "Step 3/6: Populate the files"
    local roster="$PROJECT_DIR/Helpers/assets.csv"
    local config="$PROJECT_DIR/Helpers/config.json"
    local template_rows=$(awk 'END { print NR - 1 }' "$TEMPLATES_DIR/assets.csv")
    local max_generated=$((${#FIRST_NAMES[@]} * ${#LAST_NAMES[@]}))
    local choice count

    cp "$TEMPLATES_DIR/attendance_checker.py" "$PROJECT_DIR/" &&
        cp "$TEMPLATES_DIR/config.json" "$config" ||
        die "Could not copy the template files."
    ok "Copied attendance_checker.py and Helpers/config.json from templates/"

    echo "How should Helpers/assets.csv be built?"
    echo "  A) Copy students from templates/assets.csv ($template_rows available, 4 prior sessions each)"
    echo "  B) Generate a fresh roster (attendance and absence counts start at 0)"
    while :; do
        ask choice "Choose A or B: "
        case "$choice" in
            [Aa])
                ask_number count "How many students to copy (1-$template_rows)? " 1 "$template_rows"
                head -n $((count + 1)) "$TEMPLATES_DIR/assets.csv" > "$roster" || die "Could not write the roster."
                ok "Copied the header + $count student row(s) from templates/assets.csv"
                ok "total_sessions stays at $(json_number total_sessions "$config") (4 prior sessions + today)"
                break
                ;;
            [Bb])
                ask_number count "How many students to generate (1-$max_generated)? " 1 "$max_generated"
                generate_roster "$count" "$roster" || die "Could not write the roster."
                set_json_number total_sessions 1 "$config" || die "Could not update total_sessions."
                ok "Generated $count new student row(s) in Helpers/assets.csv"
                ok "total_sessions set to $(json_number total_sessions "$config") (a fresh roster starts at session one)"
                break
                ;;
        esac
        warn "Please type A or B."
    done
}

set_permissions() {
    header "Step 4/6: Set permissions"
    chmod +x "$PROJECT_DIR/attendance_checker.py" || die "chmod failed on attendance_checker.py."
    chmod 600 "$PROJECT_DIR/Helpers/config.json" || die "chmod failed on Helpers/config.json."
    ok "$(file_mode "$PROJECT_DIR/attendance_checker.py")  attendance_checker.py  (executable)"
    ok "$(file_mode "$PROJECT_DIR/Helpers/config.json")  Helpers/config.json    (owner read/write only)"
}

update_thresholds() {
    header "Step 5/6: Attendance alert thresholds"
    local config="$PROJECT_DIR/Helpers/config.json"
    local warning failure

    info "Current values: warning = $(json_number warning "$config")%, failure = $(json_number failure "$config")%"
    if ! ask_yes_no "Update the alert thresholds? [y/n]: "; then
        info "Keeping the current thresholds."
        return 0
    fi

    while :; do
        ask_number warning "Warning threshold in % (Enter = 75): " 0 100 75
        ask_number failure "Failure threshold in % (Enter = 50): " 0 100 50
        [ "$failure" -lt "$warning" ] && break
        warn "The failure threshold must be lower than the warning threshold - please try again."
    done

    set_json_number warning "$warning" "$config" &&
        set_json_number failure "$failure" "$config" ||
        die "sed could not update config.json."
    chmod 600 "$config"
    ok "Updated Helpers/config.json in place:"
    grep -E '"(warning|failure)"' "$config"
}

verify_deployment() {
    header "Step 6/6: Verify the deployment"
    local roster="$PROJECT_DIR/Helpers/assets.csv"
    local config="$PROJECT_DIR/Helpers/config.json"

    check_structure "$PROJECT_DIR" || die "The deployed structure is incomplete."
    python3 -m json.tool "$config" >/dev/null || die "Helpers/config.json is not valid JSON."
    ok "Helpers/config.json is valid JSON"
    ok "Roster: $(awk 'END { print NR - 1 }' "$roster") students; prior sessions per student:" \
        "$(awk -F, 'NR > 1 { print $3 + $4 }' "$roster" | sort -u | paste -sd, -)" \
        "| total_sessions = $(json_number total_sessions "$config")"
    echo "Deployed structure:"
    (cd "$BASE_DIR" && find "$PROJECT_NAME" | sort | sed 's/^/    /')
}

deploy_project() {
    header "Feature 1: Deploy the application"
    CREATED_DIR=no
    PROJECT_NAME=""
    PROJECT_DIR=""
    enable_deploy_traps

    preflight_checks
    choose_project_name
    populate_files
    set_permissions
    update_thresholds
    verify_deployment

    disable_deploy_traps
    ok "Deployment of $PROJECT_NAME/ finished. Starting the app to confirm it works..."
    run_app "$PROJECT_DIR"
}

# ---- Feature 2: run ----

check_structure() {
    local dir=$1 missing=0 item
    for item in attendance_checker.py Helpers/assets.csv Helpers/config.json reports/; do
        if [ -e "$dir/$item" ]; then
            ok "found $item"
        else
            error "missing $item"
            missing=1
        fi
    done
    return "$missing"
}

run_app() {
    local dir=$1 name=${1##*/} status
    header "Feature 2: Run the application ($name)"
    command -v python3 >/dev/null 2>&1 || { error "python3 is not installed."; return 1; }
    check_structure "$dir" >/dev/null || {
        error "$name/ is not a complete deployment - deploy it again with Feature 1."
        return 1
    }

    info "Launching: cd $name && python3 attendance_checker.py"
    info "Ctrl+C inside the app stops marking early; students already marked are kept."
    # Ctrl+C goes to the python app here; the script just waits for it to finish
    trap ':' INT
    (cd "$dir" && exec python3 attendance_checker.py)
    status=$?
    trap - INT

    case $status in
        0) ok "Marking session completed - the app started and ran successfully." ;;
        130) warn "Marking session interrupted - results for students already marked were saved." ;;
        *) error "attendance_checker.py stopped with exit status $status (see its message above)." ;;
    esac

    if [ -f "$dir/reports/attendance.log" ] || [ -f "$dir/reports/absent.log" ]; then
        ask_yes_no "Archive the session logs now (Feature 3)? [y/n]: " && archive_logs "$dir"
    fi
    return "$status"
}

# ---- Feature 3: archive ----

archive_logs() {
    local dir=$1 stamp log src dest archived=0
    header "Feature 3: Archive the log files (${dir##*/})"
    stamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$dir/archives/attendance" "$dir/archives/absent" || {
        error "Could not create the archives/ directories."
        return 1
    }

    for log in attendance absent; do
        src="$dir/reports/$log.log"
        dest="$dir/archives/$log/${log}_$stamp.log"
        if [ ! -f "$src" ]; then
            if [ "$log" = absent ]; then
                warn "reports/absent.log not found - nobody was marked absent since the last archive. Skipped."
            else
                warn "reports/attendance.log not found - no students were marked since the last archive. Skipped."
            fi
        elif [ -e "$dest" ]; then
            warn "${dest#"$BASE_DIR"/} already exists - skipped reports/$log.log."
        elif mv "$src" "$dest"; then
            ok "Archived reports/$log.log -> ${dest#"$BASE_DIR"/}"
            archived=$((archived + 1))
        else
            error "Could not move reports/$log.log."
        fi
    done

    if [ "$archived" -eq 0 ]; then
        info "No logs were archived."
    else
        info "$archived log(s) archived. reports/ is ready for the next session."
    fi
}

# ---- Choosing a deployed project (Features 2 and 3) ----

list_projects() {
    local dir found=no
    for dir in "$BASE_DIR/$PREFIX"*/; do
        [ -d "$dir" ] || continue
        [ "$found" = no ] && echo "Deployed projects:"
        found=yes
        dir=${dir%/}
        echo "  - ${dir##*/"$PREFIX"}"
    done
    [ "$found" = yes ]
}

select_project() {
    local name=${1:-}
    if [ -z "$name" ]; then
        list_projects || { error "No deployed projects found - run Feature 1 (deploy) first."; return 1; }
        ask name "Project name (the part after ${PREFIX}): "
    fi
    name=${name#"$PREFIX"}
    if ! is_valid_name "$name" || [ ! -d "$BASE_DIR/$PREFIX$name" ]; then
        error "There is no project called $PREFIX$name/ - run Feature 1 (deploy) first."
        return 1
    fi
    SELECTED_DIR="$BASE_DIR/$PREFIX$name"
}

run_feature() { select_project "${1:-}" && run_app "$SELECTED_DIR"; }
archive_feature() { select_project "${1:-}" && archive_logs "$SELECTED_DIR"; }

# ---- Entry point ----

usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [name]

With no command, an interactive menu is shown. Commands:
  deploy           Feature 1 - create ${PREFIX}<name>/ and run it
  run [name]       Feature 2 - run attendance_checker.py in ${PREFIX}<name>/
  archive [name]   Feature 3 - archive reports/*.log with a timestamp
  help             show this message
EOF
}

show_menu() {
    local choice
    while :; do
        printf '\n%s===== Attendance Tracker Deploy Agent =====%s\n' "$BOLD" "$RESET"
        echo "  1) Deploy a new project (then run it)"
        echo "  2) Run the attendance checker"
        echo "  3) Archive the log files"
        echo "  4) Exit"
        ask choice "Choose an option [1-4]: "
        case "$choice" in
            1) deploy_project ;;
            2) run_feature ;;
            3) archive_feature ;;
            4 | [Qq]) echo "Goodbye."; exit 0 ;;
            *) warn "Please choose 1, 2, 3 or 4." ;;
        esac
    done
}

case "${1:-}" in
    "") show_menu ;;
    deploy) deploy_project ;;
    run) run_feature "${2:-}" ;;
    archive) archive_feature "${2:-}" ;;
    help | -h | --help) usage ;;
    *) usage >&2; exit 1 ;;
esac
