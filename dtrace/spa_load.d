/*
 * When a spa_load is attempted, print the timestamps of the various uberblocks
 * that are referenced.
 * 
 * spa_load will retry multiple times in the event of a load failure, each time
 * with an older uberblock. It's sometimes useful to see the timestamp of the
 * uberblock being attempted in relation to the last known 'good' uberblock.
 *
 */

spa_load:entry
{
	spa = args[0];
	self->spa = spa;
}

spa_load:return
/self->spa/
{
	printf("pool: %s\nubsync: %Y\nuberblock: %Y\nlast_ubsync: %Y\n\n",
	    spa->spa_name,
	    spa->spa_ubsync.ub_timestamp * 1000000000,
	    spa->spa_uberblock.ub_timestamp * 1000000000,
	    spa->spa_last_ubsync_txg_ts * 1000000000);
}
