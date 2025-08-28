#!/usr/bin/env python3
"""
Prometheus metrics exporter for Nimbus ETH1 benchmarking
Reads YAML metrics from metrics-collector.sh and exposes them via HTTP
"""

import os
import sys
import time
import logging
import re

try:
    import yaml
except ImportError:
    print("Error: PyYAML library not found. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

try:
    from prometheus_client import start_http_server, Gauge, Info, REGISTRY
    from prometheus_client.core import GaugeMetricFamily, InfoMetricFamily, REGISTRY as CORE_REGISTRY
    from prometheus_client.registry import Collector
except ImportError:
    print("Error: prometheus_client library not found. Install with: pip install prometheus-client", file=sys.stderr)
    sys.exit(1)

METRICS_FILE = os.environ.get('METRICS_FILE', '/var/lib/nimbus-benchmark-metrics/benchmark_metrics.yaml')
LISTEN_PORT = int(os.environ.get('METRICS_PORT', '9091'))
CGROUP_BASE = "/sys/fs/cgroup/system.slice"

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger('nimbus-benchmark-exporter')


class NimbusBenchmarkCollector(Collector):
    """Custom Prometheus collector that reads from YAML file and cgroups"""

    def __init__(self, metrics_file: str):
        self.metrics_file = metrics_file

    def collect(self):
        """Collect metrics from YAML file and cgroups"""
        yield from self._collect_yaml_metrics()
        yield from self._collect_cgroup_metrics()

        # Exporter health
        up = GaugeMetricFamily('nimbus_benchmark_exporter_up', 'Exporter health status')
        up.add_metric([], 1)
        yield up

        refresh_ts = GaugeMetricFamily('nimbus_benchmark_exporter_last_refresh_timestamp', 'Last refresh timestamp')
        refresh_ts.add_metric([], int(time.time()))
        yield refresh_ts

    def _collect_yaml_metrics(self):
        """Read and parse YAML metrics file"""
        if not os.path.exists(self.metrics_file):
            logger.warning(f"Metrics file not found: {self.metrics_file}")
            return

        try:
            with open(self.metrics_file, 'r') as f:
                data = yaml.safe_load(f) or {}
        except Exception as e:
            logger.error(f"Failed to read metrics file: {e}")
            return

        benchmark_type = data.get('benchmark_type', '') or ''

        # Stage metrics
        stages = data.get('stages', {}) or {}
        if stages:
            stage_success = GaugeMetricFamily(
                'nimbus_benchmark_stage_success',
                'Success status of benchmark stage',
                labels=['stage_name', 'benchmark_type']
            )
            stage_duration = GaugeMetricFamily(
                'nimbus_benchmark_stage_duration_seconds',
                'Duration of benchmark stage in seconds',
                labels=['stage_name', 'benchmark_type']
            )
            for stage_name, stage_data in stages.items():
                stage_success.add_metric([stage_name, benchmark_type], stage_data.get('success', 0))
                stage_duration.add_metric([stage_name, benchmark_type], stage_data.get('duration_seconds', 0))

            yield stage_success
            yield stage_duration

        # Metadata
        metadata = data.get('metadata', {}) or {}
        if metadata.get('git_hash'):
            info = InfoMetricFamily('nimbus_benchmark', 'Benchmark metadata information')
            info.add_metric([], {
                'git_hash': str(metadata.get('git_hash', '')),
                'benchmark_type': benchmark_type,
                'start_block': str(metadata.get('start_block', '')),
                'end_block': str(metadata.get('end_block', ''))
            })
            yield info

            total_blocks = GaugeMetricFamily(
                'nimbus_benchmark_total_blocks',
                'Total number of blocks in benchmark',
                labels=['benchmark_type']
            )
            total_blocks.add_metric([benchmark_type], metadata.get('total_blocks', 0))
            yield total_blocks

        # Timestamp
        last_run = data.get('last_run_timestamp', 0)
        if last_run:
            ts = GaugeMetricFamily(
                'nimbus_benchmark_last_run_timestamp',
                'Unix timestamp of last benchmark run',
                labels=['benchmark_type']
            )
            ts.add_metric([benchmark_type], last_run)
            yield ts

    def _read_cgroup_value(self, service: str, filename: str, parser=None):
        """Helper to read a value from a cgroup file"""
        path = f"{CGROUP_BASE}/{service}.service/{filename}"
        if not os.path.exists(path):
            return None
        try:
            with open(path, 'r') as f:
                content = f.read().strip()
            return parser(content) if parser else content
        except Exception:
            return None

    def _collect_cgroup_metrics(self):
        """Collect live cgroup metrics for benchmark services"""
        services = self._discover_services()
        if not services:
            return

        cpu = GaugeMetricFamily('nimbus_benchmark_cgroup_cpu_usage_seconds', 'CPU usage from cgroup', labels=['service'])
        mem = GaugeMetricFamily('nimbus_benchmark_cgroup_memory_bytes', 'Memory usage from cgroup', labels=['service'])
        mem_peak = GaugeMetricFamily('nimbus_benchmark_cgroup_memory_peak_bytes', 'Peak memory usage from cgroup', labels=['service'])
        pids = GaugeMetricFamily('nimbus_benchmark_cgroup_processes', 'Number of processes from cgroup', labels=['service'])
        io_read = GaugeMetricFamily('nimbus_benchmark_cgroup_io_read_bytes', 'IO read bytes from cgroup', labels=['service'])
        io_write = GaugeMetricFamily('nimbus_benchmark_cgroup_io_write_bytes', 'IO write bytes from cgroup', labels=['service'])

        for service in services:
            # CPU usage
            cpu_stat = self._read_cgroup_value(service, 'cpu.stat')
            if cpu_stat:
                for line in cpu_stat.split('\n'):
                    if 'usage_usec' in line:
                        cpu.add_metric([service], int(line.split()[1]) / 1_000_000)
                        break

            # Memory
            mem_val = self._read_cgroup_value(service, 'memory.current')
            if mem_val and mem_val.isdigit():
                mem.add_metric([service], int(mem_val))

            mem_peak_val = self._read_cgroup_value(service, 'memory.peak')
            if mem_peak_val and mem_peak_val.isdigit():
                mem_peak.add_metric([service], int(mem_peak_val))

            # PIDs
            pids_val = self._read_cgroup_value(service, 'pids.current')
            if pids_val and pids_val.isdigit():
                pids.add_metric([service], int(pids_val))

            # IO
            io_stat = self._read_cgroup_value(service, 'io.stat')
            if io_stat:
                total_read, total_write = 0, 0
                for line in io_stat.split('\n'):
                    if match := re.search(r'rbytes=(\d+)', line):
                        total_read += int(match.group(1))
                    if match := re.search(r'wbytes=(\d+)', line):
                        total_write += int(match.group(1))
                if total_read:
                    io_read.add_metric([service], total_read)
                if total_write:
                    io_write.add_metric([service], total_write)

        yield cpu
        yield mem
        yield mem_peak
        yield pids
        yield io_read
        yield io_write

    def _discover_services(self):
        """Discover nimbus benchmark services from cgroup"""
        services = []
        if not os.path.exists(CGROUP_BASE):
            return services
        try:
            for entry in os.listdir(CGROUP_BASE):
                if entry.startswith('nimbus-eth1-') and 'benchmark' in entry and entry.endswith('.service'):
                    services.append(entry.replace('.service', ''))
        except Exception as e:
            logger.warning(f"Failed to discover services: {e}")
        return services


def main():
    logger.info(f"Starting Nimbus Benchmark metrics exporter on port {LISTEN_PORT}")
    logger.info(f"Reading metrics from: {METRICS_FILE}")

    REGISTRY.register(NimbusBenchmarkCollector(METRICS_FILE))
    start_http_server(LISTEN_PORT)

    logger.info(f"Metrics endpoint: http://0.0.0.0:{LISTEN_PORT}/metrics")

    # Keep the main thread alive
    while True:
        time.sleep(60)


if __name__ == '__main__':
    main()
