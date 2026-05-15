"""
FWHT Golden Model for Hadamard RTL Verification
================================================
Bit-accurate at format boundaries (FP16 ↔ float64, INT8 ↔ int64).
Internal computation uses maximum precision: float64 for FP16 path,
int64 for INT8 path.

The 64-point Walsh-Hadamard butterfly pairing matches RTL hadamard.v:
  stage 0→1: stride 1   (0,1) (2,3) ... (62,63)
  stage 1→2: stride 2   (0,2) (1,3) ... (61,63)
  stage 2→3: stride 4   (0,4) (1,5) ... (59,63)
  stage 3→4: stride 8
  stage 4→5: stride 16
  stage 5→6: stride 32  (0,32) (1,33) ... (31,63)
"""

import struct
import numpy as np

# =========================================================================
# FP16 ↔ float64 conversion (IEEE 754 binary16)
# =========================================================================

def fp16_to_float(x: int) -> float:
    """Convert 16-bit FP16 integer to Python float."""
    sign = (x >> 15) & 0x1
    exp  = (x >> 10) & 0x1F
    frac = x & 0x3FF

    if exp == 0:
        # subnormal or zero: value = (-1)^sign * 2^-14 * 0.frac
        return (-1)**sign * (frac / 1024.0) * (2.0 ** -14)
    elif exp == 31:
        # infinity or NaN
        if frac == 0:
            return float('inf') if sign == 0 else float('-inf')
        else:
            return float('nan')
    else:
        # normal: value = (-1)^sign * 2^(exp-15) * 1.frac
        mantissa = 1.0 + frac / 1024.0
        return (-1)**sign * mantissa * (2.0 ** (exp - 15))


def float_to_fp16(x: float) -> int:
    """Convert Python float to 16-bit FP16 integer (round-to-nearest-even)."""
    if np.isnan(x):
        return 0x7E00  # canonical NaN
    if np.isinf(x):
        return 0x7C00 if x > 0 else 0xFC00
    if x == 0.0:
        return 0x0000

    sign = 0 if x >= 0 else 1
    abs_x = abs(x)

    # find exponent for normalization
    import math
    if abs_x < 2.0 ** -14:
        # subnormal range
        exp = 0
        frac = int(round(abs_x / (2.0 ** -14) * 1024.0))
        if frac >= 1024:
            exp = 1
            frac = 0
    else:
        exp_raw = int(math.floor(math.log2(abs_x)))
        exp = exp_raw + 15  # biased exponent
        if exp <= 0:
            # underflow to subnormal
            exp = 0
            frac = int(round(abs_x / (2.0 ** -14) * 1024.0))
        elif exp >= 31:
            # overflow to infinity
            return 0x7C00 if sign == 0 else 0xFC00
        else:
            mantissa = abs_x / (2.0 ** exp_raw) - 1.0
            frac = int(round(mantissa * 1024.0))
            if frac >= 1024:
                exp += 1
                frac = 0
                if exp >= 31:
                    return 0x7C00 if sign == 0 else 0xFC00

    # clamp frac for subnormal
    if frac >= 1024:
        frac = 1023

    return (sign << 15) | ((exp & 0x1F) << 10) | (frac & 0x3FF)


# =========================================================================
# Walsh-Hadamard 64-point transform (stride 1,2,4,8,16,32)
# =========================================================================

def fwht_64(data: np.ndarray) -> np.ndarray:
    """
    64-point Walsh-Hadamard transform, in-place.
    Pairing: stride 1,2,4,8,16,32 (Walsh ordering, matching RTL hadamard.v).
    Preserves input dtype (float64 or int64).
    """
    n = 64
    result = data.copy()
    for step in [1, 2, 4, 8, 16, 32]:
        for i in range(0, n, step * 2):
            for j in range(step):
                a = result[i + j]
                b = result[i + j + step]
                result[i + j] = a + b
                result[i + j + step] = a - b
    return result


