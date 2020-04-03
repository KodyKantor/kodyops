#!/usr/sbin/dtrace -qs

/*
 * Attempts to print the distribution of work and ring-full problems
 * for NICs below an aggr
 */
mac_hwring_send_priv:entry
{
    this->mip = ((mac_client_impl_t *) args[0])->mci_mip;
    self->out = this->mip;
    @tot[self->out->mi_name] = count();
    @agg = count();
}

mac_hwring_send_priv:return
/self->out/
{
    if (args[1] != NULL) {
        @full[self->out->mi_name] = count()
    } else {
        @ok[self->out->mi_name] = count()
    }
    self->out = 0;
}

ixgbe_ring_tx:entry
{
    this->ixgbe = ((ixgbe_tx_ring_t *)args[0])->ixgbe;
    @rings[(uint64_t)this->ixgbe->dip, arg0] = count();
}

END
{
    printf("ring okay\n");
    printa(" --- %s -> %@d\n", @ok);

    printf("\nring full\n");
    printa(" --- %s -> %@d\n", @full);

    printf("\ntotal (separate)\n");
    printa(" --- %s -> %@d\n", @tot);

    printf("\ntotal (aggregate)\n");
    printa(" --- %@d\n", @agg);

    printf("\nrings\n");
    printa(" --- %x / %x -> %@d\n", @rings);
}
