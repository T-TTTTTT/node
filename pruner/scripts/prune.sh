#!/bin/bash
DATA_PATH="/home/hluser/hl/data"

# Folders to exclude from pruning
# Example: EXCLUDES=("visor_child_stderr" "rate_limited_ips" "node_logs")
EXCLUDES=("visor_child_stderr")

# Log startup for debugging
echo "$(date): Prune script started" >> /proc/1/fd/1

# Check if data directory exists
if [ ! -d "$DATA_PATH" ]; then
    echo "$(date): Error: Data directory $DATA_PATH does not exist." >> /proc/1/fd/1
    exit 1
fi

# Get current disk usage percentage
DISK_USAGE=$(df "$DATA_PATH" | awk 'NR==2 {gsub("%",""); print $5}')
echo "$(date): Current disk usage: ${DISK_USAGE}%" >> /proc/1/fd/1

# Dynamic retention based on disk usage
if [ "$DISK_USAGE" -ge 90 ]; then
    # Emergency mode: keep only 1 hour
    MINUTES=60
    echo "$(date): EMERGENCY MODE - Disk usage at ${DISK_USAGE}%, pruning to 1 hour retention" >> /proc/1/fd/1
elif [ "$DISK_USAGE" -ge 80 ]; then
    # High usage: keep only 6 hours
    MINUTES=360
    echo "$(date): HIGH USAGE - Disk usage at ${DISK_USAGE}%, pruning to 6 hours retention" >> /proc/1/fd/1
elif [ "$DISK_USAGE" -ge 70 ]; then
    # Medium usage: keep 12 hours
    MINUTES=720
    echo "$(date): MEDIUM USAGE - Disk usage at ${DISK_USAGE}%, pruning to 12 hours retention" >> /proc/1/fd/1
elif [ "$DISK_USAGE" -ge 60 ]; then
    # Normal usage: keep 24 hours
    MINUTES=1440
    echo "$(date): NORMAL USAGE - Disk usage at ${DISK_USAGE}%, pruning to 24 hours retention" >> /proc/1/fd/1
else
    # Low usage: keep full 36 hours
    MINUTES=2160
    echo "$(date): LOW USAGE - Disk usage at ${DISK_USAGE}%, keeping full 36 hours retention" >> /proc/1/fd/1
fi

echo "$(date): Starting pruning process at $(date)" >> /proc/1/fd/1 
# Get directory size before pruning
size_before=$(du -sh "$DATA_PATH" | cut -f1)
files_before=$(find "$DATA_PATH" -type f | wc -l)
echo "$(date): Size before pruning: $size_before with $files_before files" >> /proc/1/fd/1 

# Build the -prune arguments for excluding directories
PRUNE_ARGS=()
for dir in "${EXCLUDES[@]}"; do
    PRUNE_ARGS+=(-path "*/$dir" -prune -o)
done

# First, prune node_order_statuses_by_block/hourly/ with special retention
if [ -d "$DATA_PATH/node_order_statuses_by_block/hourly" ]; then
    # Use more aggressive pruning for hourly stats during high disk usage
    if [ "$DISK_USAGE" -ge 80 ]; then
        HOURLY_MINUTES=180  # 3 hours during high usage
    else
        HOURLY_MINUTES=360  # 6 hours normally
    fi
    echo "$(date): Pruning node_order_statuses_by_block/hourly/ (${HOURLY_MINUTES} minute retention)" >> /proc/1/fd/1
    find "$DATA_PATH/node_order_statuses_by_block/hourly" -type f -mmin +$HOURLY_MINUTES -exec rm {} +
fi

# Then prune everything else with standard retention, excluding the already-pruned directory
find "$DATA_PATH" -mindepth 1 "${PRUNE_ARGS[@]}" \
    -path "*/node_order_statuses_by_block/hourly" -prune -o \
    -type f -mmin +$MINUTES -exec rm {} +

# Get directory size after pruning
size_after=$(du -sh "$DATA_PATH" | cut -f1)
files_after=$(find "$DATA_PATH" -type f | wc -l)
disk_after=$(df "$DATA_PATH" | awk 'NR==2 {gsub("%",""); print $5}')

echo "$(date): Size after pruning: $size_after with $files_after files" >> /proc/1/fd/1 
echo "$(date): Disk usage after pruning: ${disk_after}%" >> /proc/1/fd/1
echo "$(date): Pruning completed. Reduced from $size_before to $size_after ($(($files_before - $files_after)) files removed)." >> /proc/1/fd/1