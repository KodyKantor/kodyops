#
# Prints out when the zio_wait for OS-6602 vdev probes beings and ends.
# It 'guesses' which zio is for the vdev probes based on the bitmap of zio
# flags sent in to zio_root, so this may not be accurate on production machines.
#

zio_root:entry
/arg3 == 1152/
{
	self->trace = 1;
}

zio_root:return
/self->trace/
{
	self->zio = arg1;
	self->trace = 0;
}

zio_wait:entry
/arg0 == self->zio/
{
	trace("begin zio_wait");
	self->ts = timestamp;
}

zio_wait:return
/self->ts/
{
	printf("%u ms", (timestamp - self->ts) / 1000000);
	self->ts = 0;
}
