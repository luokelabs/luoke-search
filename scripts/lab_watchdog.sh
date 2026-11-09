#!/bin/sh
# Watches a lab run (scripts/lab_hub.sh): every 5 s reads the kernel's memory pressure, and at critical stops the lab
# hub and every PID listed in <pid file> (the indexing or eval run), so the Mac's own apps aren't squeezed. Every 30 s
# it logs the embedding worker's memory (phys_footprint, what the kernel charges it; RSS misses Metal buffers).
#
#   sh scripts/lab_watchdog.sh <lab hub PID> <pid file> <log file>
# Ends by itself when the lab hub is gone.
hub=${1:?usage: lab_watchdog.sh <hub pid> <pid file> <log file>}
pids=${2:?}
log=${3:?}
tick=0
# Only a process still running our code is stopped: a PID in the file may be left over and reused by now.
ours() { ps -o command= -p "$1" 2>/dev/null | grep -qE 'luoke-search|luoke_core'; }
stop() { for pid in "$hub" $(cat "$pids" 2>/dev/null); do ours "$pid" && kill "-$1" "$pid" 2>/dev/null; done; }
while kill -0 "$hub" 2>/dev/null; do
  level=$(sysctl -n kern.memorystatus_vm_pressure_level)
  if [ "$level" -ge 4 ]; then
    echo "$(date '+%H:%M:%S') memory pressure critical: stopping the lab hub and the run" >> "$log"
    stop TERM
    sleep 5
    stop KILL
    exit 1
  fi
  if [ $((tick % 6)) -eq 0 ]; then
    worker=$(pgrep -P "$hub" -f embed_worker | head -1)
    if [ -n "$worker" ]; then
      footprint=$(footprint "$worker" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}')
      rss=$(ps -o rss= -p "$worker" | tr -d ' ')
      echo "$(date '+%H:%M:%S') pressure=$level worker=$worker phys_footprint=$footprint rss_kb=$rss" >> "$log"
    else
      echo "$(date '+%H:%M:%S') pressure=$level worker=none" >> "$log"
    fi
  fi
  tick=$((tick + 1))
  sleep 5
done
