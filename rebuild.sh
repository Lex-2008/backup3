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

### DATABASE ###

/usr/bin/find "$BACKUP_MAIN" $BACKUP_FIND_FILTER \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP*" -printf '%P\n' | sed '
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	1i DELETE FROM history;
	'"s/'/''/g"'        # duplicate single quotes
	/[/].*[/]/!s_ _ /_; # ensure all lines have two dir separators
	s_\(\(.*\)/\)\?\(.*\)/\(.*\)'"$BACKUP_TIME_SEP"'\(.*\)_	\
		INSERT INTO history (dirname, filename, created, deleted, freq)	\
		VALUES '"('\\2', '\\3', '\\4', '\\5', 0);_
	\$a UPDATE history	\\
		SET freq = CASE		\\
			WHEN strftime('%Y-%m', created, '-1 minute') !=	\\
			     strftime('%Y-%m', deleted, '-1 minute')	\\
			     THEN 1 -- different month	\\
			WHEN strftime('%Y %W', created, '-1 minute') !=	\\
			     strftime('%Y %W', deleted, '-1 minute')	\\
			     THEN 5 -- different week	\\
			WHEN strftime('%Y-%m-%d', created, '-1 minute') !=	\\
			     strftime('%Y-%m-%d', deleted, '-1 minute')		\\
			     THEN 30 -- different day	\\
			WHEN strftime('%Y-%m-%d %H', created, '-1 minute') !=	\\
			     strftime('%Y-%m-%d %H', deleted, '-1 minute')	\\
			     THEN 720 -- different hour	\\
			ELSE $BACKUP_MAX_FREQ		\\
		END	\\
		WHERE deleted != '$BACKUP_TIME_NOW';	\\
	END TRANSACTION;" | $SQLITE

### CURRENT ###

rm -rf "$BACKUP_CURRENT"

cmd="
while test \$# -ge 1; do
	fullname=\"\$(dirname \"\$1\")\"
	mkdir -p \"$BACKUP_CURRENT/\$(dirname \"\$fullname\")\"
	ln -T \"$BACKUP_MAIN/\$1\" \"$BACKUP_CURRENT/\$fullname\"
	shift
done" 

/usr/bin/find "$BACKUP_MAIN" $BACKUP_FIND_FILTER \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" -printf '%P\0' | xargs -r -0 sh -c "$cmd" x

### INODE NUMBERS ###

sed="s/'/''/g        # duplicate single quotes
	1i BEGIN TRANSACTION;
	\$a END TRANSACTION;
	s_^([0-9]*) ((.*)/)?(.*)_	\\
	UPDATE history SET inode='\\1' WHERE dirname='\\3' AND filename='\\4';	\\
	_"
/usr/bin/find "$BACKUP_CURRENT" $BACKUP_FIND_FILTER \( -type f -o -type l \) -printf '%i %P\n' | sed -r "$sed" | $SQLITE
