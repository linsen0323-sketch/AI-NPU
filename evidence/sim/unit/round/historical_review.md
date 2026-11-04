# Round pipeline width candidate

This is a candidate directory only. Production `npu_resnet_quant.sv`, `npu_q16_vector_pipe.sv` and `npu_conv_epilogue.sv` were not modified. `candidate_manifest.json` records each unchanged production hash and candidate hash; `candidate.diff` is the complete reviewable change.

## Exact input proof

A search of the current production `source/` found three `npu_resnet_round_pipe` instantiations and one module definition. All three input connections explicitly construct sign extension, independently of any numerical bound assumed for a model or multiplier:

| Instance source | Declared payload | Connection to signed96 port | Sufficient width |
| --- | --- | --- | --- |
| `npu_resnet_quant.sv:73` | `product_value` is signed `[72:0]` at line45 | `{{23{product_value[72]}},product_value}` | signed73 |
| `npu_conv_epilogue.sv:108` | `product` is signed `[72:0]` at line55 | `{{23{product[72]}},product}` | signed73 |
| `npu_q16_vector_pipe.sv:164` | `secondary_product` is signed `[72:0]`; `evaluated7` is signed `[63:0]` | Mux of signed73 extension and signed64 extension | signed73 |

There is therefore no true 96-bit payload at a production caller. This proof concerns the actual round-pipeline input bits, so it does not depend on product mathematical precision or multiplier restrictions. The existing 96-bit input port remains unchanged. Default `MAG_W=96` retains all original generic-module behavior; only these three candidate callers set `.MAG_W(73)`. Supported parameter choices are exactly73 or96; intermediate widths are rejected by a simulation assertion. A further assertion rejects a valid narrowed input whose upper bits are not the required sign extension.

## Arithmetic preservation

The candidate narrows the segmented absolute-value high limb from32 to9 bits, three unsigned magnitude registers from96 to73 bits, and their bidirectional low/high shifter networks. Unsigned73 represents the magnitude of signed73 minimum `-2^72` exactly. Low/middle negate carry tests stay unchanged.

For right shifts, the input magnitude has no nonzero high bits beyond73. The low0..7-bit shift and high8-bit-multiple shift retain the original guard and sticky rules. Guard is zero beyond the narrowed width; sticky ORs all remaining bits plus the earlier guard/sticky. Shifts72/73/74 and all shifts through127 are explicitly exercised.

For negative shifts with absolute amount1..7, a naive73-bit left shift could discard high bits that the original96-bit pipeline kept. The candidate adds `left_overflow1/2` to retain the OR of those lost high bits and include it in `out_overflow32`. The low32 result bits are unchanged. INT8 saturation remains governed by the unchanged original full-input `force` check, plus the retained magnitude/range/rounding logic. For negative shift magnitude8..128, the original amount-zero/force-saturation behavior is preserved exactly, including the zero input. Default96 disables the new lost-high-bit flag, preserving even the old96-bit left-shift wrap behavior for arbitrary96-bit standalone inputs.

No valid, busy, tag, output pipeline depth, reset, rounding, saturation or fault interface was changed. The three magnitude registers lose69 declared FF bits and the two new overflow flags add2 bits per narrowed instance, for a theoretical67-bit net reduction before synthesis. Synthesis may already remove bits, so this is not a measured resource saving. Network/timing impact remains unmeasured.

## Verification

XSim 2025.2 build6299465 behavioral RTL; pyslang12.1.0 syntax check. Compilation and elaboration completed without warning/error. The differential simulation compares all results and status fields between:

1. The untouched original96-bit round module and candidate `.MAG_W(73)` on sign-extended73-bit inputs.
2. The untouched original96-bit round module and candidate default96 on arbitrary96-bit inputs.

Both streams passed175,194 output comparisons each, with175,242 issues,183,308 simulated cycles and17 resets, seed`498175e3`. The48 issues not retired were intentionally flushed by resets. All signed8 shifts `-128..127` are exercised with zero, +/-1, INT8/INT32 boundaries, signed73 minimum/maximum, all73 positive/negative single-bit positions and adjacent values, ties and their neighbors,64 random inputs per shift, then65,536 further random inputs. The default96 stream additionally receives explicit signed96 minimum/maximum and every high single-bit position73..95 with adjacent values at every shift. Bubble cycles, continuous issue, reset with tokens in flight and final complete drain are included. Fields checked are INT8 result, INT32 result, INT32 overflow, tag, valid and busy. The unchanged baseline block is extracted with only its module name changed in `round_before.sv`.

Terminal marker:

```text
TEST_PASS round_miter narrow=175194 default96=175194 issued=175242 cycles=183308 resets=17 shifts=-128..127 seed=498175e3
```

`verification.json` contains exact commands and hashes. `results/compile.log`, `elaborate.log` and `simulate.log` preserve full transcripts. Both production hashes and candidate source hashes were rechecked after the test.

Reproduction from the active `npu100` root:

```powershell
python verification/timing_closure_20261101_175338/round_pipe_candidate/prepare_candidate.py
python verification/timing_closure_20261101_175338/round_pipe_candidate/run_miter.py
```

This is bounded behavioral differential evidence, not formal proof, full model/Golden regression, synthesis resource evidence, timing closure or board verification. No Vivado session, synthesis or implementation was used by this subtask. The parent flow decides whether to adopt and measure the candidate.
