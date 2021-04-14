#!/opt/local/bin/gawk -f
#
# Copyright 2019, Joyent Inc.
#

# We're using gawk here because it can handle huge numbers better than nawk.
#
# This is a program meant to simulate the capacity usage for varying ZFS record
# sizes and parity levels. The input is a file that includes two columns of
# data:
# - The first column is an account. Usually this is a Triton account UUID, but
#   it doesn't need to be. Anything that doesn't have any spaces in it is fine.
# - The second column is the size in bytes of an object for the account in
#   the first column. This is likely the logical size.
# 
# For example, input might look like this, where the left column is a username,
# and the right column is the logical size of a file in bytes. This could be
# obtained using something like find(1).
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
# ./zfs_usage_simulator.sh -v recordsize_kb=128 -v raidz_stripe_width=16 -v parity_level=3 ./datafiles/trunc.1.stor.my-region

BEGIN {
	# Tunables
	target_account = "*" # Account UUID to use, or * for all accounts.

	#verbose = 0 # Used for debugging.
	#recordsize_kb = 512 # ZFS recordsize for the simulation.
	#raidz_stripe_width = 11 # disks per RAIDZ stripe.
	#parity_level = 2 # RAIDZ parity level (0 thru 3).

	# Tunables you probably don't need to tune.
	sector_size = 4096 # 4k disks are most common nowadays.

	compression = 1
	compression_ratio = 1.04

	# Need to know sectors per record so we can calculate any padding
	# necessary. Padding sectors are added until the data sectors + RAIDZ
	# sectors + padding sectors add up to a multiple of the parity level.
	recordsize_bytes = recordsize_kb * 1024
	sectors_per_record = recordsize_bytes / sector_size

	# indirect blocks:
	# approximately 1024 blkptrs per indirect block
	# ind blks are max 128k logical regardless of recordsize
	# ind blks stored compressed
	# ~45KB compressed to store 1024 ind blks
	#  - meaning ~44 bytes per blkptr/record
	avg_ind_bytes_per_block = 45
	# blkptr is 128 bytes, we store two of 'em, but they compress very well.
	# Assume 128 bytes of overhead for indirect blocks that point to data
	# blocks.
	blkptr_overhead = 128

	max_data_sectors_per_stripe = raidz_stripe_width - parity_level

	# Global counters.
	total_usage_bytes = 0
	total_records = 0
	total_wasted_bytes = 0
	total_raidz_sectors = 0
	total_padding_sectors = 0
	total_blkptr_usage_bytes = 0
	total_ind_block_usage_bytes = 0

	printf "Simulating... account %s, parity %d, recordsize %d, ",
	    target_account, parity_level, recordsize_bytes
	printf "raidz width %d, sector size %d\n",
	    raidz_stripe_width, sector_size

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
	data_stripes = 0
	parity_sectors = 0
	padding_sectors = 0
}

function print_stats() {
	if (verbose) {
	    printf "logical: %d, compressed: %d, data sect: %d, ",
	        $2, obj_size_bytes, data_sectors

	    printf "parity sect: %d, padding sect: %d, blocks: %d, ",
	        parity_sectors, padding_sectors, num_whole_records

	    printf "ind-1 usg: %d, ind-0 usg: %d\n",
	        ind_block_usage_bytes, blkptr_overhead * num_whole_records
	}
}

