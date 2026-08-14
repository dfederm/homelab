# NVIDIA power-limit tuning

`configure-nvidia-driver.sh` can persist one power limit across all NVIDIA GPUs
on a host:

```bash
NVIDIA_POWER_LIMIT_WATTS=250
```

The module writes the limit into `homelab-nvidia.service`, enables NVIDIA
persistence mode, applies the setting after the driver is ready and before
Proxmox guests start, and reads the effective limit back. An empty value removes
the cap from the unit and leaves each card at its firmware default.

Changing this value and running setup changes the live GPU limit when the NVIDIA
driver is already loaded. Treat that as an operator-approved production change,
not as a passive configuration check.

## Choosing a limit

Do not infer a limit from a card's TDP alone. The useful knee changes with the
model, serving engine, topology, request shape, cooling and other chassis load.
For two air-cooled RTX 3090s, public measurements support this bounded starting
matrix:

| Limit per card | What it tests |
|---:|---|
| 220 W | Low-power point for bandwidth-bound dual-card decode and MoE decode |
| 250 W | Balanced starting point for mixed decode and prefill-heavy work |
| 290 W | Upper point for single-card dense-model decode and unmeasured GPU workloads |

These are candidates, not universal defaults. Published measurements place a
dual-card tensor-parallel decode knee at or below 220 W/card, an RTX 3090
prefill-efficiency knee near 250 W, and a single-card dense decode knee near
290 W. Image generation and VLM serving do not have comparable power-cap data,
so include their real workflows before selecting a final value.

When a UPS protects the host, size against its watt rating and whole-system load,
not the PSU nameplate or GPU limits added together. A practical local policy is:

- sustained UPS load at or below 80%, or the configured warning threshold when
  it is lower;
- no observed sample above 90%, preserving a separate transient margin;
- no UPS overload, transfer, communication or battery alarms.

The 80% target follows UPS manufacturer sizing guidance. The 90% ceiling is an
operational guardrail, not a claim about the UPS's trip point.

## Approval-gated measurement matrix

Run the matrix only during an approved maintenance window. Each candidate
changes the live cap and each workload deliberately loads production hardware.
Start at the lowest cap and stop on any safety failure.

Test every candidate against the same model, prompt/request corpus, warmup and
run duration. After warmup, sample each scenario for at least 10 minutes. The
final candidate also needs a 30-minute worst-case concurrency soak; extend it if
GPU or drive temperatures have not stabilized. Keep the workload order fixed:

1. Current single-user chat and tool calls: measure time to first token,
   end-to-end latency and decode throughput.
2. Long-context or RAG prefill: use the largest credible prompt and record
   prefill throughput and time to first token.
3. Concurrent serving: use the expected household peak request count and record
   aggregate throughput, per-request p95 latency and errors.
4. Dual-card serving: exercise the intended tensor-parallel or split workload
   and check both cards for utilization and temperature asymmetry.
5. Future workloads that are close enough to deploy: VLM image input and one
   representative image-generation or editing job. If the software is not
   available, retain 290 W as an unvalidated upper candidate rather than
   guessing its performance at 250 W.
6. Heterogeneous two-card concurrency: overlap representative chat/tool or VLM
   requests on one card with image generation/editing on the other. Use this as
   the final candidate's 30-minute soak when that software is available.

For each scenario, use the best candidate that passed all safety checks as the
performance reference. A lower cap passes performance when:

- throughput is at least 90% of the reference;
- time to first token, end-to-end p95 latency and image-generation time are no
  more than 10% slower;
- concurrent requests complete without new errors, OOMs or queue starvation.

Safety takes precedence over performance:

- every 60-second rolling average of UPS load must stay at or below 80%, or
  `UPS_LOAD_WARNING_PERCENT` when it is lower;
- no UPS sample may exceed 90%;
- GPU core temperature must remain below 80 C;
- GPU memory-junction temperature must remain below 100 C;
- every drive must remain below the repository's 45 C smartd warning threshold;
- no NVIDIA Xid, PCIe, ZFS, SMART or thermal-throttling errors may appear.

The GPU and drive temperatures are conservative operating guardrails, not
vendor damage limits. Record the warmest GPU and drive rather than averaging
away the constrained device.

## Capture the baseline

Before applying a candidate, record the current limits and supported ranges:

```bash
nvidia-smi --query-gpu=index,name,power.limit,power.default_limit,power.min_limit,power.max_limit \
  --format=csv
nvidia-smi -q -d POWER,TEMPERATURE
systemctl cat homelab-nvidia.service
systemctl status --no-pager homelab-nvidia.service
```

Preflight every mandatory sensor before generating load. Memory-junction
temperature is not exposed by `nvidia-smi` on every GeForce/driver combination:

```bash
nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory \
  --format=csv,noheader,nounits
nvidia-smi \
  --query-gpu=index,clocks_event_reasons.sw_thermal_slowdown,clocks_event_reasons.hw_thermal_slowdown \
  --format=csv,noheader
```

