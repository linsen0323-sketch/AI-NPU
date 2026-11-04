"""ResNet numerical extension of NPUPLN1 (record flag bit 0).

This is a numerical contract, not a second execution engine. Other models keep
flags == 0 and their existing Q16 semantics. All pointers retain NPUPLN1's
tagged constants/workspace addressing and all execution uses engines 1..6.
"""

LEGACY_R18 = 1
LEGACY_MODEL_ID = 1
LEGACY_PROFILE = 2
LEGACY_ACC_BITS = 40
LEGACY_REQUANT_BITS = 72
LEGACY_ADD_NUMERATOR_BITS = 73

# Existing NPUPLN1 word numbers, not byte offsets.
FLAGS = 2
MULTIPLIER_LO = 17
MULTIPLIER_HI = 18
SHIFT = 19
ADD_MULTIPLIER_B_LO = 21
ADD_MULTIPLIER_B_HI = 22


def signed(value: int, bits: int) -> int:
    """Interpret exactly the low `bits` bits as a two's-complement integer."""
    value = int(value) & ((1 << bits) - 1)
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def round_sat_i8(value: int, shift: int) -> int:
    """Exact sign/magnitude RNE followed by full-range signed INT8 saturation.

    Python integers intentionally model the original 72/73-bit numerator;
    NumPy INT64 arithmetic would overflow valid residual/conv intermediates.
    `shift` is the signed low byte from the frozen descriptor. Negative shifts
    multiply by a power of two and preserve the original saturation behavior.
    """
    value = int(value)
    shift = signed(shift, 8)
    negative = value < 0
    magnitude = abs(value)
    if shift > 0:
        quotient, remainder = divmod(magnitude, 1 << shift)
        half = 1 << (shift - 1)
        magnitude = quotient + int(remainder > half or (remainder == half and quotient & 1))
    elif shift < 0:
        magnitude <<= -shift
    rounded = -magnitude if negative else magnitude
    return min(127, max(-128, rounded))


def requant_i8(accumulator: int, multiplier: int, shift: int) -> int:
    return round_sat_i8(signed(accumulator, 40) * signed(multiplier, 32), shift)


def residual_i8(a: int, b: int, multiplier_a: int, multiplier_b: int, shift: int) -> int:
    # There is one rounding step after addition, never one rounding per branch.
    numerator = signed(a, 8) * signed(multiplier_a, 64) + signed(b, 8) * signed(multiplier_b, 64)
    return round_sat_i8(numerator, shift)
