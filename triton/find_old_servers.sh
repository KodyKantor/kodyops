# sort servers by the date they were created.
sdc-cnapi /servers | json -Hga created hostname uuid | sort -t - -k 1,3

# find only storage nodes
sdc-cnapi /servers | json -Hga -c 'hostname.substring(0,2) === "MS" || hostname.substring(0,2) === "RM"' created hostname uuid
