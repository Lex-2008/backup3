#!/bin/bash
#
# Main backup script.
#
# Note: this is *bash* script due to 2x speed improvements that variable
# replacement like this: "${varname//a/n}" gives us over calling external
# tool like this: "$(echo "$varname" | sed 's/a/b/g')".
# Also, we use "startswith" bashism at the end of this script:
# if [[ "$string" == "$prefix"* ]]; then

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_LIST"    && BACKUP_LIST=$BACKUP_ROOT/files.txt
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_CURRENT/backup.db
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"%F %T")"

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is another copy of this script running
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

### RSYNC ###

# run rsync to backup from $1 to $2, with $3 extra arguments
run_rsync()
{
	rsync -a --fake-super --delete --one-file-system "$1" "$BACKUP_CURRENT/$2" $3
}

# run command $1 if date (formatted as $2) have changed
run_if_date_changed()
{
	test "$(date -r "$BACKUP_LIST" +"$1")" != "$(date -d "$BACKUP_TIME" +"$1")" && $2
}

# run
run_always
run_if_date_changed "%F %H" run_hourly
run_if_date_changed "%F" run_daily
run_if_date_changed "%Y %W" run_weekly
run_if_date_changed "%Y-%m" run_monthly

### DIFF ###

# listing all files together with their inodes currently in backup dir
(find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%i %P\n' ) | sort --key 2 >"$BACKUP_LIST".new

# comparing this list to its previous version
diff --new-file "$BACKUP_LIST" "$BACKUP_LIST".new | sed '/^[<>]/!d;s/^\(.\) [0-9]*/\1/;s/^>/N/;s/^</D/' | sort --key=2 --key=1 >"$BACKUP_LIST".diff

mv "$BACKUP_LIST".new "$BACKUP_LIST"
touch -d "$BACKUP_TIME" "$BACKUP_LIST"

if [[ "$BACKUP_DB" == "$BACKUP_CURRENT"* ]]; then
	# Database inode doesn't change, so add it manually
	backup_db_filename="${BACKUP_DB:${#BACKUP_CURRENT}}"
	backup_db_filename="${backup_db_filename#/}"
	echo "D $backup_db_filename" >"$BACKUP_LIST".diff
	echo "N $backup_db_filename" >"$BACKUP_LIST".diff
fi

### BACKUP ###

first_day_of_month="$(date -d "$(date -d "$BACKUP_TIME" "+%Y-%m-01")" +"%F %T")"
last_sunday="$(date -d "$(date -d "-$(date -d "$BACKUP_TIME" +%w) days" +"%Y-%m-%d")" +"%F %T")"
last_midnight="$(date -d "$(date -d "$BACKUP_TIME" "+%F")" +"%F %T")"
first_minute_of_hour="$(date -d "$(date -d "$BACKUP_TIME" "+%F %H:00")" +"%F %T")"

cat "$BACKUP_LIST".diff | (
	echo ".timeout 10000"
	echo "BEGIN TRANSACTION;"
	while read change fullname; do
		# escape vars for DB
		clean_fullname="${fullname//\'/\'\'}"
		clean_dirname="${clean_fullname%/*}"
		test "$clean_dirname" = "$clean_fullname" && clean_dirname=""
		clean_filename="${clean_fullname##*/}"
		case "$change" in
			( N ) # New file
				echo "INSERT INTO history (dirname, filename, created, deleted, freq) VALUES ('$clean_dirname', '$clean_filename', '$BACKUP_TIME', NULL, 0);"
				mkdir -p "$BACKUP_MAIN/$fullname"
				ln "$BACKUP_CURRENT/$fullname" "$BACKUP_MAIN/$fullname/$BACKUP_TIME"
				;;
			( D ) # Deleted
				echo "UPDATE history
					SET
						deleted = '$BACKUP_TIME',
						freq = CASE
							WHEN created < '$first_day_of_month' THEN 1
							WHEN created < '$last_sunday' THEN 5
							WHEN created < '$last_midnight' THEN 30
							WHEN created < '$first_minute_of_hour' THEN 720
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

if [[ "$BACKUP_DB" == "$BACKUP_CURRENT"* ]]; then
	# Above stuff created hardlink to database in backup dir. It's not
	# useful as a backup, so we break the hardlink by using SQLite "backup"
	# command. But first we need to figure out name of backup file
	backup_db_filename="${BACKUP_DB:${#BACKUP_CURRENT}}"
	backup_db_filename="${backup_db_filename#/}"
	backup_db_backup="$BACKUP_MAIN/$backup_db_filename#$BACKUP_TIME"
	rm "$backup_db_backup"
	$SQLITE ".backup '$backup_db_backup'"
fi
