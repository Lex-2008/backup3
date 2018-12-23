#!/bin/bash

# Note: it is bash instead of dash for speed improvements which the following
# bashism gives us: to replace ' with ", instead of calling external tool like this:
#	clean_name="$(echo "$fullname" | sed "s/'/''/g")"
# We can do it natively in bash, like this:
#	clean_name="${fullname//\'/\'\'}"

ROOT=$PWD/t

test -z "$SRC"            && SRC=$ROOT/a/
test -z "$DST"            # this is fine
test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$ROOT/b
test -z "$BACKUP_LIST"    && BACKUP_TMP=$ROOT/files.txt
test -z "$BACKUP"         && BACKUP=$ROOT/d
test -z "$BACKUP_LOG"     && BACKUP_LOG=$ROOT/rsync.log
test -z "$SQLITE_DB"      && SQLITE_DB=backup.db

EXTRA_PERCENT=10

test -z "$NOW" && NOW="$(date +"%F %T")"
# TODO: check and set if running monthly/weekly/daily/hourly/etc

SQLITE="sqlite3 $SQLITE_DB"

### RSYNC ###
# TODO: actually, ALL rsync commands
# rsync -a --fake-super --delete --one-file-system $RSYNC_EXTRA "$SRC" "$BACKUP_CURRENT"/"$DST"

### DIFF ###

echo 'listing all files...'
(find "$BACKUP_CURRENT" -type f -printf '%i %P\n' ) | sort --key 2 >"$BACKUP_LIST".new

echo "found files: $(wc -l "$BACKUP_LIST".new)"

echo 'generating diff...'
diff --new-file "$BACKUP_LIST" "$BACKUP_LIST".new | sed '/^[<>]/!d;s/^\(.\) [0-9]*/\1/;s/^>/N/;s/^</D/' | sort --key=2,1 >"$BACKUP_LIST".diff

echo "found changes: $(wc -l "$BACKUP_LIST".diff)"

mv "$BACKUP_LIST".new "$BACKUP_LIST"

### BACKUP ###
echo 'writing changes to disk...'
sync

first_day_of_month="$(date -d "$(date -d "$NOW" "+%Y-%m-01")" +"%F %T")"
last_sunday="$(date -d "$(date -d "-$(date -d "$NOW" +%w) days" +"%Y-%m-%d")" +"%F %T")"
last_midnight="$(date -d "$(date -d "$NOW" "+%F")" +"%F %T")"
first_minute_of_hour="$(date -d "$(date -d "$NOW" "+%F %H:00")" +"%F %T")"

echo "parsing $(cat "$BACKUP_LIST".diff | wc -l) changes to db..."
cat "$BACKUP_LIST".diff | (
	echo "BEGIN TRANSACTION;"
	while read change fullname; do
		# escape vars for DB
		clean_name="${fullname//\'/\'\'}"
		# clean_name="$(echo "$fullname" | sed "s/'/''/g")"
		clean_dirname="${clean_fullname%/*}"
		test "$clean_dirname" = "$clean_fullname" && dirname=""
		clean_filename="${clean_fullname##*/}"
		case "$change" in
			( N ) # New file
				echo "INSERT INTO history (dirname, filename, created, deleted, freq) VALUES ('$clean_dirname', '$clean_filename', '$NOW', NULL, 0);"
				dirname="${fullname%/*}"
				test "$dirname" = "$fullname" && dirname=""
				newname="$fullname#$NOW"
				mkdir -p "$BACKUP"/"$dirname"
				ln "$BACKUP_CURRENT"/"$fullname" "$BACKUP"/"$newname"
				;;
			( D ) # Deleted
				echo "UPDATE history
					SET
						deleted = '$NOW',
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

echo 'done!'
exit 0




### CLEAN UP ###

total_space=$(df -B1 --output=size "$BACKUP" | sed '1d')
FREE_SPACE_NEEDED=$(echo "$total_space*$EXTRA_PERCENT/100" | bc /dev/stdin)

# return status of 0 (true) means "need to clear space"
check_space()
{
	free_space_available=$(df -B1 --output=avail "$BACKUP" | sed '1d')
	test $free_space_available -lt $FREE_SPACE_NEEDED
}

while check_space; do
	$SQLITE "SELECT rowid,
			dirname,
			filename,
			MIN(deleted),
			freq,
			freq*(strftime('%s', 'now')-deleted) AS age
		FROM history
		GROUP BY freq
		ORDER BY age DESC
		LIMIT 1;" | while IFS='|' read rowid dirname filename deleted freq age; do
		test "$dirname" = "" && dirname="."
		fullname="$dirname/$filename"
		newname="$fullname#$deleted"
		rm -f "$BACKUP"/"$newname"
		$SQLITE "DELETE FROM history WHERE rowid=$rowid;"
	done
done
