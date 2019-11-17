#!/usr/bin/python
#
# Helper script to wait 1~5 seconds after input and run a command.
# Logic is like this: we run the command 1 second after last input,
# but not later than 5 seconds after first input.
# Numbers 1 and 5 are first two arguments to the script, rest is the command to run.
# Moreover, we do not run two commands in parallel - instead, we wait for one to finish
# and tun the second one after that. Also, if a new input comes when a command is running -
# we schedule a new command run to happen after this one is over
# Usage example:
# $ inotifywait -m ~/dir1 | run_between.py 1 5 rsync -a ~/dir1 ~/dir2
# to sync ~/dir1 to ~/dir2 as soon as something changes
#
# Evolved from code based on https://stackoverflow.com/questions/15461287/how-to-kill-subprocess-if-no-activity-in-stdout-stderr

import sys
import subprocess
import signal
import time

if len(sys.argv) < 4:
    # 0th argument is script name, others are arguments
    print 'requires at least three arguments: min and max timeouts (in seconds), and command (with optional arguments)'
    sys.exit(1)
try:
    min_timeout = int(sys.argv[1])
    max_timeout = int(sys.argv[1]) - min_timeout
except:
    print 'first two arguments should be integers, showing how long to wait before running command, in seconds.'
    sys.exit(1)
args = sys.argv[3:]

first_input = None
processes = None

def _handler(signum, frame):
    global first_input, processes, args
    if processes is not None and processes.poll() is None:
        # process is still running - reschedule alarm to trigger later
        signal.alarm(min_timeout)
    else:
        # process exited or not running - fire new process
        processes = subprocess.Popen(args, shell=False, stdin=None)
        first_input = None

signal.signal(signal.SIGALRM, _handler)
while True:
    # inline = raw_input()
    inline = sys.stdin.readline()
    if not inline:
        break
    # print inline
    # sys.stdout.write('[%s]' % inline)
    if first_input is None:
        # this is first input of the batch,
        # set the alarm and note the start of the batch
        first_input = time.time()
        signal.alarm(min_timeout)
    elif time.time() - first_input < max_timeout:
        # this is second (or so) input within the reasonable timeframe (4 sec since start of the batch),
        # postpone the alarm
        signal.alarm(min_timeout)
    else:
        # inputs were happening for too long,
        # let the alarm ring
        pass

