FROM=/backups/flower

ROOT=$FROM/.new

export BACKUP_CURRENT=$ROOT/current
export BACKUP_TMP=$ROOT/tmp
export BACKUP=$ROOT/data
export BACKUP_LOG=$ROOT/rsync.log
export BACKUP_DEV=/dev/sda4
export SQLITE_DB=$ROOT/backup.db

rm -rf $ROOT
mkdir -p $BACKUP_CURRENT $BACKUP_TMP $BACKUP

sqlite3 $SQLITE_DB "CREATE TABLE IF NOT EXISTS history(
dirname TEXT NOT NULL,
filename TEXT NOT NULL,
created TEXT NOT NULL,
deleted TEXT,
freq INTEGER NOT NULL);"

(cd $FROM; ls -d */*/) | sed 's_/_ _' | sort -k 2 | uniq -f 1 | sed 's_ _/_' | while read dir; do
	export SRC="$FROM/$dir/"
	dir="${dir#*/}"
	dir="${dir%/}"
	export RSYNC_EXTRA="--link-dest=$SRC"
	export NOW="$(date -d "$(echo "$dir" | sed 's/_/ /')" +"%F %T")"
	echo "processing $NOW..."
	dash ~/backup3/backup.sh
	break
done



