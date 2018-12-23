FROM=/backups/flower

ROOT=$FROM/.new

# SRC
# export DST="flower"
export BACKUP_CURRENT=$ROOT/current
export BACKUP_LIST=$ROOT/files.txt
export BACKUP_TMP=$ROOT/tmp
export BACKUP=$ROOT/data
export BACKUP_LOG=$ROOT/rsync.log
export SQLITE_DB=$ROOT/backup.db

rm -rf $ROOT
mkdir -p $BACKUP_CURRENT $BACKUP_TMP $BACKUP

sqlite3 $SQLITE_DB "CREATE TABLE IF NOT EXISTS history(
dirname TEXT NOT NULL,
filename TEXT NOT NULL,
created TEXT NOT NULL,
deleted TEXT,
freq INTEGER NOT NULL);
CREATE INDEX history_update ON history (dirname, filename) WHERE freq = 0;"

a=0
(cd $FROM; ls -d */*/) | sed 's_/_ _' | sort -k 2 | uniq -f 1 | sed 's_ _/_' | while read dir; do
	# export SRC="$FROM/$dir"
	rm -rf $BACKUP_CURRENT/flower
	cp -al "$FROM/$dir" $BACKUP_CURRENT/flower
	dir="${dir#*/}"
	dir="${dir%/}"
	export NOW="$(echo "$dir" | sed 's/_/ /')"
	echo "processing [$NOW]..."
	time bash ~/git/backup3/backup.sh || exit 1
	test "$a" = "1" && break
	a=1
done

