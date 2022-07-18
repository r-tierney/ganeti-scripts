## Description:

This script was created with the primary goal of moving an instance from one node to another whilst migrating from the xen hypervisor to KVM at the same time.

It is also capable of moving an instance from one cluster to another providing you have setup ssh-keys from the source node Ganeti master to:
- source node of where the instance is to be moved from,
- Destination node of where the instance is to be moved to,
- Ganeti master of the destination node

## Overview / How it works?

Basic steps of how this script works:

1. Create a logical volume on the destination node with the same size as the original logical volume from the instance we're moving.
2. Shutdown and rename the original instance ( Rename is neccessary so we can create an instance with the original name )
3. Copy the instance filesystem from the source node to the new logical volume on the destination node
4. Add a new KVM instance using the original instance name on the destination node whilst adopting the new logical volume we just created / copied data to
5. Pause and ask the user for a confirmation if they would like to remove the original instance on the source node. ( gives the user time to check before removing the original )
6. Clean up


## Requirements

1. On the source node ganeti master:
    ```bash
    apt install pv
    git clone git@github.com:r-tierney/ganeti-scripts.git
    cd ganeti-scripts
    chmod +x move-instance.sh
    ssh-copy-id source_node
    ssh-copy-id destination_node
    ssh-copy-id destination_node_ganeti_master
    ```

## Usage:

```
Usage: ./move-instance.sh [-i instance] [-d destination node]
  -i, --instance           The instance / Virtual machine you would like to move
  -d, --destination-node   The node you would like to move the instance to

Example: ./move-instance.sh --instance dns01.lan --destination-node kvm02.lan
```

## Final notes

This script was made open source with the hope it helps someone migrating instances either from one cluster to another or from one hypervisor to another <br />
whilst this has proven to work in our environment, this script may require a bit of tweaking for your environment but I hope this gives you good head start. <br />

I would recommend reading this script first and understanding it before use and always test it on a throw-away instance or test cluster first.

If you are using partitions within your instance you may have to add the necessary `kpartx` steps to this script in order to mount your root partition and any further partitions first. <br />
Also we are using the xfs filesystem in this script feel free to change this to whatever you are using.

I would also like to mention if you are just wanting to move instance from one cluster to another without changing hypervisors then there is also this script from Ganeti: <br />
https://docs.ganeti.org/docs/ganeti/3.0/html/move-instance.html


## Disclaimer 

I am not responsible for any damages or loss of data. If you choose to run this script it is then your responsibility to understand the code and its consequences.

As mentioned above I always recommend testing with a throw away instance or test cluster first.

With all that out of the way I really do hope this helps you in some way!
