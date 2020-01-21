#!/bin/busybox ash

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_SHOW"    && BACKUP_SHOW=$BACKUP_ROOT/show
test -z "$BACKUP_PASS"    && BACKUP_PASS=$BACKUP_ROOT/pass.txt
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640
test -z "$SQLITE"         && SQLITE="sqlite3 $BACKUP_DB"

# init # doesn't return anything, just creates index
#       ls|dir|date
# timeline|dir
#      tar|dir|date
#      get|dir|date|file
#       ll|dir|*|file

if test "$QUERY_STRING" = "|init"; then
	echo "HTTP/1.0 200 OK"
	echo "Cache-Control: max-age=600"
	echo
	echo "CREATE INDEX IF NOT EXISTS api ON history(dirname);" | $SQLITE
	echo .
	exit 0
fi


IFS='|' read -r pass request dir date file <<EOL
$(busybox httpd -d "$QUERY_STRING")
EOL
# TODO: clean them from '

# # TODO: protect agains hacks like 'asd/../../../../'
# # also protect against accessing password-protected dirs via 'public/../private/..'
# # maybe match for '(^|/)..(/|$)' would be enough?
# file="$(realpath --no-symlinks -m "$PWD/$request")"
# if [ "$(expr substr "$file" 1 ${#PWD})" != "$PWD" ]; then
# # if [ "${file:0:${#PWD}}" != "$PWD" ]; then
# 	echo "HTTP/1.0 403 Forbidden"
# 	echo
# 	echo "$PWD/$request"
# 	echo $file
# 	exit 0
# fi

root="${dir#./}"
root="${root%%/*}"

# check root-pass by trying to SMB into requested share
if test -f "$BACKUP_CURRENT/$root.pw"; then
	IFS='|' read -r user share <"$BACKUP_CURRENT/$root.pw"
	if expr index "$pass" ' ' >/dev/null; then
		IFS=' ' read -r user pass <<EOL
$pass
EOL
	fi
	if ! smbclient -U "$user" -c exit "$share" "$pass" >/dev/null 2>&1; then
		echo "HTTP/1.0 403 Forbidden"
		echo
		echo "$BACKUP_CURRENT/$root.pw"
		cat  "$BACKUP_CURRENT/$root.pw"
		echo "[$user][$pass][$share]"
		echo smbclient -U "$user" -c exit "$share" "$pass" 2>&1
		exit 1
	fi
fi

case "$request" in
	(ls)
		echo "HTTP/1.0 200 OK"
		echo "Cache-Control: max-age=600"
		echo
		echo "SELECT filename, type, created || '$BACKUP_TIME_SEP' || deleted
			FROM history
			WHERE dirname = '$dir'
			  AND created <= '$date'
			  AND deleted > '$date'
			  AND filename!='.'
			  ORDER BY type, filename;" | $SQLITE
	;;
	(timeline)
		echo "HTTP/1.0 200 OK"
		echo "Cache-Control: max-age=600"
		# echo "Content-Encoding: gzip"
		echo
		echo "PRAGMA case_sensitive_like = ON;
		CREATE TEMP TABLE api AS
		SELECT created, deleted,
			CASE
				WHEN freq <= $BACKUP_MAX_FREQ THEN freq
				ELSE 43800 -- every minute
			END AS freq
		FROM history
		WHERE dirname = '$dir';
		  -- AND freq != 0; -- *why*?
		SELECT datetime(created) FROM api
		UNION
		SELECT datetime(deleted) FROM api
		WHERE freq != 0;
		SELECT '===';
		SELECT freq, datetime(MIN(deleted))
			FROM api
			WHERE freq != 0
			GROUP BY freq;" | $SQLITE # | gzip
	;;
	(tar)
		export BACKUP_ROOT BACKUP_MAIN BACKUP_DB
		# TODO: mktmp
		filename="$(basename "$BACKUP_SHOW/$dir")"
		echo "HTTP/1.0 200 OK"
		echo "Cache-Control: max-age=3600"
		echo "Content-Disposition: attachment; filename=\"$(basename "$filename").tar\""
		# https://lists.gnu.org/archive/html/bug-tar/2007-01/msg00013.html
		../../show.sh "$date" "$dir" "$BACKUP_SHOW"
		echo -n "Content-Length: "
		/bin/tar --create --ignore-failed-read --one-file-system --preserve-permissions --sparse -C "$BACKUP_SHOW/$dir/.." "$filename" --totals --file=/dev/null 2>&1 | sed '/Total bytes written/!d;s/.*: \([0-9]*\) (.*/\1/'
		echo
		/bin/tar --create --ignore-failed-read --one-file-system --preserve-permissions --sparse -C "$BACKUP_SHOW/$dir/.." "$filename"
		rm -rf "$BACKUP_SHOW"
	;;
	(get)
		echo "HTTP/1.0 200 OK"
		echo "Cache-Control: max-age=600"
		filename="$BACKUP_MAIN/$dir/$file/$date"
		echo "Content-Disposition: attachment; filename=\"$file\""
		test -f "$filename" || exit 2
		stat -c 'Content-Length: %s' "$filename"
		echo
		cat "$filename"
	;;
	(ll)
		echo "HTTP/1.0 200 OK"
		echo "Cache-Control: max-age=600"
		echo
		echo "$BACKUP_TIME_SEP"
		echo "$BACKUP_TIME_NOW"
		echo "SELECT created, deleted, freq
			FROM history
			WHERE dirname = '$dir'
			  AND filename = '$file';" | $SQLITE
	;;
	(*)
		echo "HTTP/1.0 501 Not Implemented"
esac
