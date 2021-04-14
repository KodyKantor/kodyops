#!/usr/bin/env python3

'''
Copyright 2020 Joyent, Inc.
'''

import random
from functools import reduce

# How many bits per unit. Don't modify this.
byte = 8
bit = 1

# Variables.

# User data in gigabits
upload_data_gigabits = 600
download_data_gigabits = 300

# For printing stats in 'byte' base or 'bit' base.
unit_divisor = bit

# Number of storage clusters.
cluster_count = 4

# Physical nodes per cluster. This is also used as the EC stripe width.
nodes_per_cluster = 12

parity_chunks = 4

'''
True: Pack all of a given DC's cluster members into one rack.
False: Spread out a given DC's cluster members into separate racks. This will
  still 'bin pack' each rack.
'''
rack_locality = False

datacenters = 3
racks_per_dc = 4
machines_per_rack = 4
disks_per_machine = 35

class Region:
    def __init__(self, datacenters, racks_per_dc, machines_per_rack):
        self.dc_idx = 0
        self.machine_idx = 0
        self.rack_idx = 0
        self.cluster_idx = 0

        self.clusters = []
        self.datacenters = []
        for x in range(datacenters):
            self.datacenters.append(Datacenter(
                self,
                racks=racks_per_dc,
                machines_per_rack=machines_per_rack))

    def get_number_of_datacenters(self):
        return len(self.datacenters)

    def allocate_dc_idx(self):
        val = self.dc_idx
        self.dc_idx += 1
        return val

    def allocate_machine_idx(self):
        val = self.machine_idx
        self.machine_idx += 1
        return val
    
    def allocate_rack_idx(self):
        val = self.rack_idx
        self.rack_idx += 1
        return val

    def allocate_cluster_idx(self):
        val = self.cluster_idx
        self.cluster_idx += 1
        return val

    def allocate_smaug_cluster(self, opts):
        hosts_per_dc = opts['nodes'] / opts['dcs']
        if not hosts_per_dc.is_integer():
            return 'hosts must be evenly divisible by number of DCs'

        cluster = StorageCluster(self, opts)
        self.clusters.append(cluster)

        opts['hosts_per_dc'] = hosts_per_dc
        for dc in self.datacenters:
            err = dc.allocate_smaug_cluster(cluster, opts)
            if err != None:
                return err

    def upload(self, size_gigabits):
        data_per_cluster = size_gigabits / len(self.clusters)
        for cluster in self.clusters:
            cluster.ingress(data_per_cluster)

    def download(self, size_gigabits):
        data_per_cluster = size_gigabits / len(self.clusters)
        for cluster in self.clusters:
            cluster.egress(data_per_cluster)

    def __str__(self):
        ret = 'Region\n'
        for dc in self.datacenters:
            ret = ret + str(dc)
        return ret


class Datacenter:
    def __init__(self, region, racks, machines_per_rack):
        #self.region = region
        self.idx = region.allocate_dc_idx()
        self.racks = []
        for x in range(racks):
            self.racks.append(Rack(region, machines=machines_per_rack))

    def get_tx(self):
        return reduce((lambda x, y: x + y.get_tx()), self.racks, 0)

    def get_rx(self):
        return reduce((lambda x, y: x + y.get_rx()), self.racks, 0)

    def allocate_smaug_cluster(self, cluster, opts):
        hosts_per_dc = opts['hosts_per_dc']
        allocated = []
        err = None

        for rack in self.racks:
            # operator wants rack locality and this rack has capacity.
            if opts['rack_locality'] and rack.get_capacity() >= hosts_per_dc:
                err = rack.allocate_machines(cluster, hosts_per_dc)
                if err != None:
                    break

                # successfully allocated all of this datacenter's cluster nodes.
                break
            elif opts['rack_locality'] and rack.get_capacity() < hosts_per_dc:
                continue
            elif not opts['rack_locality'] and rack.get_capacity() >= 1:
                rack.allocate_machines(cluster, 1)
                allocated.append(rack)
                if err != None or len(allocated) == hosts_per_dc:
                    break
            if err != None:
                map(lambda x: x.deallocate_machines(cluster), allocated)
                err = 'failed to allocate cluster: ' + err
                break
        if not opts['rack_locality'] and len(allocated) < hosts_per_dc:
            map(lambda x: x.deallocate_machines(cluster), allocated)
            err = 'failed to allocate enough machines'
        return err

    def __str__(self):
        tx = self.get_tx()
        rx = self.get_rx()
        ret = '  DC{0}: tx={1:.1f} rx={2:.1f}\n'.format(self.idx, tx, rx)
        for rack in self.racks:
            ret = ret + '   ' + str(rack)
        return ret

