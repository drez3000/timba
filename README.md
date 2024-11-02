# Timba: cross-platform incremental backups with rsync

This script offers Time Machine-style backup using rsync. It creates incremental backups of files and directories to the destination of your choice. The backups are structured in a way that makes it easy to recover any file at any point in time.

It works on Linux, macOS and Windows (via WSL or Cygwin). The main advantage over Time Machine is the flexibility as it can backup from/to any filesystem and works on any platform. You can also backup, for example, to a Truecrypt drive without any problem.

On macOS, it has a few disadvantages compared to Time Machine - in particular it does not auto-start when the backup drive is plugged (though it can be achieved using a launch agent), it requires some knowledge of the command line, and no specific GUI is provided to restore files. Instead files can be restored by using any file explorer, including Finder, or the command line.

## Installation

	git clone https://github.com/drez3000/timba

## Usage

	Usage: timba.sh [OPTION]... <[USER@HOST:]SOURCE> <[USER@HOST:]DESTINATION>
	
	Options
	 -h, --help                 Display this help message.
	 -y, --yes                  If backup destination directory doesn't exist, or isn't marked for backup,
	                            automatically create the directory (`mkdir -p`) and mark it as backup
	                            destination.
	 -x, --exclude-from=        Path to an exclusion patterns file to be passed to rsync --exclude-from 
	                            value.
	 -p, --ssh-port=            rsync ssh port to be used.
	 -i, --ssh-identity-file=   rsync ssh key to be used.
	 -s, --strategy=            Set the expiration strategy. Default: "1:1 30:7 365:30" means after one
	                            day, keep one backup per day. After 30 days, keep one backup every 7 days.
	                            After 365 days keep one backup every 30 days.
	 --no-auto-expire           Disable automatically deleting backups when out of space. Instead an error
	                            is logged, and the backup is aborted.
	 --log-dir=                 Set the log file directory. If this flag is set, generated files will
	                            not be managed by the script - in particular they will not be
	                            automatically deleted.
	                            Default: $LOG_DIR
	 --rsync-get-flags          Display the default rsync flags that are used for backup. If using remote
	                            drive over SSH, --compress will be added.
	 --rsync-set-flags=         Set the rsync flags that are going to be used for backup.
	 --rsync-append-flags=      Append the rsync flags that are going to be used for backup.
	 --ssh-get-flags            Display the default ssh flags that are used by the ssh client.
	 --ssh-set-flags=           Set the ssh flags that are going to be used by the ssh client.
	 --ssh-append-flags=        Append ssh flags that are going to be used by the ssh client.

## Features

* Each backup is on its own folder named after the current timestamp. Files can be copied and restored directly, without any intermediate tool.

* Backup to/from remote destinations over SSH.

* Files that haven't changed from one backup to the next are hard-linked to the previous backup so take very little extra space.

* Safety check - the backup will only happen if the destination has explicitly been marked as a backup destination.

* Resume feature - if a backup has failed or was interrupted, the tool will resume from there on the next backup.

* Exclude file - support for pattern-based exclusion via the `--exclude-from` rsync parameter.

* Automatically purge old backups unless told otherwise - within 24 hours, all backups are kept. Within one month, the most recent backup for each day is kept. For all previous backups, the most recent of each month is kept.

* "latest" symlink that points to the latest successful backup.

## Changes from rsync-time-backup

* Adheres to the machine SSH settings with no silent overrides. Overrides can be added explicitly with `--ssh-append-flags=`.

* `--exclude-from=` is an option.

* Parses arguments before options and vice-versa, eg. `timba a b --no-auto-expire` and `timba --no-auto-expire a b` both work.

* Long form options for non-boolean values, eg. `--exclude-from=/path/to/exclusions/file` use an "=" suffix.

* Short form options use a space suffix, eg. `-x /path/to/exclusions/file`.

* All `rsync-time-backup` options are supported, but naming may be different (see [usage](#Usage)).

* Default log directory is chosen according to the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/0.8/#variables).

* Script is formatted with [shellcheck](https://github.com/koalaman/shellcheck).

## Examples

* Backup the home folder to backup_drive
	
		timba.sh /home /mnt/backup_drive

* Backup with exclusion list:
	
		timba.sh --exclude-from=excluded_patterns.txt /home /mnt/backup_drive

* Backup to remote drive over SSH, on port 2222:

		timba.sh -p 2222 /home user@example.com:/mnt/backup_drive

* Backup from remote drive over SSH:

		timba.sh user@example.com:/home /mnt/backup_drive

* To mimic Time Machine's behaviour, a cron script can be setup to backup at regular interval. For example, the following cron job checks if the drive "/mnt/backup" is currently connected and, if it is, starts the backup. It does this check every 1 hour.
		
		0 */1 * * * if grep -qs /mnt/backup /proc/mounts; then timba.sh /home /mnt/backup; fi

## Backup expiration logic

Backup sets are automatically deleted following a simple expiration strategy defined with the `--strategy` flag. This strategy is a series of time intervals with each item being defined as `x:y`, which means "after x days, keep one backup every y days". The default strategy is `1:1 30:7 365:30`, which means:

- After **1** day, keep one backup every **1** day (**1:1**).
- After **30** days, keep one backup every **7** days (**30:7**).
- After **365** days, keep one backup every **30** days (**365:30**).

Before the first interval (i.e. by default within the first 24h) it is implied that all backup sets are kept. Additionally, if the backup destination directory is full, the oldest backups are deleted until enough space is available.

## Exclusion file

An optional exclude file can be provided with the option `--exclude-from=`. It should be compatible with the `--exclude-from` parameter of rsync. See [this tutorial](https://web.archive.org/web/20230126121643/https://sites.google.com/site/rsync2u/home/rsync-tutorial/the-exclude-from-option) for more information.

## Built-in lock

The script is designed so that only one backup operation can be active for a given directory. If a new backup operation is started while another is still active (i.e. it has not finished yet), the new one will be automaticalled interrupted. Thanks to this the use of `flock` to run the script is not necessary.

## Rsync options

To display the rsync options that are used for backup, run `./timba.sh --rsync-get-flags`. It is also possible to add or remove options using the `--rsync-append-flags` or `--rsync-set-flags` option. For example, to exclude backing up permissions and groups:

	timba.sh --rsync-append-flags="--no-perms --no-group" /src /dest

## No automatic backup expiration

An option to disable the default behaviour to purge old backups when out of space. This option is set with the `--no-auto-expire` flag.

## How to restore

The script creates a backup in a regular directory so you can simply copy the files back to the original directory. You could do that with something like `rsync -aP /path/to/last/backup/ /path/to/restore/to/`. Consider using the `--dry-run` option to check what exactly is going to be copied. Use `--delete` if you also want to delete files that exist in the destination but not in the backup (obviously extra care must be taken when using this option).

## TODO

* Add `--whole-file` arguments on Windows? See http://superuser.com/a/905415/73619
* check that the destination supports hard links (see TODO comment in the source)

## LICENSE

This open source project is released under the MIT license. See the LICENSE file for details.
