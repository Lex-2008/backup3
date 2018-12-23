#!/bin/sh

ROOT=$PWD/t

test -z "$SRC"            && SRC=$ROOT/a/
test -z "$DST"            # this is fine
test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$ROOT/b
test -z "$BACKUP_TMP"     && BACKUP_TMP=$ROOT/c
test -z "$BACKUP"         && BACKUP=$ROOT/d
test -z "$BACKUP_LOG"     && BACKUP_LOG=$ROOT/rsync.log
test -z "$BACKUP_DEV"     && BACKUP_DEV=/dev/sda1
test -z "$SQLITE_DB"      && SQLITE_DB=backup.db

EXTRA_PERCENT=10

test -z "$NOW" && NOW="$(date +"%F %T")"
# TODO: check and set if running monthly/weekly/daily/hourly/etc

SQLITE="sqlite3 $SQLITE_DB"

### RSYNC ###
# TODO: actually, ALL rsync commands
# rsync -ai --fake-super --delete --one-file-system --backup --backup-dir="$BACKUP_TMP" $RSYNC_EXTRA "$SRC" "$BACKUP_CURRENT"/"$DST" >"$BACKUP_LOG"

### IMPORT ###

echo 'listing new files...'
rsync -ain --fake-super --delete --one-file-system "$SRC" "$BACKUP_CURRENT"/"$DST" > "$BACKUP_LOG"

echo 'copying all files...'
(
	cd "$SRC"
	IFS="
"
	cp -al $(ls -f | fgrep -v -x -e '.' -e '..' ) "$BACKUP_CURRENT"/"$DST" --backup
)

echo 'detecting backed-up files...'
rsync -ain --delete "$SRC" "$BACKUP_CURRENT"/"$DST" >deleted_files

echo "moving $(cat "deleted_files" | fgrep "*deleting" | grep -v "/$" | wc -l) backed-up files into BACKUP_TMP..."
cat deleted_files | while read itemiz fullname; do
	test "$itemiz" = "*deleting" || continue
	newname="${fullname%~}"
	dirname="${newname%/*}"
	test "$dirname" = "$newname" && dirname=""
	test -d "$BACKUP_CURRENT"/"$DST"/"$fullname" && continue
	test -f "$BACKUP_CURRENT"/"$DST"/"$fullname" || echo "file not found: [$BACKUP_CURRENT/$DST/$fullname]"
	mkdir -p "$BACKUP_TMP"/"$DST"/"$dirname"
	mv "$BACKUP_CURRENT"/"$DST"/"$fullname" "$BACKUP_TMP"/"$DST"/"$newname"
done

### BACKUP ###
echo 'writing changes to disk...'
sync

first_day_of_month="$(date -d "$(date -d "$NOW" "+%Y-%m-01")" +"%F %T")"
last_sunday="$(date -d "$(date -d "-$(date -d "$NOW" +%w) days" +"%Y-%m-%d")" +"%F %T")"
last_midnight="$(date -d "$(date -d "$NOW" "+%F")" +"%F %T")"
first_minute_of_hour="$(date -d "$(date -d "$NOW" "+%F %H:00")" +"%F %T")"

# let SQLite know about new file.
# Args: dirname, filename
add_file()
{
	echo "INSERT INTO history (dirname, filename, created, deleted, freq) VALUES ('$1', '$2', '$NOW', NULL, 0);"
}

echo "adding $(cat "$BACKUP_LOG" | fgrep '>f+++' | wc -l) new files to db..."
# cat "$BACKUP_LOG" | while read fullname; do
cat "$BACKUP_LOG" | while read itemiz fullname; do
	case "$itemiz" in
		( ">"f+* )
			# new file
			# escape var for DB
			fullname="$(echo "$fullname" | sed "s/'/''/g")"
			dirname="${fullname%/*}"
			test "$dirname" = "$fullname" && dirname=""
			filename="${fullname##*/}"
			add_file "$dirname" "$filename"
			;;
	esac
done | $SQLITE

echo 'finding changed files...'
(cd "$BACKUP_TMP" && find -type f) >new_files
echo "updating $(cat new_files | wc -l) files in db..."
cat new_files | while read fullname; do
	fullname="${fullname#./}" # remove leading ./
	dirname="${fullname%/*}"
	test "$dirname" = "$fullname" && dirname=""
	filename="${fullname##*/}"
	newname="$fullname#$NOW"
	mkdir -p "$BACKUP"/"$dirname"
	mv "$BACKUP_TMP"/"$fullname" "$BACKUP"/"$newname"
	# escape vars for DB
	dirname="$(echo "$dirname" | sed "s/'/''/g")"
	filename="$(echo "$filename" | sed "s/'/''/g")"
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
		WHERE dirname = '$dirname'
		AND filename = '$filename'
		AND freq = 0;"
	test -f "$BACKUP_CURRENT"/"$fullname" && add_file "$dirname" "$filename"
done | $SQLITE

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
