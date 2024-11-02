#!/usr/bin/env bash
set -euo pipefail

APPNAME=$(basename "$0" | sed "s/\.sh$//")

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------
fn_check_rsync_3_is_available() {
	local has_rsync
	has_rsync=$(which rsync >/dev/null 2>&1 && echo true || echo false)
	if [[ "$has_rsync" != "true" ]]; then
		echo "This machine doesn't appear to have rsync installed. Aborting."
		exit 1
	fi

	local rsync_version
	rsync_version=$(rsync --version | grep version | sed 's/protocol.*//' | sed 's/[^0-9.]//g')
	local min_rsync_version="3.0.0"
	if [[ $(printf "%s\n" "$rsync_version" "$min_rsync_version" | sort -V | head -n 1) != "$min_rsync_version" ]]; then
		echo "This script requires rsync version >= $min_rsync_version. Found: $rsync_version. Aborting."
		exit 1
	fi
}
fn_check_rsync_3_is_available

# -----------------------------------------------------------------------------
# Log functions
# -----------------------------------------------------------------------------

fn_log_info()  { echo "$APPNAME: $1"; }

fn_log_warn()  { echo "$APPNAME: [WARNING] $1" 1>&2; }

fn_log_error() { echo "$APPNAME: [ERROR] $1" 1>&2; }

fn_log_info_cmd()  {
	if [ -n "$SSH_DEST_FOLDER_PREFIX" ]; then
		echo "$APPNAME: $SSH_CMD '$1'";
	else
		echo "$APPNAME: $1";
	fi
}

# -----------------------------------------------------------------------------
# Make sure everything really stops when CTRL+C is pressed
# -----------------------------------------------------------------------------

fn_terminate_script() {
	fn_log_info "SIGINT caught."
	exit 1
}

trap 'fn_terminate_script' SIGINT

# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------
fn_display_usage() {
	echo "Usage: $(basename "$0") [OPTION]... <[USER@HOST:]SOURCE> <[USER@HOST:]DESTINATION>"
	echo ""
	echo "Options"
	echo " -h, --help                 Display this help message."
	echo " -y, --yes                  If backup destination directory doesn't exist, or isn't marked for backup,"
	echo "                            automatically create the directory (\`mkdir -p\`) and mark it as backup"
	echo "                            destination."
	echo " -x, --exclude-from=        Path to an exclusion patterns file to be passed to rsync --exclude-from "
	echo "                            value."
	echo " -p, --ssh-port=            rsync ssh port to be used."
	echo " -i, --ssh-identity-file=   rsync ssh key to be used."
	echo " -s, --strategy=            Set the expiration strategy. Default: \"1:1 30:7 365:30\" means after one"
	echo "                            day, keep one backup per day. After 30 days, keep one backup every 7 days."
	echo "                            After 365 days keep one backup every 30 days."
	echo " --no-auto-expire           Disable automatically deleting backups when out of space. Instead an error"
	echo "                            is logged, and the backup is aborted."
	echo " --log-dir=                 Set the log file directory. If this flag is set, generated files will"
	echo "                            not be managed by the script - in particular they will not be"
	echo "                            automatically deleted."
	echo "                            Default: $LOG_DIR"
	echo " --rsync-get-flags          Display the default rsync flags that are used for backup. If using remote"
	echo "                            drive over SSH, --compress will be added."
	echo " --rsync-set-flags=         Set the rsync flags that are going to be used for backup."
	echo " --rsync-append-flags=      Append the rsync flags that are going to be used for backup."
	echo " --ssh-get-flags            Display the default ssh flags that are used by the ssh client."
	echo " --ssh-set-flags=           Set the ssh flags that are going to be used by the ssh client."
	echo " --ssh-append-flags=        Append ssh flags that are going to be used by the ssh client."
	echo ""
	echo "For more detailed help, please see the README file:"
	echo ""
	echo "https://github.com/drez3000/timba/blob/master/README.md"
}

