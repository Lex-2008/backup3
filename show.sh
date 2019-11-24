#!/bin/busybox ash
#
# Script to show contents of archive for a given date.
#
# Call it like this:
# $ show.sh "2018-12-24 00:24" stuff /tmp/dir
# to hard-link files from "stuff" directory in backup to /tmp/dir

test -z "$BACKUP_ROOT"    && exit 2
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"

SHOW_DATE="$1"
SHOW_DIR="$2"
SHOW_IN="$3"

SQLITE="sqlite3 $BACKUP_DB"

rm -rf "$SHOW_IN"

# TODO: Check performance, we don't have an index for this
sql="PRAGMA case_sensitive_like = ON;
	SELECT	dirname || filename,
		created || '$BACKUP_TIME_SEP' || deleted
	FROM history
	WHERE dirname LIKE '$SHOW_DIR%'
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
