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
test -z "$BACKUP_LIST"    && BACKUP_LIST=$BACKUP_ROOT/files.txt
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is backup in progress
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

test "$1" = '--fix' && FIX_MISSING=1
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
	if test -n "$FIX_MISSING"; then
		cd "$BACKUP_CURRENT"
		tee /dev/stderr | fgrep -v -f- "$BACKUP_LIST" >"$BACKUP_LIST.new"
		mv "$BACKUP_LIST.new" "$BACKUP_LIST"
	elif test -n "$DELETE_MISSING"; then
		cd "$BACKUP_CURRENT"
		tee /dev/stderr | xargs -d '\n' rm -f
	else
		cat
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
	else
		cat
	fi
)

$SQLITE "DROP INDEX check_old;VACUUM;"

echo "Checking current FS => old FS"

find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%i %P\n' | while read inode fullname; do
	ls -if "$BACKUP_MAIN/$fullname" 2>/dev/null | grep -q "^$inode " || echo "$fullname"
done | (
	# TODO: if it's the same file we've already "fixed" on "current FS => DB"
	# step, we don't need to remove it now
	if test -n "$DELETE_MISSING"; then
		cd "$BACKUP_CURRENT"
		tee /dev/stderr | xargs -d '\n' rm -f
	else
		cat
	fi
)

echo "Checking overlapping dates in DB"

$SQLITE "SELECT a.dirname, a.filename, a.rowid, b.rowid, a.created, a.deleted, b.created, b.deleted
	FROM (SELECT rowid, dirname, filename, created, deleted
		FROM history
		) AS a
	JOIN (SELECT rowid, dirname, filename, created, deleted
		FROM history
		WHERE freq != 0
		) AS b
	ON a.rowid < b.rowid
	AND a.dirname = b.dirname
	AND a.filename = b.filename
	AND a.created < b.deleted
	AND b.created < a.deleted;"
	# TODO: fix?


echo "Checking duplicates in DB"

$SQLITE "SELECT a.dirname, a.filename, a.rowid, b.rowid, a.created, a.deleted, b.created, b.deleted
	FROM (SELECT rowid, dirname, filename, created, deleted
		FROM history
		) AS a
	JOIN (SELECT rowid, dirname, filename, created, deleted
		FROM history
		WHERE freq != 0
		) AS b
	ON a.rowid < b.rowid
	AND a.dirname = b.dirname
	AND a.filename = b.filename
	AND ( a.created = b.created
	   OR a.deleted = b.deleted);"
	# TODO: delete


echo "Checking that created < deleted in DB"

$SQLITE "SELECT *
	FROM history
	WHERE created >= deleted;"


if test -n "$FIX_MISSING"; then
	echo "Fixing freq in DB"
	$SQLITE "UPDATE history
		SET freq = CASE
			WHEN substr(created, 1, 7) != substr(deleted, 1, 7) THEN 1 -- different month
			WHEN strftime('%Y %W', created) != strftime('%Y %W', deleted) THEN 5 -- different week
			WHEN substr(created, 1, 10) != substr(deleted, 1, 10) THEN 30 -- different day
			WHEN substr(created, 1, 13) != substr(deleted, 1, 13) THEN 720 -- different hour
			ELSE 8640
		END
		WHERE freq != 0;"
else
	echo "Checking freq in DB"
	$SQLITE "SELECT *
		FROM history
		WHERE freq != 0 AND
		freq != CASE
			WHEN substr(created, 1, 7) != substr(deleted, 1, 7) THEN 1 -- different month
			WHEN strftime('%Y %W', created) != strftime('%Y %W', deleted) THEN 5 -- different week
			WHEN substr(created, 1, 10) != substr(deleted, 1, 10) THEN 30 -- different day
			WHEN substr(created, 1, 13) != substr(deleted, 1, 13) THEN 720 -- different hour
			ELSE 8640
		END;"

fi
