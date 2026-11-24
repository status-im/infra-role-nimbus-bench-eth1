# Description

This role provisions a benchmarking service for nimbus-eth1 clients. A host runs one of two benchmarks:
Short benchmark (imports a fixed number of blocks on top of a template database, about 8 hours)
Long benchmark (imports the whole chain, about 4 days)

Results are published to [nimbus-eth1-benchmarks](https://github.com/status-im/nimbus-eth1-benchmarks).

# Status
```
systemctl status nimbus-eth1-mainnet-master-short-benchmark.service
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

The entrypoint script that runs the benchmark is located at files/run-benchmark.sh
The required arguments would be :
```bash

BENCHMARKING_TYPE="short | long"
FORCE_RUN="true | false"

```

# Triggering

Runs are started by the `Benchmark` workflow of the nimbus-eth1-benchmarks repository, either by hand or by its scheduler, and can be followed there. The role installs a GitHub Actions runner on the host for this, labeled `nimbus-bench-short` or `nimbus-bench-long`.

```
gh workflow run benchmark.yml -R status-im/nimbus-eth1-benchmarks -f type=short
gh workflow run benchmark.yml -R status-im/nimbus-eth1-benchmarks -f type=short -f commit=<hash> -f force=true
```

The job does not run the benchmark itself. It calls `trigger-benchmark.sh`, which starts the benchmark systemd service, mirrors its log into the job and reports the result. Cancelling the job stops the service.

The runner executes whatever a workflow of that repository asks for, so its user `ghrunner` is kept apart from the benchmark user:

* It is not in the `staff` group and its service cannot see `/home`, which holds the keys used to publish results.
* It may only start and stop the benchmark service through `sudo`.
* It passes the commit to benchmark in a file that `run-benchmark.sh` parses strictly instead of sourcing it.
* The Discord webhook is kept in `benchmark-secrets.env`, which it cannot read.

Request, log, status and summary of each run are exchanged in `/var/lib/nimbus-benchmark-trigger`.

## Registering the runner

The first run of the role on a host needs a registration token, which is valid for one hour:
```
gh api -X POST repos/status-im/nimbus-eth1-benchmarks/actions/runners/registration-token --jq .token
ansible-playbook ansible/bench.yml -e github_runner_registration_token=<token>
```

## Runner service
```
systemctl status github-runner-nimbus-bench.service
```
