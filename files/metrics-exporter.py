#!/usr/bin/env python3
"""
Prometheus metrics exporter for Nimbus ETH1 benchmarking
Serves metrics collected by metrics-collector.sh via HTTP
"""

import os
import sys
import time
import logging
import re
from typing import Dict, List
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    from prometheus_client import start_http_server, Gauge, Info, CollectorRegistry, generate_latest, CONTENT_TYPE_LATEST
    from prometheus_client.core import REGISTRY
except ImportError:
    print("Error: prometheus_client library not found. Install with: pip install prometheus-client", file=sys.stderr)
    sys.exit(1)

METRICS_FILE = os.environ.get('METRICS_FILE', '/var/lib/nimbus-benchmark-metrics/benchmark_metrics.prom')
LISTEN_HOST = os.environ.get('METRICS_HOST', '0.0.0.0')
LISTEN_PORT = int(os.environ.get('METRICS_PORT', '9091'))
REFRESH_INTERVAL = int(os.environ.get('REFRESH_INTERVAL', '10'))

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('nimbus-benchmark-exporter')


class NimbusBenchmarkCollector:
    """Prometheus collector for Nimbus benchmark metrics"""

    def __init__(self, metrics_file: str, refresh_interval: int):
        self.metrics_file = metrics_file
        self.refresh_interval = refresh_interval
        self.last_refresh = 0

        self.registry = CollectorRegistry()

        self.stage_success = Gauge(
            'nimbus_benchmark_stage_success',
            'Success status of benchmark stage',
            ['stage_name', 'benchmark_type'],
            registry=self.registry
        )

        self.stage_duration = Gauge(
            'nimbus_benchmark_stage_duration_seconds',
            'Duration of benchmark stage in seconds',
            ['stage_name', 'benchmark_type'],
            registry=self.registry
        )

        self.benchmark_info = Info(
            'nimbus_benchmark',
            'Benchmark metadata information',
            registry=self.registry
        )

        self.total_blocks = Gauge(
            'nimbus_benchmark_total_blocks',
            'Total number of blocks in benchmark',
            ['benchmark_type'],
            registry=self.registry
        )

        self.last_run_timestamp = Gauge(
            'nimbus_benchmark_last_run_timestamp',
            'Unix timestamp of last benchmark run',
            ['benchmark_type'],
            registry=self.registry
        )

        self.cgroup_cpu_usage = Gauge(
            'nimbus_benchmark_cgroup_cpu_usage_seconds',
            'CPU usage from cgroup',
            ['service'],
            registry=self.registry
        )

        self.cgroup_memory_bytes = Gauge(
            'nimbus_benchmark_cgroup_memory_bytes',
            'Memory usage from cgroup',
            ['service'],
            registry=self.registry
        )

        self.cgroup_memory_peak_bytes = Gauge(
            'nimbus_benchmark_cgroup_memory_peak_bytes',
            'Peak memory usage from cgroup',
            ['service'],
            registry=self.registry
        )

        self.cgroup_processes = Gauge(
            'nimbus_benchmark_cgroup_processes',
            'Number of processes from cgroup',
            ['service'],
            registry=self.registry
        )

        self.cgroup_io_read_bytes = Gauge(
            'nimbus_benchmark_cgroup_io_read_bytes',
            'IO read bytes from cgroup',
            ['service'],
            registry=self.registry
        )

        self.cgroup_io_write_bytes = Gauge(
            'nimbus_benchmark_cgroup_io_write_bytes',
            'IO write bytes from cgroup',
            ['service'],
            registry=self.registry
        )

        self.exporter_up = Gauge(
            'nimbus_benchmark_exporter_up',
            'Exporter health status',
            registry=self.registry
        )

        self.exporter_last_refresh = Gauge(
            'nimbus_benchmark_exporter_last_refresh_timestamp',
            'Last refresh timestamp',
            registry=self.registry
        )

    def should_refresh(self) -> bool:
        return time.time() - self.last_refresh > self.refresh_interval

    def parse_benchmark_metrics_file(self):
        """Parse the benchmark metrics file and update Prometheus metrics"""
        try:
            if not os.path.exists(self.metrics_file):
                return

            with open(self.metrics_file, 'r') as f:
                content = f.read()

            for line in content.strip().split('\n'):
                if not line or line.startswith('#'):
                    continue

                if '{' in line and '}' in line:
                    metric_part, value_part = line.rsplit(' ', 1)
                    metric_name = metric_part.split('{')[0]
                    labels_str = metric_part.split('{', 1)[1].rsplit('}', 1)[0]

                    labels = {}
                    if labels_str:
                        for label_pair in labels_str.split(','):
                            key, val = label_pair.split('=', 1)
                            labels[key.strip()] = val.strip().strip('"')

                    try:
                        value = float(value_part)
                    except ValueError:
                        continue

                    if metric_name == 'nimbus_benchmark_stage_success':
                        self.stage_success.labels(
                            stage_name=labels.get('stage_name', ''),
                            benchmark_type=labels.get('benchmark_type', '')
                        ).set(value)
                    elif metric_name == 'nimbus_benchmark_stage_duration_seconds':
                        self.stage_duration.labels(
                            stage_name=labels.get('stage_name', ''),
                            benchmark_type=labels.get('benchmark_type', '')
                        ).set(value)
                    elif metric_name == 'nimbus_benchmark_total_blocks':
                        self.total_blocks.labels(
                            benchmark_type=labels.get('benchmark_type', '')
                        ).set(value)
                    elif metric_name == 'nimbus_benchmark_last_run_timestamp':
                        self.last_run_timestamp.labels(
                            benchmark_type=labels.get('benchmark_type', '')
                        ).set(value)
                    elif metric_name == 'nimbus_benchmark_info':
                        self.benchmark_info.info(labels)

        except Exception as e:
            logger.warning(f"Failed to parse benchmark metrics file: {e}")

    def _read_cgroup_file(self, file_path: str) -> str:
        """Helper function to read cgroup files"""
        if not os.path.exists(file_path):
            return ""
        try:
            with open(file_path, 'r') as f:
                return f.read().strip()
        except Exception:
            return ""

    def collect_live_cgroup_metrics(self):
        """Collect live cgroup metrics and update Prometheus gauges"""
        services = []
        try:
            cgroup_base = "/sys/fs/cgroup/system.slice"
            if os.path.exists(cgroup_base):
                for entry in os.listdir(cgroup_base):
                    if (entry.startswith('nimbus-eth1-') and
                        'benchmark' in entry and
                        entry.endswith('.service')):
                        services.append(entry.replace('.service', ''))
        except Exception as e:
            logger.warning(f"Failed to discover services dynamically: {e}")

        # Fallback
        if not services:
            services = [
                'nimbus-eth1-mainnet-master-short-benchmark',
                'nimbus-eth1-mainnet-master-long-benchmark'
            ]

        for service in services:
            cgroup_path = f"/sys/fs/cgroup/system.slice/{service}.service"

            if not os.path.exists(cgroup_path):
                continue

            try:
                cpu_stat = self._read_cgroup_file(f"{cgroup_path}/cpu.stat")
                for line in cpu_stat.split('\n'):
                    if 'usage_usec' in line and line.strip():
                        cpu_usec = int(line.split()[1])
                        cpu_seconds = cpu_usec / 1000000.0
                        self.cgroup_cpu_usage.labels(service=service).set(cpu_seconds)

                mem_bytes = self._read_cgroup_file(f"{cgroup_path}/memory.current")
                if mem_bytes.isdigit():
                    self.cgroup_memory_bytes.labels(service=service).set(int(mem_bytes))

                mem_peak = self._read_cgroup_file(f"{cgroup_path}/memory.peak")
                if mem_peak.isdigit():
                    self.cgroup_memory_peak_bytes.labels(service=service).set(int(mem_peak))

                pids = self._read_cgroup_file(f"{cgroup_path}/pids.current")
                if pids.isdigit():
                    self.cgroup_processes.labels(service=service).set(int(pids))

                io_stat = self._read_cgroup_file(f"{cgroup_path}/io.stat")
                if io_stat:
                    total_read = 0
                    total_write = 0
                    for line in io_stat.split('\n'):
                        if 'rbytes=' in line:
                            match = re.search(r'rbytes=(\d+)', line)
                            if match:
                                total_read += int(match.group(1))
                        if 'wbytes=' in line:
                            match = re.search(r'wbytes=(\d+)', line)
                            if match:
                                total_write += int(match.group(1))

                    if total_read > 0:
                        self.cgroup_io_read_bytes.labels(service=service).set(total_read)
                    if total_write > 0:
                        self.cgroup_io_write_bytes.labels(service=service).set(total_write)

            except Exception as e:
                logger.warning(f"Failed to collect cgroup metrics for {service}: {e}")

    def refresh(self):
        """Refresh all metrics"""
        try:
            self.parse_benchmark_metrics_file()
            self.collect_live_cgroup_metrics()
            self.exporter_up.set(1)
            self.last_refresh = time.time()
            self.exporter_last_refresh.set(int(self.last_refresh))

            logger.info(f"Refreshed metrics from {self.metrics_file}")

        except Exception as e:
            logger.error(f"Failed to refresh metrics: {e}")

    def get_metrics(self) -> bytes:
        """Get metrics in Prometheus format"""
        if self.should_refresh():
            self.refresh()

        return generate_latest(self.registry)


