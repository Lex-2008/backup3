#!/bin/busybox ash

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now
test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_LIST"    && BACKUP_LIST=$BACKUP_ROOT/files.txt
test -z "$BACKUP_FIND_FILTER" # this is fine

SQLITE="sqlite3 $BACKUP_DB"

echo 'Step 1: updating deleted timestamps'
$SQLITE "UPDATE history
	SET deleted = '$BACKUP_TIME_NOW'
	WHERE freq = 0;"

echo 'Step 2: renaming old files'
$SQLITE "SELECT dirname,
		filename,
		created,
		deleted
	FROM history
	WHERE freq != 0;" | while IFS='|' read dirname filename created deleted; do
		mv "$BACKUP_MAIN/$dirname/$filename/$created" "$BACKUP_MAIN/$dirname/$filename/$created$BACKUP_TIME_SEP$deleted"
	done

echo 'Step 3: renaming existing files'
$SQLITE "SELECT dirname,
		filename,
		created
	FROM history
	WHERE freq = 0;" | while IFS='|' read dirname filename created deleted; do
		mv "$BACKUP_MAIN/$dirname/$filename/$created" "$BACKUP_MAIN/$dirname/$filename/$created$BACKUP_TIME_SEP$BACKUP_TIME_NOW"
	done

echo 'Step 4: updating list file'
# delete file sizes and convert from newline-separated file to zero-separated one
sed 's/ [0-9]* / /' "$BACKUP_LIST" | tr '\n' '\0' | LC_ALL=POSIX sort -z >"$BACKUP_LIST".new
mv "$BACKUP_LIST".new "$BACKUP_LIST"
