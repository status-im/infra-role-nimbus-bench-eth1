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
# path to template-db, the short benchmark starts from a copy of it
nimbus_eth1_template_db: 'path/to/template-db'
# era files, both benchmarks import blocks from them
nimbus_eth1_era_dir: 'path/to/era-files'
# era1 files, the long benchmark imports the blocks before the merge from them
nimbus_eth1_era1_dir: 'path/to/era1-files'
# false keeps the scheduler from starting runs on the host
nimbus_eth1_benchmark_scheduled: true
# GCC version nimbus is built with, installed next to the default one of the OS
nimbus_eth1_benchmark_gcc_version: 11
```

The entrypoint script that runs the benchmark is located at files/run-benchmark.sh
The required arguments would be :
```bash

BENCHMARKING_TYPE="short | long"
FORCE_RUN="true | false"

```

# Secrets

Read from the password store:

| Entry | Purpose |
|-|-|
| `services/nimbus-eth1-benchmark/deploy-key` | SSH key with write access to nimbus-eth1-benchmarks |
| `services/nimbus-eth1-benchmark/signing-key` | SSH key that signs the result commits, registered on the `status-im-auto` account |
| `services/nimbus-eth1-benchmark/discord-webhook` | Webhook that gets an alert when a run fails |
| `services/nimbus-eth1-benchmark/discord-mention-id` | ID of the Discord user mentioned in that alert |

# GitHub access

The role registers the runner and puts the benchmark on the schedule through the GitHub API. Those calls are made on the machine Ansible runs on, with the token of the GitHub CLI:
```
gh auth status
```
The account has to have admin rights on the nimbus-eth1-benchmarks repository. A different token can be given in `nimbus_eth1_github_api_token`.

# Data

The role does not fetch the data the benchmarks run on, it has to be put on a new host by hand:

| Path | Needed by | Content | Source |
|-|-|-|-|
| `nimbus_eth1_era_dir` | both | era files 0 to 1247, 534 GiB | https://mainnet.era.nimbus.team/ |
| `nimbus_eth1_era1_dir` | long | all 1897 era1 files, 427 GiB | https://mainnet.era1.nimbus.team/ |
| `nimbus_eth1_template_db` | short | state at block 20M, 79 GiB | https://eth1-db.nimbus.team/files/mainnet-noroot/mainnet-noroot-0019.tar.zst, unpacked |

The long benchmark imports every block the era files hold, so the set of era files has to stay the same for results to be comparable.

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

## Scheduling

The scheduler of the nimbus-eth1-benchmarks repository starts a run whenever nimbus-eth1 has a commit without results. It does so for the benchmark types listed in the repository variable `BENCHMARK_SCHEDULE_TYPES`, to which the role adds the type of the host. With `nimbus_eth1_benchmark_scheduled: false` the role takes it off the list again, runs can then only be started by hand.

## Registering the runner

The role registers the runner on its first run on a host, with a registration token it requests from GitHub. A reinstalled host takes the place of its old registration.

## Runner service
```
systemctl status github-runner-nimbus-bench.service
```
