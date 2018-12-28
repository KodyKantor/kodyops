/*
 * Tries to pretty-print the callstack of a given program using the given fbt
 * module.
 *
 * For example, if you want to see the ZFS calls that a 'dd' program makes you
 * would run this:
 *
 *     dtrace -s callstack.d zfs '"dd"' > dd_callstack.out
 *
 * In another window you'd run the 'dd' program. When 'dd' finishes you'd come
 * back to this window and Ctrl+c to stop the trace.
 */
#pragma D option quiet

BEGIN
{
	pattern = "|--";
	sep = "";

	printf("waiting for command\n");
}

fbt:$1::entry
/execname == $2/
{
	sep = strjoin(sep, pattern);
}

fbt:$1::*
/execname == $2/
{
	printf("%s %s -> %s\n", sep, probefunc, probename);
}

fbt:$1::return
/execname == $2/
{
	sep = substr(sep, 0, strlen(sep) - strlen(pattern));
}
