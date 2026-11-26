# STRAXIOM: Feasibility Checks

Each check states its question, conditions, metrics, pass criteria and tripwires **before** it runs (brief v1.3 §14.1, operating rule 6). The Results section stays empty until the run happens. Numbers are recorded as measured, never estimated.

Lines marked `TODO(engineer)` are decisions the engineer makes and must be able to defend. Fill all of them before the load run.

Tunable values (thresholds, rates, intervals) live in one committed file per check and are referred to here by `NAME`. Secrets never go in that file; they stay in `.env` (D-022).

## Check 3: stack sizing (B1)

Decisions: D-009 (VM size under test), D-014 (swap watch), D-005 / D-003 (disk tripwire), D-023 (scope), D-024 (Wazuh pin), D-032 (ingest-latency markers).

Parameters: `eval/feasibility/check3/params.env`. Record the commit of that file used for the run under Conditions.

### Question

Can the stack VM (4608 MB, 3 vCPUs, D-009) run the Wazuh manager, OpenObserve, Vector and Postgres next to one 2048 MB victim, on this host, with no swap, no OOM kills and no disk stalls?

Secondary question (pending decision "Sysmon path to OpenObserve"): what does the Wazuh-agent path actually deliver for Sysmon for Linux events? See Notes.

### Setup

- Stack VM: Ubuntu 24.04.4, kernel 6.8.0-147-generic, 4608 MB, 3 vCPUs, host I/O cache on (D-006), host-only NIC `192.168.100.10`.
- Compose services: Wazuh manager, OpenObserve, Vector, Postgres. No Wazuh indexer or dashboard. Manager vulnerability detection disabled.
- Images: exact tags and digests from `lab/versions.yml` at commit `9e1588e`.
- Exposure: OpenObserve publishes only `192.168.100.10:5080`. Wazuh publishes only `192.168.100.10:1514` and `192.168.100.10:1515`. Postgres, Vector and the Wazuh API (55000) publish nothing.
- Victim: manual clone of the baseline, 2048 MB, `192.168.100.21`, with Wazuh agent 4.14.10, auditd and Sysmon for Linux 1.5.3 (D-016, D-017), enrolled to the manager.
- Isolation: NAT removed from both VMs before the run. `ip route get 192.168.100.1` shows `dev enp0s8` on both.
- Time: chrony on both VMs, installed while NAT is still up. The stack serves time to the lab network and the victim syncs to it. Only the clocks relative to each other matter, not real-world time. Before the run, `chronyc tracking` on the victim must show an offset under `CLOCK_MAX_OFFSET_MS`.

### Conditions recorded at run time

- Date and start time:
- Host: available RAM at start, other applications running:
- `lab/versions.yml` commit:
- `eval/feasibility/check3/params.env` commit:
- OpenObserve memory cap, if any (it distorts the result, §14.1):
- Victim VM settings, if different from Setup:

### Procedure

1. Start the stack with `docker compose up -d` and confirm the agent shows as active on the manager.
2. Warm-up: `WARMUP_MIN` minutes. Measure nothing during image pulls or first indexing.
3. Load: `LOAD_MIN` minutes.
   - Failed SSH logins against the victim from the stack, one at a time in a loop with `SSH_FAIL_SLEEP_S` between attempts (at 1 s, about 900 over 15 minutes):
     `ssh -o BatchMode=yes -o PubkeyAuthentication=no -o ConnectTimeout=$SSH_CONNECT_TIMEOUT_S $SSH_FAIL_USER@$VICTIM_IP true; sleep $SSH_FAIL_SLEEP_S`.
     The fixed username `SSH_FAIL_USER` makes the events countable. Record the actual number of attempts, since each ssh call adds time and the real rate comes out below 1/s.
   - Light normal activity on the victim, a scripted loop every `ACTIVITY_INTERVAL_S` seconds (at 10 s, about 90 iterations), the same every run. Each iteration:
     - Sysmon Event 1: `ls /etc`, `ps aux`, `cat /etc/os-release` (output discarded).
     - Sysmon Event 11: create and then delete `${ACTIVITY_TMP_PREFIX}<n>`. `/tmp/` is an included path in the Sysmon config.
     - Sysmon Event 3: `curl -s http://$STACK_IP:$OPENOBSERVE_PORT/healthz`.
     - Committed scripts: `eval/feasibility/check3/activity.sh` (victim) and `eval/feasibility/check3/ssh-fail.sh` (stack).
4. Read the metrics at about the 10-minute mark of the load.
5. Ingest latency: write `MARKER_COUNT` (at least 5) unique markers on the victim, spaced `MARKER_SPACING_S` apart, starting at minute 1 of the load. Spreading them across the whole window is meant to prevent a false pass: markers bunched in a quiet minute would miss a disk that backs up later in the run. For each one, record the time it was written and the time it became searchable in OpenObserve. (Amended 2026-11-15 before any Check 3 data, D-032: see Notes.)
6. Snapshot the stack VM after the run.

### Metrics

