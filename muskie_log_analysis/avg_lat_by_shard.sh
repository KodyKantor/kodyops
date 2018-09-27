#!/usr/bin/bash

# Look at last $1 log entries, take a given timer $2, and average the latency by
# shard. Result is in milliseconds.
#
# This is useful for finding particular portions of handler pipelines that are
# slow, broken down on a per-shard basis.

echo "$2 latency by shard"
tail -n $1 /var/log/muskie.log | \
	grep 'entryShard' | \
	json -ga entryShard req.timers.$2 | \
	sed -e 's/tcp:\/\///g' | \
	sed -e 's/:2020//g' | \
	awk 'BEGIN{printf("%35s %6s %5s\n", "SHARD", "LAT", "NR");} {sh[$1] += $2; tot[$1]++} END{for (i in sh) {printf("%35s %6d ms %5d\n", i, (sh[i]/tot[i])/1000, tot[i]);}}'|\
	sort -n -k 2
