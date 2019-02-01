#!/bin/busybox ash

BACKUP_ROOT=/backups/new

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_PASS"    && BACKUP_PASS=$BACKUP_ROOT/pass.txt
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db

SQLITE="sqlite3 $BACKUP_DB"

# init <<returns list of roots
# timeline|pass|root
#  dirtree|pass|root
#       ls|pass|dir|date
#      tar|pass|dir|date
#      get|pass|dir|date|file
#       ll|pass|dir|*|file

if test "$QUERY_STRING" = "init"; then
	echo "HTTP/1.0 200 OK"
	echo "Cache-Control: max-age=600"
	echo
	ls -p "$BACKUP_CURRENT"
	exit 0
fi

IFS='|' read request pass dir date file <<EOL
$(busybox httpd -d "$QUERY_STRING")
EOL

# TODO
# # protect agains hacks like 'asd/../../../../'
# # doesn't work if ROOT start with /
# file="$(realpath --no-symlinks -m "$PWD/$request")"
# if [ "$(expr substr "$file" 1 ${#PWD})" != "$PWD" ]; then
# # if [ "${file:0:${#PWD}}" != "$PWD" ]; then
# 	echo "HTTP/1.0 403 Forbidden"
# 	echo
# 	echo "$PWD/$request"
# 	echo $file
# 	exit 0
# fi

root="${dir%%/*}"

# check root-pass by trying to SMB into requested share
if test -f "$BACKUP_CURRENT/$root.pw"; then
	IFS='|' read user share <"$BACKUP_CURRENT/$root.pw"
	if ! smbclient -U "$user" -N -c exit "$share" "$pass" >/dev/null 2>&1; then
		echo "HTTP/1.0 403 Forbidden"
		echo
		echo "$BACKUP_CURRENT/$root.pw"
		cat  "$BACKUP_CURRENT/$root.pw"
		echo smbclient -U "$user" -N -c exit "$share" "$pass"
		exit 1
	fi
fi

case "$request" in
	(timeline)
		echo "HTTP/1.0 200 OK"
		echo "Cache-Control: max-age=600"
		echo
		# TODO: create dirname index for this
		$SQLITE "PRAGMA case_sensitive_like = ON;
		SELECT DISTINCT created
			FROM history
			WHERE dirname = '$root'
			   OR dirname LIKE '$root/%';
		SELECT '---';
		SELECT DISTINCT deleted
			FROM history
			WHERE dirname = '$root'
			   OR dirname LIKE '$root/%';
		SELECT '===';
		SELECT freq, MIN(deleted)
			FROM history
			WHERE freq != 0
			  AND ( dirname = '$root'
			        OR dirname LIKE '$root/%'
			      )
			GROUP BY freq;
		SELECT '+++';
		SELECT dirname, MIN(created), MAX(deleted)
			FROM history
			WHERE dirname = '$root'
			   OR dirname LIKE '$root/%'
			   GROUP BY dirname;"
	;;
	(ls)
		echo "HTTP/1.0 200 OK"
		echo "Cache-Control: max-age=600"
		echo
		$SQLITE "SELECT filename, created
			FROM history
			WHERE dirname = '$dir'
			  AND created <= '$date'
			  AND deleted > '$date';"
	;;
	(tar)
		echo "HTTP/1.0 501 Not Implemented"
		# run show.sh and tar results
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
		$SQLITE "SELECT created, deleted
			FROM history
			WHERE dirname = '$dir'
			  AND filename = '$file';"
	;;
	(*)
		echo "HTTP/1.0 501 Not Implemented"
esac
