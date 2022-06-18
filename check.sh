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
		ORDER BY dirname;" | $SQLITE | (
			echo '.timeout 10000'
			echo 'BEGIN TRANSACTION;'
			while IFS="$NL" read -r f; do
				filename="${f%%|*}"
				rowid="${f##*|}"
				if ! test -e "$BACKUP_CURRENT/$filename" -o -L "$BACKUP_CURRENT/$filename"; then
					echo "$BACKUP_CURRENT/$filename" >>check.db2current
					test -n "$FIX" && echo "DELETE FROM history WHERE rowid='$rowid';"
				fi
			done
			echo 'END TRANSACTION;'
			) | $SQLITE
}

db2old ()
{
	echo "SELECT dirname || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted,
			rowid
		FROM history
		WHERE type != 'd'
		ORDER BY dirname;" | $SQLITE | (
			echo '.timeout 10000'
			echo 'BEGIN TRANSACTION;'
			while IFS="$NL" read -r f; do
				filename="${f%%|*}"
				rowid="${f##*|}"
				if ! test -e "$BACKUP_MAIN/$filename" -o -L "$BACKUP_MAIN/$filename"; then
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
	my_find "$BACKUP_CURRENT" . | sed -r "
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
			LIMIT 1	\\
		) THEN 1	\\
		ELSE '\\2\\3' END;_" | $SQLITE | fgrep -v -x 1 >"$BACKUP_ROOT/check.current2db"
}

old2db ()
{
	if test -n "$FIX"; then
		my_find "$BACKUP_MAIN" . \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" | sed -r "
		s/'/''/g;
		1i BEGIN TRANSACTION;
		s_^([0-9]*) . (.*/)([^/]*)/([^/$BACKUP_TIME_SEP]*)$BACKUP_TIME_SEP([^/$BACKUP_TIME_SEP]*)\$_	\\
			INSERT INTO history(inode, dirname, filename, created, deleted)	\\
			SELECT '\\1', '\\2', '\\3', '\\4', '\\5'	\\
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
	find . \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" | while IFS="$NL" read -r f; do
				# $f points to the file in data dir - i.e. it's like this:
				# dirname/filename/created~now
				filename="${f%/*}"
				if ! test -f "$BACKUP_CURRENT/$filename" -o -L "$BACKUP_CURRENT/$filename"; then
					echo "ln $BACKUP_MAIN/$f => $BACKUP_CURRENT/$filename" >>$OLDPWD/check.old2current
					if test -n "$FIX"; then
						mkdir -p "$BACKUP_CURRENT/${filename%/*}"
						ln "$BACKUP_MAIN/$f" "$BACKUP_CURRENT/$filename"
					fi
				fi
			done
	cd -> /dev/null
}

current2old ()
{
	test -n "$FIX" && echo "current2old: --fix is not supported"
	my_find "$BACKUP_CURRENT" . -type f -o -type l | sed -r 's/^([0-9]*) . (.*)/\1|\2/' | while IFS="$NL" read -r f; do
		inode="${f%%|*}"
		fullname="${f##*|}"
		ls -i "$BACKUP_MAIN/$fullname" 2>/dev/null | grep -q "^ *$inode " || echo "$fullname"
	done >"$BACKUP_ROOT/check.current2old"
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
			while IFS="$NL" read -r f; do
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
	echo "SELECT dirname || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted
		FROM history
		WHERE created >= deleted;" | $SQLITE | while IFS="$NL" read -r f; do
			echo rm "$BACKUP_MAIN/$f" >>check.db_order
			test -n "$FIX" && rm "$BACKUP_MAIN/$f"
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

# Tests that might delete files in 'old' but leave entries in db
# db2old will remove them from db, but they will remain in 'current'
check db_order

# Tests that might delete some DB rows
check db2current
check db2old
check db_dups_created

# Tests that might change created date
check db_overlaps

# Tests that might add new rows
check old2db

# Tests that do not have '--fix' option
# (fixed by running `backup.sh`)
check current2db
check current2old

# This test should never fail
check db_dups_freq0

echo "DROP INDEX IF EXISTS check_tmp;CREATE UNIQUE INDEX history_update ON history(dirname, filename) WHERE freq = 0;VACUUM;" | $SQLITE

wc -l check.*

# release the lock
rm "$BACKUP_FLOCK"
