#!/bin/busybox ash
#
# Script to check that database matches filesystem.
#
# Optional argument --fix to correct info
# corresponding DB entry / file

. "${0%/*}/common.sh"
acquire_lock

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
	echo "SELECT dirname || filename,
			rowid
		FROM history
		WHERE freq = 0
		  AND type != 'd'
		ORDER BY dirname;" | $SQLITE | (
			echo '.timeout 10000'
			echo 'BEGIN TRANSACTION;'
			while IFS="$NL" read f; do
				filename="${f%%|*}"
				rowid="${f##*|}"
				if ! test -f "$BACKUP_CURRENT/$filename" -o -L "$BACKUP_CURRENT/$filename"; then
					echo "$BACKUP_CURRENT/$filename" >>check.db2current
					test -n "$FIX" && echo "DELETE FROM history WHERE rowid='$rowid';"
				fi
			done
			echo 'END TRANSACTION;'
			) | $SQLITE
}

db2current_dirs ()
{
	echo "SELECT dirname || filename,
			rowid
		FROM history
		WHERE freq = 0
		  AND type = 'd'
		ORDER BY dirname;" | $SQLITE | (
			echo '.timeout 10000'
			echo 'BEGIN TRANSACTION;'
			while IFS="$NL" read f; do
				filename="${f%%|*}"
				rowid="${f##*|}"
				if ! test -d "$BACKUP_CURRENT/$filename"; then
					echo "$BACKUP_CURRENT/$filename" >>check.db2current_dirs
					test -n "$FIX" && echo "DELETE FROM history WHERE rowid='$rowid';"
				fi
			done
			echo 'END TRANSACTION;'
			) | $SQLITE
}

db2old ()
{
	cmd="	echo '.timeout 10000'
		echo 'BEGIN TRANSACTION;'
		while test \$# -ge 1; do
			filename=\"\${1%%|*}\"
			rowid=\"\${1##*|}\"
			if ! test -f \"$BACKUP_MAIN/\$filename\" -o -L \"$BACKUP_MAIN/\$filename\"; then
				echo \"$BACKUP_MAIN/\$filename\" >>check.db2old
				test -n \"$FIX\" && echo \"DELETE FROM history WHERE rowid='\$rowid';\"
			fi
			shift
		done
		echo 'END TRANSACTION;'
		"
	echo "SELECT dirname || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted,
			rowid
		FROM history
		WHERE type != 'd'
		ORDER BY dirname;" | $SQLITE | (
			echo '.timeout 10000'
			echo 'BEGIN TRANSACTION;'
			while IFS="$NL" read f; do
				filename="${f%%|*}"
				rowid="${f##*|}"
				if ! test -f "$BACKUP_MAIN/$filename" -o -L "$BACKUP_MAIN/$filename"; then
					echo "$BACKUP_MAIN/$filename" >>check.db2old
					test -n "$FIX" && echo "DELETE FROM history WHERE rowid='$rowid';"
				fi
			done
			echo 'END TRANSACTION;'
			) | $SQLITE
}

current2db ()
{
	test -n "$FIX" && echo "current2db: --fix is not supported"
	my_find "$BACKUP_CURRENT" . -type f -o -type l | sed -r "
	s/'/''/g
	s_^([0-9]*) . (.*/)([^/]*)_	\\
	SELECT CASE	\\
		WHEN EXISTS(	\\
			SELECT 1	\\
			FROM history	\\
			WHERE inode='\\1'	\\
			AND dirname='\\2'	\\
			AND filename='\\3'	\\
			AND freq=0	\\
			AND type != 'd'	\\
			LIMIT 1	\\
		) THEN 1	\\
		ELSE '\\2\\3' END;_" | $SQLITE | fgrep -v -x 1 >"$BACKUP_ROOT/check.current2db"
}

current2db_dirs ()
{
	test -n "$FIX" && echo "current2db_dirs: --fix is not supported"
	my_find "$BACKUP_CURRENT" . -type d | sed -r "
	s/'/''/g
	s_^([0-9]*) . (.*/)([^/]*)_	\\
	SELECT CASE	\\
		WHEN EXISTS(	\\
			SELECT 1	\\
			FROM history	\\
			WHERE inode='\\1'	\\
			AND dirname='\\2'	\\
			AND filename='\\3'	\\
			AND freq=0	\\
			AND type = 'd'	\\
			LIMIT 1	\\
		) THEN 1	\\
		ELSE '\\1|\\2|\\3' END;_" | $SQLITE | fgrep -v -x 1 >"$BACKUP_ROOT/check.current2db_dirs"
}

