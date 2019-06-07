#!/opt/local/bin/gawk -f
# using gawk because it can handle huge numbers better than nawk.

# This is a program meant to simulate the capacity usage for varying ZFS record
# sizes and parity levels. The input is a file that includes two columns of
# data:
# - The first column is an account. Usually this is a Triton account UUID, but
#   it doesn't need to be. Anything that doesn't have any spaces in it is fine.
# - The second column is the size in kilobytes of an object for the account in
#   the first column.
# 
# For example, input might look like this:
# 
# 	kody	1
# 	kody	102
# 	kody	99
# 	kody	10403
# 	bob	1
# 	eve	1000000000
# 	alice	10

BEGIN {
	# Tunables
	recordsize_kb = 512 # ZFS recordsize for the simulation.
	target_account = "*" # Account UUID to use, or * for all accounts.
	parity_level = 2 # RAIDZ parity level (0 thru 3).
	verbose = 0 # Used for debugging.

	# Tunables you probably don't need to tune.
	minimum_recordsize = 512 # smallest possible ZFS record.
	sector_size = 4096 # 4k disks are most common nowadays.
	recordsize_bytes = recordsize_kb * 1024

	# indirect blocks:
	# approximately 1024 blkptrs per indirect block
	# ind blks are max 128k logical regardless of recordsize
	# ind blks stored compressed
	# ~45KB compressed to store 1024 ind blks
	#  - meaning ~44 bytes per blkptr/record
	avg_ind_bytes_per_rec = 0

	# Global counters.
	total_usage_bytes = 0
	total_raidz_sectors = 0
	total_records = 0
	total_wasted_bytes = 0

	printf "Simulating using account %s, parity %d, and recordsize %d\n",
	    target_account, parity_level, recordsize_bytes
}

# Main loop.
{
	account = $1
	obj_size_kb = $2

	# Sigh. No local variables. Make sure everything is zeroed.
	obj_size_bytes = 0
	num_records = 0
	num_whole_records = 0
	unused_record_portion = 0
	wasted_bytes = 0
	parity_sectors = 0
	parity_bytes = 0
	ind_block_usage_bytes = 0

	# * is a wildcard. Otherwise only look at objects for the provided
	# account uuid.
	if (target_account != "*" && account != target_account) {
		next
	}

	# mako dumps report Kilobytes, but we want Kibibytes.
	obj_size_kb *= 0.9765625

	# I'm not sure if this case is possible from the mako manifests,
	# but we should account for it. If a file is 512 bytes or less
	# the recordsize will be 512 bytes.
	if (obj_size_kb < recordsize_kb) {
		if (obj_size_kb < 1) {
			obj_size_bytes = minimum_recordsize
		} else {
			# convert KiB to bytes
			obj_size_bytes = obj_size_kb * 1024
		}

		parity_bytes = sector_size * parity_level

		total_usage_bytes += obj_size_bytes
		total_usage_bytes += parity_bytes
		total_records += 1
		total_raidz_sectors += parity_level

		if (verbose) {
			printf "%d kb obj: 1 record, %d disk bytes, ",
				obj_size_kb, obj_size_bytes
			printf "%d parity bytes\n", parity_bytes
		}
		next
	}

	# Figure out how many full and 'partial' records this file uses.
	num_records = obj_size_kb / recordsize_kb
	num_whole_records = int(obj_size_kb / recordsize_kb)
	unused_record_portion = num_records - num_whole_records
	if (unused_record_portion > 0) {
		# ZFS uses a full record to write this 'partial' record.
		num_whole_records++

		# ZFS wastes the remainder of the recordsize block.
		wasted_bytes = recordsize_bytes - \
		    (recordsize_bytes * unused_record_portion)
	}

	# Do the usage calculations.
	obj_size_bytes = num_whole_records * recordsize_bytes
	parity_sectors = num_whole_records * parity_level
	parity_bytes = parity_sectors * sector_size
	ind_block_usage_bytes = num_whole_records * avg_ind_bytes_per_rec

	total_usage_bytes += obj_size_bytes
	total_usage_bytes += parity_bytes
	total_usage_bytes += ind_block_usage_bytes
	total_records += num_whole_records
	total_raidz_sectors += parity_sectors
	total_wasted_bytes += wasted_bytes

	if (verbose) {
		printf "%d kb obj: %d records, %d disk bytes, ", obj_size_kb,
			num_whole_records, obj_size_bytes
 		printf "%d parity bytes, %d ind, %d wasted\n", parity_bytes,
			ind_block_usage_bytes, wasted_bytes
	}
}

# Big numbers are hard to read!
# One TiB is 1024^4 bytes.
function btotib(bytes) {
	return bytes / 1024 / 1024 / 1024 / 1024
}

END {
	printf "=== REPORT ===\n"
	printf "%d\t\tBytes Used\n%d\t\tWasted Bytes\n", total_usage_bytes,
	    total_wasted_bytes
	printf "%d\t\tRecords\n%d\t\tRAIDZ sectors\n", total_records,
	    total_raidz_sectors

	printf "%.2g\t\t\tTiB Used\n%.2g\t\t\tTiB wasted\n",
	    btotib(total_usage_bytes), btotib(total_wasted_bytes)
	printf "%.2g\t\t\tRAIDZ usage\n",
	    btotib(total_raidz_sectors * sector_size)

}
