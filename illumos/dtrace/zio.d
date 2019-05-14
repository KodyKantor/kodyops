#!/usr/sbin/dtrace -Cs

/*
 * Print zio pipelines and the time they spend in each step of the pipeline.
 *
 * You can run it like this:
 *   ./zio.d zil_lwb_write_issue 200 '"ns"' | sort -n | awk '{$1=""; print $0}'
 *
 * Which will print the first ZIO pipeline that has a total duration of 200ns.
 * The output looks like this:
 *
 *   [65532ns] zil_lwb_write_issue
 *   [20317ns] zio_write_bp_init
 *   [27606ns] wait
 *   [15031ns] zio_issue_async
 *   [16879ns] wait
 *   [11901ns] zio_write_compress
 *   [11568ns] wait
 *   [13422ns] zio_checksum_generate
 *   [12041ns] wait
 *   [10437ns] zio_ready
 *   [11355ns] wait
 *   [27992ns] zio_vdev_io_start
 *   [25709ns] wait
 *   [9557ns] zio_vdev_io_done
 *   [314426ns] wait
 *   [13820ns] zio_vdev_io_done
 *   [8677ns] wait
 *   [18070ns] zio_vdev_io_assess
 *   [17351ns] wait
 *   [81714ns] zio_done
 *   [10576ns] wait
 *   [743981ns] DTrace calculated duration
 *   [664521ns] ZIO reported duration
 */

#pragma D option quiet

#define CALC_AND_PRINT() \
	this->duration = (timestamp - timer) / SCALE; \
	total = total + this->duration; \
	printf("%d [%d%s] %s\n", timestamp, this->duration, SCALE_UNIT, \
	    last_func);
	

BEGIN
{
	THRESHOLD = $2;
	SCALE_UNIT = $3;

	if (SCALE_UNIT == "ns") {
		SCALE = 1;
	} else if (SCALE_UNIT == "us") {
		SCALE = 1000;
	} else if (SCALE_UNIT == "ms") {
		SCALE = 1000000;
	}

	total = 0;
	in_progress = 0;
}

$1:entry
/!in_progress/
{
	spec = speculation();
	timer = timestamp;
	last_func = probefunc;
	in_progress = 1; /* lock out other operations */
	self->trace = 1;
}

/* We're not really interested in parent pipelines right now */
zio_wait:entry,
zio_nowait:entry
/self->trace && args[0]->io_type != ZIO_TYPE_NULL && zio == NULL/
{
	zio = args[0];
}

/* Do one last speculation to print the total time in the pipeline */
zio_destroy:entry
/args[0] == zio/
{
	speculate(spec);
	CALC_AND_PRINT();

	this->d = (timestamp - zio->io_queued_timestamp) / SCALE;

	/*
	 * Add one to timestamp so these are printed in order when sorted by
	 * 'sort -n'.
	 */
	printf("%d [%d%s] %s\n", timestamp + 1, total, SCALE_UNIT,
	    "DTrace calculated duration");
	printf("%d [%d%s] %s\n", timestamp + 2, this->d, SCALE_UNIT,
	    "ZIO reported duration");
}

/*
 * If the pipeline took longer than our threshold, commit the speculation.
 *
 * Note that we use three zio_destroy:entry probes because DTrace has rules
 * about what can and can't be done in the same probe invocation as
 * the commit/discard operation.
 */
zio_destroy:entry
/args[0] == zio/
{
	this->d = (timestamp - zio->io_queued_timestamp) / SCALE;
	if (this->d > THRESHOLD) {
		self->commit = 1;
		commit(spec);
	} else {
		discard(spec);
	}
}

zio_destroy:entry
/args[0] == zio/
{
	if (self->commit) {
		exit(0);
	} else {
		/* This ZIO was beneath our threshold. Try again. */
		total = 0;
		zio = NULL;
		spec = 0;
		timer = 0;
		last_func = 0;
	}
}


zio_read_bp_init:entry,
zio_write_bp_init:entry,
zio_free_bp_init:entry,
zio_issue_async:entry,
zio_write_compress:entry,
zio_checksum_generate:entry,
zio_nop_write:entry,
zio_ddt_read_start:entry,
zio_ddt_read_done:entry,
zio_ddt_write:entry,
zio_ddt_free:entry,
zio_gang_assemble:entry,
zio_gang_issue:entry,
zio_dva_throttle:entry,
zio_dva_allocate:entry,
zio_dva_free:entry,
zio_dva_claim:entry,
zio_ready:entry,
zio_vdev_io_start:entry,
zio_vdev_io_done:entry,
zio_vdev_io_assess:entry,
zio_checksum_verify:entry,
zio_done:entry
/args[0] == zio/
{
	speculate(spec);

	CALC_AND_PRINT();

	last_func = probefunc;
	timer = timestamp;
	self->trace = 1;
}


/*
 * The ZIO pipeline should never burn a thread.
 * The ZIO pipeline steps either complete normally, or return
 * to be resumed later.
 */
zio_read_bp_init:return,
zio_write_bp_init:return,
zio_free_bp_init:return,
zio_issue_async:return,
zio_write_compress:return,
zio_checksum_generate:return,
zio_nop_write:return,
zio_ddt_read_start:return,
zio_ddt_read_done:return,
zio_ddt_write:return,
zio_ddt_free:return,
zio_gang_assemble:return,
zio_gang_issue:return,
zio_dva_throttle:return,
zio_dva_allocate:return,
zio_dva_free:return,
zio_dva_claim:return,
zio_ready:return,
zio_vdev_io_start:return,
zio_vdev_io_done:return,
zio_vdev_io_assess:return,
zio_checksum_verify:return,
zio_done:return
/self->trace && last_func == probefunc/
{
	speculate(spec);

	CALC_AND_PRINT();

	last_func = "wait";
	timer = timestamp;
	self->trace = 0;
}
