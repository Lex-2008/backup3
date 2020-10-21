#!/bin/busybox ash
#
# from http://www.bashcookbook.com/bashinfo/source/bash-4.0/examples/scripts/timeout3
# via https://stackoverflow.com/a/687994
#
# The Bash shell script executes a command with a time-out.
# Upon time-out expiration SIGTERM (15) is sent to the process. If the signal
# is blocked, then the subsequent SIGKILL (9) terminates it.
#
# Based on the Bash documentation example.

# Hello Chet,
# please find attached a "little easier"  :-)  to comprehend
# time-out example.  If you find it suitable, feel free to include
# anywhere: the very same logic as in the original examples/scripts, a
# little more transparent implementation to my taste.
#
# Dmitry V Golovashkin <Dmitry.Golovashkin@sas.com>

scriptName="${0##*/}"

# Timeout.
timeout=$1
# Interval between checks if the process is still alive.
interval=1
# Delay between posting the SIGTERM signal and destroying the process by SIGKILL.
delay=2

function printUsage() {
    cat <<EOF

Synopsis
    $scriptName timeout command
    Execute a command with a time-out.
    Upon time-out expiration SIGTERM (15) is sent to the process. If SIGTERM
    signal is blocked, then the subsequent SIGKILL (9) terminates it.

    timeout
        Number of seconds to wait for command completion.

As of today, Bash does not support floating point arithmetic (sleep does),
therefore all delay/time values must be integers.
EOF
}

shift 1

# $# should be at least 1 (the command to execute), however it may be strictly
# greater than 1 if the command itself has options.
if test $# == 0; then
    printUsage
    exit 1
fi

# kill -0 pid   Exit code indicates if a signal may be sent to $pid process.
(
    t=$timeout

    while test $t -gt 0; do
        sleep $interval
        kill -0 $$ || exit 0
        t="$((t - interval))"
    done

    # Be nice, post SIGTERM first.
    # The 'exit 0' below will be executed if any preceeding command fails.
    kill -s SIGTERM $$ && kill -0 $$ || exit 0
    sleep $delay
    kill -s SIGKILL $$
) 2> /dev/null &

exec "$@"
