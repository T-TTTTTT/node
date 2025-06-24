# Hyperliquid Node Performance Optimization Guide

## Overview

This guide describes the performance optimizations available for running a Hyperliquid node with minimal latency.

## Standard Configuration

The default `docker-compose.yml` includes basic optimizations:
- Host networking mode for reduced network overhead
- Bind mounts for better I/O performance
- Increased file descriptor limits
- Memory locking to prevent swapping
- Optimized logging settings

## Production Configuration

For ultra-low latency requirements, use `docker-compose.prod.yml`:

```bash
docker compose -f docker-compose.prod.yml up -d
```

Key features:
- **tmpfs mount** for order status files (in-memory storage)
- **Host PID/IPC namespaces** for direct system access
- **CPU pinning** to cores 0-7
- **Privileged mode** for kernel-level optimizations
- **Real-time priority** settings
- **Disabled logging** for maximum performance
- **Network tuning** via sysctls

## Host System Optimization

Run the optimization script before starting the node:

```bash
sudo ./optimize-host.sh
```

This script applies:
- CPU governor set to "performance" mode
- Network stack optimizations
- File descriptor limit increases
- Transparent Huge Pages disabled
- Low-latency TCP settings

## Orderbook Service Integration

For best performance, run the orderbook service directly on the host (not in Docker):

1. The node writes order status files to `./hl-data/data/node_order_statuses/`
2. The orderbook service monitors this directory directly
3. No Docker exec or network overhead

## Performance Metrics

Expected latencies with optimizations:
- File write to disk: < 1ms
- File detection (inotify): < 100μs
- Order parsing: < 50μs
- Total end-to-end: < 2ms

## Monitoring

Monitor performance with:
```bash
# CPU usage by core
mpstat -P ALL 1

# Network latency
ping -i 0.2 <gossip-peer-ip>

# File system latency
ioping -c 10 hl-data/

# Docker stats
docker stats
```

## Troubleshooting

If you experience high latency:

1. Check CPU throttling:
   ```bash
   cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
   ```

2. Verify network settings:
   ```bash
   sysctl net.core.rmem_max net.core.wmem_max
   ```

3. Monitor order file growth:
   ```bash
   watch -n 1 'ls -la hl-data/data/node_order_statuses/hourly/*/*'
   ```

## Security Note

The production configuration uses privileged mode and host namespaces. Only use in trusted environments.