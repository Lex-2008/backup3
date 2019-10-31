#!/bin/busybox ash
#
# Script to check that database matches filesystem.
#
# Optional argument --fix to correct info
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

# see backup1.sh for explanation
BACKUP_MAX_FREQ_SEC="$(echo "2592000 $BACKUP_MAX_FREQ / p" | dc)"

SQLITE="sqlite3 $BACKUP_DB"

# wait for lock to be available
exec 200>"$BACKUP_FLOCK"
flock 200 || exit 200

if test "$1" = '--fix'; then
	FIX=1
	export FIX
	shift
fi

if test -n "$1"; then
	ONLY="$1"
	export ONLY
fi


db2current ()
{
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
		echo 'END TRANSACTION;'
		"
	$SQLITE "SELECT dirname || '/' || filename,
			rowid
		FROM history
		WHERE freq = 0
		ORDER BY dirname;" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE
}

db2old ()
{
	cmd="	echo '.timeout 10000'
		echo 'BEGIN TRANSACTION;'
		while test \$# -ge 1; do
			filename=\"\${1%%|*}\"
			rowid=\"\${1##*|}\"
			if ! test -e \"$BACKUP_MAIN/\$filename\"; then
				echo \"\$filename\" >>check.db2old
				test -n \"$FIX\" && echo \"DELETE FROM history WHERE rowid='\$rowid';\"
			fi
			shift
		done
		echo 'END TRANSACTION;'
		"
	$SQLITE "SELECT dirname || '/' || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted,
			rowid
		FROM history
		ORDER BY dirname;" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE
}

current2db ()
{
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
	if test -n "$FIX"; then
		/usr/bin/find "$BACKUP_MAIN" \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" -printf '%P\0' | /bin/sed -z -r "
		s/'/''/g;
		1i BEGIN TRANSACTION;
		s_^((.*)/)?(.*)/(.*)$BACKUP_TIME_SEP(.*)\$_	\\
			INSERT INTO history(dirname, filename, created, deleted, freq)	\\
			SELECT '\\2', '\\3', '\\4', '\\5', 0	\\
			WHERE NOT EXISTS (	\\
				SELECT 1	\\
				FROM history	\\
				WHERE dirname='\\2'	\\
				  AND filename='\\3'	\\
				  AND created='\\4'	\\
				  AND deleted='\\5'	\\
				LIMIT 1);	\\
			_
		  \$a END TRANSACTION;
		" | tr '\0' '\n' | $SQLITE
	else
		/usr/bin/find "$BACKUP_MAIN" \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" -printf '%P\0' | /bin/sed -z -r "
		s/'/''/g;
		1i BEGIN TRANSACTION;
		s_^((.*)/)?(.*)/(.*)$BACKUP_TIME_SEP(.*)\$_	\\
		SELECT CASE WHEN EXISTS	\\
		  (SELECT 1	\\
		   FROM history	\\
		   WHERE dirname='\\2'	\\
		     AND filename='\\3'	\\
		     AND created='\\4'	\\
		     AND deleted='\\5'	\\
		   LIMIT 1) THEN 1	\\
                  ELSE '\\1\\3/\\4$BACKUP_TIME_SEP\\5'	\\
		  END;_
		  \$a END TRANSACTION;
		  " | tr '\0' '\n' | $SQLITE | fgrep -v -x 1 >"$BACKUP_ROOT/check.old2db"
	fi
}

old2current ()
{
	cmd="	len=
		while test \$# -ge 1; do
			# remove $BACKUP_MAIN prefix from filename
			filename=\"\${1:${#BACKUP_MAIN}}\"
			if ! test -f \"$BACKUP_CURRENT/\$filename\"; then
				echo \"$filename\"
				test -n \"$FIX\" && ln \"\$1\" \"$BACKUP_CURRENT/\$filename\"
			fi
			shift
		done"
	/usr/bin/find "$BACKUP_MAIN" \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" -printf '%h\0' | xargs -0 sh -c "$cmd" x
}

current2old ()
{
	cmd="	while test \$# -ge 1; do
			inode=\"\${1%%|*}\"
			fullname=\"\${1##*|}\"
			ls -i \"$BACKUP_MAIN/\$fullname\" 2>/dev/null | grep -q \"^ *\$inode \" || echo \"\$fullname\"
			shift
		done"
	/usr/bin/find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%i|%P\0' | xargs -0 sh -c "$cmd" x | (
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
			tee "$BACKUP_ROOT/check.current2old" | fgrep -vz -f- "$BACKUP_LIST" >"$BACKUP_LIST.new"
			sed 's/^/0 /' "$BACKUP_ROOT/check.current2old" | tr '\n' '\0' >>"$BACKUP_LIST.new"
			LC_ALL=POSIX sort -z "$BACKUP_LIST.new" >"$BACKUP_LIST"
			rm "$BACKUP_LIST.new"
		else
			cat >"$BACKUP_ROOT/check.current2old"
		fi
	)
}

db_overlaps ()
{
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
		echo 'END TRANSACTION;'
		"
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
		GROUP BY a.dirname, a.filename, a.created;
		" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE
}

db_order ()
{
	if test -n "$FIX"; then
		$SQLITE "DELETE
			FROM history
			WHERE created >= deleted;"
	else
		$SQLITE "SELECT *
			FROM history
			WHERE created >= deleted;" >check.db_order
	fi
}

db_dups_created ()
{
	if test -n "$FIX"; then
		operation="DELETE"
	else
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
	if test -n "$FIX"; then
		query="UPDATE history SET freq = CASE"
	else
		query="SELECT * FROM history WHERE freq != CASE"
	fi
	$SQLITE "$query
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
}

check () {
	test -n "$ONLY" -a "$ONLY" != "$1" && return
	echo ===== $1 =====
	$1
	test -s check.$1 || return
	head check.$1
}

if test -e check.sh; then
	cd "$BACKUP_ROOT"
	test -e check.sh && exit 3
fi
rm check.*

$SQLITE "CREATE INDEX IF NOT EXISTS check_tmp ON history(dirname, filename, created);ANALYZE;"

# Tests that might add new files in current
check old2current

# Tests that might delete some DB rows
check db_order
check db2current
check db2old
check db_dups_created

# Tests that might add new rows with wrong freq
check old2db

# Tests that might change created date (and invalidate freq)
check db_overlaps

# Tests that fix freq according to created/deleted
check db_freq

# Tests that remove files from files.txt
check current2db
check current2old

# This test should never fail
check db_dups_freq0

$SQLITE "DROP INDEX IF EXISTS check_tmp;VACUUM;"

wc -l check.*