| Metric | Where | Command or method | Recorded as |
| --- | --- | --- | --- |
| Guest RAM | stack, victim | `free -m` | used, available (MB) |
| Per-container memory and CPU | stack | `docker stats --no-stream` | per service |
| Swap activity | stack, victim | `vmstat $SAMPLE_INTERVAL_S` during load | `si`, `so` (peak and typical) |
| Disk | stack | `iostat -x $SAMPLE_INTERVAL_S` during load | `w_await`, `r_await` (ms), `%util` |
| OOM kills | stack, victim | `journalctl -k \| grep -i oom` or `dmesg` | count |
| Host RAM and pagefile | Windows host | `Get-Counter` every `SAMPLE_INTERVAL_S` over the load window, exported to CSV: `\Memory\Available MBytes`, `\Memory\Pages Input/sec`, `\Paging File(_Total)\% Usage` | min available MB, Pages Input/sec, CSV committed as evidence |
| Sysmon events per ID | victim to OpenObserve | Victim source: `sudo journalctl -t sysmon --since "<T0>" --until "<T0+15m>" -o cat \| grep -o '<EventID>[0-9]*</EventID>' \| sort \| uniq -c`. Sink (`wazuh_alerts`): `SELECT count(*) FROM "wazuh_alerts" WHERE str_match(full_log, 'Sysmon') OR str_match(location, 'sysmon')`. Pre-registered hypothesis: sink count is 0 because Wazuh 4.14.10 has no Sysmon-for-Linux decoder | count per event ID (source) and total (sink) |
| Ingest latency | victim to OpenObserve | marker write time vs. time searchable in `wazuh_alerts` (`data_srcuser = 'marker-<n>'`, polled every `MARKER_POLL_INTERVAL_S` = 0.5 s; upper bound with ~0.6 s resolution) | median and max over at least 5 markers |

### Pass criteria (brief v1.3 §14.1)

- Host `\Memory\Available MBytes` stays above `HOST_MIN_AVAILABLE_MB` in every sample, with no sustained pagefile activity: `\Paging File(_Total)\% Usage` rises by at most `HOST_PAGEFILE_MAX_RISE_PCT` percentage points over the load window AND median `\Memory\Pages Input/sec` during load stays at or below `HOST_PAGES_INPUT_MAX_MEDIAN` (amended 2026-11-26 before any Check 3 data; see Notes).
- `vmstat` `si` and `so` near 0 on both guests. "Near 0" means: in the load window, `si` and `so` are 0 in every sample except at most `SWAP_MAX_NONZERO_SAMPLES` isolated non-zero sample(s) per guest.
- No OOM kills in either guest.

### Tripwires

- Ingest latency max above `LATENCY_MAX_S` seconds, or `iostat` `w_await` above `DISK_W_AWAIT_MAX_MS` ms for `DISK_W_AWAIT_CONSECUTIVE` consecutive samples on the stack VM's data disk. Single spikes do not count. Baseline: D-005 fsync p99 about 6 ms. Either one means the D-005 disk tripwire fired, so the NEM vs. native comparison reopens (D-003).

### Outcomes (brief v1.3 §14.1)

| Outcome | Plan impact |
| --- | --- |
| Pass | Sizing holds. Log the final stack size (updates D-009), then move on to Vagrant |
| Swap or OOM | Stack to about 5.5 GB and victim to 1.5 GB, then cut services, or move the stack to the Mac |
| Tripwire | Reopen NEM vs. native with this workload (D-003) |

### Time-box (operating rule 10)

- First budget: one working day, stopping at hour 4 if not ingesting. Started about 2026-11-09 (start time not recorded). Exceeded, mainly because of the DNS failure on `enp0s3` (brief v1.4 §14.1).
- Second attempt: 2026-11-10 23:53 to 2026-11-11 03:53 (UTC+7). Lapsed unused: the window went to pre-registration (D-023 to D-026), and no ingest work happened in it.
- Third attempt: 2-hour budget. The engineer started the clock at 2026-11-11 12:00 (UTC+7), but the Vector logs show stack work already under way at 11:42 (container recreated at 04:42 UTC). The marker was searchable in OpenObserve at about 12:08 (written 05:07:46 UTC, picked up by Vector at 05:07:48 UTC), so it passed within budget whichever start time is used.
- Third attempt causes: (1) the root Docker daemon created the missing bind-mount folder `./testdata` as root, so the user's marker write failed (fixed with `chown` and a tracked `testdata/.gitkeep`, see D-027); (2) a startup race: `depends_on` orders container start, not readiness, so Vector's first healthcheck got "Connection refused" while OpenObserve was booting. Harmless; data flowed once OpenObserve was up. Left as is for now.
- Fourth attempt: 2-working-day Phase 1 budget. Fresh victim VM (`straxiom-victim-linux-1`), Sysmon 1.5.3, Wazuh agent 4.14.10, Chrony (< 1 ms offset), Vector `alerts.json` pipeline, and `marker-0` live dry run completed on 2026-11-25/26 (`marker-0` arrived in `wazuh_alerts` at 2026-11-26 07:03Z).

### Definition of done

