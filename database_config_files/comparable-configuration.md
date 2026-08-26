# Comparable configuration: MariaDB vs. PostgreSQL

Analysis behind the four `*_comparable_<vcpu>vcpu_<ram>gb.*` config files:

| File | Engine | Sized for |
|---|---|---|
| `mariadb/mariadb_comparable_4vcpu_16gb.cnf` | MariaDB | 4 vCPU / 16GB RAM |
| `postgresql/postgresql_comparable_4vcpu_16gb.conf` | PostgreSQL | 4 vCPU / 16GB RAM |
| `mariadb/mariadb_comparable_16vcpu_32gb.cnf` | MariaDB | 16 vCPU / 32GB RAM |
| `postgresql/postgresql_comparable_16vcpu_32gb.conf` | PostgreSQL | 16 vCPU / 32GB RAM |

(Renamed from `*_minimum.*` in August 2026, then split from a single
undifferentiated `*_comparable.*` pair into these two explicit host-size
tiers, also August 2026. The larger tier's RAM budget was reduced from an
initial 64GB draft to 32GB shortly after, per review feedback — every
number below reflects the current 32GB figure.) Written to be reviewable
on its own — every
numeric claim below was checked against the actual pinned source trees
(`postgresql-src/postgresql-18.4`, `mariadb-src/`), not against
documentation alone; each finding says where to re-verify it.

## Scope

These files exist to answer one question: starting from each engine's
compiled-in defaults, what is the smallest, best-justified set of
config-file changes that makes a MariaDB run and a PostgreSQL run
comparable on **cache size, write-durability granularity, and I/O
parallelism** — the three levers that dominate OLTP throughput — without
turning either config into a general-purpose tuning exercise?

They are now split into two size tiers because a single fixed config
(originally 4G buffer pool / 4 vCPU worth of I/O threads, with no stated
RAM) left the sizing logic implicit and untestable at other host sizes.
Naming the vCPU count and RAM amount in the filename makes the sizing
assumption an explicit, checkable fact instead of something a reader has
to infer from the numbers.

Config-file changes are necessary but not sufficient. A large second half
of this document (External Conditions) covers the host- and OS-level
factors that TAF does not currently control, and that will silently
invalidate a comparison even if the right tier's `.cnf`/`.conf` files are
used unmodified.

## Sizing model

Both tiers apply the *same ratios*, scaled to the host's RAM and vCPU
count — the point is that going from the 4vCPU/16GB tier to the
16vCPU/32GB tier is a like-for-like scale-up, not a different tuning
philosophy chosen twice.

| Rule | 4 vCPU / 16GB | 16 vCPU / 32GB | Rationale |
|---|---|---|---|
| Buffer pool / `shared_buffers` = 25% of RAM | 4GB | 8GB | Standard PostgreSQL sizing heuristic (25% shared_buffers), applied identically to InnoDB's buffer pool so both engines commit the same *fraction* of host memory, not just a number chosen once. |
| `effective_cache_size` = 75% of RAM | 12GB | 24GB | Other half of the standard shared_buffers/effective_cache_size heuristic. Resolves the open question left by the previous review pass, where 4GB was pinned with no stated host RAM to justify it. |
| Redo log / `max_wal_size` = 1:4 ratio to buffer pool | 1GB | 2GB | Ratio carried over unchanged from the original tuning request (1G redo for a 4G pool); scaled by the same factor as the buffer pool itself. |
| I/O threads / `io_workers` = vCPU-scaled | 8 (2x vCPUs) | 16 (1x vCPUs) | See "Why the I/O-thread ratio changes between tiers" below — not the same multiplier on purpose. |
| `innodb_io_capacity`/`_max` | 2000 / 4000 | 4000 / 8000 (2x) | Storage-IOPS assumption, not CPU/RAM-derived — see the explicit caveat below before trusting the 16vCPU tier's number. |
| `thread_handling` | `pool-of-threads` | `pool-of-threads` | Not vCPU- or RAM-dependent; applies identically to both tiers. |

### Why the I/O-thread ratio changes between tiers

The 4vCPU tier uses **2x vCPU count** (8 read + 8 write on 4 vCPUs) —
this was the literal ratio in the original tuning request, which
explicitly called the MariaDB 4/4 default too low even for what it
described as a 4-core host. That's a defensible choice: InnoDB I/O
threads spend most of their time blocked on the storage device, not
spinning on CPU, so oversubscribing past the raw core count doesn't cost
much and buys more outstanding I/O.