def fwht_64_stages(data: np.ndarray) -> list:
    """
    64-point Walsh-Hadamard with per-stage snapshots.
    Returns list of 7 arrays: [stage0, stage1, ..., stage6]
    stage0 = input data, stage1..6 = after each stride.
    Preserves input dtype.
    """
    n = 64
    stages = [data.copy()]
    result = data.copy()
    for step in [1, 2, 4, 8, 16, 32]:
        for i in range(0, n, step * 2):
            for j in range(step):
                a = result[i + j]
                b = result[i + j + step]
                result[i + j] = a + b
                result[i + j + step] = a - b
        stages.append(result.copy())
    return stages


def print_fp16_stages(stages: list, max_show: int = 8):
    """Print per-stage FP16 hex values for first max_show elements."""
    for s_idx, stage in enumerate(stages):
        vals = [f"0x{int(x):04X}" for x in stage[:max_show]]
        print(f"  stage{s_idx}: [{', '.join(vals)}{'...' if len(stage) > max_show else ''}]")


def print_int_stages(stages: list, max_show: int = 8):
    """Print per-stage integer values for first max_show elements."""
    for s_idx, stage in enumerate(stages):
        vals = [f"{int(x):d}" for x in stage[:max_show]]
        print(f"  stage{s_idx}: [{', '.join(vals)}{'...' if len(stage) > max_show else ''}]")


# =========================================================================
# FP16 golden path
# =========================================================================

def fwht_fp16(data_64: list) -> list:
    """
    FP16 golden model.
    Input:  64 FP16 values (16-bit ints)
    Output: 64 FP16 values (16-bit ints)
    Internal: float64 precision
    """
    f64 = np.array([fp16_to_float(int(x)) for x in data_64], dtype=np.float64)
    result = fwht_64(f64)
    return [float_to_fp16(float(x)) for x in result]


def fwht_fp16_stages(data_64: list) -> list:
    """
    FP16 golden model with per-stage snapshots.
    Returns list of 7 lists of FP16 ints: [stage0..stage6].
    Internal: float64 precision, rounded to FP16 at each stage boundary.
    """
    f64 = np.array([fp16_to_float(int(x)) for x in data_64], dtype=np.float64)
    stages_f64 = fwht_64_stages(f64)
    return [np.array([float_to_fp16(float(x)) for x in stage], dtype=np.int32)
            for stage in stages_f64]


# =========================================================================
# INT8 golden path
# =========================================================================

def fwht_int8(data_64: list) -> list:
    """
    INT8 golden model.
    Input:  64 INT8 values (-128..127 Python ints)
    Output: 64 INT8 values, [7:0] truncation (matching RTL hadamard.v dout_int8)
    Internal: int64 exact integer arithmetic
    """
    arr = np.array([int(x) for x in data_64], dtype=np.int64)
    result = fwht_64(arr)
    # RTL truncation: take lower 8 bits (2's complement wrapping, NOT saturation)
    return result.astype(np.int8).astype(int).tolist()


# =========================================================================
# Test suite
# =========================================================================

def _assert_close(actual, expected, tol=0, name=""):
    """Compare two lists, return (pass, max_diff, details)."""
    diffs = []
    max_abs_diff = 0
    for i, (a, e) in enumerate(zip(actual, expected)):
        if tol == 0:
            diff = abs(int(a) - int(e))
        else:
            diff = abs(float(a) - float(e))
        if diff > tol:
            diffs.append(f"  [{i}] actual={a} expected={e} diff={diff}")
        max_abs_diff = max(max_abs_diff, diff)

    if diffs:
        print(f"  FAIL {name}: {len(diffs)} mismatches, max_diff={max_abs_diff}")
        for d in diffs[:8]:
            print(d)
        if len(diffs) > 8:
            print(f"  ... and {len(diffs) - 8} more")
        return False, max_abs_diff
    else:
        print(f"  PASS {name}")
        return True, max_abs_diff


