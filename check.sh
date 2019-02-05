#!/bin/busybox ash
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
test -z "$BACKUP_DB_BAK"  && BACKUP_DB_BAK=backup.db

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is backup in progress
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

test "$1" = '--delete' && DELETE_MISSING=1


db2current ()
{
	echo "Checking DB => current FS"

	$SQLITE "SELECT rowid, dirname, filename, created
		FROM history
		WHERE freq = 0
		ORDER BY dirname;" | while IFS='|' read rowid dirname filename created; do
		if ! test -e "$BACKUP_CURRENT/$dirname/$filename"; then
			echo "Missing file: [$dirname][$filename][$created]" >&2
			test -n "$DELETE_MISSING" && echo "DELETE FROM history WHERE rowid='$rowid';"
		fi
	done | $SQLITE
}

db2old ()
{
	echo "Checking DB => old FS"

	$SQLITE "SELECT rowid, dirname, filename, created
		FROM history
		ORDER BY dirname;" | while IFS='|' read rowid dirname filename created; do
		if ! test -e "$BACKUP_MAIN/$dirname/$filename/$created"; then
			echo "Missing file: [$dirname][$filename][$created]" >&2
			test -n "$DELETE_MISSING" && echo "DELETE FROM history WHERE rowid='$rowid';"
		fi
	done | $SQLITE
}

current2db ()
{
	echo "Checking current FS => DB"

	/usr/bin/find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%P\n' | sed '/"/d;s_^\(\(.*\)/\)\?\(.*\)$_SELECT CASE WHEN EXISTS(SELECT 1 FROM history WHERE dirname="\2" AND filename="\3" AND freq=0 LIMIT 1) THEN 1 ELSE "\2/\3" END;_' | $SQLITE | fgrep -v -x 1 | (
		if test -n "$DELETE_MISSING"; then
			cd "$BACKUP_CURRENT"
			tee /dev/stderr | fgrep -v -f- "$BACKUP_LIST" >"$BACKUP_LIST.new"
			mv "$BACKUP_LIST.new" "$BACKUP_LIST"
		else
			cat
		fi
	)
}

old2db ()
{
	echo "Checking old FS => DB"
	/usr/bin/find "$BACKUP_MAIN" \( -type f -o -type l \) -printf '%P\n' | sed '/"/d;s_^\(\(.*\)/\)\?\(.*\)/\(.*\)$_SELECT CASE WHEN EXISTS(SELECT 1 FROM history WHERE dirname="\2" AND filename="\3" AND created="\4" LIMIT 1) THEN 1 ELSE "\2/\3/\4" END;_' | $SQLITE | fgrep -v -x 1 | (
		if test -n "$DELETE_MISSING"; then
			cd "$BACKUP_MAIN"
			tee /dev/stderr | tr '\n' '\0' | xargs -0 rm -f
		else
			cat
		fi
	)
}

current2old ()
{
	echo "Checking current FS => old FS"

	/usr/bin/find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%i %P\n' | grep -v "^[0-9]* *$BACKUP_DB_BAK$" | while read inode fullname; do
		ls -i "$BACKUP_MAIN/$fullname" 2>/dev/null | grep -q "^ *$inode " || echo "$fullname"
	done | (
		if test -n "$DELETE_MISSING"; then
			cd "$BACKUP_CURRENT"
			# These files might either be in DB, or not. If they
			# are not in DB - it was taken care of above, in
			# `current2db`. But if they are in DB - we sholud make
			# sure that on next run of backup.sh script they will
			# be marked as modified. For this, we make a sed script
			# to convert list of filenames to sed script which
			# clears inode numbers of relevant entries in
			# "$BACKUP_LIST", and apply it. After that we must sort
			# "$BACKUP_LIST" file again
			sed 's/.*/s|^[0-9]* &$|0 &|;/' | sed -f /dev/stdin "$BACKUP_LIST" >"$BACKUP_LIST.new"
			LC_ALL=POSIX sort "$BACKUP_LIST.new" >"$BACKUP_LIST"
		else
			cat
		fi
	)
}