If either card reports `N/A` for memory temperature, use a board-specific hwmon
sensor only after mapping its label to that card and confirming it changes
under a brief, non-sustained smoke load. If no trustworthy memory-junction
sensor is available, stop: the matrix cannot certify its thermal criterion.
Core temperature is not a substitute. The thermal-slowdown fields must also be
available; any `Active` sample during the matrix fails the candidate.

Use the configured NUT UPS name to record the whole-system baseline:

```bash
upsc "$NUT_UPS_NAME" ups.status
upsc "$NUT_UPS_NAME" ups.load
upsc "$NUT_UPS_NAME" battery.charge
upsc "$NUT_UPS_NAME" battery.runtime
```

During each run, sample both GPUs:

```bash
nvidia-smi \
  --query-gpu=timestamp,index,power.draw,power.limit,temperature.gpu,temperature.memory,utilization.gpu,clocks.sm,pstate,clocks_event_reasons.sw_thermal_slowdown,clocks_event_reasons.hw_thermal_slowdown \
  --format=csv -l 5
```

In another terminal, sample the UPS at the same cadence:

```bash
set -euo pipefail
UPS_LOG=$(mktemp)
UPS_SAMPLE_SECONDS=5
UPS_DURATION_SECONDS=600
UPS_SUSTAINED_LIMIT=$(
  awk -v configured="${UPS_LOAD_WARNING_PERCENT:-80}" '
    BEGIN {
      if (configured !~ /^[0-9]+([.][0-9]+)?$/) exit 1
      print (configured < 80 ? configured : 80)
    }
  '
)
UPS_END_SECONDS=$((SECONDS + UPS_DURATION_SECONDS))
UPS_LOAD_WINDOW=()

metric() {
  local key="$1"
  awk -v key="$key" 'index($0, key ": ") == 1 {
    print substr($0, length(key) + 3)
    exit
  }' <<< "$sample"
}

while [ "$SECONDS" -lt "$UPS_END_SECONDS" ]; do
  sleep "$UPS_SAMPLE_SECONDS"
  sample=$(upsc "$NUT_UPS_NAME") || {
    echo "ABORT: lost UPS telemetry" >&2
    exit 1
  }
  status=$(metric "ups.status")
  load=$(metric "ups.load")
  charge=$(metric "battery.charge")
  runtime=$(metric "battery.runtime")
  alarm=$(metric "ups.alarm")

  if [[ " $status " != *" OL "* ]] \
      || ! [[ "$load" =~ ^[0-9]+([.][0-9]+)?$ ]] \
      || ! [[ "$charge" =~ ^[0-9]+([.][0-9]+)?$ ]] \
      || ! [[ "$runtime" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ABORT: invalid or unsafe UPS telemetry" >&2
    exit 1
  fi

  for token in OB LB RB FSD OFF BYPASS OVER ALARM; do
    if [[ " $status " == *" $token "* ]]; then
      echo "ABORT: unhealthy UPS status '$status'" >&2
      exit 1
    fi
  done
  if [ -n "$alarm" ]; then
    echo "ABORT: UPS alarm '$alarm'" >&2
    exit 1
  fi

  awk -v sample_load="$load" \
    'BEGIN { exit (sample_load <= 90 ? 0 : 1) }' || {
    echo "ABORT: UPS load exceeded 90%" >&2
    exit 1
  }

  UPS_LOAD_WINDOW+=("$load")
  if [ "${#UPS_LOAD_WINDOW[@]}" -gt 12 ]; then
    UPS_LOAD_WINDOW=("${UPS_LOAD_WINDOW[@]:1}")
  fi
  if [ "${#UPS_LOAD_WINDOW[@]}" -eq 12 ]; then
    rolling_average=$(
      printf '%s\n' "${UPS_LOAD_WINDOW[@]}" |
        awk '{ sum += $1 } END { printf "%.6f", sum / NR }'
    )
    awk -v average="$rolling_average" -v limit="$UPS_SUSTAINED_LIMIT" \
      'BEGIN { exit (average <= limit ? 0 : 1) }' || {
      printf 'ABORT: 60-second UPS average %.1f%% exceeds %.1f%%\n' \
        "$rolling_average" "$UPS_SUSTAINED_LIMIT" >&2
      exit 1
    }
  fi

  printf '%s,%s,%s,%s,%s,%s\n' \
    "$(date --iso-8601=seconds)" "$status" "$load" "$charge" "$runtime" "$alarm" |
    tee -a "$UPS_LOG"
done

echo "UPS sample log: $UPS_LOG"
```