fn_parse_date() {
	# Converts YYYY-MM-DD-HHMMSS to YYYY-MM-DD HH:MM:SS and then to Unix Epoch.
	case "$OSTYPE" in
		linux*|cygwin*|netbsd*)
			date -d "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}" +%s ;;
		FreeBSD*) date -j -f "%Y-%m-%d-%H%M%S" "$1" "+%s" ;;
		darwin*)
			# Under MacOS X Tiger
			# Or with GNU 'coreutils' installed (by homebrew)
			#   'date -j' doesn't work, so we do this:
			yy=${1:0:4}
			mm=$(( ${1:5:2} - 1 ))
			dd=${1:8:2}
			hh=${1:11:2}
			mi=${1:13:2}
			ss=${1:15:2}

			perl -e 'use Time::Local; print timelocal('"$ss"','"$mi"','"$hh"','"$dd"','"$mm"','"$yy"'),"\n";' ;;
	esac
}

fn_find_backups() {
	fn_run_cmd_dest "find \"$DEST_FOLDER/\" -maxdepth 1 -type d -name \"????-??-??-??????\" -prune | sort -r"
}

fn_expire_backup() {
	# Double-check that we're on a backup destination to be completely
	# sure we're deleting the right folder
	if [ -z "$(fn_find_backup_marker "$(dirname -- "$1")")" ]; then
		fn_log_error "$1 is not on a backup destination - aborting."
		exit 1
	fi

	fn_log_info "Expiring $1"
	fn_rm_dir "$1"
}

fn_expire_backups() {
	local current_timestamp=$EPOCH
	local last_kept_timestamp=9999999999

	# we will keep requested backup
	backup_to_keep="$1"
	# we will also keep the oldest backup
	oldest_backup_to_keep="$(fn_find_backups | sort | sed -n '1p')"

	# Process each backup dir from the oldest to the most recent
	for backup_dir in $(fn_find_backups | sort); do

		local backup_date
		local backup_timestamp
		backup_date=$(basename "$backup_dir")
		backup_timestamp=$(fn_parse_date "$backup_date")

		# Skip if failed to parse date...
		if [ -z "$backup_timestamp" ]; then
			fn_log_warn "Could not parse date: $backup_dir"
			continue
		fi

		if [ "$backup_dir" == "$backup_to_keep" ]; then
			# this is the latest backup requsted to be kept. We can finish pruning
			break
		fi

		if [ "$backup_dir" == "$oldest_backup_to_keep" ]; then
			# We dont't want to delete the oldest backup. It becomes first "last kept" backup
			last_kept_timestamp=$backup_timestamp
			# As we keep it we can skip processing it and go to the next oldest one in the loop
			continue
		fi

		# Find which strategy token applies to this particular backup
		for strategy_token in $(echo "$EXPIRATION_STRATEGY" | tr " " "\n" | sort -r -n); do
			IFS=':' read -r -a t <<< "$strategy_token"

			# After which date (relative to today) this token applies (X) - we use seconds to get exact cut off time
			local cut_off_timestamp
			cut_off_timestamp=$((current_timestamp - t[0] * 86400))

			# Every how many days should a backup be kept past the cut off date (Y) - we use days (not seconds)
			local cut_off_interval_days
			cut_off_interval_days=$((t[1]))

			# If we've found the strategy token that applies to this backup
			if [ "$backup_timestamp" -le "$cut_off_timestamp" ]; then

				# Special case: if Y is "0" we delete every time
				if [ $cut_off_interval_days -eq "0" ]; then
					fn_expire_backup "$backup_dir"
					break
				fi

				# we calculate days number since last kept backup
				local last_kept_timestamp_days
				local backup_timestamp_days
				local interval_since_last_kept_days
				last_kept_timestamp_days=$((last_kept_timestamp / 86400))
				backup_timestamp_days=$((backup_timestamp / 86400))
				interval_since_last_kept_days=$((backup_timestamp_days - last_kept_timestamp_days))

				# Check if the current backup is in the interval between
				# the last backup that was kept and Y
				# to determine what to keep/delete we use days difference
				if [ "$interval_since_last_kept_days" -lt "$cut_off_interval_days" ]; then

					# Yes: Delete that one
					fn_expire_backup "$backup_dir"
					# backup deleted no point to check shorter timespan strategies - go to the next backup
					break

				else

					# No: Keep it.
					# this is now the last kept backup
					last_kept_timestamp=$backup_timestamp
					# and go to the next backup
					break
				fi
			fi
		done
	done
}

