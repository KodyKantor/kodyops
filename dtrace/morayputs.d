#!/usr/sbin/dtrace -Cs

/*
 * print the count of objects and dirs created in moray per user.
 */

#pragma D option strsize=1024
#pragma D option quiet

BEGIN
{
	numticks = 0;
	printf("%40s %3s %3s\n", "OWNER", "DIR", "OBJ")
}

moray*:::putobject-start
{
	val = copyinstr(arg4);
	if (json(val, "type") == "directory") {
		@dirs[json(val, "owner")] = count()
	} else {
		@objs[json(val, "owner")] = count()
	}
}

tick-3s
{
	if (numticks == 10) {
		printf("%40s %3s %3s\n", "OWNER", "DIR", "OBJ");
		numticks = 0;
	}

	printa("%40s %3@d %3@d\n", @dirs, @objs);
	printf("\n");

	clear(@dirs);
	clear(@objs);
	numticks++
}
