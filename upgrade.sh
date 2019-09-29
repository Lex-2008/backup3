#!/bin/busybox ash

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_OLD"     && BACKUP_OLD=$BACKUP_ROOT/old
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_DB_BAK"  && BACKUP_DB_BAK=backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now
test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_LIST"    && BACKUP_LIST=$BACKUP_ROOT/files.txt
test -z "$BACKUP_FIND_FILTER" # this is fine

SQLITE="sqlite3 $BACKUP_DB"

if test -d "$BACKUP_MAIN"; then
	echo "$BACKUP_MAIN exists, aborting."

if test -d "$BACKUP_OLD"; then
	echo "$BACKUP_OLD exists, skipping backing up."
else
	echo 'Step 0: backing up'
	mv "$BACKUP_MAIN" "$BACKUP_OLD"
	cp "$BACKUP_DB" "$BACKUP_DB.bak"
	cp "$BACKUP_LIST" "$BACKUP_LIST.bak"
fi

echo 'Step 1: updating deleted timestamps'
$SQLITE "UPDATE history
	SET deleted = '$BACKUP_TIME_NOW'
	WHERE freq = 0;"

echo 'Step 2: renaming files'
$SQLITE "SELECT dirname,
		filename,
		created,
		deleted
	FROM history
	WHERE dirname!=''
	   OR filename!='$BACKUP_DB_BAK';" | while IFS='|' read dirname filename created deleted; do
		mkdir -p "$BACKUP_MAIN/$dirname/$filename/$created$BACKUP_TIME_SEP$deleted"
		cp -l "$BACKUP_OLD/$dirname/$filename/$created" "$BACKUP_MAIN/$dirname/$filename/$created$BACKUP_TIME_SEP$deleted"
	done

echo 'Step 3: updating list file'
# delete backup.db entry and file sizes
sed -i '/^[0-9]* backup.db/d;s/ [0-9]* / /' "$BACKUP_LIST"

if test "$BACKUP_DB_BAK" != "no"; then
	echo 'Step 4: deleting backup.db backups from filesystem'
	rm -f "$BACKUP_CURRENT/$BACKUP_DB_BAK"
fi
