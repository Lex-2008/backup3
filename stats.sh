#!/bin/bash
#
# Script to show some stats

test -z "$BACKUP_BIN" && BACKUP_BIN="${0%/*}"
. "$BACKUP_BIN/common.sh"

cd "$BACKUP_ROOT"

banner() {
	echo  ===== ===== "$@" ===== =====
}

banner uptime
uptime

echo
# banner sensors
# sensors

banner disk usage
sh -c "$STATS_DF"

echo
banner backup stats

echo " SELECT
		dirname AS 'Last backup of browser tabs',
		filename,
		max(created) AS 'created',
		round(julianday('now', 'localtime') - julianday(created), 2) AS 'days ago'
	FROM history
	WHERE freq = 0
	  AND dirname LIKE './browsers/%/Sessions/'
	GROUP BY dirname;" | $SQLITE -header -column

echo
echo " SELECT
		max(created) AS 'Last backup overall',
		'created' AS 'direction',
		round(julianday('now', 'localtime') - julianday(max(created)), 2) AS 'days ago'
	FROM history
	WHERE freq = 0
UNION ALL
	SELECT
		max(deleted) AS 'Last backup overall',
		'deleted' AS 'direction',
		round(julianday('now', 'localtime') - julianday(max(deleted)), 2) AS 'days ago'
	FROM history
	WHERE freq != 0
	;" | $SQLITE -header -column

echo
echo " SELECT
		freq,
		min(deleted) AS 'oldest file',
		round((strftime('%s','now','localtime')-strftime('%s',min(deleted)))*freq/2592000,2) as 'age'
        FROM history
        WHERE freq != 0
	  AND freq <= 8640
        GROUP BY freq;" | $SQLITE -header -column

test "$STATS_DU" = 1 || exit 0

echo
echo "Disk usage of each dir"
echo "---- ----- -- ---- ---"

(
	echo 'name current data'
	(
		echo .
		ls data
	) | xargs -I% echo 'echo "% $(test -e current/% && du -BG -d0 current/% | cut -f1) $(du -BG -d0 data/% | cut -f1)"' | sh
) | column -t

# echo
# echo "Par2 stats"
# echo "---- -----"

# ~/git/backup3/par2stats.sh -q
