#!/bin/busybox ash
#
# Script to show contents of archive for a given date.
#
# Call it like this:
# $ show.sh "2018-12-24 00:24" ./path/to/ stuff/ /tmp/dir
# to hard-link files from "./path/to/stuff/" directory in backup to "/tmp/dir"
# Note that "./path/to/" must begin with "./" and end with "/", exactly as
# stored in DB, but "/tmp/dir" might be without trailing slash.
#
# To show a dir in the root:
# $ show.sh "2018-12-24 00:24" ./ browsers/ /tmp/dir
#
# To show root itself (i.e. everything):
# $ show.sh "current" '' ./ /tmp/dir
# After that, contents of /tmp/dir should be equal to $BACKUP_CURRENT

test -z "$BACKUP_ROOT"    && exit 2
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"

SHOW_DATE="$1"
SHOW_PARENT="$2"
SHOW_DIR="$3"
SHOW_IN="$4"

SQLITE="sqlite3 $BACKUP_DB"

rm -rf "$SHOW_IN"

# TODO: Check performance, we don't have an index for this. It could be INDEXED
# BY history_update, but history_update has history.freq = 0, which is not
# applicable here
sql="PRAGMA case_sensitive_like = ON;
	SELECT	parent || dirname || filename,
		created || '$BACKUP_TIME_SEP' || deleted
	FROM history
	WHERE (
		( -- list all files in given dir
			history.parent = '$SHOW_PARENT'
			AND
			history.dirname = '$SHOW_DIR'
		)
		OR
		( -- and in all of its subdirs
			history.parent LIKE '$SHOW_PARENT$SHOW_DIR%'
		)
	)
	  AND created <= '$SHOW_DATE'
	  AND deleted > '$SHOW_DATE';"

cmd="
	while test \$# -ge 1; do
		fullname=\"\${1%|*}\"
		times=\"\${1#*|}\"
		mkdir -p \"$SHOW_IN/\$(dirname \"\$fullname\")\"
		ln \"$BACKUP_MAIN/\$fullname/\$times\" \"$SHOW_IN/\$fullname\"
		shift
	done
"

$SQLITE "$sql" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x