old2db ()
{
	if test -n "$FIX"; then
		my_find "$BACKUP_MAIN" . \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" | sed -r "
		s/'/''/g;
		1i BEGIN TRANSACTION;
		s_^([0-9]*) . (.*/)([^/]*)/([^/$BACKUP_TIME_SEP]*)$BACKUP_TIME_SEP([^/$BACKUP_TIME_SEP]*)\$_	\\
			INSERT INTO history(inode, dirname, filename, created, deleted, freq)	\\
			SELECT '\\1', '\\2', '\\3', '\\4', '\\5', 0	\\
			WHERE NOT EXISTS (	\\
				SELECT 1	\\
				FROM history	\\
				WHERE dirname='\\2'	\\
				  AND filename='\\3'	\\
				  AND created='\\4'	\\
				  AND deleted='\\5'	\\
				  AND inode='\\1'	\\
				  AND type!='d'	\\
				LIMIT 1);	\\
			_
		  \$a END TRANSACTION;
		" | $SQLITE
	else
		my_find "$BACKUP_MAIN" . \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" | sed -r "
		s/'/''/g;
		s_^([0-9]*) . (.*/)([^/]*)/([^/$BACKUP_TIME_SEP]*)$BACKUP_TIME_SEP([^/$BACKUP_TIME_SEP]*)\$_	\\
		SELECT CASE WHEN EXISTS	\\
		  (SELECT 1	\\
		   FROM history	\\
		   WHERE dirname='\\2'	\\
		     AND filename='\\3'	\\
		     AND created='\\4'	\\
		     AND deleted='\\5'	\\
		     AND inode='\\1'	\\
		     AND type!='d'	\\
		   LIMIT 1) THEN 1	\\
                  ELSE '\\2\\3/\\4$BACKUP_TIME_SEP\\5'	\\
		  END;_
		  " | $SQLITE | fgrep -v -x 1 >"$BACKUP_ROOT/check.old2db"
	fi
}

old2current ()
{
	cd "$BACKUP_MAIN"
	find . \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" | while IFS="$NL" read f; do
				# $f points to the file in data dir - i.e. it's like this:
				# dirname/filename/created~now
				filename="${f%/*}"
				if ! test -f "$BACKUP_CURRENT/$filename" -o -L "$BACKUP_CURRENT/$filename"; then
					echo "ln $BACKUP_MAIN/$1 => $BACKUP_CURRENT/$filename"
					if test -n "$FIX"; then
						mkdir -p "$BACKUP_CURRENT/${filename%/*}"
						ln "$BACKUP_MAIN/$1" "$BACKUP_CURRENT/$filename"
					fi
				fi
			done
	cd -> /dev/null
}

current2old ()
{
	my_find "$BACKUP_CURRENT" . -type f -o -type l | sed -r 's/^([0-9]*) . (.*)/\1|\2/' | while IFS="$NL" read f; do
		inode="${f%%|*}"
		fullname="${f##*|}"
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
	echo "SELECT
			a.dirname || a.filename || '/' || a.created || '$BACKUP_TIME_SEP' || a.deleted,
			a.dirname || a.filename || '/' || a.created || '$BACKUP_TIME_SEP' || b.created,
			'UPDATE history SET deleted = \"' || b.created || '\" WHERE rowid = \"' || a.rowid || '\";'
		FROM history AS a, history AS b
		WHERE a.created < b.created
			AND a.dirname = b.dirname
			AND a.filename = b.filename
			AND a.created < b.deleted
			AND b.created < a.deleted
		GROUP BY a.dirname, a.filename, a.created;
		" | $SQLITE | (
			echo '.timeout 10000'
			echo 'BEGIN TRANSACTION;'
			while IFS="$NL" read f; do
				filenames="${f%|*}"
				filename1="${filenames%%|*}"
				filename2="${filenames##*|}"
				sql="${f##*|}"
				echo "[$filename1][$filename2][$sql]" >>check.db_overlaps
				if test -n "$FIX"; then
					mv "$BACKUP_MAIN/$filename1" "$BACKUP_MAIN/$filename2"
					echo "$sql"
				fi
			done
			echo 'END TRANSACTION;'
			) | $SQLITE
}

db_order ()
{
	cmd="	while test \$# -ge 1; do
			echo rm \"$BACKUP_MAIN/\$1\"
			test -n \"$FIX\" && rm \"$BACKUP_MAIN/\$1\"
			shift
		done
		"
	echo "SELECT dirname || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted
		FROM history
		WHERE created >= deleted;" | $SQLITE | while IFS="$NL" read f; do
			echo rm "$BACKUP_MAIN/$1" >>check.db_order
			test -n "$FIX" && rm "$BACKUP_MAIN/$1"
		done
}

db_dups_created ()
{
	if test -n "$FIX"; then
		operation="DELETE"
	else
		operation="SELECT *"
	fi
	echo "$operation FROM history
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
		); " | $SQLITE >check.db_dups_created
}

db_dups_freq0 ()
{
	echo "SELECT a.*, b.created
		FROM history AS a,
		history AS b
		WHERE a.freq = 0
			AND a.rowid < b.rowid
			AND a.dirname = b.dirname
			AND a.filename = b.filename
			AND b.freq = 0
			;" | $SQLITE >check.db_dups_freq0
}

db_freq ()
{
	if test -n "$FIX"; then
		query="UPDATE history SET freq = CASE"
	else
		query="SELECT * FROM history WHERE freq != CASE"
	fi
	echo "$query
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

echo "BEGIN TRANSACTION; DROP INDEX IF EXISTS history_update; CREATE INDEX IF NOT EXISTS check_tmp ON history(dirname, filename, created);ANALYZE; END TRANSACTION;" | $SQLITE

# Tests that might add new files in current
check old2current

# Tests that might delete some files in db
check db_order

# Tests that might delete some DB rows
check db2current
check db2current_dirs
check db2old
check db_dups_created

# Tests that might change created date (and invalidate freq)
check db_overlaps

# Tests that might add new rows with wrong freq
check old2db

# Tests that fix freq according to created/deleted
check db_freq

# Tests that remove files from files.txt
check current2db
check current2db_dirs
check current2old

# This test should never fail
check db_dups_freq0

echo "DROP INDEX IF EXISTS check_tmp;CREATE UNIQUE INDEX history_update ON history(dirname, filename) WHERE freq = 0;VACUUM;" | $SQLITE

wc -l check.*

# release the lock
rm "$BACKUP_FLOCK"
