#!/usr/sbin/dtrace -Cs

#
# Print zio pipelines and the time they spend in each step. Currently this is
# hard-coded to work with zil_commit (zil_lwb_write_issue) IOs.
#
# You can run it like this:
#   ./zio.d 200 '"ns"' | sort -n | awk '{$1=""; print $0}'
#
# Which will print the first ZIO pipeline that has a total duration of 200ns.
# The output looks like this:
# 
#    [31258ns] zil_lwb_write_issue
#    [21950ns] zio_write_bp_init
#    [19065ns] wait
#    [23748ns] zio_issue_async
#    [7885ns] wait
#    [76183ns] zio_write_compress
#    [24082ns] wait
#    [112295ns] zio_checksum_generate
#    [67010ns] wait
#    [21968ns] zio_ready
#    [83548ns] wait
#    [94428ns] zio_vdev_io_start
#    [22395ns] wait
#    [16261ns] zio_vdev_io_done
#    [157279ns] wait
#    [21977ns] zio_vdev_io_done
#    [75554ns] wait
#    [19515ns] zio_vdev_io_assess
#    [17843ns] wait
#    [87418ns] zio_done
#    [1001662ns] calculated_total
#    [982835ns] lwb_total
#


#pragma D option quiet
#pragma D option temporal

#define CALC_AND_PRINT() \
	this->duration = (timestamp - timer) / SCALE; \
	TOTAL = TOTAL + this->duration; \
	printf("%d [%d%s] %s\n", timestamp, this->duration, SCALE_UNIT, \
	    last_func); \
	

BEGIN
{
	THRESHOLD = $1;
	
	if ($2 == "ms") {
		SCALE = 1000000;
	} else if ($2 == "ns") {
		SCALE = 1;
	} else if ($2 == "us") {
		SCALE = 1000;
	}
	SCALE_UNIT = $2;

	TOTAL = 0;
}

zil_lwb_write_issue:entry
/m_zio == NULL/
{
	m_zio = args[1]->lwb_write_zio;
	spec = speculation();
	timer = timestamp;
	last_func = probefunc;
	self->trace = 1;
}

zil_lwb_write_done:entry
/args[0] == m_zio/
{
	speculate(spec);
	CALC_AND_PRINT();

	this->lwb = (lwb_t *)args[0]->io_private;
	this->d = (timestamp - this->lwb->lwb_issued_timestamp) / SCALE;

	/*
	 * Add one to timestamp so this is printed last when sorted by 'sort -n'.
	 * This means these are off by a few ns, but who's counting?
	 */
	printf("%d [%d%s] %s\n", timestamp + 1, TOTAL, SCALE_UNIT, "calculated_total");
	printf("%d [%d%s] %s\n", timestamp + 2, this->d, SCALE_UNIT, "lwb_total");
}

zil_lwb_write_done:entry
/args[0] == m_zio/
{
	this->lwb = (lwb_t *)args[0]->io_private;
	this->d = (timestamp - this->lwb->lwb_issued_timestamp) / SCALE;
	if (this->d > THRESHOLD) {
		self->comm = 1;
		commit(spec);
	} else {
		discard(spec);
	}
}

zil_lwb_write_done:entry
/args[0] == m_zio/
{
	if (self->comm) {
		exit(0);
	} else {
		TOTAL = 0;
		m_zio = NULL;
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
/args[0] == m_zio/
{
	speculate(spec);

	CALC_AND_PRINT();

	last_func = probefunc;
	timer = timestamp;
	self->trace = 1;
}


/*
 * The ZIO pipeline states that it never burns a thread.
 * The zio pipeline steps either complete normally, or return
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
zio_done:return,
zil_lwb_write_issue:return
/self->trace && last_func == probefunc/
{
	speculate(spec);

	CALC_AND_PRINT();

	last_func = "wait";
	timer = timestamp;
	self->trace = 0;
}
