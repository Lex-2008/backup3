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
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is backup in progress
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

if test "$1" = '--fix'; then
	FIX=1
	export FIX
fi


db2current ()
{
	echo "Checking DB => current FS"

	cmd="	echo '.timeout 10000'
		echo 'BEGIN TRANSACTION;'
		while test \$# -ge 1; do
			filename=\"\${1%%|*}\"
			rowid=\"\${1##*|}\"
			if ! test -e \"$BACKUP_CURRENT/\$filename\"; then
				echo \"$BACKUP_CURRENT/\$filename\" >>check.db2current
				test -n \"$FIX\" && echo \"DELETE FROM history WHERE rowid='\$rowid';\"
			fi
			shift
		done
		echo 'END TRANSACTION;'"

	$SQLITE "SELECT dirname || '/' || filename,
			rowid
		FROM history
		WHERE freq = 0
		ORDER BY dirname;" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE
}

db2old ()
{
	echo "Checking DB => old FS"

	cmd="	echo '.timeout 10000'
		echo 'BEGIN TRANSACTION;'
		while test \$# -ge 1; do
			filename=\"\${1%%|*}\"
			rowid=\"\${1##*|}\"
			if ! test -e \"$BACKUP_MAIN/\$filename\"; then
				echo \"$BACKUP_MAIN/\$filename\" >>check.db2old
				test -n \"$FIX\" && echo \"DELETE FROM history WHERE rowid='\$rowid';\"
			fi
			shift
		done
		echo 'END TRANSACTION;'"

	$SQLITE "SELECT dirname || '/' || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted,
			rowid
		FROM history
		ORDER BY dirname;" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE
}

current2db ()
{
	echo "Checking current FS => DB"

	/usr/bin/find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%P\n' | sed '/"/d;s_^\(\(.*\)/\)\?\(.*\)$_SELECT CASE WHEN EXISTS(SELECT 1 FROM history WHERE dirname="\2" AND filename="\3" AND freq=0 LIMIT 1) THEN 1 ELSE "\2/\3" END;_' | $SQLITE | fgrep -v -x 1 | (
		if test -n "$FIX"; then
			cd "$BACKUP_CURRENT"
			tee "$BACKUP_ROOT/check.current2db" | fgrep -vz -f- "$BACKUP_LIST" >"$BACKUP_LIST.new"
			mv "$BACKUP_LIST.new" "$BACKUP_LIST"
		else
			cat >"$BACKUP_ROOT/check.current2db"
		fi
	)
}

old2db ()
{
	echo "Checking old FS => DB"
	/usr/bin/find "$BACKUP_MAIN" \( -type f -o -type l \) -printf '%P\n' | sed '/"/d;s_^\(\(.*\)/\)\?\(.*\)/\(.*\)'"$BACKUP_TIME_SEP"'\(.*\)$_SELECT CASE WHEN EXISTS(SELECT 1 FROM history WHERE dirname="\2" AND filename="\3" AND created="\4" AND deleted="\5" LIMIT 1) THEN 1 ELSE "\2/\3/\4'"$BACKUP_TIME_SEP"'\5" END;_' | $SQLITE | fgrep -v -x 1 | (
		if test -n "$FIX"; then
			cd "$BACKUP_MAIN"
			tee "$BACKUP_ROOT/check.old2db" | tr '\n' '\0' | xargs -0 rm -f
		else
			cat >"$BACKUP_ROOT/check.old2db"
		fi
	)
}

current2old ()
{
	echo "Checking current FS => old FS"

	/usr/bin/find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%i %P\n' | while read inode fullname; do
		ls -i "$BACKUP_MAIN/$fullname" 2>/dev/null | grep -q "^ *$inode " || echo "$fullname"
	done | (
		if test -n "$FIX"; then
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
			tee "$BACKUP_ROOT/check.current2old" | sed 's/.*/s|^[0-9]* &$|0 &|;/' | /bin/sed -z -f /dev/stdin "$BACKUP_LIST" >"$BACKUP_LIST.new"
			LC_ALL=POSIX sort -z "$BACKUP_LIST.new" >"$BACKUP_LIST"
		else
			cat >"$BACKUP_ROOT/check.current2old"
		fi
	)
}