fn_parse_ssh() {
	# To keep compatibility with bash version < 3, we use grep
	if echo "$DEST_FOLDER"|grep -Eq '^[A-Za-z0-9\._%\+\-]+@[A-Za-z0-9.\-]+\:.+$'
	then
		SSH_USER=$(echo "$DEST_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\1/')
		SSH_HOST=$(echo "$DEST_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\2/')
		SSH_DEST_FOLDER=$(echo "$DEST_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\3/')
		if [ -n "$SSH_IDENTITY" ] ; then
			SSH_CMD="ssh -p $SSH_PORT -i $SSH_IDENTITY $SSH_FLAGS ${SSH_USER}@${SSH_HOST}"
		else
			SSH_CMD="ssh -p $SSH_PORT $SSH_FLAGS ${SSH_USER}@${SSH_HOST}"
		fi
		SSH_DEST_FOLDER_PREFIX="${SSH_USER}@${SSH_HOST}:"
	elif echo "$SRC_FOLDER"|grep -Eq '^[A-Za-z0-9\._%\+\-]+@[A-Za-z0-9.\-]+\:.+$'
	then
		SSH_USER=$(echo "$SRC_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\1/')
		SSH_HOST=$(echo "$SRC_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\2/')
		SSH_SRC_FOLDER=$(echo "$SRC_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\3/')
		if [ -n "$SSH_IDENTITY" ] ; then
			SSH_CMD="ssh -p $SSH_PORT -i $SSH_IDENTITY $SSH_FLAGS ${SSH_USER}@${SSH_HOST}"
		else
			SSH_CMD="ssh -p $SSH_PORT $SSH_FLAGS ${SSH_USER}@${SSH_HOST}"
		fi
		SSH_SRC_FOLDER_PREFIX="${SSH_USER}@${SSH_HOST}:"
	fi
}

fn_run_cmd_dest() {
	if [ -n "$SSH_DEST_FOLDER_PREFIX" ]
	then
		eval "$SSH_CMD '$1'"
	else
		eval "$1"
	fi
}

fn_run_cmd_src() {
	if [ -n "$SSH_SRC_FOLDER_PREFIX" ]
	then
		eval "$SSH_CMD '$1'"
	else
		eval "$1"
	fi
}

fn_find() {
	fn_run_cmd_dest "find '$1'"  2>/dev/null
}

fn_get_absolute_path() {
	fn_run_cmd_dest "cd '$1';pwd"
}

fn_get_xdg_log_dir () {
	# https://specifications.freedesktop.org/basedir-spec/0.8/#variables
	state_home=${XDG_STATE_HOME:-"${HOME}/.local/share"}
	echo "${state_home}/${APPNAME}/log"
}

fn_mkdir() {
	fn_run_cmd_dest "mkdir -p -- '$1'"
}

# Removes a file or symlink - not for directories
fn_rm_file() {
	fn_run_cmd_dest "rm -f -- '$1'"
}

fn_rm_dir() {
	fn_run_cmd_dest "rm -rf -- '$1'"
}

fn_touch() {
	fn_run_cmd_dest "touch -- '$1'"
}

fn_ln() {
	fn_run_cmd_dest "ln -s -- '$1' '$2'"
}

fn_test_file_exists_src() {
	fn_run_cmd_src "test -e '$1'"
}

fn_df_t_src() {
	fn_run_cmd_src "df -T '${1}'"
}

fn_df_t() {
	fn_run_cmd_dest "df -T '${1}'"
}

# -----------------------------------------------------------------------------
# Source and destination information
# -----------------------------------------------------------------------------
SSH_USER=""
SSH_HOST=""
SSH_PORT="22"
SSH_IDENTITY=""
SSH_DEST_FOLDER=""
SSH_SRC_FOLDER=""
SSH_DEST_FOLDER_PREFIX=""
SSH_SRC_FOLDER_PREFIX=""
SSH_CMD=""

SRC_FOLDER=""
DEST_FOLDER=""
EXCLUDE_FROM=""
LOG_DIR=$(fn_get_xdg_log_dir)
AUTO_DELETE_LOG=1
EXPIRATION_STRATEGY="1:1 30:7 365:30"
AUTO_EXPIRE=1
CREATE_BACKUP_DIR=0

RSYNC_FLAGS="-D --numeric-ids --links --hard-links --one-file-system --itemize-changes --times --recursive --perms --owner --group --stats --human-readable"
SSH_FLAGS=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|-\?|--help)
			fn_display_usage
			exit
			;;
		-y|--yes)
			CREATE_BACKUP_DIR=1
			shift
			;;
		-x)
			shift
			EXCLUDE_FROM="$1"
			shift
			;;
		--exclude-from=*)
			EXCLUDE_FROM="${1#*=}"
			shift
			;;
		-s)
			shift
			EXPIRATION_STRATEGY="$1"
			shift
			;;
		--strategy=*)
			EXPIRATION_STRATEGY="${1#*=}"
			shift
			;;
		-p)
			shift
			SSH_PORT="$1"
			shift
			;;
		--ssh-port=*)
			SSH_PORT="${1#*=}"
			shift
			;;
		-i)
			shift
			SSH_IDENTITY="$1"
			shift
			;;
		--ssh-identity-file=*)
			SSH_IDENTITY="${1#*=}"
			shift
			;;
		--ssh-get-flags)
			echo "$SSH_FLAGS"
			# shift
			exit
			;;
		--ssh-set-flags=*)
			SSH_FLAGS="${1#*=}"
			shift
			;;
		--ssh-append-flags=*)
			SSH_FLAGS="$SSH_FLAGS ${1#*=}"
			shift
			;;
		--rsync-get-flags)
			echo "$RSYNC_FLAGS"
			# shift
			exit
			;;
		--rsync-set-flags=*)
			RSYNC_FLAGS="${1#*=}"
			shift
			;;
		--rsync-append-flags=*)
			RSYNC_FLAGS="$RSYNC_FLAGS ${1#*=}"
			shift
			;;
		--log-dir=*)
			LOG_DIR="${1#*=}"
			AUTO_DELETE_LOG=0
			shift
			;;
		--no-auto-expire)
			AUTO_EXPIRE=0
			shift
			;;
		--)
			shift
			SRC_FOLDER="$1"
			DEST_FOLDER="$2"
			break
			;;
		-*)
			fn_log_error "Unknown option: \"$1\""
			fn_log_info ""
			fn_display_usage
			exit 1
			;;
		*)
			if [[ -z "$SRC_FOLDER" ]]; then
				SRC_FOLDER="$1"
			elif [[ -z "$DEST_FOLDER" ]]; then
				DEST_FOLDER="$1"
			else
				fn_log_error "Too many positional arguments."
				fn_log_info ""
				fn_display_usage
				exit 1
			fi
			shift
			;;
	esac