class MetricsHandler(BaseHTTPRequestHandler):

    def __init__(self, *args, collector: NimbusBenchmarkCollector, **kwargs):
        self.collector = collector
        super().__init__(*args, **kwargs)

    def do_GET(self):
        if self.path == '/metrics':
            self.send_metrics()
        elif self.path == '/health':
            self.send_health()
        else:
            self.send_error(404, 'Not Found')

    def send_metrics(self):
        try:
            metrics_data = self.collector.get_metrics()

            self.send_response(200)
            self.send_header('Content-Type', CONTENT_TYPE_LATEST)
            self.end_headers()
            self.wfile.write(metrics_data)

        except Exception as e:
            logger.error(f"Error sending metrics: {e}")
            self.send_error(500, 'Internal Server Error')

    def send_health(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'OK\n')

    def log_message(self, format, *args):
        logger.debug(f"{self.client_address[0]} - {format % args}")


def main():
    collector = NimbusBenchmarkCollector(METRICS_FILE, REFRESH_INTERVAL)
    collector.refresh()

    handler = lambda *args, **kwargs: MetricsHandler(
        *args, collector=collector, **kwargs
    )

    httpd = HTTPServer((LISTEN_HOST, LISTEN_PORT), handler)

    logger.info(f"Starting Nimbus Benchmark metrics exporter on {LISTEN_HOST}:{LISTEN_PORT}")
    logger.info(f"Metrics endpoint: http://{LISTEN_HOST}:{LISTEN_PORT}/metrics")
    logger.info(f"Health endpoint: http://{LISTEN_HOST}:{LISTEN_PORT}/health")
    logger.info(f"Reading metrics from: {METRICS_FILE}")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down metrics exporter")
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
