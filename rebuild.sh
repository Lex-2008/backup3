#!/bin/busybox ash
#
# Rebuild database from files.

. "${0%/*}/common.sh"

echo "### DATABASE ###"

rm "$BACKUP_DB"

echo "1: create"
$BACKUP_BIN/init.sh --noindex

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
# https://stackoverflow.com/a/34665012
echo "WITH RECURSIVE cte(org, parent, name, rest, pos, data1, data2) AS (
		SELECT dirname, '', '.', SUBSTR(dirname,3), 0, min(created), max(deleted) FROM history
		GROUP BY dirname
	UNION ALL
		SELECT org,
		SUBSTR(org,1,pos+length(name)+1) as parent,
		SUBSTR(rest,1,INSTR(rest, '/')-1) as name,
		SUBSTR(rest,INSTR(rest,'/')+1) as rest,
		pos+length(name)+1 as pos,
		data1, data2
	FROM cte
	WHERE rest <> ''
)
INSERT INTO history (inode, type, dirname, filename, created, deleted, freq)
SELECT 0, 'd', parent, name, min(data1), max(data2), 0
FROM cte
WHERE pos <> 0
GROUP BY parent, name;" | $SQLITE

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
$BACKUP_BIN/init.sh --notable

if test "$1" = "--current"; then
	echo "### CURRENT ###"

	rm -rf "$BACKUP_CURRENT"

	# note that this simply prints fiilenames so no need to use my_find
	cd "$BACKUP_MAIN"
	find . $BACKUP_FIND_FILTER -not -type d -name "*$BACKUP_TIME_SEP$BACKUP_TIME_NOW" | while IFS="$NL" read f; do
		fullname="$(dirname "$f")"
		mkdir -p "$BACKUP_CURRENT/$(dirname "$fullname")"
		ln "$BACKUP_MAIN/$f" "$BACKUP_CURRENT/$fullname"
	done
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
