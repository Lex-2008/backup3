#!/bin/busybox ash
#
# Main backup script.
#
# Note: this script should be executed by shell which understands variable
# replacement like this: "${varname//a/n}" (it's x2 faster then calling external
# tool like this: "$(echo "$varname" | sed 's/a/b/g')".
# Also, we use busybox because it has mkdir and ln built-ins

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_LIST"    && BACKUP_LIST=$BACKUP_ROOT/files.txt
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_RSYNC_LOGS" && BACKUP_RSYNC_LOGS=$BACKUP_ROOT/rsync.logs
test -z "$BACKUP_FIND_FILTER" # this is fine
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_DB_BAK"  && BACKUP_DB_BAK=backup.db
test -n "$BACKUP_TIME"    && BACKUP_TIME="$(date -d "$BACKUP_TIME" +"%F %H:%M")"
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"%F %H:%M")"

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is another copy of this script running
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

### RSYNC ###

# run rsync to backup from $1 to $2, with $3 extra arguments
run_rsync()
{
	when="$1"
	to="$2"
	from="$3"
	shift 3
	logfile="$BACKUP_RSYNC_LOGS/$to"
	case "$when" in
		( hourly )	date_fmt="%F %H" ;;
		( daily )	date_fmt="%F" ;;
		( weekly )	date_fmt="%Y %W" ;;
		( monthly )	date_fmt="%Y-%m" ;;
		( * )    	date_fmt="%F %T" ;;
	esac
	# test if we need to run it at all - or not enough time had passed
	test -f "$logfile" -a "$(date -r "$logfile" +"$date_fmt")" = "$(date -d "$BACKUP_TIME" +"$date_fmt")" && return 0
	# test if we can connect
	timeout rsync "$@" "$from" >/dev/null 2>&1 || return 0
	rsync -a --itemize-changes --human-readable --stats --fake-super --delete --one-file-system "$@" "$from" "$BACKUP_CURRENT/$to" >"$logfile"
}

# run
command -v run_this >/dev/null && run_this

if test "$BACKUP_DB_BAK" != "no"; then
	# Update inode of backup.db backup
	touch "$BACKUP_CURRENT/$BACKUP_DB_BAK.new"
	mv "$BACKUP_CURRENT/$BACKUP_DB_BAK.new" "$BACKUP_CURRENT/$BACKUP_DB_BAK"
fi

### DIFF ###

# listing all files together with their inodes currently in backup dir
# note that here we use "real" find, because the busybox one doesn't have "-printf"
/usr/bin/find "$BACKUP_CURRENT" $BACKUP_FIND_FILTER \( -type f -o -type l \) -printf '%i %P\n' | sort -k 2 >"$BACKUP_LIST".new

# comparing this list to its previous version
/usr/bin/diff -N "$BACKUP_LIST" "$BACKUP_LIST".new | sed '/^[<>]/!d;s/^\(.\) [0-9]*/\1/;s/^>/N/;s/^</D/' | sort -k 2 -k 1 >"$BACKUP_LIST".diff

mv "$BACKUP_LIST".new "$BACKUP_LIST"
touch -d "$BACKUP_TIME" "$BACKUP_LIST"

### BACKUP ###

this_month="$(date -d "$BACKUP_TIME" +"%Y-%m")"
this_week="$(date -d "$BACKUP_TIME" +"%Y %W")"
today="$(date -d "$BACKUP_TIME" +"%F")"
this_hour="$(date -d "$BACKUP_TIME" +"%F %H")"

cat "$BACKUP_LIST".diff | (
	echo ".timeout 10000"
	echo "BEGIN TRANSACTION;"
	while read change fullname; do
		# escape vars for DB
		clean_fullname="${fullname//'/''}"
		clean_dirname="${clean_fullname%/*}"
		test "$clean_dirname" = "$clean_fullname" && clean_dirname=""
		clean_filename="${clean_fullname##*/}"
		case "$change" in
			( N ) # New file
				echo "INSERT INTO history (dirname, filename, created, deleted, freq) VALUES ('$clean_dirname', '$clean_filename', '$BACKUP_TIME', '9999-01-01 00:00', 0);"
				mkdir -p "$BACKUP_MAIN/$fullname"
				ln "$BACKUP_CURRENT/$fullname" "$BACKUP_MAIN/$fullname/$BACKUP_TIME"
				;;
			( D ) # Deleted
				echo "UPDATE history
					SET
						deleted = '$BACKUP_TIME',
						freq = CASE
							WHEN created < '$this_month' THEN 1
							WHEN strftime('%Y %W', created) < '$this_week' THEN 5
							WHEN created < '$today' THEN 30
							WHEN created < '$this_hour' THEN 720
							ELSE 8640
						END
					WHERE dirname = '$clean_dirname'
					AND filename = '$clean_filename'
					AND freq = 0;"
				;;
		esac
	done
	echo "END TRANSACTION;"
) | $SQLITE

### Database backup ###

if test "$BACKUP_DB_BAK" != "no"; then
	# Backup database
	mkdir -p "$BACKUP_MAIN/$BACKUP_DB_BAK"
	backup_db_backup="$BACKUP_MAIN/$BACKUP_DB_BAK/$BACKUP_TIME"
	rm "$backup_db_backup"
	$SQLITE ".backup '$backup_db_backup'"
fi
