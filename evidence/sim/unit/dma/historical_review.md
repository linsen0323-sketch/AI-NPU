# Registered DMA nonempty candidate

Candidate only, prepared 2026-11-01. Production/active implementation untouched.

## Change and exact cycle contract

`rd_valid=rst_n&&(r_used!=0)` becomes `rd_valid=rst_n&&r_nonempty`. The redundant flag is updated on exactly the original occupancy edges:

| Condition | Original occupancy | Flag |
|---|---|---|
| synchronous reset | 0 | 0 |
| accepted new read descriptor | 0 | 0 |
| active store, no pop | used+1 | 1 |
| active pop, no store | used-1 | used!=1 |
| active store and pop, or neither | hold | hold |
| inactive | hold | hold |

No latency, queue-depth, credit, channel, AXI, arithmetic-width, precision, or cycle-output change is intended. Late/early RLAST and RRESP fault handling still controls the existing `r_store`, `r_pop`, `r_active`, and descriptor state; the new flag has no independent fault transition that could clear live buffered data. Once drained, the final pop clears it. Accepted invalid descriptors and reset clear both count and predicate. The original occupancy remains authoritative for every credit/issue/terminal predicate.

For legal occupancy 0..FIFO_WORDS, the transition relation preserves `r_nonempty==(r_used!=0)` by induction. A small exhaustive arithmetic check covered 960 legal store/pop/count transitions at depths16/32/64/128. This is arithmetic support, not formal HDL verification. Invalid count-overflow inputs are outside the valid credit contract.

The reason to measure this candidate is removing the multibit reduction from the `rd_valid` combinational cone. The change adds one redundant register and moves comparison into its update path. No synthesis, area, placement, routed-timing, bitstream, or board claim is made. It does not remove the rest of the DMA/ownership/Copy control cone.

## Real XSim result

XSim2025.2 Build6299465. Isolated native `xvlog`, `xelab`, `xsim` against the exact copied current production DMA and the candidate. No primitive/IP dependency or main Vivado interpreter access. All three final stages exit0 and the explicit terminal marker is present:

`TEST_PASS dma_nonempty configurations=6 public_outputs=45`

| ID | FIFO words | Read / write outstanding | Diagnostics / perf | Seed | Cases | Compared cycles at case completion | Max used | Max read outstanding |
|---|---:|---|---|---|---:|---:|---:|---:|
| 0 | 16 | 1 / 1 | 1 / 1 | 10293847 | 117 | 18655 | 16 | 1 |
| 1 | 32 | 2 / 2 | 1 / 1 | 103c5c5a | 117 | 16749 | 32 | 2 |
| 2 | 64 | 4 / 2 | 1 / 1 | 104f806d | 117 | 18045 | 64 | 4 |
| 3 | 128 | 4 / 2 | 1 / 1 | 1062a480 | 117 | 19348 | 128 | 4 |
| 4 | 64 | 3 / 2 | 1 / 1 | 1075c893 | 117 | 16589 | 64 | 3 |
| 5 | 16 | 2 / 1 | 0 / 0 | 1088eca6 | 117 | 18287 | 16 | 2 |

Every public output port is compared with four-state inequality after each clock edge, including payloads outside valid, statistics, and all85 diagnostic bits. The miter also compares occupancy, reservations, outstanding counts, queue pointers and write response state. It asserts the new flag invariant and credit bounds after every edge, including reset.

Independent numeric scoreboards verify read data/keep/last against generated AXI responses, write data/keep against supplied source beats, burst length/alignment/page boundaries, and write burst last. The environment drives both DUTs from identical common inputs without force/deposit. Its random stall generators are replayable from the six recorded seeds.

Each configuration runs117 scenarios: directed FIFO/credit full and write-FIFO full, simultaneous store/pop, one-word/unaligned/page-boundary reads, concurrent independent reads/writes, early and late RLAST, RRESP and BRESP errors, terminal backpressure, accepted descriptor drain during stop, a held descriptor blocked by stop, zero-byte and endpoint-overflow descriptors, reset while read-active/buffered/full, reset while write-active/buffered, reset with terminal held, successful recovery, and96 random mixed descriptors. Diagnostics/perf disabled is separately exercised. Read outstanding=3 verifies a non-power-of-two outstanding queue configuration.

Per-configuration required coverage was enforced before PASS. Aggregate lower bounds at each configuration's own completion:

- cases: 702
- compared: 107673
- rdwords: 65980
- wrwords: 13944
- full: 54
- wfull: 1124
- credit: 3513
- simultaneous: 47281
- empty_set: 11742
- last_clear: 11730
- held_terminal: 8680
- stop_active: 5478
- reset_active: 18
- shortlast: 6
- latelast: 6
- readfault: 6
- writefault: 6

Comparison continues until the last configuration finishes at193480ns; the summed per-configuration counters above conservatively exclude any additional idle comparisons after that configuration's PASS.

The initial verification-only fill stimulus started16 bytes before a4KiB boundary. At FIFO16, the two-beat first burst prevented the next full16-beat credit reservation while the consumer was deliberately stopped; the wait could not fill the FIFO. That test run was stopped and its logs retained under `results/first_pass`. Only the fill case was page-aligned, and the final full run completed. The candidate RTL did not change after the first run. A finite2ms simulation watchdog bounds later reproduction. The final complete logs contain zero WARNING, ERROR, or Fatal lines.

## Reproduce and scope

Run `./run.ps1` from PowerShell; it generates the45-port miter from the copied module header, compiles/elaborates, runs the self-checking test, and rejects missing PASS or Fatal. The final testbench/source/log hashes are in `manifest.json`; `candidate.patch` applies only the intended source changes.

Production baseline SHA256: `015172020834EB45F937467FC1D48A8D67041A6B3626C6004A5E59F6497E321F`

Candidate SHA256: `6D5FC7201EA5EAC6DFE23D803EC6CFA760CAE2D580F2CF493844205723912CEF`

This is a focused behavioral equivalence/numeric regression, not formal proof, full-system/three-model Golden, synthesis, implementation, final timing, deployment, or board verification. Candidate adoption remains a separate root-agent decision.
