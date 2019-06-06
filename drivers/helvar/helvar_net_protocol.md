
# Helvar.net Protocol

Reference: https://aca.im/driver_docs/Helvar/HelvarNet-Overview.pdf

For use with Helvar to DALI routers

* TCP port: 50000
* UDP port: 50001


## Addressing

The Helvar lighting router system would consist of a number of routers (910 or 920) that enable
connection to a variety of different inputs and outputs using a different data buses.

The backbone structure of the system uses Ethernet Cat 5 cabling & the TCP/IP protocol. As
such each system (or workgroup) is a cluster of routers. The cluster (3rd Octet in IP addressing)
forms the first part of the unique device address

Each router within the system will then have a unique IP address with the 4th octet providing the
unique router number. This number forms the second digit of the unique device address.

The cluster.router is then followed by a subnet. The subnet refers to the data bus on which
inputs or output devices are connected. Depending on the router type (910 or 920) there are 2
or 4 subnets available. In both case’s subnet 1 & 2 use the DALI protocol. For the 920 you have
additional subnets 3 (using S-Dim) and 4 (DMX).

Following cluster.router.subnet is then the device address. This number is limited by the type of
subnet to which the device is connected and in the case of output devices completes the device
address.

For input devices there is a further sub-device which will refer to a particular property of that
input device for example a control panel (device) would have a number of buttons (sub-device).

So a full address would be written:-

* Cluster (1..253), Router (1..254), Subnet (1..4), Device (1..255), Subdevice (1..16)
* cluster.router.subnet.address for output devices
* cluster.router.subnet.address for input devices
* cluster.router.subnet.address.sub-address for input sub-devices

### Address Structure

* Cluster = the 3rd octet of the IP address range used
* Router = the 4th octet of the IP address of that particular router
* Subnet = the data bus on which devices are connected (Dali 1 = 1, Dali 2 = 2, S-Dim = 3, DMX = 4)
* Address = the device address, dependant on the data bus (Dali = 1-64, S-Dim = 1-252, DMX = 1-512)
* Sub-address = the sub-device of the device (button, sensor, input etc.)


## Commands

* `>V:` is the command prefix (`>V:2` represents the protocol version 2)
* `C:` is the command type
  * `11` == select scene
  * `13` == direct level group address
  * `14` == direct level short address
  * `109` == query selected scene
* `G:` specifies the lighting group
* `S:` specifices the lighting scene
* `F:` specifies the fade time (in 1/100ths of a second. So a fade of 900 is 9 seconds)
* `L:` specifies the level (between 1 and 100)
* `@` specifies the short address (looks like: 1.2.1.1)
* all commands end with a `#`


### Example Commands

* Direct level, short address: `>V:1,C:14,L:{0},F:{1},@{2}#`
  * {0} == level, {1} == fade_time, {2} == address
* Direct level, group address: `>V:1,C:13,G:{0},L:{1},F:{2}#`
  * {0} == address, {1} == level, {2} == fade_time
* Keep socket alive: `>V:1,C:14,L:0,F:9000,@65#`
  * Write to dummy address to keep socket alive


### Example Query

* `>V:2,C:109,G:17#` query Group 17 as to which scene it is currently in
  * responds with: `?V:2,C:109,G:17=14#`
  * i.e. Group 17 is in scene 14

### Example Error

* `>V:1,C:104,@:2.2.1.1#` query device type
  * responds with: `!V:1,C:104,@:2.2.1.1=11#`
  * i.e. error 11, device does not exist


References:

* https://github.com/tkln/HelvarNet/blob/master/helvar.py
* https://github.com/houmio/houmio-driver-helvar-router/blob/master/src/driver.coffee