- Every TODO above filled before the load run.
- All metrics recorded with their conditions.
- A one-line verdict: pass, swap/OOM, or tripwire.
- A decision-log row for the final stack size (updates D-009).
- A stack VM snapshot taken after the run.
- The `marker-0` dry run arrived in `wazuh_alerts` before the load run (verified 2026-11-26: `rule_id = "5710"`, `data_srcuser = "marker-0"`, `"total": 1`).

### Notes

- **Sysmon for Linux and Wazuh (checked 2026-11-10 against the v4.14.10 ruleset).** `0330-sysmon_rules.xml` matches only `Microsoft-Windows-Sysmon/Operational`, so it covers Windows Sysmon only. No decoder file with "sysmon" or "linux" in its name showed up in the `ruleset/decoders` listing. Treat that as **unverified**, because the listing was read through a summarizer. If it holds, Sysmon for Linux events reach the manager without decoding, and they only appear in `alerts.json` when a rule fires. Raw events would need `logall_json` (writing `archives.json`), which adds disk writes to a flush-bound disk (D-005).
- **Vector checkpoints (found 2026-11-11, fixed and verified 2026-11-12).** The Vector image declares no `VOLUME`, so file-source checkpoints lived in the container's writable layer. The 2026-11-11 06:07Z recreate re-shipped `smoke.log` from the beginning (`read_from: beginning` applies whenever no checkpoint exists), and markers written before it had `COUNT = 2` in OpenObserve. Fix: named volume `vectordata` at `/var/lib/vector`, with `data_dir` set explicitly in `pipeline/vector.yaml`. Verified: after `--force-recreate`, marker counts were unchanged and a new marker arrived once. Checkpoint `position` was 104, matching 4 lines × 26 bytes. **Run rules:** let Vector start once with the volume before the run, so the first start's full re-read happens outside the measurement; never set `ignore_checkpoints` during a run; `docker compose down -v` deletes both the checkpoints and OpenObserve's data.
- **Wazuh vulnerability detection filled the stack disk (2026-11-12, before the run).** With the image's default `ossec.conf`, the vulnerability scanner starts at first boot. It unpacks `/var/ossec/tmp/vd_1.0.0_vd_4.13.0.tar.xz` (483 MB, shipped inside the image) into the container's writable layer. The unpacked file reached 10.59 GB in about 8 minutes, then failed with `Write failed` when `/` hit 100% (25 GB disk, D-009). Its full size is unknown. A `.env` saved while the disk was full was left at 0 bytes, and then re-created with mode 664. Also seen at startup: indexer-connector retries, Filebeat retrying `wazuh.indexer`, and SCA and rootcheck scans of the manager's own container.
- **Amendment 2026-11-13, before any Check 3 data (D-031).** Setup said "Manager vulnerability detection disabled." The manager now runs agent-facing functions only. Vulnerability detection, the indexer connector, syscollector, SCA, rootcheck, syscheck and the manager's own `localfile` entries are off. Reason: the vulnerability scanner filled the disk on first start, and the other modules scan the manager container itself, not the victims.
- **Amendment 2026-11-15, before any Check 3 data (D-032).** Step 5 said markers are "written on the victim". Wazuh writes only rule matches to `alerts.json`, so a marker line written to a file on the victim would never reach OpenObserve. Each marker is now a failed SSH login from the stack with a unique username, `marker-<n>` (n = 1 to `MARKER_COUNT`), which the stock sshd "Invalid user" rule turns into an alert (rule ID **unverified**, confirmed by the dry run). Write time is the start of the ssh call on the stack. Searchable time is when a query for `marker-<n>` in the `wazuh_alerts` stream first returns it. Both times come from the stack clock. The earlier stack-side marker test (`/testdata`) covered only Vector → OpenObserve. Pre-run check: one dry run with `marker-0` must appear in OpenObserve before the load run.
- **Amendment 2026-11-26, before any Check 3 data (dry run + marker query).** The `marker-0` dry run confirmed Wazuh rule `5710` (level 5) and OpenObserve flattened fields `rule_id = "5710"`, `data_srcuser = "marker-0"`, and `full_log`, with `"total"` in the `_search` response envelope. Under load (`ssh-fail.sh`), Wazuh escalates repeated failures from the same IP to rules `5712` or `40111`, so the marker tool queries by `data_srcuser = 'marker-<n>'` (or `str_match(full_log, 'marker-<n>')` for `n <= 9`) rather than `rule_id`. Polling every `MARKER_POLL_INTERVAL_S` (0.5 s) makes each recorded latency an upper bound with ~0.6 s resolution.
- **Amendment 2026-11-26, before any Check 3 data ("pagefile flat").** `\Memory\Pages Input/sec` also counts normal memory-mapped file reads on Windows (idle host checks showed 0 to 3.55/s), so strict zero is unmeasurable. "No sustained pagefile activity" is pre-registered as `\Paging File(_Total)\% Usage` rising by at most `HOST_PAGEFILE_MAX_RISE_PCT` (2.0 percentage points) over the load window AND median `\Memory\Pages Input/sec` during load staying at or below `HOST_PAGES_INPUT_MAX_MEDIAN` (20/s).

### Results

(Empty until the run.)