db_overlaps ()
{
	echo "Checking overlapping dates in DB"
	cmd="	echo '.timeout 10000'
		echo 'BEGIN TRANSACTION;'
		while test \$# -ge 1; do
			filenames=\"\${1%|*}\"
			filename1=\"\${filenames%%|*}\"
			filename2=\"\${filenames##*|}\"
			sql=\"\${1##*|}\"
			echo \"[\$filename1][\$filename2][\$sql]\" >>check.db_overlaps
			if test -n \"$FIX\"; then
				mv \"$BACKUP_MAIN/\$filename1\" \"$BACKUP_MAIN/\$filename2\"
				echo \"\$sql\"
			fi
			shift
		done
		echo 'END TRANSACTION;'"
	$SQLITE "SELECT
			a.dirname || '/' || a.filename || '/' || a.created || '$BACKUP_TIME_SEP' || a.deleted,
			a.dirname || '/' || a.filename || '/' || a.created || '$BACKUP_TIME_SEP' || b.created,
			'UPDATE history SET deleted = \"' || b.created || '\" WHERE rowid = \"' || a.rowid || '\";'
		FROM history AS a, history AS b
		WHERE a.created < b.created
			AND a.dirname = b.dirname
			AND a.filename = b.filename
			AND a.created < b.deleted
			AND b.created < a.deleted
		GROUP BY a.dirname, a.filename, a.created
		ORDER BY a.dirname;" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE
}

db_order ()
{
	if test -n "$FIX"; then
		echo "Deleting where created not < deleted in DB"
		$SQLITE "DELETE
			FROM history
			WHERE created >= deleted;"
	else
		echo "Checking that created < deleted in DB"
		$SQLITE "SELECT *
			FROM history
			WHERE created >= deleted;" >check.db_order
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
		);" >check.db_dups_created
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
			;" >check.db_dups_freq0
}

db_freq ()
{
	if test -n "$DELETE_MISSING"; then
		echo "Fixing freq in DB"
		$SQLITE "UPDATE history
			SET freq = CASE
				WHEN strftime('%Y-%m', created, '-1 minute') !=
				     strftime('%Y-%m', deleted, '-1 minute')
				     THEN 1 -- different month
				WHEN strftime('%Y %W', created, '-1 minute') !=
				     strftime('%Y %W', deleted, '-1 minute')
				     THEN 5 -- different week
				WHEN strftime('%Y-%m-%d', created, '-1 minute') !=
				     strftime('%Y-%m-%d', deleted, '-1 minute')
				     THEN 30 -- different day
				WHEN strftime('%Y-%m-%d %H', created, '-1 minute') !=
				     strftime('%Y-%m-%d %H', deleted, '-1 minute')
				     THEN 720 -- different hour
				ELSE $BACKUP_MAX_FREQ
			END
			WHERE freq != 0;"
	else
		echo "Checking freq in DB"
		$SQLITE "SELECT *
			FROM history
			WHERE freq != 0 AND
			freq != CASE
				WHEN strftime('%Y-%m', created, '-1 minute') !=
				     strftime('%Y-%m', deleted, '-1 minute')
				     THEN 1 -- different month
				WHEN strftime('%Y %W', created, '-1 minute') !=
				     strftime('%Y %W', deleted, '-1 minute')
				     THEN 5 -- different week
				WHEN strftime('%Y-%m-%d', created, '-1 minute') !=
				     strftime('%Y-%m-%d', deleted, '-1 minute')
				     THEN 30 -- different day
				WHEN strftime('%Y-%m-%d %H', created, '-1 minute') !=
				     strftime('%Y-%m-%d %H', deleted, '-1 minute')
				     THEN 720 -- different hour
				ELSE $BACKUP_MAX_FREQ
			END;" >check.db_freq
	fi
}

test -e check.sh && exit 3
rm check.*

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

$SQLITE "DROP INDEX IF EXISTS check_tmp;VACUUM;ANALYZE;"

wc -l check.*