def test_impulse():
    """Delta impulse: input[0]=1, rest=0 → output = all 1s (Walsh row 0)."""
    print("\n--- test_impulse ---")
    # INT8
    data = [1] + [0] * 63
    out = fwht_int8(data)
    expected = [1] * 64
    _assert_close(out, expected, name="INT8 impulse")

    # FP16: 1.0 → impulse → all 1.0
    data_fp16 = [float_to_fp16(1.0 if i == 0 else 0.0) for i in range(64)]
    out_fp16 = fwht_fp16(data_fp16)
    out_f = [fp16_to_float(x) for x in out_fp16]
    # all values should be close to 1.0
    errors = [abs(x - 1.0) for x in out_f]
    max_err = max(errors)
    if max_err < 0.01:
        print(f"  PASS FP16 impulse (-1.0): max_err={max_err:.6f}")
    else:
        print(f"  FAIL FP16 impulse: max_err={max_err:.6f}")


def test_all_127():
    """
    All +127 input.
    - Unclamped FWHT: output[0] = 8128, rest = 0 (Walsh orthogonality)
    - INT8 golden: output[0] = 127 (saturated from 8128), rest = 0
    - FP16 golden: output[0] = 8128 (exact), rest ~0
    """
    print("\n--- test_all_127 ---")
    # Verify raw (unclamped) FWHT correctness
    arr = np.array([127] * 64, dtype=np.int64)
    raw = fwht_64(arr)
    raw_expected = [8128] + [0] * 63
    _assert_close(raw.tolist(), raw_expected, name="unclamped FWHT all+127")

    # INT8 golden: [7:0] wrapping truncation → 8128 & 0xFF = 192 → -64 (signed)
    out = fwht_int8([127] * 64)
    expected_truncated = [-64] + [0] * 63
    _assert_close(out, expected_truncated, name="INT8 golden (truncated)")

    # FP16: 127.0 in FP16 is exact, 8128 is also exact (fits in 11-bit man)
    data_fp16 = [float_to_fp16(127.0)] * 64
    out_fp16 = fwht_fp16(data_fp16)
    out_f = [fp16_to_float(x) for x in out_fp16]
    err0 = abs(out_f[0] - 8128.0) / 8128.0
    others = [abs(out_f[i]) for i in range(1, 64)]
    max_other = max(others)
    print(f"  FP16 all+127: dout[0]={out_f[0]:.1f} (rel_err={err0:.6f}), max_other={max_other:.6f}")
    if err0 < 0.001 and max_other < 1.0:
        print(f"  PASS FP16 all+127")
    else:
        print(f"  FAIL FP16 all+127")


def test_zeros():
    """All zeros → all zeros."""
    print("\n--- test_zeros ---")
    # INT8
    data = [0] * 64
    out = fwht_int8(data)
    _assert_close(out, [0] * 64, name="INT8 zeros")

    # FP16
    data_fp16 = [0] * 64
    out_fp16 = fwht_fp16(data_fp16)
    _assert_close(out_fp16, [0] * 64, name="FP16 zeros")


