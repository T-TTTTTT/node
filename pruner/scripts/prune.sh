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

# Delete data older than 1 hour = 60 minutes (default)
MINUTES=60

# First, prune node_order_statuses_by_block/hourly/ with 15 minute retention
if [ -d "$DATA_PATH/node_order_statuses_by_block/hourly" ]; then
    echo "$(date): Pruning node_order_statuses_by_block/hourly/ (6 hour retention)" >> /proc/1/fd/1
    find "$DATA_PATH/node_order_statuses_by_block/hourly" -type f -mmin +360 -exec rm {} +
fi

# Then prune everything else with standard retention, excluding the already-pruned directory
find "$DATA_PATH" -mindepth 1 "${PRUNE_ARGS[@]}" \
    -path "*/node_order_statuses_by_block/hourly" -prune -o \
    -type f -mmin +$MINUTES -exec rm {} +

# Get directory size after pruning
size_after=$(du -sh "$DATA_PATH" | cut -f1)
files_after=$(find "$DATA_PATH" -type f | wc -l)
echo "$(date): Size after pruning: $size_after with $files_after files" >> /proc/1/fd/1 echo "$(date): Pruning completed. Reduced from $size_before to $size_after ($(($files_before - $files_after)) files removed)." >> /proc/1/fd/1 