The 16vCPU tier instead uses **1x vCPU count** (16 read + 16 write on 16
vCPUs) rather than continuing the 2x ratio (which would mean 32+32 — at
the edge of what's normally recommended for InnoDB I/O threads, and past
the point where there's evidence of it helping on typical NVMe/vSAN
backends). Treat both tiers' thread counts as a starting point to
re-measure against the actual storage backend, not a law — this is
exactly the kind of number a first benchmark run should be used to
correct.

### The one number in this document that is a modeling assumption, not a measured fact

`innodb_io_capacity`/`_max` (and the absence of a PG-side equivalent — see
finding 3) describe a storage device's IOPS budget, not something that
scales with vCPU or RAM. The 16vCPU tier's 4000/8000 values were reached
by scaling the 4vCPU tier's 2000/4000 by the same 2x factor as the
RAM/buffer-pool jump, on the **assumption** that a bigger host tier is
paired with proportionally faster storage. This is the weakest-justified
number in either tier's files — verify it against the actual rated IOPS
of the storage backing each host before trusting it, especially if both
tiers are ever run against the *same* physical storage (in which case
the values should probably be identical between tiers, not scaled).

## Config-level comparison (both tiers)

| Area | MariaDB | PostgreSQL | Status |
|---|---|---|---|
| Data cache (real allocation) | `innodb_buffer_pool_size` = 4G / 8G | `shared_buffers` = 4GB / 8GB | ✅ Matched |
| Redo log / WAL size | `innodb_log_file_size` = 1G / 2G | `max_wal_size` = 1GB / 2GB | ✅ Matched |
| I/O worker/thread count | `innodb_read/write_io_threads` = 8/8 → 16/16 | `io_workers` = 8 → 16 | ✅ Matched (not structurally identical, see finding 2) |
| Background I/O rate ceiling | `innodb_io_capacity(_max)` = 2000/4000 → 4000/8000 | *(no equivalent)* | ➖ Structural, cannot be matched |
| Connection-handling model | `thread_handling = pool-of-threads` | *(fixed process-per-connection)* | ➖ Structural, cannot be matched |
| Planner cache-size hint | *(n/a)* | `effective_cache_size` = 12GB / 24GB | ✅ Now derived from a stated RAM budget (see Sizing model) |

## Findings from this round

### 1. `shared_buffers` was the real gap, not `effective_cache_size`

The first pass at this pairing (`*_minimum.*`) left PostgreSQL entirely at
its stock defaults, reasoning that `effective_cache_size = 4GB` already
matched MariaDB's 4G buffer pool. That reasoning was wrong:
`effective_cache_size` is a `GUC_EXPLAIN`-flagged **planner cost hint** —
it changes query plan choices (index scan vs. sequential scan) but
allocates zero bytes. The actual PG analog of `innodb_buffer_pool_size` is
`shared_buffers`, a real shared-memory allocation (`NBuffers` in
`src/backend/utils/misc/guc_tables.c`), and its stock default is
**128MB** — the same small-box number MariaDB starts from. Left unfixed,
this would have handed MariaDB a decisive, unintended cache advantage on
any working set larger than 128MB. Both PostgreSQL tiers now set
`shared_buffers` explicitly (4GB / 8GB) to close this, using the same
25%-of-RAM rule InnoDB's buffer pool uses.

### 2. I/O worker count matched, but the mechanisms differ structurally

`io_workers` (default 3) is PostgreSQL 18's async-I/O worker pool, raised
to match MariaDB's `innodb_read_io_threads` + `innodb_write_io_threads`
by headline count in each tier. These are not equivalent designs:
InnoDB's threads are permanently split by direction and always running;
PG's `io_workers` are a single shared pool that services queued reads
(and, depending on `io_method`, some writes) for *all* backends. Matching
the headline count is the best available lever, but do not expect
matching numbers to produce matching queue behavior under saturation —
this is worth watching in the results, not assuming away.

### 3. Two knobs are structural, not tunable gaps

