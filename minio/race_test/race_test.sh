#!/usr/bin/bash

targ0="min0"
targ1="min1"

while true;
do
	echo "uploads: begin"

	mc pipe $targ0/test/dest < one &
	mc pipe $targ1/test/dest < two &

	wait
	echo "uploads: done"

	echo "downloading file"
	out=$( (mc cat $targ0/test/dest > result) 2>&1 )
	if [[ "$out" != "" ]];
	then
		echo "mc failed: '$out'"
		exit 1
	fi

	echo "comparing files"
	diff result one > /dev/null
	oneres=$?

	diff result two > /dev/null
	twores=$?

	if [[ "$oneres" -ne 0 && "$twores" -ne 0 ]];
	then
		echo "data corruption!"
		exit 1
	fi

	echo "pass"
	echo "---"
done;
