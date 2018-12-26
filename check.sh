#!/bin/bash
#
# Script to check that database matches filesystem.
#
# Optional argument --delete to delete files / DB rows which don't have
# corresponding DB entry / file

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_CURRENT/backup.db

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is backup in progress
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

test "$1" = '--delete' && DELETE_MISSING=1

echo "Checking DB => FS"

$SQLITE "SELECT rowid, dirname, filename, created
	FROM history
	ORDER BY dirname;" | while IFS='|' read rowid dirname filename created; do
	fullname="$dirname/$filename"
	if test -n "$created"; then
		newname="$BACKUP_MAIN/$dirname/$filename/$created"
	else
		newname="$BACKUP_CURRENT/$dirname/$filename"
	fi
	if ! test -e "$newname"; then
		echo "Missing file: [$newname] [$dirname][$filename][$created]" >&2
		test -n "$DELETE_MISSING" && echo "DELETE FROM history WHERE rowid='$rowid';"
	fi
	deleted=""
done | $SQLITE


echo "Checking current FS => DB"

find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%P\n' | while read fullname; do
	# escape vars for DB
	clean_fullname="${fullname//\'/\'\'}"
	clean_dirname="${clean_fullname%/*}"
	test "$clean_dirname" = "$clean_fullname" && clean_dirname=""
	clean_filename="${clean_fullname##*/}"
	echo "SELECT
		CASE
		WHEN EXISTS(SELECT 1
			FROM history
			WHERE dirname='$clean_dirname'
			  AND filename='$clean_filename'
			  AND freq=0
			LIMIT 1)
		THEN 1
		ELSE '$clean_fullname'
		END;"
done | $SQLITE | fgrep -v -x 1 | (
	echo "Orphan files in $BACKUP_CURRENT:" >&2
	if test -n "$DELETE_MISSING"; then
		cd "$BACKUP_CURRENT"
		tee /dev/stderr | xargs -d '\n' rm -f
	fi
)


echo "Checking old FS => DB"

$SQLITE "CREATE INDEX IF NOT EXISTS check_old ON history(dirname, filename, created);"

find "$BACKUP_MAIN" \( -type f -o -type l \) -printf '%P\n' | while read fullname; do
	# escape vars for DB
	clean_fullname="${fullname//\'/\'\'}"
	clean_created="${clean_fullname##*/}"
	clean_dirfilename="${clean_fullname%/*}"
	clean_filename="${clean_dirfilename##*/}"
	clean_dirname="${clean_dirfilename%/*}"
	test "$clean_dirname" = "$clean_dirfilename" && clean_dirname=""
	echo "SELECT
		CASE
		WHEN EXISTS(SELECT 1
			FROM history
			WHERE dirname='$clean_dirname'
			  AND filename='$clean_filename'
			  AND created='$clean_created'
			LIMIT 1)
		THEN 1
		ELSE '$clean_fullname'
		END;"
done | $SQLITE | fgrep -v -x 1 | (
	echo "Orphan files in $BACKUP_MAIN:" >&2
	if test -n "$DELETE_MISSING"; then
		cd "$BACKUP_MAIN"
		tee /dev/stderr | xargs -d '\n' rm -f
	fi
)

$SQLITE "DROP INDEX check_old;"
