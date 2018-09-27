/*
 * file-progress.d - tool to watch database scans
 *
 * The caller provides a pid as the only argument to the program.
 *
 * This script was written to watch long-running processes that sequentially
 * scan PG database files. As such, the 'sizes' are hard-coded to be 1GB.
 *
 * The idea is that we'll give the user a per-file progress bar and some
 * throughput data.
 *
 * I wrote this while trying to figure out why a REINDEX was so slow.
 * Turns out that running `dd` in the background with a large block size
 * pre-fetches the data files and buffers them in memory long enough for the
 * REINDEX (or any other DB scan function) to speed up by 5-10x.
 */

/* aggpack makes the histogram look like a progress bar */
#pragma D option aggpack
#pragma D option quiet

BEGIN
{
	prev_file = "";
	cur_file = "";
	bytes_read = 0;

	@reads["read"] = lquantize(0, 0, 100, 1);
}

fbt::read:entry
/pid == $1/
{
	cur_file = fds[arg0].fi_pathname;
	if (cur_file != prev_file) {
		/* we've started reading a new file, so clear the aggregation */
		clear(@reads);
		prev_file = cur_file;
	}
	@reads["read"] = lquantize(fds[arg0].fi_offset*100/1073741824, 0, 100,
	    1);
	bytes_read += args[2];
}

/*
 * keep track of any writes that the process might be doing
 */
fbt::write:entry
/pid == $1/
{
	/* [file_name, "write"] */
	@writes[fds[arg0].fi_name, "write"] = lquantize(
	    fds[arg0].fi_offset*100/1073741824, 0, 100, 1);
}

/*
 * print stats every second
 */
tick-1s
{

	throughput_kbps = bytes_read / 1024;
	throughput_mbps = bytes_read / 1024 / 1024;

	@throughput["KB/s"] = quantize(throughput_kbps);
	bytes_read = 0;

	printf("file: %s\ncurrent throughput\n\t(KB/s): %d\n\t(MB/s): %d\n",
	    cur_file, throughput_kbps, throughput_mbps);
	printa("avg throughput: \n\t(%s):%@d\n", @throughput);

	printa(@reads);
	printa(@writes);
}
