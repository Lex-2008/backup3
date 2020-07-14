#!/bin/busybox ash
#
# Script to show par2 archives or duplicates stats
#
# Call it like this:
# 
# $ par2stats.sh [OPTIONS]
# (without arguments) to show stats for all files in all monthly backups
#
# $ par2stats.sh [OPTIONS] 1
# to show stats for all files in last 1 monthly backups
#
# $ par2stats.sh [OPTIONS] 3 2
# to show stats for all files in backups which are older than 2 but newer than 3 months old
#
# Options are:
#   -q to be less verbose regarding progress

. "$(dirname "$0")/common.sh"

if test "$1" = "-q"; then
	quiet_progress=1
	shift
fi

cond2="AND created<strftime('%Y-%m', 'now')"
if test ! -z "$1"; then
	cond1="AND created>=strftime('%Y-%m', 'now', '-$1 months')"
fi
if test ! -z "$2"; then
	cond2="AND created<strftime('%Y-%m', 'now', '-$2 months')"
fi

sql1=" SELECT count(*)
	FROM history
	WHERE type='f'
	  AND freq<2 $cond1 $cond2;"

sql=" SELECT dirname || filename || '/' || created,
	'$BACKUP_TIME_SEP' || deleted
	FROM history
	WHERE type='f'
	  AND freq<2 $cond1 $cond2
	ORDER BY dirname;"

echo "total files to check:"
echo "$sql1" | $SQLITE

export LC_ALL=POSIX
echo "$sql" | $SQLITE | (
	a=0
	b=0
	while IFS="$NL" read -r f; do
		filepart="$BACKUP_MAIN/${f%%|*}"
		fileend="${f##*|}"
		filename="$filepart$fileend"
		# if test "$filename" -ef "$filepart.bak"; then
		# 	# *.bak file is hardlinked to original => remove
		# 	rm -f "$filepart.bak"
		# fi
		a=$(expr $a + 1)
		if test -f "$filepart.bak" || test -f "$filepart.par2"; then
			# *.bak or *.par2 file found
			b=$(expr $b + 1)
		fi
		if test -z "$quiet_progress" && expr $a : '.*00$' >/dev/null; then
			echo "checked [$a], secured [$b] files"
		fi
	done
	if dc --help 2>&1 | head -n1 | grep -q 'BusyBox v1.2'; then
		# busybox before 1.30.0 has dc which accepts plain expression
		prc=$(dc $b 100 '*' $a / p)
	else
		# other dc need `-e` before expression (otherwise treat argument
		# as a filename)
		prc=$(dc -e "$b 100 '*' $a / p")
	fi
	echo "$b out of $a files secured ($prc%)"
	)