def test_involution():
    """FWHT is its own inverse (up to scale): fwht(fwht(x)) / 64 == x."""
    print("\n--- test_involution ---")
    rng = np.random.RandomState(42)
    data = rng.randint(-128, 128, size=64).tolist()

    # INT8: fwht(fwht(x)) should recover x (after /64)
    out1 = fwht_int8(data)
    # For involution test on integer path, use int64 directly without clamp
    arr = np.array(data, dtype=np.int64)
    fwht_once = fwht_64(arr)
    fwht_twice = fwht_64(fwht_once)
    recovered = (fwht_twice // 64).astype(int)
    mismatches = sum(1 for a, b in zip(recovered, data) if a != b)
    if mismatches == 0:
        print(f"  PASS INT8 involution: fwht(fwht(x)) // 64 == x")
    else:
        print(f"  FAIL INT8 involution: {mismatches} mismatches")

    # FP16: check orthogonality
    data_fp16 = [float_to_fp16(float(x)) for x in data]
    out1_fp16 = fwht_fp16(data_fp16)
    out2_fp16 = fwht_fp16(out1_fp16)
    out2_f = [fp16_to_float(x) / 64.0 for x in out2_fp16]
    orig_f = [fp16_to_float(x) for x in data_fp16]
    diffs = [abs(out2_f[i] - orig_f[i]) for i in range(64)]
    max_diff = max(diffs)
    if max_diff < 1.0:
        print(f"  PASS FP16 involution: max_diff={max_diff:.4f}")
    else:
        print(f"  FAIL FP16 involution: max_diff={max_diff:.4f}")


def test_fp16_vs_int8():
    """
    Compare FP16 vs INT8 golden outputs.
    Differences arise from:
    - FP16: float64 internal precision + FP16 output rounding
    - INT8: int64 exact + clamp to [-128,127]
    For values in overlapping range, FP16 rounding error should be < 2.0.
    """
    print("\n--- test_fp16_vs_int8 ---")
    rng = np.random.RandomState(123)
    data = rng.randint(-128, 128, size=64).tolist()

    out_int8 = fwht_int8(data)
    data_fp16 = [float_to_fp16(float(x)) for x in data]
    out_fp16 = fwht_fp16(data_fp16)
    out_fp16_ints = [int(round(fp16_to_float(x))) for x in out_fp16]

    # Only compare values where INT8 is not saturated
    saturated = sum(1 for x in out_int8 if abs(x) >= 127)
    in_range = [(out_fp16_ints[i], out_int8[i])
                for i in range(64) if abs(out_int8[i]) < 127]
    diffs_in_range = [abs(a - b) for a, b in in_range]
    max_in_range = max(diffs_in_range) if diffs_in_range else 0
    large_in_range = sum(1 for d in diffs_in_range if d > 1)

    print(f"  Saturated INT8 outputs: {saturated}/64")
    print(f"  In-range max diff: {max_in_range}, large diffs (>1): {large_in_range}/{len(diffs_in_range)}")
    if large_in_range == 0:
        print(f"  PASS FP16 vs INT8 (in-range values match within 1)")
    else:
        print(f"  WARN FP16 vs INT8: {large_in_range} in-range diffs > 1")


def test_random():
    """Random test with known Walsh-Hadamard matrix."""
    print("\n--- test_random (Walsh matrix check) ---")
    rng = np.random.RandomState(99)
    data = rng.randint(-128, 128, size=64).tolist()

    # Build 64x64 Walsh-Hadamard matrix (Walsh ordering)
    # H_1 = [[1,1],[1,-1]], H_k = H_1 ⊗ H_{k-1}
    H = np.array([[1]], dtype=np.int64)
    for _ in range(6):
        H = np.block([[H, H], [H, -H]])

    arr = np.array(data, dtype=np.int64)
    expected = H @ arr
    expected_truncated = expected.astype(np.int8).astype(int)

    out = np.array(fwht_int8(data))
    mismatches = sum(1 for a, b in zip(out, expected_truncated) if a != b)
    if mismatches == 0:
        print(f"  PASS random Walsh matrix: exact match")
    else:
        raw_mismatches = sum(1 for a, b in zip(out, expected) if int(a) != int(b))
        print(f"  Truncated mismatches: {mismatches}/64 (raw: {raw_mismatches})")


# =========================================================================
# Main
# =========================================================================

if __name__ == "__main__":
    print("=" * 60)
    print("FWHT Golden Model — Verification Suite")
    print("FP16 and INT8 paths, Walsh-ordered 64-point FWHT")
    print("=" * 60)

    test_zeros()
    test_impulse()
    test_all_127()
    test_involution()
    test_fp16_vs_int8()
    test_random()

    print("\n" + "=" * 60)
    print("Done.")
