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
# ./zfs_usage_simulator.sh -v recordsize_kb=128 -v raidz_stripe_width=16 -v parity_level=3 ./datafiles/trunc.1.stor.my-region

BEGIN {
	# Tunables
	target_account = "*" # Account UUID to use, or * for all accounts.
	verbose = 0 # Used for debugging.

	#recordsize_kb = 512 # ZFS recordsize for the simulation.
	#raidz_stripe_width = 11 # disks per RAIDZ stripe.
	#parity_level = 2 # RAIDZ parity level (0 thru 3).

	# Tunables you probably don't need to tune.
	minimum_recordsize = 512 # smallest possible ZFS record.
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
	avg_ind_bytes_per_rec = 45
	# blkptr is 128 bytes, we store two of 'em, but the minimal allocation
	# size is one sector, so blkptr_overhead == sector_size?
	#blkptr_overhead = 256
	blkptr_overhead = sector_size

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

		# ZFS wastes one extra sector worth of space when compression
		# is enabled. I verified this using one system with 512 disks
		# and one system with 4k disks.
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
	data_sectors = num_whole_records * sectors_per_record
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
	# This is so that ZFS doesn't end up with un-allocatable space in the
	# event that a partial-width stripe is freed.
	padding_sectors = (parity_sectors + data_sectors) % (parity_level + 1)

	obj_size_bytes = num_whole_records * recordsize_bytes
	parity_bytes = parity_sectors * sector_size
	padding_bytes = padding_sectors * sector_size
	if (num_whole_records > 1) {
		ind_block_usage_bytes = blkptr_overhead
		ind_block_usage_bytes += num_whole_records * \
		    avg_ind_bytes_per_rec
	}

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
	return btogib(bytes) / 1024
}

function btogib(bytes) {
	return bytes / 1024 / 1024 / 1024
}

END {
	if (compression) {
		total_usage_bytes /= compression_ratio
	}

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
