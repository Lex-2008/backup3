#!/bin/busybox ash
#
# Main backup script.

test -z "$BACKUP_FROM"    && exit 2
test -z "$BACKUP_ROOT"    && exit 2
test -z "$1"              && exit 2
fullname="$1"

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -n "$BACKUP_TIME"    && BACKUP_TIME="$(date -d "$BACKUP_TIME" +"%F %H:%M:%S")"
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"%F %H:%M:%S")"
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~" # must be regexp-safe
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now # must be 'now' or valid date in future
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640

SQLITE="sqlite3 $BACKUP_DB"

filename="${fullname##*/}"
dirname="${fullname%/*}"
filename="${filename/'/''}"
dirname="${dirname/'/''}"
test "$dirname" = "$filename" && dirname=''

### OLD FILE ###
if test -f "$BACKUP_CURRENT/$fullname"; then
	old_created_filename="$($SQLITE ".timeout 10000
		SELECT dirname || '/' || filename || '/' || created
		FROM history
		WHERE dirname = '$dirname'
		  AND filename = '$filename'
		  AND freq = 0
		LIMIT 1;
		UPDATE history
		SET 	deleted = '$BACKUP_TIME',
			freq = CASE
				WHEN strftime('%Y-%m', created,        '-1 minute') !=
				     strftime('%Y-%m', '$BACKUP_TIME', '-1 minute')
				     THEN 1 -- different month
				WHEN strftime('%Y %W', created,        '-1 minute') !=
				     strftime('%Y %W', '$BACKUP_TIME', '-1 minute')
				     THEN 5 -- different week
				WHEN strftime('%Y-%m-%d', created,        '-1 minute') !=
				     strftime('%Y-%m-%d', '$BACKUP_TIME', '-1 minute')
				     THEN 30 -- different day
				WHEN strftime('%Y-%m-%d %H', created,        '-1 minute') !=
				     strftime('%Y-%m-%d %H', '$BACKUP_TIME', '-1 minute')
				     THEN 720 -- different hour
				ELSE $BACKUP_MAX_FREQ
			END
		WHERE dirname = '$dirname'
		  AND filename = '$filename'
		  AND freq = 0;
		  ")"
	mv "$BACKUP_MAIN/$old_created_filename$BACKUP_TIME_SEP$BACKUP_TIME_NOW" "$BACKUP_MAIN/$old_created_filename$BACKUP_TIME_SEP$BACKUP_TIME"
fi

rsync -a --fake-super "$BACKUP_FROM/$fullname" "$BACKUP_CURRENT/$fullname"

### NEW FILE ###

inode=$(stat -c%i "$BACKUP_CURRENT/$fullname")
$SQLITE ".timeout 10000
	INSERT INTO history (dirname, filename, created, deleted, freq)
	VALUES ('$inode', '$dirname', '$filename', '$BACKUP_TIME', '$BACKUP_TIME_NOW', 0);
	"
ln "$BACKUP_CURRENT/$fullname" "$BACKUP_MAIN/$fullname/$BACKUP_TIME$BACKUP_TIME_SEP$BACKUP_TIME_NOW"

