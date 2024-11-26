# Description

This role provisions 2 benchmarking services that benchmark nimbus-eth1 clients.
Short benchmark (a service that runs for 24 hours)
Long benchmark (a service that runs for 1 week)

# Status
```
systemctl status nimbus-eth1-mainnet-short-benchmark.service
```

# Configuration

The crucial settings are:
```yaml
# can be either `short` or `long`
nimbus_eth1_benchmark_type: 'short'
# path to template-db, needed for short benchmarking
nimbus_eth1_template_db: 'path/to/template-db'
# era1 files are necessary for import process to run
nimbus_eth1_era_dir: 'path/to/era-files'
# era files are necessary for import process to run
nimbus_eth1_era1_dir: 'path/to/era1-files'
```
