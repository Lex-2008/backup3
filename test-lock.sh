#!/bin/busybox ash

rm -rf test
mkdir test
export BACKUP_ROOT="$PWD/test"
export BACKUP_CONFIG="/dev/null"

cat <<EOF >test/a.sh
. "${0%/*}/common.sh"
echo "a locked"
acquire_lock
sleep 3
echo "a unlocked"
EOF

cat <<EOF >test/b.sh
. "${0%/*}/common.sh"
sleep 1
echo "b wants a lock"
acquire_lock
echo "FAIL: b should not be here"
EOF

cat <<EOF >test/c.sh
. "${0%/*}/common.sh"
sleep 1
BACKUP_WAIT_FLOCK=1
echo "c waits for a lock"
acquire_lock
echo "PASS: c should have a lock"
echo \$\$ equals to:
cat \$BACKUP_FLOCK
EOF

chmod a+x test/*.sh

sh test/a.sh &
sh test/b.sh &
sh test/c.sh &

wait

echo "test done"