done

# Display usage information if required arguments are not passed
if [[ -z "$SRC_FOLDER" || -z "$DEST_FOLDER" ]]; then
	fn_display_usage
	exit 1
fi

# Strips off last slash from dest. Note that it means the root folder "/"
# will be represented as an empty string "", which is fine
# with the current script (since a "/" is added when needed)
# but still something to keep in mind.
# However, due to this behavior we delay stripping the last slash for
# the source folder until after parsing for ssh usage.

DEST_FOLDER="${DEST_FOLDER%/}"

fn_parse_ssh

if [ -n "$SSH_DEST_FOLDER" ]; then
	DEST_FOLDER="$SSH_DEST_FOLDER"
fi

if [ -n "$SSH_SRC_FOLDER" ]; then
	SRC_FOLDER="$SSH_SRC_FOLDER"
fi

# Exit if source folder does not exist.
if ! fn_test_file_exists_src "${SRC_FOLDER}"; then
	fn_log_error "Source folder \"${SRC_FOLDER}\" does not exist - aborting."
	exit 1
fi

# Now strip off last slash from source folder.
SRC_FOLDER="${SRC_FOLDER%/}"

for ARG in "$SRC_FOLDER" "$DEST_FOLDER" "$EXCLUDE_FROM"; do
	if [[ "$ARG" == *"'"* ]]; then
		fn_log_error 'Source and destination directories may not contain single quote characters.'
		exit 1
	fi
