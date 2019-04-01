#!/bin/busybox ash
#
# Rebuild database from files.

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is another copy of this script running
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

### NEW FILES ###

/usr/bin/find "$BACKUP_MAIN" $BACKUP_FIND_FILTER \( -type f -o -type l \) -printf '%s %P\n' | sed '
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	1i DELETE FROM history;
	'"s/'/''/g"'        # duplicate single quotes
	/[/].*[/]/!s_ _ /_; # ensure all lines have two dir separators
	s_\([0-9]*\) \(.*\)/\(.*\)/\(.*\)'"$BACKUP_TIME_SEP"'\(.*\)_	\
		INSERT INTO history (dirname, filename, created, deleted, freq, size)	\
		VALUES ("\2", "\3", "\4", "\5", 0, "\1");_
	$a '"UPDATE history	\\
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
	UPDATE history	\\
		SET deleted = '9999-01-01 00:00'	\\
		WHERE deleted = '$BACKUP_TIME_NOW';	\\
	END TRANSACTION;" | tee rebuild.dbg.txt | $SQLITE

