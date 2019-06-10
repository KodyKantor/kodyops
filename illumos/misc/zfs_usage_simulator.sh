#!/opt/local/bin/gawk -f
# using gawk because it can handle huge numbers better than nawk.

# This is a program meant to simulate the capacity usage for varying ZFS record
# sizes and parity levels. The input is a file that includes two columns of
# data:
# - The first column is an account. Usually this is a Triton account UUID, but
#   it doesn't need to be. Anything that doesn't have any spaces in it is fine.
# - The second column is the size in bytes of an object for the account in
#   the first column. This is likely the logical size.
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
#
#
# I run this program using a command like this:
# ./zfs_usage_simulator.sh -v recordsize_kb=128 ./datafiles/trunc.1.stor.my-region

BEGIN {
	# Tunables
	#recordsize_kb = 512 # ZFS recordsize for the simulation.
	target_account = "*" # Account UUID to use, or * for all accounts.
	parity_level = 2 # RAIDZ parity level (0 thru 3).
	verbose = 0 # Used for debugging.

	# Tunables you probably don't need to tune.
	minimum_recordsize = 512 # smallest possible ZFS record.
	sector_size = 4096 # 4k disks are most common nowadays.
	recordsize_bytes = recordsize_kb * 1024

	# We still have a lot of unaccounted for capacity usage. This is here
	# until we can track that down. It's possible that to get closer to the
	# exact usage number we'd have to make the user pass in their zpool
	# layout information. Some things depend on the number (and size?) of
	# vdevs (both top-level and concrete?).
	misc_zfs_overhead_ratio = 1.15

	# Need to know sectors per record so we can calculate any padding
	# necessary. Padding sectors are added until the data sectors + RAIDZ
	# sectors + padding sectors add up to a multiple of the parity level.
	sectors_per_record = recordsize_bytes / sector_size

	# indirect blocks:
	# approximately 1024 blkptrs per indirect block
	# ind blks are max 128k logical regardless of recordsize
	# ind blks stored compressed
	# ~45KB compressed to store 1024 ind blks
	#  - meaning ~44 bytes per blkptr/record
	avg_ind_bytes_per_rec = 45
	blkptr_overhead = 256 # blkptr is 128 bytes, store two of 'em

	# Global counters.
	total_usage_bytes = 0
	total_records = 0
	total_wasted_bytes = 0
	total_raidz_sectors = 0
	total_padding_sectors = 0

	printf "Simulating using account %s, parity %d, and recordsize %d\n",
	    target_account, parity_level, recordsize_bytes
}

function zero_variables() {
	# Sigh. No local variables. Make sure everything is zeroed.
	num_records = 0
	num_whole_records = 0
	unused_record_portion = 0

	wasted_bytes = 0
	parity_bytes = 0
	padding_bytes = 0
	ind_block_usage_bytes = 0

	data_sectors = 0
	parity_sectors = 0
	padding_sectors = 0
}

# Main loop.
{
	account = $1
	obj_size_bytes = $2
	zero_variables()
	
	# * is a wildcard. Otherwise only look at objects for the provided
	# account uuid.
	if (target_account != "*" && account != target_account) {
		next
	}

	# I'm not sure if this case is possible from the mako manifests,
	# but we should account for it. If a file is 512 bytes or less
	# the recordsize will be 512 bytes.
	if (obj_size_bytes < recordsize_bytes) {
		if (obj_size_bytes <= minimum_recordsize) {
			obj_size_bytes = minimum_recordsize
		}

		parity_bytes = sector_size * parity_level

		data_sectors = obj_size_bytes / sectors_per_record
		if (data_sectors == 0) {
			# objects less than one sector in size
			data_sectors = 1
		}
		parity_sectors = parity_level
		padding_sectors = (data_sectors + parity_sectors) % parity_level
		padding_bytes = padding_sectors * sector_size

		total_usage_bytes += obj_size_bytes
		total_usage_bytes += parity_bytes
		total_records += 1
		total_raidz_sectors += parity_level
		total_padding_sectors += padding_sectors
		total_usage_bytes += padding_bytes

		if (verbose) {
			printf "%d byte obj: 1 record, %d disk bytes, ",
				obj_size_bytes, obj_size_bytes
			printf "%d parity bytes\n", parity_bytes
		}
		next
	}

	# Figure out how many full and 'partial' records this file uses.
	num_records = obj_size_bytes / recordsize_bytes
	num_whole_records = int(obj_size_bytes / recordsize_bytes)
	unused_record_portion = num_records - num_whole_records
	if (unused_record_portion > 0) {
		# ZFS uses a full record to write this 'partial' record.
		num_whole_records++

		# ZFS wastes the remainder of the recordsize block.
		wasted_bytes = recordsize_bytes - \
		    (recordsize_bytes * unused_record_portion)
	}

	# Do the usage calculations.
	data_sectors = num_whole_records * sectors_per_record
	parity_sectors = num_whole_records * parity_level
	padding_sectors = (data_sectors + parity_sectors) % parity_level

	obj_size_bytes = num_whole_records * recordsize_bytes
	parity_bytes = parity_sectors * sector_size
	padding_bytes = padding_sectors * sector_size
	if (num_whole_records > 1) {
		ind_block_usage_bytes = blkptr_overhead
		ind_block_usage_bytes += num_whole_records * \
		    avg_ind_bytes_per_rec
	}

	total_usage_bytes += blkptr_overhead * num_whole_records
	total_usage_bytes += obj_size_bytes
	total_usage_bytes += parity_bytes
	total_usage_bytes += ind_block_usage_bytes
	total_usage_bytes += padding_bytes
	total_wasted_bytes += wasted_bytes
	total_records += num_whole_records
	total_raidz_sectors += parity_sectors
	total_padding_sectors += padding_sectors

	if (verbose) {
		printf "%d byte obj: %d records, %d disk bytes, ", obj_size_bytes,
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
	total_usage_bytes *= misc_zfs_overhead_ratio
	
	printf "=== REPORT ===\n"
	printf "%d\t\tBytes Used\n%d\t\tWasted Bytes\n", total_usage_bytes,
	    total_wasted_bytes
	printf "%d\t\tRecords\n%d\t\tRAIDZ sectors\n", total_records,
	    total_raidz_sectors
	printf "%d\t\tPadding sectors\n", total_padding_sectors

	printf "%.2f\t\t\tTiB Used\n%.2g\t\t\tTiB wasted\n",
	    btotib(total_usage_bytes), btotib(total_wasted_bytes)
	printf "%.2f\t\t\tTiB RAIDZ\n",
	    btotib(total_raidz_sectors * sector_size)

}