- **`innodb_io_capacity` / `innodb_io_capacity_max`** rate-limit InnoDB's
  own background flush/purge work in IOPS. PostgreSQL has no equivalent
  throttle; it relies on `checkpoint_completion_target` (spreads
  checkpoint writes over time, not IOPS-bounded) and OS-level write-back.
  There is nothing to set on the PG side to "match" this — a design
  difference between the engines, not a config gap.
- **`thread_handling = pool-of-threads`** removes MariaDB's per-connection
  thread-creation overhead. PostgreSQL's one-process-per-connection model
  is fixed at compile time; there is no GUC to change it. Note this when
  interpreting connection-churn-heavy workloads — PG pays a fork() cost
  per new connection that neither engine's config can tune away (a
  connection pooler in front of PG, e.g. pgbouncer, is the real-world
  answer, but that is outside the scope of these files).

### 4. Correction carried over from the previous review

`innodb_redo_log_capacity` does not exist in MariaDB 12.2.2 — verified
directly against `storage/innobase/handler/ha_innodb.cc` in the pinned
checkout: the only redo-log-size sysvar registered is
`innodb_log_file_size` (default 96MB, "Redo log size in bytes"). It is a
MySQL 8.0.30+ setting MariaDB never adopted. Both MariaDB tier files use
`innodb_log_file_size`; a config using the MySQL name would fail
`mariadbd` startup with an unknown-variable error.

### 5. `innodb_flush_method` and `innodb_flush_neighbors` — deliberately untouched in both tiers

`innodb_flush_method` stays at its stock default `fsync` (buffered I/O).
PostgreSQL 18.4 also does not use direct I/O by default (`debug_io_direct`
defaults off) — leaving both engines on buffered I/O is the
closer-to-both-defaults choice, not a gap. Practically, this means **both
engines double-buffer through the OS page cache identically today** — a
genuinely fair starting condition, and one that would stop being fair the
moment only one side is switched to `O_DIRECT`. `innodb_flush_neighbors`
(default 1, spinning-disk-era behavior) is left alone for the same
reason: it's a storage-medium decision, not a hardware-sizing one. Revisit
both only as a deliberate, separately-labeled experiment once the storage
medium for the benchmark host is known (see External Conditions).

## External conditions required for comparability

Config files only control what happens inside each server process. TAF
today does **not** manage any of the following (grepped for
`transparent_hugepage`, `swappiness`, `ulimit`, `numa` across
`framework_functional_tests/setup_almalinux10.sh` and both database
plugin modules — no matches). Every item below must be verified or set by
whoever provisions the benchmark host(s), and must be **identical across
the MariaDB run and the PostgreSQL run** — not merely "similar."

### Host identity and CPU
- **Same physical or virtual host**, or two hosts with an identical CPU
  model, core count, and clock/turbo behavior. A run comparing a 4-vCPU
  host against a 16-vCPU host invalidates the comparison outright — this
  is exactly why the config files are now named by tier: **use the
  4vcpu_16gb pair together, or the 16vcpu_32gb pair together, never one
  file from each tier.**
- **CPU governor** set to the same policy on both (`performance` vs.
  `powersave`/`ondemand`) — frequency scaling noise shows up directly in
  TPS variance and will be misread as an engine difference.
- **Actual host vCPU/RAM must match the filename's claim.** Verify the
  real `pgtaf-*` VM flavor's vCPU count and RAM against whichever tier's
  files are in use before a run — a mismatch here silently invalidates
  every ratio in the Sizing model section above.
- **NUMA topology**, if the host is NUMA (multi-socket, or a 16vCPU VM
  pinned across sockets): pin both engines' processes/vCPUs the same way,
  or disable NUMA interleaving effects identically. A buffer pool /
  shared_buffers allocation that spans NUMA nodes on one engine but not
  the other is a hidden asymmetry, and becomes more likely at the
  16vCPU/32GB tier than the 4vCPU/16GB one.

### Memory
- **Total host RAM must match the tier in use** — 16GB or 32GB, not
  "close to it." Both engines commit a fixed 25% of that RAM to real,
  pinned cache; the remaining 75% is assumed available as OS page cache
  headroom (see Sizing model) because both engines also lean on the OS
  page cache underneath that allocation (finding 5: both use buffered
  I/O). Running a tier's config on a host with meaningfully less RAM
  than its name claims leaves no OS cache headroom and produces a much
  worse, noisier result that has nothing to do with either engine.