done

# -----------------------------------------------------------------------------
# Check that the destination drive is a backup drive
# -----------------------------------------------------------------------------

# TODO: check that the destination supports hard links

fn_backup_marker_path() { echo "$1/backup.marker"; }
fn_find_backup_marker() { fn_find "$(fn_backup_marker_path \""$1"\")" 2>/dev/null; }

MARKER_PATH=$(fn_backup_marker_path "$DEST_FOLDER" || true)
MARKER_FOUND=$(fn_find_backup_marker "$DEST_FOLDER" || true)
if [[ -z "$MARKER_FOUND" && "$CREATE_BACKUP_DIR" == 0 ]]; then
	fn_log_info "Safety check failed - the destination does not appear to be a backup folder or drive (marker file not found)."
	fn_log_info "If it is indeed a backup folder, you may run this command again adding the --yes flag,"
	fn_log_info "or manually add the marker file with:"
	fn_log_info ""
	fn_log_info_cmd "mkdir -p -- \"$DEST_FOLDER\" ; touch \"$MARKER_PATH\""
	fn_log_info ""
	exit 1
elif [[ -z "$MARKER_FOUND" && "$CREATE_BACKUP_DIR" == 1 ]]; then
	fn_run_cmd_dest "mkdir -p -- \"$DEST_FOLDER\""
	fn_run_cmd_dest "touch \"$MARKER_PATH\""
fi

# Check source and destination file-system (df -T /dest).
# If one of them is FAT, use the --modify-window rsync parameter
# (see man rsync) with a value of 1 or 2.
#
# The check is performed by taking the second row
# of the output of the first command.
if [[ "$(fn_df_t_src "${SRC_FOLDER}" | awk '{print $2}' | grep -c -i -e "fat")" -gt 0 ]]; then
	fn_log_info "Source file-system is a version of FAT."
	fn_log_info "Using the --modify-window rsync parameter with value 2."
	RSYNC_FLAGS="${RSYNC_FLAGS} --modify-window=2"
elif [[ "$(fn_df_t "${DEST_FOLDER}" | awk '{print $2}' | grep -c -i -e "fat")" -gt 0 ]]; then
	fn_log_info "Destination file-system is a version of FAT."
	fn_log_info "Using the --modify-window rsync parameter with value 2."
	RSYNC_FLAGS="${RSYNC_FLAGS} --modify-window=2"
fi

# -----------------------------------------------------------------------------
# Setup additional variables
# -----------------------------------------------------------------------------

# Date logic
NOW=$(date +"%Y-%m-%d-%H%M%S")
EPOCH=$(date "+%s")

export IFS=$'\n' # Better for handling spaces in filenames.
DEST="$DEST_FOLDER/$NOW"
PREVIOUS_DEST="$(fn_find_backups | head -n 1)"
INPROGRESS_FILE="$DEST_FOLDER/backup.inprogress"
MYPID="$$"

# -----------------------------------------------------------------------------
# Create log folder if it doesn't exist
# -----------------------------------------------------------------------------

if [ ! -d "$LOG_DIR" ]; then
	fn_log_info "Creating log folder in '$LOG_DIR'..."
	mkdir -p "$LOG_DIR"
fi

# -----------------------------------------------------------------------------
# Handle case where a previous backup failed or was interrupted.
# -----------------------------------------------------------------------------