class Rack:
    def __init__(self, region, machines):
        #self.region = region
        self.idx = region.allocate_rack_idx()
        self.machines = []
        for x in range(machines):
            self.machines.append(Machine(region))
        self.capacity = len(self.machines)

    def get_capacity(self):
        return self.capacity

    def get_tx(self):
        return reduce((lambda x, y: x + y.get_tx()), self.machines, 0)

    def get_rx(self):
        return reduce((lambda x, y: x + y.get_rx()), self.machines, 0)

    def allocate_machines(self, cluster, nr_allocate):
        allocated = []
        err = None

        for machine in self.machines:
            if not machine.is_allocated() and len(allocated) < nr_allocate:
                err = machine.allocate(cluster)
                allocated.append(machine)
                cluster.add_placement(machine)
                if err != None:
                    break
                self.capacity -= 1

        # make sure we don't leave machines allocated in the face of an error.
        if err != None or len(allocated) < nr_allocate:
            map(lambda x: x.deallocate(), allocated)
            return err

    def deallocate_machines(self, cluster):
        for machine in self.machines:
            if machine.is_allocated() and machine.get_cluster_idx() == cluster.get_idx():
                machine.deallocate()

    def __str__(self):
        tx = self.get_tx()
        rx = self.get_rx()
        ret = '  RACK{0}: tx={1:.1f} rx={2:.1f}\n'.format(self.idx, tx, rx)
        for machine in self.machines:
            ret = ret + '      ' + str(machine)
        return ret

class Machine:
    def __init__(self, region):
        self.idx = region.allocate_machine_idx()
        self.cluster_idx = -1
        self.rx = 0
        self.tx = 0
        self.write = 0
        self.read = 0

    def is_allocated(self):
        return self.cluster_idx >= 0

    def allocate(self, cluster):
        self.cluster_idx = cluster.get_idx()

    def deallocate(self):
        self.cluster_idx = -1

    def get_cluster_idx(self):
        return self.cluster_idx

    def get_tx(self):
        return self.tx / unit_divisor

    def get_rx(self):
        return self.rx / unit_divisor

    def get_read(self):
        return self.read / unit_divisor

    def get_write(self):
        return self.write / unit_divisor

    def ingress(self, size_gigabits, net, disk):
        if net:
            self.rx += size_gigabits
        if disk:
            self.write += size_gigabits

    def egress(self, size_gigabits, net, disk):
        if net:
            self.tx += size_gigabits
        if disk:
            self.read += size_gigabits

    def __str__(self):
        # Network IO.
        tx = self.get_tx()
        rx = self.get_rx()

        # Disk IO.
        write = self.get_write()
        read = self.get_read()

        id_str = ''
        if self.cluster_idx == -1:
            id_str = 'unalloc'
        else:
            id_str = str(self.cluster_idx)
        ret = '  MACHINE{0}: cluster={1} tx={2:.1f} rx={3:.1f} disk_write={4:.1f} disk_read={5:.1f}\n'.format(
                self.idx, id_str, tx, rx, write, read)
        return ret

class StorageCluster:
    def __init__(self, region, opts):
        self.idx = region.allocate_cluster_idx()
        self.placement = []
        self.parity = opts['parity_chunks']

    def get_idx(self):
        return self.idx

    def add_placement(self, machine):
        self.placement.append(machine)


    def ingress(self, size_gigabits):
        '''
        The inbound stream of user data is split evenly between all members of
        the cluster. This happens before we perform erasure coding.
        '''
        user_data_per_node = size_gigabits / len(self.placement)

        '''
        The chunk size is based on the size of the user data (input) divided
        by the number of _data_ chunks in the cluster.
        '''
        chunk_size = user_data_per_node / (len(self.placement) - self.parity)
        for server in self.placement:
            server.ingress(user_data_per_node, net=True, disk=False)

            for remote in self.placement:

                '''
                The remote chunk server is actually local.
                '''
                if remote == server:
                    remote.ingress(chunk_size, net=False, disk=True)
                else:
                    server.egress(chunk_size, net=True, disk=False)
                    remote.ingress(chunk_size, net=True, disk=True)

    def egress(self, size_gigabits):
        user_data_per_node = size_gigabits / len(self.placement)
        chunk_size = user_data_per_node / (len(self.placement) - self.parity)

        '''
        Assuming there is no data corruption we only need to retrieve
        (stripe_width - parity) chunks and concatenate them. In practice the
        system will know which chunks are the data vs parity chunks, but here
        we'll just randomly select a subset of nodes to be the data nodes.
        This should model the actual behavior well in aggregate.
        '''
        data_chunk_count = len(self.placement) - self.parity

        '''
        Create chunk metadata.

        The first N chunks are always data chunks, the last (self.parity) chunks
        are always parity chunks. We shuffle this later to randomize data/parity
        locality.
        '''
        chunks = [i for i in range(len(self.placement))]

        for server in self.placement:
            server.egress(user_data_per_node, net=True, disk=False)

            '''
            Reorder chunk list to randomly spread data/parity chunk selection
            across entire cluster.
            '''
            random.shuffle(chunks)

            for remote_ind in range(data_chunk_count):
                remote = self.placement[chunks[remote_ind]]

                '''
                The remote chunk server is actually local.
                '''
                if remote == server:
                    remote.egress(chunk_size, net=False, disk=True)
                else:
                    remote.egress(chunk_size, net=True, disk=True)
                    server.ingress(chunk_size, net=True, disk=False)

if __name__ == '__main__':
    region = Region(datacenters, racks_per_dc, machines_per_rack)

    for x in range(cluster_count):
        err = region.allocate_smaug_cluster({
            'nodes': nodes_per_cluster,
            'rack_locality': rack_locality,
            'dcs': 3,
            'parity_chunks': parity_chunks
        })

        if err:
            print('error allocating smaug cluster: ' + str(err))
            break

    region.upload(upload_data_gigabits)
    region.download(download_data_gigabits)

    # print out the stats.
    print(region)