- **Swap and `vm.swappiness`**: identical on both runs, ideally swap
  disabled outright for a benchmark host. A multi-GB fixed allocation
  getting partially swapped on one run and not the other is a silent,
  large confound.
- **Transparent Huge Pages (THP)**: set to the same policy (commonly
  `madvise` or `never` for database workloads) on both. THP compaction
  stalls show up as latency-tail noise that differs run to run if left on
  `always`, and matter more at the 16GB/32GB scale than at small
  allocations.
- **`vm.overcommit_memory`** and `vm.dirty_ratio` /
  `vm.dirty_background_ratio`: since both engines write through the page
  cache (finding 5), these two directly govern how aggressively the
  kernel defers or forces writeback — keep identical, or checkpoint/flush
  behavior differences will be attributed to the wrong engine.

### Storage
- **Same block device, filesystem, and mount options** for both engines'
  datadirs (same disk/volume type — e.g. both on the same vSAN-backed
  volume, not one on local NVMe and one on network storage).
- **I/O scheduler** (`none`/`mq-deadline` for NVMe, etc.) identical on
  both.
- **Storage IOPS budget matches the `innodb_io_capacity` assumption in
  use** — see the explicit caveat in the Sizing model section about the
  16vCPU tier's 4000/8000 being a scaled assumption, not a measurement.
- **Cache state at the start of each run**: decide and document whether
  each run starts cold (`echo 3 > /proc/sys/vm/drop_caches` before
  start, plus a fresh `mariadbd`/`postgres` process so neither buffer
  pool nor `shared_buffers` carries over warm pages) or warm
  (deliberate warm-up phase of fixed duration before measurement). Doing
  this differently between the two engine runs is one of the easiest
  ways to accidentally favor one side.

### OS / kernel
- **File descriptor limits** (`ulimit -n` / ulimit for the service user):
  same value for both. MariaDB's `open_files_limit=0` derives from the OS
  ulimit; PostgreSQL derives `max_files_per_process` similarly — an
  artificially low shared limit throttles both, but a limit that differs
  between the two runs throttles only one.
- **Kernel and glibc version**: same OS image for both runs (this should
  already hold if both engines run on hosts provisioned from the same
  `pgtaf-*` image, but confirm rather than assume, especially if MariaDB
  and PostgreSQL are ever validated on different base images for
  packaging reasons).

### Workload / measurement (outside the DB config, but part of "comparable")
- Same benchmark tool, version, and client-side thread/connection count
  for both engines.
- Same dataset size and same schema (row count, index set, data
  distribution) loaded identically before each run.
- Same number of iterations and same warm-up/measurement window, per the
  `ITERATIONS`/`COUNTS` convention already used by the Plovdiv orchestrator
  run scripts.
- **Dataset size relative to tier**: a dataset sized to fit comfortably
  in the 4vCPU/16GB tier's cache may fit entirely in the 16vCPU/32GB
  tier's cache too, hiding any I/O-path differences the larger tier's
  files are meant to expose. Scale the dataset with the tier, or
  deliberately keep it fixed and document that the larger tier is
  measuring "same data, more headroom" rather than "same ratio, bigger
  scale."

## Review checklist

Use this list to sign off a specific benchmark run as "comparable" rather
than just "using one of the comparable config file pairs":

- [ ] Confirmed which tier is intended for this run (4vcpu_16gb or
      16vcpu_32gb), and that **both** the MariaDB and PostgreSQL config
      loaded are from the *same* tier
- [ ] Both files loaded unmodified (or any deviation is logged and
      justified)
- [ ] Actual host vCPU count and RAM match the tier's filename
- [ ] `innodb_io_capacity`/`_max` re-verified against real storage IOPS,
      not assumed from the tier's scaled default
- [ ] Swap disabled or `vm.swappiness` pinned identically on both runs
- [ ] THP policy identical on both runs
- [ ] Same storage device/filesystem/mount options for both datadirs
- [ ] Cache-state policy (cold vs. warm start) chosen and applied
      identically to both runs
- [ ] `ulimit -n` (or equivalent) identical on both runs
- [ ] Same OS image/kernel version for both runs
- [ ] Same benchmark tool version, client thread count, dataset size, and
      iteration count for both runs
