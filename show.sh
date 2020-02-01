#!/bin/busybox ash
#
# Script to show contents of archive for a given date.
#
# Call it like this:
# $ show.sh "2018-12-24 00:24" ./stuff/ /tmp/dir
# to hard-link files from "./stuff/" directory in backup to "/tmp/dir"
# Note that "./stuff/" should begin with "./" and end with "/", as dirname are
# stored in DB, but "/tmp/dir" might be without trailing slash.

. "$(dirname "$0")/common.sh"

SHOW_DATE="$1"
SHOW_DIR="$2"
SHOW_IN="$3"

rm -rf "$SHOW_IN"

# TODO: Check performance, we don't have an index for this
sql="PRAGMA case_sensitive_like = ON;
	SELECT	dirname || filename,
		created || '$BACKUP_TIME_SEP' || deleted
	FROM history
	WHERE dirname LIKE '$SHOW_DIR%'
	  AND created <= '$SHOW_DATE'
	  AND deleted > '$SHOW_DATE';"

echo "$sql" | $SQLITE | tr '\n' '\0' | while IFS="$NL" read f; do
	fullname="${f%|*}"
	times="${f#*|}"
	mkdir -p "$SHOW_IN/$(dirname "$fullname")"
	ln "$BACKUP_MAIN/$fullname/$times" "$SHOW_IN/$fullname"
done
