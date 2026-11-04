# Native production WBUF

Production source is `npu100/source/acceleration/unified_npu/rtl/npu_banked_buffer.sv`.
The only design edit in this task is this file. The input loader is unchanged.

The specialization applies only to BANKS=32, DATA_W=64, ROW_W=7, READ_LATENCY=2
with appended USE_NATIVE_WBUF=1. Other configurations and explicitly disabled
specialization retain the original XPM path. The conv engine's u_weights has
this production configuration (TAG_W=4 and RESERVE_PENDING_READ_PAGE=1).

Each of the 32 banks instantiates one RAMB36E1 in SDP x72 mode. Only 256 of its
512 words and its 64 regular data bits are used. This is the same physical
BRAM count as the preceding synthesized 256x64 XPM mapping. No fabric payload
registers, reset, read forwarding or additional banks were added. Resource
savings and implemented timing must be determined by the parent build.

The native write strobes directly preserve every byte lane, including one-hot,
mixed and zero masks. Page arbitration, ready logic, tag/valid metadata and
accepted-transaction ownership are unchanged. ENARDEN admits a read into the
BRAM latch; REGCEAREGCE advances the native output register independently. The
existing two-stage elastic control therefore still handles empty slots and
prolonged response backpressure. RAM payload is not reset.

## Primitive references

Official AMD UG473 v1.14, July 3, 2019 was retrieved from:
`https://docs.amd.com/api/khub/documents/9gZGbqBxtlKXxBfkBt~lAg/content`.
The original PDF and extracted text are preserved as amd_ug473.pdf/.txt.

- Page 30 Table 1-14: RAMB36E1 SDP x72 uses address [14:6], with 64 regular and
  eight parity bits per word. The wrapper uses {0,page,row7} for the nine word bits.
- Page 31 Table 1-15: low/high regular data halves map to DIADI/DIBDI and
  DOADO/DOBDO. The parity inputs are zero and parity outputs are unused.
- Pages 26-29: WEBWE supplies eight SDP byte write enables, ENARDEN is read
  enable, ENBWREN is write enable, and REGCEAREGCE controls the output register.
- Page 32 recommends unused address inputs high. Physical bit15 and low bits
  [5:0] follow this recommendation. The unused logical word MSB remains zero.
- Page 36 discusses READ_FIRST address overlap. DELAYED_WRITE is retained;
  accepted accesses cannot hit the same logical page.

Installed `D:/FPGA/2025.2/Vivado/data/verilog/src/unisims/RAMB36E1.v` provides
the exact 2025.2 primitive signature and behavioral model. Lines 672-878
confirm x72 SDP data/enable mapping; lines 3731-3745 reject NO_CHANGE in SDP.
Both WRITE_MODE parameters use legal READ_FIRST, both output register enables
are configured to one, and the unused REGCEB is tied low. The installed XPM
model in data/ip/xpm/xpm_memory/hdl/xpm_memory.sv supplies the comparison model.

The AMD documentation search MCP is not registered in this session. Standard
web tool requests returned no usable document text; the official PDF was
retrieved directly instead. No third-party implementation reference is used.

## Verification result

Vivado 2025.2 XSim compiled and elaborated the actual production source against
the installed unisims_ver and XPM libraries. It ran in isolated session
`vivado-20261101-180548-20283a47`, not the parent timing session.

`tb_wbuf_native.sv` instantiates four wrappers: native/XPM with bank masks off,
and native/XPM with bank masks enabled. Every DUT is checked each clock against
an independent byte-memory image and two-slot transaction scoreboard. TAG_W=8
is used to make response identities distinct; tag width does not alter BRAM.

The test initializes every one of the 8192 bank words independently; reads
all rows of both pages; tests row/bank corners, all eight one-hot byte strobes,
mixed/zero strobes, full throughput, gaps, a full pipeline stalled for 20 cycles,
same-page reservation conflicts and opposite-page simultaneous read/write;
runs 5000 deterministic random stimulus cycles (seed 08ba51e7); asserts reset
while queued results exist; and reads all rows again to prove RAM persistence.

Terminal result at 137748 ns:

```
TEST_PASS cycles=13775 writes=10073 reads=2390 responses=2388 conflicts=630 stalls=1974 masked_reads=1586 zero_writes=5 simultaneous=461 seed=08ba51e7
```

The two-read difference is intentional reset flushing. The watchdog is 1ms.
All compile, elaborate and runtime logs were read in full and checked by
check_results.py. Runtime has no failed assertion, unexpected error, primitive
DRC error, data mismatch or watchdog. Elaboration reports four existing
module-timescale warnings. Runtime reports existing XPM MESSAGE_CONTROL
configuration notices and an automatic waveform-display size warning; these
do not report collisions or functional failures. The final simulation was
closed so logs and WDB were flushed.

The test first passed with unused address pins tied low, then passed again
after those ignored physical pins were tied high to follow UG473. The final
source SHA256 is bound in result.json. The parent round04 synthesis had already
started before the physical constant change; its launch manifest must be
interpreted using its captured source identity. This change does not alter
logical addresses or valid data.

This is behavioral module verification, not full-network Golden equivalence,
post-synthesis simulation, routed timing, bitstream/XSA creation or board proof.

To reproduce in a separate Vivado session: source setup.tcl, then execute
`launch_simulation -simset sim_1 -mode behavioral`, close_sim -force, and run
`python check_results.py`. Setup modifies only that isolated session's child
environment and creates the project in this verification folder.
