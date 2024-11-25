# Description

This role provisions 2 benchmarking services that benchmark nimbus-eth1 clients.

# Ports

The service exposes five ports by default:

* `30303` - DevP2P peering port. Must __ALWAYS__ be public.
* `8545` - Combo HTTP port (JSON RPC, Websocket RPC, Graphql). Must __NEVER__ be public.
* `8550` - Engine API HTTP port. Must __NEVER__ be public.
* `9093` - Prometheus metrics port. Should not be public.

# Installation

Add to your `requirements.yml` file:
```yaml
- name: infra-role-nimbus-eth1
  src: git+git@github.com:status-im/infra-role-nimbus-eth1.git
  scm: git
```

# Configuration

The crucial settings are:
```yaml
# branch which should be built
nimbus_eth1_repo_branch: 'master'
# ethereum network to connect to
nimbus_eth1_network: 'mainnet'
# increase maximum number of peers
nimbus_eth1_max_peers: 160
# optional setting for debug mode
nimbus_eth1_log_level: 'DEBUG'
```

# Usage

Assuming the `master` branch was built you can manage the service with:
```sh
systemctl start nimbus-eth1-mainnet-master
systemctl status nimbus-eth1-mainnet-master
systemctl stop nimbus-eth1-mainnet-master
```
You can view logs under:
```sh
tail -f /data/nimbus-eth1-mainnet-master/logs/service.log
```
The service will store all data in the `/data/nimbus-eth1-mainnet-master/data` directory.

# Building

A timer will be installed to build the image:
```sh
systemctl list-timers 'build-nimbus-eth1-*'
```
To rebuild the image:
```sh
systemctl start build-nimbus-eth1-mainnet-master.service
```
To check build logs use:
```sh
journalctl -u build-nimbus-eth1-mainnet-master.service
```