if [ -n "$(fn_find "$INPROGRESS_FILE")" ]; then
	if [ "$OSTYPE" == "cygwin" ]; then
		# 1. Grab the PID of previous run from the PID file
		RUNNINGPID="$(fn_run_cmd_dest "cat $INPROGRESS_FILE")"

		# 2. Get the command for the process currently running under that PID and look for our script name
		RUNNINGCMD="$(procps -wwfo cmd -p "$RUNNINGPID" --no-headers | grep "$APPNAME")"

		# 3. Grab the exit code from grep (0=found, 1=not found)
		GREPCODE=$?

		# 4. if found, assume backup is still running
		if [ "$GREPCODE" = 0 ]; then
			fn_log_error "Previous backup task is still active - aborting (command: $RUNNINGCMD)."
			exit 1
		fi
	elif [[ "$OSTYPE" == "netbsd"* ]]; then
		RUNNINGPID="$(fn_run_cmd_dest "cat $INPROGRESS_FILE")"
		if ps -axp "$RUNNINGPID" -o "command" | grep "$APPNAME" > /dev/null; then
			fn_log_error "Previous backup task is still active - aborting."
			exit 1
		fi
	else
		RUNNINGPID="$(fn_run_cmd_dest "cat $INPROGRESS_FILE")"
		if ps -p "$RUNNINGPID" -o command | grep "$APPNAME"
		then
			fn_log_error "Previous backup task is still active - aborting."
			exit 1
		fi
	fi

	if [ -n "$PREVIOUS_DEST" ]; then
		# - Last backup is moved to current backup folder so that it can be resumed.
		# - 2nd to last backup becomes last backup.
		fn_log_info "$SSH_DEST_FOLDER_PREFIX$INPROGRESS_FILE already exists - the previous backup failed or was interrupted. Backup will resume from there."
		fn_run_cmd_dest "mv -- $PREVIOUS_DEST $DEST"
		if [ "$(fn_find_backups | wc -l)" -gt 1 ]; then
			PREVIOUS_DEST="$(fn_find_backups | sed -n '2p')"
		else
			PREVIOUS_DEST=""
		fi
		# update PID to current process to avoid multiple concurrent resumes
		fn_run_cmd_dest "echo $MYPID > $INPROGRESS_FILE"
	fi
fi

