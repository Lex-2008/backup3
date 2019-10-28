#!/bin/busybox ash
#
# Rebuild database from files.

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~" # must NOT be /
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is another copy of this script running
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200


echo "### DATABASE ###"

/usr/bin/find "$BACKUP_MAIN" $BACKUP_FIND_FILTER \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP*" -printf '%i %P\n' | sed -r "
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	1i DELETE FROM history;
	s/'/''/g        # duplicate single quotes
	s_^([0-9]*) ((.*)/)?(.*)/(.*)$BACKUP_TIME_SEP(.*)_	\\
		INSERT INTO history (inode, dirname, filename, created, deleted, freq)	\\
		VALUES ('\\1', '\\3', '\\4', '\\5', '\\6', \\
		CASE	\\
			WHEN '\\6' = '$BACKUP_TIME_NOW'	\\
			     THEN 0 -- still exists	\\
			WHEN strftime('%Y-%m', '\\5', '-1 second') !=	\\
			     strftime('%Y-%m', '\\6', '-1 second')	\\
			     THEN 1 -- different month	\\
			WHEN strftime('%Y %W', '\\5', '-1 second') !=	\\
			     strftime('%Y %W', '\\6', '-1 second')	\\
			     THEN 5 -- different week	\\
			WHEN strftime('%Y-%m-%d', '\\5', '-1 second') !=	\\
			     strftime('%Y-%m-%d', '\\6', '-1 second')		\\
			     THEN 30 -- different day	\\
			WHEN strftime('%Y-%m-%d %H', '\\5', '-1 second') !=	\\
			     strftime('%Y-%m-%d %H', '\\6', '-1 second')	\\
			     THEN 720 -- different hour	\\
			ELSE $BACKUP_MAX_FREQ		\\
		END	\\
		);_
	\$a END TRANSACTION;" | $SQLITE

echo "### CURRENT ###"

rm -rf "$BACKUP_CURRENT"

cmd="
while test \$# -ge 1; do
	fullname=\"\$(dirname \"\$1\")\"
	mkdir -p \"$BACKUP_CURRENT/\$(dirname \"\$fullname\")\"
	ln \"$BACKUP_MAIN/\$1\" \"$BACKUP_CURRENT/\$fullname\"
	shift
done" 

/usr/bin/find "$BACKUP_MAIN" $BACKUP_FIND_FILTER \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" -printf '%P\0' | xargs -r -0 sh -c "$cmd" x
