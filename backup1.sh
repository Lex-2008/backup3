#!/bin/busybox ash
#
# Script to update single file (hence the name).
# Accepts two arguments: operation and filename.

test -z "$BACKUP_FROM"    && exit 2
test -z "$BACKUP_ROOT"    && exit 2
test -z "$2"              && exit 2
operation="$1"            # either 'r' for new files or 'u' for deleted ones
fullname="$2"

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -n "$BACKUP_TIME"    && BACKUP_TIME="$(date -d "$BACKUP_TIME" +"%F %H:%M:%S")"
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"%F %H:%M:%S")"
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~" # must be regexp-safe
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now # must be 'now' or valid date in future
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640

# 2592000 is number of seconds / month
# BACKUP_MAX_FREQ is number of events / month
# hence 2592000/BACKUP_MAX_FREQ is number of seconds / event
# usually 300 seconds for BACKUP_MAX_FREQ=8640 (5 minutes)
BACKUP_MAX_FREQ_SEC="$(echo "2592000 $BACKUP_MAX_FREQ / p" | dc)"

SQLITE="sqlite3 $BACKUP_DB"

filename="${fullname##*/}"
unsafedirname="${fullname%/*}"
filename="${filename/'/''}"
dirname="${unsafedirname/'/''}"
test "$dirname" = "$filename" && dirname=''

### OLD FILE ###
if test "$operation" = "u"; then
	# Get part of filename with created date (for rename op)
	# AND add the deleted timestamp to DB entry
	old_created_filename="$(echo ".timeout 1000
		SELECT dirname || '/' || filename || '/' || created
		FROM history
		WHERE dirname = '$dirname'
		  AND filename = '$filename'
		  AND freq = 0
		LIMIT 1;
		UPDATE history
		SET 	deleted = '$BACKUP_TIME',
			freq = CASE
				WHEN strftime('%Y-%m', created,        '-1 second') !=
				     strftime('%Y-%m', '$BACKUP_TIME', '-1 second')
				     THEN 1 -- different month
				WHEN strftime('%Y %W', created,        '-1 second') !=
				     strftime('%Y %W', '$BACKUP_TIME', '-1 second')
				     THEN 5 -- different week
				WHEN strftime('%Y-%m-%d', created,        '-1 second') !=
				     strftime('%Y-%m-%d', '$BACKUP_TIME', '-1 second')
				     THEN 30 -- different day
				WHEN strftime('%Y-%m-%d %H', created,        '-1 second') !=
				     strftime('%Y-%m-%d %H', '$BACKUP_TIME', '-1 second')
				     THEN 720 -- different hour
				WHEN strftime('%s', created, '-1 second')/$BACKUP_MAX_FREQ_SEC !=
				     strftime('%s', '$BACKUP_TIME', '-1 second')/$BACKUP_MAX_FREQ_SEC
				     THEN $BACKUP_MAX_FREQ -- crosses BACKUP_MAX_FREQ boundary (usually 5 minutes)
				ELSE 2592000 / (strftime('%s', '$BACKUP_TIME') - strftime('%s', created))
				     -- 2592000 is number of seconds per month
			END
		WHERE dirname = '$dirname'
		  AND filename = '$filename'
		  AND freq = 0;
		  " | $SQLITE)"
	# echo "got [$old_created_filename]"
	# echo rm "$BACKUP_CURRENT/$fullname"
	# echo mv "$BACKUP_MAIN/$old_created_filename$BACKUP_TIME_SEP$BACKUP_TIME_NOW" "$BACKUP_MAIN/$old_created_filename$BACKUP_TIME_SEP$BACKUP_TIME"
	rm "$BACKUP_CURRENT/$fullname"
	mv "$BACKUP_MAIN/$old_created_filename$BACKUP_TIME_SEP$BACKUP_TIME_NOW" "$BACKUP_MAIN/$old_created_filename$BACKUP_TIME_SEP$BACKUP_TIME"
fi

### NEW FILE ###
if test "$operation" = "r"; then
	mkdir -p "$BACKUP_CURRENT/$unsafedirname"
	rsync -a --fake-super "$BACKUP_FROM/$fullname" "$BACKUP_CURRENT/$fullname"

	inode=$(stat -c%i "$BACKUP_CURRENT/$fullname")
	echo ".timeout 10000
		INSERT INTO history (inode, dirname, filename, created, deleted, freq)
		VALUES ('$inode', '$dirname', '$filename', '$BACKUP_TIME', '$BACKUP_TIME_NOW', 0);
		" | $SQLITE
	mkdir -p "$BACKUP_MAIN/$fullname"
	# echo ln "$BACKUP_CURRENT/$fullname" "$BACKUP_MAIN/$fullname/$BACKUP_TIME$BACKUP_TIME_SEP$BACKUP_TIME_NOW"
	ln "$BACKUP_CURRENT/$fullname" "$BACKUP_MAIN/$fullname/$BACKUP_TIME$BACKUP_TIME_SEP$BACKUP_TIME_NOW"
fi
