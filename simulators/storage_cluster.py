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
user_data_gigabits = 120

# For printing stats in 'byte' base or 'bit' base.
unit_divisor = byte

# Number of storage clusters.
cluster_count = 1

# Physical nodes per cluster. This is also used as the EC stripe width.
nodes_per_cluster = 9

parity_chunks = 3

# True: Pack all of a given DC's cluster members into one rack.
# False: Spread out a given DC's cluster members into separate racks.
rack_locality = False

datacenters = 3
racks_per_dc = 3
machines_per_rack = 10

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

        cluster = SmaugCluster(self, opts)
        self.clusters.append(cluster)

        opts['hosts_per_dc'] = hosts_per_dc
        for dc in self.datacenters:
            err = dc.allocate_smaug_cluster(cluster, opts)
            if err != None:
                return err

    def get_number_of_datacenters(self):
        return len(self.datacenters)

    def receive_data(self, size_gigabits):
        data_per_cluster = size_gigabits / len(self.clusters)
        for cluster in self.clusters:
            cluster.receive_data(data_per_cluster)
        pass

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

    def __str__(self):
        tx = self.get_tx()
        rx = self.get_rx()
        ret = '-> DC{0}: tx={1:.1f} rx={2:.1f}\n'.format(self.idx, tx, rx)
        for rack in self.racks:
            ret = ret + '   ' + str(rack)
        return ret

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
                return 'could not fit cluster in one rack (locality)'
            elif not opts['rack_locality'] and rack.get_capacity() >= 1:
                rack.allocate_machines(cluster, 1)
                allocated.append(rack)
                if err != None or len(allocated) == hosts_per_dc:
                    break
            if err != None:
                map(lambda x: x.deallocate_machines(cluster), allocated)
                err = 'failed to allocate cluster: ' + err
                break
        if len(allocated) < hosts_per_dc:
            map(lambda x: x.deallocate_machines(cluster), allocated)
            err = 'failed to allocate enough machines'
        return err

    def get_tx(self):
        return reduce((lambda x, y: x + y.get_tx()), self.racks, 0)

    def get_rx(self):
        return reduce((lambda x, y: x + y.get_rx()), self.racks, 0)


class Rack:
    def __init__(self, region, machines):
        #self.region = region
        self.idx = region.allocate_rack_idx()
        self.machines = []
        for x in range(machines):
            self.machines.append(Machine(region))
        self.capacity = len(self.machines)

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

    def get_capacity(self):
        return self.capacity

    def get_tx(self):
        return reduce((lambda x, y: x + y.get_tx()), self.machines, 0)

    def get_rx(self):
        return reduce((lambda x, y: x + y.get_rx()), self.machines, 0)

    def __str__(self):
        tx = self.get_tx()
        rx = self.get_rx()
        ret = '-> RACK{0}: tx={1:.1f} rx={2:.1f}\n'.format(self.idx, tx, rx)
        for machine in self.machines:
            ret = ret + '      ' + str(machine)
        return ret

class Machine:
    def __init__(self, region):
        #self.region = region
        self.idx = region.allocate_machine_idx()
        self.cluster_idx = -1
        self.rx = 0
        self.tx = 0

    def is_allocated(self):
        return self.cluster_idx >= 0

    def allocate(self, cluster):
        self.cluster_idx = cluster.get_idx()

    def deallocate(self):
        self.cluster_idx = -1

    def get_cluster_idx(self):
        return self.cluster_idx

    def receive_data(self, size_gigabits):
        self.rx += size_gigabits

    def send_data(self, size_gigabits):
        self.tx += size_gigabits

    def get_tx(self):
        return self.tx / unit_divisor

    def get_rx(self):
        return self.rx / unit_divisor

    def __str__(self):
        tx = self.get_tx()
        rx = self.get_rx()
        id_str = ''
        if self.cluster_idx == -1:
            id_str = 'unalloc'
        else:
            id_str = str(self.cluster_idx)
        ret = '-> MACHINE{0}: cluster={1} tx={2:.1f} rx={3:.1f}\n'.format(self.idx, id_str, tx, rx)
        return ret

class SmaugCluster:
    def __init__(self, region, opts):
        self.idx = region.allocate_cluster_idx()
        self.placement = []
        self.parity = opts['parity_chunks']
        self.rx = 0
        self.tx = 0

    def get_idx(self):
        return self.idx

    def receive_data(self, size_gigabits):
        # XXX: unused
        self.rx += size_gigabits

        '''
        request_handler_node = self.placement[random.randint(0, len(self.placement) - 1)]
        request_handler_node.receive_data(size_gigabits)
        '''
        
        user_data_per_node = size_gigabits / len(self.placement)

        # The chunk size is based on the size of the user data (input) divided
        # by the number of _data_ chunks in the cluster.
        chunk_size = user_data_per_node / (len(self.placement) - self.parity)
        for server in self.placement:
            server.receive_data(user_data_per_node)

            for remote in self.placement:
                # Need to differentiate between rx/tx and disk throughput.
                if remote == server:
                    pass
                server.send_data(chunk_size)
                remote.receive_data(chunk_size)

    def add_placement(self, machine):
        self.placement.append(machine)

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

    size_gigabits = user_data_gigabits
    region.receive_data(size_gigabits)

    print(region)
