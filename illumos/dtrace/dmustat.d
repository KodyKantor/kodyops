#!/usr/sbin/dtrace -Cs

/*
 * dmustat.d - watch PG locks and the DMU txg throttle simultaneously.
 *
 *
 * I used this to track down MANTA-3808 and MANTA-3803.
 *
 * This is really a copy of some parts of the pgsqllocks script that dap wrote
 * with some goop to keep track of any time ZFS decides to throttle txg flushes
 * because it thinks the disks can't keep up.
 *
 * In MANTA-3808/MANTA-3803 we don't see the ZFS txg throttle, which was
 * shown using this script.
 *
 */

#pragma D option quiet
#pragma D option zdefs

#define	ACCESS_SHARE          	1
#define	ROW_SHARE             	2
#define	ROW_EXCLUSIVE         	3
#define	SHARE_UPDATE_EXCLUSIVE	4
#define	SHARE                 	5
#define	SHARE_ROW_EXCLUSIVE   	6
#define	EXCLUSIVE             	7
#define	ACCESS_EXCLUSIVE      	8
#define	LOCKTYPE_MAX		ACCESS_EXCLUSIVE

BEGIN
{
	printf("%20s %5s %5s %5s %5s %5s %5s %5s %5s %5s %5s\n",
		"timestamp",
		"AS", "RS", "RX", "SUX", "S", "SRX", "X", "AX",
		"nr",
		"tot_del"
	);
	@count = count();
	@duration = sum(0)
}

postgresql*:::lock-wait-start
/arg5 <= LOCKTYPE_MAX/
{
	waiting[arg5]++;
}

sdt:zfs:dmu_tx_delay:delay-mintime
{
	@count = count();
	@duration = sum(arg2)
}

tick-5s
{
	printf("%Y %5d %5d %5d %5d %5d %5d %5d %5d",
		walltimestamp,
		waiting[ACCESS_SHARE],
		waiting[ROW_SHARE],
		waiting[ROW_EXCLUSIVE],
		waiting[SHARE_UPDATE_EXCLUSIVE],
		waiting[SHARE],
		waiting[SHARE_ROW_EXCLUSIVE],
		waiting[EXCLUSIVE],
		waiting[ACCESS_EXCLUSIVE]
	);
	printa("%@5u %@5u", @count, @duration);
	printf("\n");

	waiting[ACCESS_SHARE] = 0;
	waiting[ROW_SHARE] = 0;
	waiting[ROW_EXCLUSIVE] = 0;
	waiting[SHARE_UPDATE_EXCLUSIVE] = 0;
	waiting[SHARE] = 0;
	waiting[SHARE_ROW_EXCLUSIVE] = 0;
	waiting[EXCLUSIVE] = 0;
	waiting[ACCESS_EXCLUSIVE] = 0;

	clear(@count);
	clear(@duration);
}

