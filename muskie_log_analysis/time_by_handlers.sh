#!/usr/bin/bash

# provide arguments:
#  1: search back through the previous N log lines
#  2: HTTP methods to search for (e.g. 'PUT' or 'GET')
# this script will look at the last chunk of requests and print the time that
# muskie spent in each of the handler functions. This information comes from the
# req.timers data in the audit logs.

tail -n $1 /var/log/muskie.log | grep 'audit' | json -ga -c "req.url.indexOf('/* FILL_IN_URL */')!=-1 && req.method=='$2'" \
        req.timers | grep \" | tr -d '"' | tr -d ',' | tr -d ':' | \
        awk '{ x[$1] += $2; ttl += $2; if ($1 == "setup") { num++ } } \
	END{ \
		for (i in x) {printf("%30s %5d us %3.3g%%\n", i, x[i] / num, (x[i] / ttl) * 100.0)}; \
	}' | \
	sort -n +1
