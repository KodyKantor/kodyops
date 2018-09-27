#!/usr/bin/bash

# search for shards that have really high request latency (five seconds),
# and print them in sorted order.

tail -n 100000 /var/log/muskie.log | json -ga -c 'this.latency > 5000' entryShard | sort | uniq -c | sort -n
