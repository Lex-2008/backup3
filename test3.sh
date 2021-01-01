#!/bin/busybox ash

rm -rf test
mkdir -p test/src/ignore test/src/use/me
export BACKUP_ROOT="$PWD/test"
export BACKUP_TIME_FORMAT="%F %T"
export BACKUP_CONFIG="/dev/null"
./init.sh

which tree >/dev/null 2>&1 || tree() { `which find` $2 -printf '%i\t%p\n'; }

# test 1: sync whole tree
echo a>test/src/ignore/file
echo b>test/src/use/me/file
echo c>test/src/use/file

rsync -a "$PWD/test/src/" "$PWD/test/current"

./backup.sh
tree --inodes test
sqlite3 -column -header test/backup.db 'select * from history;'
echo "looks good?"
read

# test 2: sync only one subdir
echo d>test/src/ignore/file
echo e>test/src/use/me/file
echo f>test/src/use/file

run_this()
{
	run_rsync always use/me "$PWD/test/src/use/me/"
}

. ./backup.sh
tree --inodes test
sqlite3 -column -header test/backup.db 'select * from history;'
echo "looks good?"
# read
