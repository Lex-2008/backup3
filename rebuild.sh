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
test -z "$SQLITE"         && SQLITE="sqlite3 $BACKUP_DB"

# see backup1.sh for explanation
BACKUP_MAX_FREQ_SEC="$(echo "2592000 $BACKUP_MAX_FREQ / p" | dc)"

# `find` replacement, which scans a given dir and for each object found it prints:
# * its inode number
# * its type ('f' for file, 'd' for dir, 's' for others)
# * its name
# all in one line
# Arguments:
# * dir to `cd` prior to `find`
# * dirname and other filters to pass to `find`
my_find()
{
	cd "$1"
	shift
	if test -f /usr/bin/find && /usr/bin/find --version 2>&1 | grep -q GNU; then
		/usr/bin/find "$@" -printf '%i %y %h/%f\n'
	else
		sed='s/^([0-9]*) regular( empty)? file /\1 f /
		     s/^([0-9]*) directory /\1 d /
		     t
		     s/^([0-9]*) [^.]* /\1 s /'
		find "$@" | xargs stat -c '%i %F %n' | sed -r '$sed'
	fi
	cd -> /dev/null
}

# check if there is another copy of this script running
lock_available()
{
	file="$1"
	test ! -f "$file" && return 0
	pid="$(cat "$file")"
	test ! -d "/proc/$pid" && { echo "process $pid does not exist"; rm "$file"; return 0; }
	test ! -f "/proc/$pid/fd/200" && { echo "process $pid does not have FD 200"; rm "$file"; return 0; }
	test ! "$(stat -c %N /proc/$pid/fd/200)" == "/proc/$pid/fd/200 -> $file" && { echo "process $pid has FD 200 not pointing to $file"; rm "$file"; return 0; }
	return 1
}
if ! lock_available; then
	test -z "$BACKUP_WAIT_FLOCK" && exit 200
	while ! lock_available; do sleep 1; done
fi
# acquire lock
exec 200>"$BACKUP_FLOCK"
echo "$$">&200

echo "### DATABASE ###"

rm "$BACKUP_DB"

echo "1: create"
./init.sh --noindex

echo "2: fill files"
my_find "$BACKUP_MAIN" . $BACKUP_FIND_FILTER -not -type d -name "*$BACKUP_TIME_SEP*" | sed -r "
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	s/'/''/g        # duplicate single quotes
	s_^([0-9]*) (.) (.*/)([^/]*)/([^/$BACKUP_TIME_SEP]*)$BACKUP_TIME_SEP([^/$BACKUP_TIME_SEP]*)_	\\
		INSERT INTO history (inode, type, dirname, filename, created, deleted, freq) VALUES	\\
		('\\1', '\\2', '\\3', '\\4', '\\5', '\\6', 0);_
	\$a END TRANSACTION;" | $SQLITE

echo "3: fill dirs"
echo "SELECT dirname, MIN(created), MAX(deleted)
		FROM history
		GROUP BY dirname;" | $SQLITE | sed -r "
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	s/'/''/g        # duplicate single quotes
	s_^./\\|_././\\|_	# special case for root dir
	s_^(.*/)([^/|]*)/\\|([^|]*)\\|([^|]*)_	\\
		INSERT INTO history (inode, type, dirname, filename, created, deleted, freq) VALUES	\\
		(0, 'd', '\\1', '\\2', '\\3', '\\4', 0);_
	\$a END TRANSACTION;" | $SQLITE

echo "4: update freq"
echo "UPDATE history SET freq = CASE
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
	END;" | $SQLITE

echo "5: index"
./init.sh --notable

if test "$1" = "--current"; then
	echo "### CURRENT ###"

	rm -rf "$BACKUP_CURRENT"

	cmd="
	while test \$# -ge 1; do
		fullname=\"\$(dirname \"\$1\")\"
		mkdir -p \"$BACKUP_CURRENT/\$(dirname \"\$fullname\")\"
		ln \"$BACKUP_MAIN/\$1\" \"$BACKUP_CURRENT/\$fullname\"
		shift
	done"

	# note that this uses simple -print0 which is supported both in GNU and busybox find
	cd "$BACKUP_MAIN"
	find . $BACKUP_FIND_FILTER -not -type d -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" -print0 | xargs -r -0 sh -c "$cmd" x
	cd -> /dev/null
fi

echo "6: update dir inodes"
min_date="$(echo 'SELECT min(created) FROM history;' | $SQLITE)"
echo "min_date=$min_date"
my_find  "$BACKUP_CURRENT" . $BACKUP_FIND_FILTER -type d | sed -r "
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	s/'/''/g        # duplicate single quotes
	s@^([0-9]*) . (.*/)([^/]*)@	\\
		INSERT INTO history (inode, type, dirname, filename, created, deleted, freq) VALUES	\\
		('\\1', 'd', '\\2', '\\3', '$min_date', 'now', 0)	\\
		ON CONFLICT(dirname, filename) WHERE freq = 0 DO UPDATE \\
		SET inode='\\1';@
	\$a END TRANSACTION;" | $SQLITE

# release the lock
rm "$BACKUP_FLOCK"
