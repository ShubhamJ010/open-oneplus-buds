---
name: perf-testing-buds
description: Profile, benchmark, and audit live performance of deployed Buds app, measuring CPU, battery drain, energy impact, memory footprint, leaks, context switch churn, and live unified logs. Use when auditing Buds app performance, checking CPU or battery drain, inspecting live logs, profiling memory or leaks, or diagnosing background resource loops without running unit or integration tests.
---

# Performance Testing Buds App (`perf-testing-buds`)

Audit live runtime performance, energy impact, and unified logging of running Buds macOS application. Focuses strictly on live process profiling and runtime loop diagnostics, excluding unit or integration tests.

## Quick Start

Run automated diagnostic snapshot:

```bash
# Audit Buds process (by name or PID)
./.agents/skills/perf-testing-buds/scripts/audit_perf.sh Buds [SampleCount]

# Example: 3 samples
./.agents/skills/perf-testing-buds/scripts/audit_perf.sh Buds 3
```

## Core Diagnostic Workflow

### 1. Identify Process & Deployment Path

```bash
pgrep -fl Buds
ps -p <PID> -o pid,ppid,user,%cpu,%mem,vsz,rss,stat,time,command
```

Verify binary path is deployed instance (`~/Applications/Buds.app` or `/Applications/Buds.app`).

### 2. Measure CPU & Battery / Energy Impact

Sample active threads, context switches, and power score over interval:

```bash
top -l 5 -s 1 -pid <PID> -stats pid,command,cpu,power,csw,threads,mem,idlew
```

#### Evaluation Thresholds for Buds (Menu Bar Background App):
- **%CPU:** Idle target `< 1.0%`. Sustained `> 5%` indicates busy waiting, unthrottled timers, or infinite reconnects.
- **POWER Score:** Target `< 1.0`. Sustained `> 10.0` represents severe battery drain.
- **Context Switches (CSW):** Growth should be `< 50/sec`. Delta `> 500/sec` indicates timer hammer or XPC churn.
- **Idle Wakeups (IDLEW):** Target `< 10/sec`. High IDLEW indicates non-push polling loops.

### 3. Memory & Leak Profiling

Inspect memory footprint and heap integrity:

```bash
# Summary footprint (check Physical footprint vs resident)
vmmap -summary <PID>

# Heap leak audit
leaks <PID> 2>&1 | grep -E "leaks for|total leaked bytes"
```

### 4. Call Stack & Thread Sampling

Pinpoint active functions during high CPU:

```bash
sample <PID> 1 -file /tmp/buds_sample.txt
grep -A 25 "Call graph:" /tmp/buds_sample.txt
```

### 5. Live Unified Log Diagnostics

Check live subsystem `local.nordbuds` or process logs for hot loops, repeated XPC calls, or connection storms:

```bash
# Query recent logs with debug and info levels
/usr/bin/log show --predicate 'process == "Buds"' --info --debug --last 2m --style compact

# Stream live logs in real time
/usr/bin/log stream --predicate 'process == "Buds"' --info --style compact
```

#### Common Root Causes to Check:
1. **Periodic Timers:** Hardcoded `Timer.scheduledTimer` or `Task.sleep` loops polling system state instead of push notifications / event callbacks.
2. **Connection Thrash:** Bluetooth / network callbacks triggering reconnects while a connection or discovery is already in-flight.
3. **IPC / XPC Hammer:** Private framework or daemon requests (e.g., MediaRemote `playbackState`) blasting queries every second.
4. **Executor Assertion Failures:** Un-isolated C/Obj-C callbacks hitting Swift actor checks and throwing exceptions or loops.

### 6. Verify Post-Fix Baseline

Re-sample using `audit_perf.sh` to confirm CPU returns to `< 1%`, power score drops to `< 1`, and logs are quiet while idle.