# Run in a loop to handle the "No space left on device" logic.
while : ; do

	# -----------------------------------------------------------------------------
	# Check if we are doing an incremental backup (if previous backup exists).
	# -----------------------------------------------------------------------------

	LINK_DEST_OPTION=""
	if [ -z "$PREVIOUS_DEST" ]; then
		fn_log_info "No previous backup - creating new one."
	else
		# If the path is relative, it needs to be relative to the destination. To keep
		# it simple, just use an absolute path. See http://serverfault.com/a/210058/118679
		PREVIOUS_DEST="$(fn_get_absolute_path "$PREVIOUS_DEST")"
		fn_log_info "Previous backup found - doing incremental backup from $SSH_DEST_FOLDER_PREFIX$PREVIOUS_DEST"
		LINK_DEST_OPTION="--link-dest='$PREVIOUS_DEST'"
	fi

	# -----------------------------------------------------------------------------
	# Create destination folder if it doesn't already exists
	# -----------------------------------------------------------------------------

	if [ -z "$(fn_find "$DEST -type d" 2>/dev/null)" ]; then
		fn_log_info "Creating destination $SSH_DEST_FOLDER_PREFIX$DEST"
		fn_mkdir "$DEST"
	fi

	# -----------------------------------------------------------------------------
	# Purge certain old backups before beginning new backup.
	# -----------------------------------------------------------------------------

	if [ -n "$PREVIOUS_DEST" ]; then
		# regardless of expiry strategy keep backup used for --link-dest
		fn_expire_backups "$PREVIOUS_DEST"
	else
		# keep latest backup
		fn_expire_backups "$DEST"
	fi

	# -----------------------------------------------------------------------------
	# Start backup
	# -----------------------------------------------------------------------------

	EXIT_CODE=0
	NO_SPACE_LEFT=0
	LOG_FILE="$LOG_DIR/$(date +"%Y-%m-%d-%H%M%S").log"

	fn_log_info "Starting backup..."
	fn_log_info "From: $SSH_SRC_FOLDER_PREFIX$SRC_FOLDER/"
	fn_log_info "To:   $SSH_DEST_FOLDER_PREFIX$DEST/"

	CMD="rsync"
	if [ -n "$SSH_CMD" ]; then
		RSYNC_FLAGS="$RSYNC_FLAGS --compress"
		if [ -n "$SSH_IDENTITY" ] ; then
			CMD="$CMD -e 'ssh -p $SSH_PORT -i $SSH_IDENTITY $SSH_FLAGS'"
		else
			CMD="$CMD -e 'ssh -p $SSH_PORT $SSH_FLAGS'"
		fi
	fi
	CMD="$CMD $RSYNC_FLAGS"
	CMD="$CMD --log-file '$LOG_FILE'"
	if [ -n "$EXCLUDE_FROM" ]; then
		# We've already checked that $EXCLUDE_FROM doesn't contain a single quote
		CMD="$CMD --exclude-from '$EXCLUDE_FROM'"
	fi
	CMD="$CMD $LINK_DEST_OPTION"
	CMD="$CMD -- '$SSH_SRC_FOLDER_PREFIX$SRC_FOLDER/' '$SSH_DEST_FOLDER_PREFIX$DEST/'"

	# -----------------------------------------------------------------------------
	# Run rsync
	# -----------------------------------------------------------------------------

	if [[ "$EXIT_CODE" != 1 && "$NO_SPACE_LEFT" == 0 ]]; then
		fn_log_info "Running command:"
		fn_log_info "$CMD"
		fn_run_cmd_dest "echo $MYPID > $INPROGRESS_FILE"
		eval "$CMD"
	fi

	# -----------------------------------------------------------------------------
	# Check if we ran out of space
	# -----------------------------------------------------------------------------

	no_space_logged=$(cat "$LOG_FILE" | grep "No space left on device (28)\|Result too large (34)" || true)
	if [[ -n "$no_space_logged" ]]; then
		NO_SPACE_LEFT=1
	fi
	if [[ "$EXIT_CODE" != 1 && "$NO_SPACE_LEFT" == 1 ]]; then

		if [[ "$AUTO_EXPIRE" == 0 ]]; then
			fn_log_error "No space left on device, and automatic purging of old backups is disabled."
			exit 1
		fi

		fn_log_warn "No space left on device - removing oldest backup and resuming."

		if [[ "$(fn_find_backups | wc -l)" -lt "2" ]]; then
			fn_log_error "No space left on device, and no old backup to delete."
			exit 1
		fi

		fn_expire_backup "$(fn_find_backups | tail -n 1)"

		# Resume backup
		continue
	fi

	# -----------------------------------------------------------------------------
	# Check whether rsync reported any errors
	# -----------------------------------------------------------------------------

	if grep -q "rsync error:" "$LOG_FILE"; then
		fn_log_error "Rsync reported an error. Run this command for more details: grep -E 'rsync:|rsync error:' '$LOG_FILE'"
		EXIT_CODE=1
	elif grep -q "rsync:" "$LOG_FILE"; then
		fn_log_warn "Rsync reported a warning. Run this command for more details: grep -E 'rsync:|rsync error:' '$LOG_FILE'"
		EXIT_CODE=1
	else
		fn_log_info "Backup completed without errors."
		if [[ "$AUTO_DELETE_LOG" == 1 ]]; then
			rm -f -- "$LOG_FILE"
		fi
	fi

	# -----------------------------------------------------------------------------
	# Add symlink to last backup
	# -----------------------------------------------------------------------------

	if [[ "$EXIT_CODE" == 0 ]]; then
		# Create the latest symlink only when rsync succeeded
		fn_rm_file "$DEST_FOLDER/latest"
		fn_ln "$(basename -- "$DEST")" "$DEST_FOLDER/latest"

		# Remove .inprogress file only when rsync succeeded
		fn_rm_file "$INPROGRESS_FILE"
	fi

	exit $EXIT_CODE
done