db_overlaps ()
{
	if test -n "$DELETE_MISSING"; then
		echo "Fixing overlapping dates in DB"
		$SQLITE "UPDATE history
			SET deleted = (
				SELECT created
				FROM history AS b
				WHERE history.created < b.created
				AND history.dirname = b.dirname
				AND history.filename = b.filename
				AND history.created < b.deleted
				AND b.created < history.deleted
				LIMIT 1
			),
			freq = 123 -- proper value will be set in db_freq later
			WHERE EXISTS (
				SELECT *
				FROM history AS b
				WHERE history.created < b.created
				AND history.dirname = b.dirname
				AND history.filename = b.filename
				AND history.created < b.deleted
				AND b.created < history.deleted
			);"
	else
		echo "Checking overlapping dates in DB"
		$SQLITE "SELECT a.*, b.created
			FROM history AS a,
			history AS b
				WHERE a.created < b.created
				AND a.dirname = b.dirname
				AND a.filename = b.filename
				AND a.created < b.deleted
				AND b.created < a.deleted
			;"
	fi
}

db_order ()
{
	if test -n "$DELETE_MISSING"; then
		echo "Deleting where created not < deleted in DB"
		$SQLITE "DELETE
			FROM history
			WHERE created >= deleted;"
	else
		echo "Checking that created < deleted in DB"
		$SQLITE "SELECT *
			FROM history
			WHERE created >= deleted;"
	fi
}

db_dups_created ()
{
	if test -n "$DELETE_MISSING"; then
		echo "Deleting duplicate DB entries with same created"
		operation="DELETE"
	else
		echo "Checking duplicate DB entries with same created"
		operation="SELECT *"
	fi
	$SQLITE "$operation FROM history
		WHERE EXISTS (
			SELECT *
			FROM history AS b
			-- check that they're duplicates
			WHERE history.dirname = b.dirname
			AND history.filename = b.filename
			AND history.created = b.created
			AND history.rowid != b.rowid
			-- check when to delete 'history' row, not the other one
			AND ( history.freq = 0 AND b.freq != 0
				OR (
					NOT (history.freq != 0 AND b.freq = 0)
					AND history.rowid < b.rowid
				)
			)
		);"
}

db_dups_freq0 ()
{
	echo "Checking duplicate DB entries which still exist"
	$SQLITE "SELECT a.*, b.created
		FROM history AS a,
		history AS b
		WHERE a.freq = 0
			AND a.rowid < b.rowid
			AND a.dirname = b.dirname
			AND a.filename = b.filename
			AND b.freq = 0
			;"
}

db_freq ()
{
	if test -n "$DELETE_MISSING"; then
		echo "Fixing freq in DB"
		$SQLITE "UPDATE history
			SET freq = CASE
				WHEN substr(created, 1, 7) != substr(deleted, 1, 7) OR created LIKE '%-01 00:00' THEN 1 -- different month
				WHEN strftime('%Y %W', created) != strftime('%Y %W', deleted) OR
					created LIKE '% 00:00' AND strftime('%w', created) ='1' THEN 5 -- different week
				WHEN substr(created, 1, 10) != substr(deleted, 1, 10) OR created LIKE '% 00:00' THEN 30 -- different day
				WHEN substr(created, 1, 13) != substr(deleted, 1, 13) OR created LIKE '%:00' THEN 720 -- different hour
				ELSE 8640
			END
			WHERE freq != 0;"
	else
		echo "Checking freq in DB"
		$SQLITE "SELECT *
			FROM history
			WHERE freq != 0 AND
			freq != CASE
				WHEN substr(created, 1, 7) != substr(deleted, 1, 7) OR created LIKE '%-01 00:00' THEN 1 -- different month
				WHEN strftime('%Y %W', created) != strftime('%Y %W', deleted) OR
					created LIKE '% 00:00' AND strftime('%w', created) ='1' THEN 5 -- different week
				WHEN substr(created, 1, 10) != substr(deleted, 1, 10) OR created LIKE '% 00:00' THEN 30 -- different day
				WHEN substr(created, 1, 13) != substr(deleted, 1, 13) OR created LIKE '%:00' THEN 720 -- different hour
				ELSE 8640
			END;"
	fi
}

$SQLITE "CREATE INDEX IF NOT EXISTS check_tmp ON history(dirname, filename, created);"

# Tests that might delete some DB rows
db_order
db2current
db2old
db_dups_created

# Tests that might change created
db_overlaps

# Tests that fix freq according to created/deleted
db_freq

# Tests that remove files from files.txt
current2db
current2old

# Tests that delete files for missing DB rows
old2db

# This test should never fail
db_dups_freq0

$SQLITE "DROP INDEX IF EXISTS check_tmp;VACUUM;"
