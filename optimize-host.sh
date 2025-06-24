#!/bin/bash
# Host system optimizations for low-latency Hyperliquid node operation

set -e

echo "Applying host system optimizations for Hyperliquid node..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

# CPU Performance
echo "Setting CPU governor to performance..."
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > $cpu 2>/dev/null || true
done

# Disable CPU frequency scaling
echo "Disabling CPU frequency scaling..."
systemctl stop ondemand 2>/dev/null || true
systemctl disable ondemand 2>/dev/null || true

# Network optimizations
echo "Applying network optimizations..."
cat >> /etc/sysctl.conf <<EOF

# Hyperliquid Node Network Optimizations
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_congestion_control = cubic
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_no_metrics_save = 1
net.core.busy_poll = 50
net.core.busy_read = 50
EOF

# Apply sysctl settings
sysctl -p

# File system optimizations
echo "Applying filesystem optimizations..."
# Increase file descriptor limits
cat >> /etc/security/limits.conf <<EOF

# Hyperliquid Node Limits
* soft nofile 1048576
* hard nofile 1048576
* soft memlock unlimited
* hard memlock unlimited
EOF

# Disable transparent huge pages
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Create systemd drop-in for Docker
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/override.conf <<EOF
[Service]
LimitNOFILE=1048576
LimitMEMLOCK=infinity
EOF

# Reload systemd
systemctl daemon-reload

# Create hl-data directory with optimal permissions
mkdir -p hl-data
chown -R 10000:10000 hl-data

echo "Host optimizations complete!"
echo "Please reboot the system for all changes to take effect."
echo ""
echo "After reboot, run the node with:"
echo "  docker compose -f docker-compose.prod.yml up -d"