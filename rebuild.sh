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

# see backup1.sh for explanation
BACKUP_MAX_FREQ_SEC="$(echo "2592000 $BACKUP_MAX_FREQ / p" | dc)"

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is another copy of this script running
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200


echo "### DATABASE ###"

rm "$BACKUP_DB"

echo "1: create"
./init.sh noindex

echo "2: fill"
/usr/bin/find "$BACKUP_MAIN" $BACKUP_FIND_FILTER \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP*" -printf '%i ./%P\n' | sed -r "
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	s/'/''/g        # duplicate single quotes
	s_^([0-9]*) (.*/)([^/]*)/([^/$BACKUP_TIME_SEP]*)$BACKUP_TIME_SEP([^/$BACKUP_TIME_SEP]*)_	\\
		INSERT INTO history (inode, dirname, filename, created, deleted, freq) VALUES	\\
		('\\1', '\\2', '\\3', '\\4', '\\5', 0);_
	\$a END TRANSACTION;" | $SQLITE

echo "3: update freq"

$SQLITE "UPDATE history SET freq = CASE
		WHEN deleted = '$BACKUP_TIME_NOW'
		     THEN 0 -- not deleted yet
		WHEN strftime('%Y-%m', created, '-1 second') !=
		     strftime('%Y-%m', deleted, '-1 second')
		     THEN 1 -- different month
		WHEN strftime('%Y %W', created, '-1 second') !=
		     strftime('%Y %W', deleted, '-1 second')
		     THEN 5 -- different week
		WHEN strftime('%Y-%m-%d', created, '-1 second') !=
		     strftime('%Y-%m-%d', deleted, '-1 second')
		     THEN 30 -- different day
		WHEN strftime('%Y-%m-%d %H', created, '-1 second') !=
		     strftime('%Y-%m-%d %H', deleted, '-1 second')
		     THEN 720 -- different hour
		WHEN strftime('%s', created, '-1 second')/$BACKUP_MAX_FREQ_SEC !=
		     strftime('%s', deleted, '-1 second')/$BACKUP_MAX_FREQ_SEC
		     THEN $BACKUP_MAX_FREQ -- crosses BACKUP_MAX_FREQ boundary (usually 5 minutes)
		ELSE 2592000 / (strftime('%s', deleted) - strftime('%s', created))
		     -- 2592000 is number of seconds per month
	END;"
echo "3: index"
./init.sh notable

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
