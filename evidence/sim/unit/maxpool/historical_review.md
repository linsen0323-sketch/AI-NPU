# Maxpool packed source-word candidate

Status: **directed comparison passed; ready for the parent to apply in a subsequent build**. The production `npu_maxpool_engine.sv` was not edited by this work. This directory is an independent candidate and verification package.

## Source identity and change

- Baseline: `../before/source/acceleration/unified_npu/rtl/npu_maxpool_engine.sv`.
- Baseline and production SHA256 at verification: `5907257BE2C7FF3A4C4AE82382ED05FD0683BA7FAB3EADB6107EDE66E2140DB9`.
- Candidate: `npu_maxpool_engine.sv`, SHA256 `435AA68D4F895F5F4D4B51064715600641F78E303226E76CE4231D04F1FDDDF5`.
- `npu_maxpool_engine_before.sv` is byte-equivalent to the baseline after its module name is changed to `npu_maxpool_engine_before`; this condition was checked by a script.
- `maxpool_source_words.patch` contains the complete source delta, with production-relative patch paths. `manifest.json` records source, helper, testbench, runner, patch and log hashes.

The candidate packs eight signed 32-bit source-row registers into four 64-bit words with `ram_style="distributed"`. Each accepted scalar or bulk read beat writes one complete 64-bit address. The selected sample uses `fast_scan[2:1]` for the word and `fast_scan[0]` for its lower or upper signed 32-bit half. The intention is to expose a single-write-address distributed-RAM inference pattern instead of two variable-index 32-bit writes.

No state, arithmetic, address sequence, handshake, result interface or error behavior was intentionally changed. There is no extra DMA, BRAM, PE or DSP in the source change. Actual resource inference and savings have **not been measured** for this candidate.

## Verification executed

Standalone Vivado XSim 2025.2, build 6299465, using `xvlog`, `xelab` and `xsim`; `EXTERNAL_MATH=1`. No running root Vivado session or XDC was accessed. `run.ps1` reproduces the run using the recorded helper `npu_wide_math.sv` and two wrapper tops, one for `ENABLE_MAXPOOL_BULK=1` and one for `ENABLE_MAXPOOL_BULK=0`.

Both DUTs receive the same deterministic memory/math environment driven by the reference handshake. All 30 public outputs are compared with four-state inequality after each rising edge, including valid, ready, command payload, memory data, math data and terminal fault payload. Independent nested-loop maxpool calculations check every output pixel on successful commands. Input samples include varying signed values and INT32 minimum/maximum.

| Configuration | Cases including reset scenarios | Golden pixels | Compared cycles | Scalar reads/writes | Bulk reads/writes |
| --- | ---: | ---: | ---: | ---: | ---: |
| ENABLE_MAXPOOL_BULK=1 | 23 | 472 | 14673 | 163 / 121 | 56 / 10 |
| ENABLE_MAXPOOL_BULK=0 | 15 | 472 | 13559 | 296 / 249 | 0 / 0 |

Final logs contain one `TEST_PASS` per configuration. Compile, both elaboration logs and both final simulation logs contain no WARNING, ERROR or FATAL. The complete second run exited normally with status 0. An earlier passing run is retained under `results/first_pass`; the table above records the strengthened final run only.

Covered cases:

- Fast 8x8 I32 pooling with kernels 5, 9 and 13, both bulk-aligned output and scalar fallback through a non-128-aligned output address.
- No stalls, gapped request/data channels, terminal read response simultaneous with the last beat, and delayed terminal read response. Every command terminal response is stalled for seven clocks.
- Generic I32 and signed legacy I8, 5x7 input to 3x4 output with kernel 3, stride 2 and padding 1, including boundary and tail behavior.
- Scalar read and write faults, invalid full-width kernel command, and external math fault, with exact expected fault codes.
- Bulk read fault, malformed KEEP, early LAST, missing LAST, short three-beat packet and extra five-beat packet, plus a bulk write fault after three accepted data beats and the reference drain behavior.
- Reset during pending scalar read, after two received bulk-read beats, after three accepted bulk-write beats, and after at least three horizontal-scan positions. A final successful command checks recovery after the fault/reset sequences.

The engine has **no cancellation input**. Reset coverage is separate from cancellation. This run does not claim dispatcher-level or end-to-end cancellation validation.

## Static checks and limits

The unified diff has only the source storage declaration/comment, packed sample selection and the two accepted-read write locations. The reference-wrapper rename-only assertion and baseline/production SHA256 equality passed. XSim compilation and elaboration passed for both configurations.

This is directed behavioral evidence, not formal equivalence or full-system regression. No candidate synthesis, placement, routing, resource utilization, timing closure, bitstream, XSA or board validation was performed here. The next whole-system build must measure the actual inferred storage, resources and timing after the parent applies the candidate.

The earlier spatial activation RESET-remap recommendation is **rejected by the parent's measured whole-system results** (LUT 48220 to 52316, control sets 1010 to 2930, placement still failed). This maxpool candidate contains no RESET remap and does not revive that recommendation.