# Main loop.
{
	account = $1
	obj_size_bytes = $2 / compression_ratio
	zero_variables()

	trailing_bytes = obj_size_bytes % sector_size;
	if (trailing_bytes > 0) {
	    # round up physical usage to the next sector
	    obj_size_bytes = obj_size_bytes + (sector_size - trailing_bytes)
	}
	
	# * is a wildcard. Otherwise only look at objects for the provided
	# account uuid.
	if (target_account != "*" && account != target_account) {
		next
	}

	if (obj_size_bytes <= sector_size) {
		obj_size_bytes = sector_size
		parity_sectors = parity_level

		# num_whole_records affects the total reported capacity for
		# the total record and blkptr overhead calculations.
		#
		# The actual size of the record isn't used in the accounting
		# routine though, so this is fine.
		num_whole_records = 1
		data_sectors = 1

		parity_bytes = parity_sectors * sector_size
		padding_bytes = 0
		ind_block_usage_bytes = 0
		wasted_bytes = 0
		padding_sectors = 0

		print_stats()
		calculate_totals()
		next
	}

	# Figure out how many full and 'partial' records this file uses.
	num_records = obj_size_bytes / recordsize_bytes
	num_whole_records = int(obj_size_bytes / recordsize_bytes)
	if (num_whole_records == 0) { num_whole_records = 1 }

	unused_record_portion = num_records - num_whole_records
	if (unused_record_portion > 0 && num_whole_records > 0) {
		# ZFS uses a full record to write this 'partial' record.
		# This doesn't take into account embedded blockpointers.
		num_whole_records++

		# ZFS wastes appx one extra sector worth of space when
		# compression is enabled. I verified this using one system with
		# 512b disks and one system with 4k disks.
		#
		# If compression is _not_ enabled, the waste is much worse - the
		# remainder of the record is wasted space.
		if (compression) {
			wasted_bytes = sector_size
		} else {
			wasted_bytes = recordsize_bytes - \
			    (recordsize_bytes * unused_record_portion)
		}
	}

	# Do the usage calculations.
	data_sectors = obj_size_bytes / sector_size
	if (data_sectors % 1 > 0) {
	    # No partial data sectors
	    data_sectors = int(data_sectors + 1)
	}
	data_stripes = data_sectors / max_data_sectors_per_stripe

	if (data_stripes % 1 > 0) {
		# Partial parity sectors don't make sense - round up.
		parity_sectors = (int(data_stripes) + 1) * parity_level
	} else {
		parity_sectors = data_stripes * parity_level
	}

	# The number of data and parity sectors must be a multiple of
	# parity_level+1. If it is not, add padding until it is.
	#
	# This is so that ZFS always has space for small allocations like one
        # data sector and two parity sectors.	
	remainder = (parity_sectors + data_sectors) % (parity_level + 1)
	padding_sectors = (remainder == 0 ? 0 : parity_level + 1 - remainder)

	parity_bytes = parity_sectors * sector_size
	padding_bytes = padding_sectors * sector_size
	if (num_whole_records > 1) {
		ind_block_usage_bytes = blkptr_overhead
	}

	print_stats()
	calculate_totals()
}

function calculate_totals() {
	total_blkptr_usage_bytes += blkptr_overhead * num_whole_records
	total_ind_block_usage_bytes += ind_block_usage_bytes

	total_usage_bytes += blkptr_overhead * num_whole_records
	total_usage_bytes += obj_size_bytes
	total_usage_bytes += parity_bytes
	total_usage_bytes += ind_block_usage_bytes
	total_usage_bytes += padding_bytes

	total_wasted_bytes += wasted_bytes
	total_records += num_whole_records
	total_raidz_sectors += parity_sectors
	total_padding_sectors += padding_sectors
}

# Big numbers are hard to read!
# One TiB is 1024^4 bytes.
function btotib(bytes) {
	return btogib(bytes) / 1024
}

function btogib(bytes) {
	return bytes / 1024 / 1024 / 1024
}

END {
	if (output_csv) {
		printf "records,gib_used,gib_wasted,gib_raidz,gib_padding,"
		printf "gib_blkptrs,gib_ind\n"

		printf "%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n\n",
		    total_records,
		    btogib(total_usage_bytes),
		    btogib(total_wasted_bytes),
		    btogib(total_raidz_sectors * sector_size),
		    btogib(total_padding_sectors * sector_size),
		    btogib(total_blkptr_usage_bytes),
		    btogib(total_ind_block_usage_bytes)
	} else {
		printf "=== REPORT ===\n"
		printf "%d\t\tRecords\n", total_records

		printf "%.2f\t\t\tGiB Used\n",
		    btogib(total_usage_bytes)

		printf "%.2f\t\t\tGiB wasted\n", btogib(total_wasted_bytes)

		printf "%.2f\t\t\tGiB RAIDZ\n",
		    btogib(total_raidz_sectors * sector_size)

		printf "%.2f\t\t\tGiB Padding\n",
		    btogib(total_padding_sectors * sector_size)

		printf "%.2f\t\t\tGiB for blkptrs\n",
		    btogib(total_blkptr_usage_bytes)

		printf "%.2f\t\t\tGiB for ind blocks\n",
		    btogib(total_ind_block_usage_bytes)
    }
}