The workload operator must stop the workload and restore the prior GPU limits
if this monitor exits for any reason. After each run, calculate 60-second
rolling averages from the 5-second load samples; the command evaluates each
complete 12-sample window immediately. Any window above 80% aborts at that
sample rather than waiting for the run to finish, even if
`UPS_LOAD_WARNING_PERCENT` is higher. Set `UPS_DURATION_SECONDS=1800` for the
final 30-minute soak.

Record drive temperatures before, during and after the run with `smartctl`. Use
stable serial numbers or `/dev/disk/by-id` paths when comparing drives across
reboots; `/dev/sdX` ordering is not stable.

Record the kernel-log start time before each candidate:

```bash
RUN_START=$(date --iso-8601=seconds)
```

After stopping the workload, review all warnings since that timestamp and fail
the candidate on any NVIDIA Xid, PCIe/AER, thermal, ZFS or SMART event:

```bash
journalctl -k --since "$RUN_START" --no-pager
journalctl -u smartd --since "$RUN_START" --no-pager
zpool status -x "$ZFS_POOL"
```

Do not treat an unavailable command, missing journal, stale sensor or parse
failure as a clean result. Stop the matrix and fix the measurement path.
The GPU CSV must show both thermal-slowdown fields as `Not Active` for every
sample; `Active`, `N/A`, a missing column or a stopped sampler fails the run.

## Apply a temporary candidate

Run the candidate matrix from a root shell so the original per-card limits stay
in shell memory. This path is temporary; it does not edit the external env or
the systemd unit:

```bash
set -euo pipefail

ORIGINAL_LIMITS=$(
  nvidia-smi --query-gpu=index,power.limit --format=csv,noheader,nounits |
    tr -d ' '
)

restore_gpu_limits() {
  local index watts actual
  local failed=0
  while IFS=, read -r index watts; do
    [ -n "$index" ] || continue
    watts=${watts%%.*}
    if ! nvidia-smi -i "$index" -pl "$watts"; then
      failed=1
      continue
    fi
    if ! actual=$(
      nvidia-smi -i "$index" --query-gpu=power.limit \
        --format=csv,noheader,nounits
    ); then
      failed=1
      continue
    fi
    [ "${actual%%.*}" = "$watts" ] || failed=1
  done <<< "$ORIGINAL_LIMITS"
  return "$failed"
}

apply_candidate() {
  local candidate="$1"
  local index actual
  while IFS= read -r index; do
    [ -n "$index" ] || continue
    nvidia-smi -i "$index" -pl "$candidate"
    actual=$(
      nvidia-smi -i "$index" --query-gpu=power.limit \
        --format=csv,noheader,nounits
    )
    [ "${actual%%.*}" = "$candidate" ] || return 1
  done < <(
    nvidia-smi --query-gpu=index --format=csv,noheader,nounits
  )
}

trap 'restore_gpu_limits' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CANDIDATE_WATTS=220
apply_candidate "$CANDIDATE_WATTS" || exit 1
nvidia-smi --query-gpu=index,power.limit --format=csv
```

Run one candidate's workloads while that root shell remains open. Stop the
workload immediately on any safety or telemetry failure, then run:

```bash
restore_gpu_limits
trap - EXIT INT TERM
nvidia-smi --query-gpu=index,power.limit,power.default_limit --format=csv
```

Start a fresh root shell for the next candidate and change
`CANDIDATE_WATTS`. If the shell exits unexpectedly, the trap attempts the same
restore. Do not proceed unless every card's readback matches either the
candidate before load or its recorded original limit after restore.

## Apply and verify the selected limit

After the matrix is reviewed, set the selected value in the GPU host's external
machine env file and run setup on that host:

```bash
bash scripts/setup/setup.sh
```

The setup output must report the expected limit for every GPU. Verify directly:

```bash
nvidia-smi --query-gpu=index,power.limit,power.default_limit --format=csv
systemctl is-enabled homelab-nvidia.service
systemctl is-active homelab-nvidia.service
systemctl cat homelab-nvidia.service
```

At the next approved reboot, repeat those checks before starting a sustained
workload. Run setup a second time and confirm it makes no unit change or
restart.

## Roll back

Set `NVIDIA_POWER_LIMIT_WATTS` to the last accepted value and rerun setup. To
return to firmware defaults, clear the value and rerun setup:

```bash
NVIDIA_POWER_LIMIT_WATTS=
```

Clearing the value removes the `nvidia-smi -pl` command from
`homelab-nvidia.service`; it does not immediately reset a limit already active
in the running driver. Reboot during an approved window, or explicitly set each
card back to the `power.default_limit` recorded in the baseline. Verify the
readback after either path.

## References

- [NVIDIA System Management Interface](https://docs.nvidia.com/deploy/nvidia-smi/index.html)
- [club-3090 RTX 3090 power measurements](https://github.com/noonghunna/club-3090/blob/master/docs/HARDWARE.md#power)
- [Schneider Electric UPS sizing guidance](https://www.se.com/us/en/faqs/FAQ000268376/)
