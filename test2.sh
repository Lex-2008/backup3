#!/bin/busybox ash

rm -rf test
mkdir -p test/src/ignore test/src/use
export BACKUP_ROOT="$PWD/test"
export BACKUP_TIME_FORMAT="%F %T"
./init.sh


# test 1: sync whole tree
echo a>test/src/ignore/file
echo b>test/src/use/file

rsync -a "$PWD/test/src/" "$PWD/test/current"

./backup.sh
tree --inodes test
sqlite3 -column -header test/backup.db 'select * from history;'
echo "looks good?"
read

# test 2: sync only one subdir
echo c>test/src/ignore/file
echo d>test/src/use/file

run_this()
{
	run_rsync always use "$PWD/test/src/use/"
}

. ./backup.sh
tree --inodes test
sqlite3 -column -header test/backup.db 'select * from history;'
echo "looks good?"
# read
