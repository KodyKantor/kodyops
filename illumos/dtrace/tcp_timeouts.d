#!/usr/sbin/dtrace -qs

/*
 * Prints out the addresses of functions set up as tcp timeouts (e.g. with
 * tcp_timeout()), and how long it took for the given timeout to be canceled or
 * invoked.
 *
 * I'm not sure how accurate this is. According to this script some timers take
 * tens of milliseconds to be cancelled and timers are very rarely invoked.
 */

tcp_timeout:entry
{
	self->func = (uint64_t)args[1];
	@[self->func]=count()
}

tcp_timeout:return
/self->func/
{
	ids[args[1]] = self->func;
	timers[args[1]] = timestamp;
}

tcp_timeout_cancel:entry
/ids[args[1]]/
{
	@ccl[ids[args[1]]] = count();
	@ccl_dur[ids[args[1]]] = quantize(timestamp - timers[args[1]]);
}

tcp_timer_handler:entry
{
	this->tid = ((conn_t *)args[0])->conn_proto_priv.cp_tcp->tcp_timer_tid;
	if (ids[this->tid]) {
		@call_dur[ids[this->tid]] = quantize(timestamp - timers[this->tid]);
	}
}

END
{
	printf("timeouts set\n");
	printa("--- %x %@d\n", @);
	printf("timeouts cancelled\n");
	printa("--- %x %@d\n", @ccl);

	printf("time spent before cancel\n");
	printa("--- %x %@d\n", @ccl_dur);

	printf("time spent before invoke\n");
	printa("--- %x %@d\n", @call_dur);
}
