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
# 768×30 block-diagonal FWHT (CLIP text feature scale)
# =========================================================================

def fwht_768x30_fp16(data_flat: list, vec_dim: int = 768,
                      num_vectors: int = 30) -> list:
    """
    Block-diagonal 64-point FWHT for 768-dim vectors × 30.
    Each 768-dim vector is processed as 12 independent groups of 64 elements.
    Input:  flat list of 23040 FP16 ints (768 × 30)
    Output: flat list of 23040 FP16 ints
    Internal: float64 precision, round-to-nearest-even at output.
    """
    group_size = 64
    num_groups = vec_dim // group_size  # 768 / 64 = 12

    if len(data_flat) != vec_dim * num_vectors:
        raise ValueError(f"Expected {vec_dim * num_vectors} values, got {len(data_flat)}")

    result = []
    for v in range(num_vectors):
        base = v * vec_dim
        for g in range(num_groups):
            start = base + g * group_size
            chunk = data_flat[start : start + group_size]
            result.extend(fwht_fp16(list(chunk)))

    return result


def fwht_768x30_fp16_analyze(input_data: list, output_data: list = None,
                              vec_dim: int = 768, num_vectors: int = 30):
    """
    Analyze FWHT effect on 768×30 data with outliers.
    If output_data is None, runs fwht_768x30_fp16 first.

    Prints per-vector outlier statistics showing how FWHT diffuses
    outlier energy across elements.
    """
    if output_data is None:
        output_data = fwht_768x30_fp16(input_data, vec_dim, num_vectors)

    print(f"\n{'='*60}")
    print(f"FWHT 768×30 Outlier Diffusion Analysis")
    print(f"{'='*60}")

    inp_f = np.array([fp16_to_float(int(x)) for x in input_data], dtype=np.float64)
    out_f = np.array([fp16_to_float(int(x)) for x in output_data], dtype=np.float64)

    # Global stats
    inp_std = float(np.std(inp_f))
    inp_outliers = int(np.sum(np.abs(inp_f) > 5 * inp_std))
    out_std = float(np.std(out_f))
    out_outliers = int(np.sum(np.abs(out_f) > 5 * out_std))

    print(f"\nGlobal:")
    print(f"  Input:  mean={inp_f.mean():.3f} std={inp_std:.2f} "
          f"min={inp_f.min():.2f} max={inp_f.max():.2f} outliers(>5σ)={inp_outliers}")
    print(f"  Output: mean={out_f.mean():.3f} std={out_std:.2f} "
          f"min={out_f.min():.2f} max={out_f.max():.2f} outliers(>5σ)={out_outliers}")
    if inp_outliers > 0:
        reduction = (1.0 - out_outliers / inp_outliers) * 100
        print(f"  Outlier reduction: {inp_outliers} → {out_outliers} ({reduction:.1f}%)")

    # Per-vector analysis
    print(f"\nPer-vector analysis:")
    for v in range(num_vectors):
        base = v * vec_dim
        vin = inp_f[base : base + vec_dim]
        vout = out_f[base : base + vec_dim]
        vin_std = float(np.std(vin))
        vin_peaks = int(np.sum(np.abs(vin) > 5 * vin_std))
        vout_peaks = int(np.sum(np.abs(vout) > 5 * vin_std))
        vout_maxabs = float(np.max(np.abs(vout)))

        marker = ""
        if vin_peaks > 0:
            marker = f" → {vout_peaks} after FWHT"
            if vout_peaks < vin_peaks:
                marker += " ✓"
        print(f"  vec {v:2d}: in_std={vin_std:5.1f} "
              f"out_max={vout_maxabs:6.1f} "
              f"in_outliers={vin_peaks}{marker}")

    return output_data


def write_fp16_mem(data: list, filepath: str, values_per_block: int = 32):
    """
    Write FP16 values as $readmemh-compatible .mem file.
    Byte ordering matches generate_input.py (RTL-compatible).
    Each block = 512 bits = 64 bytes = 32 FP16 values.
    """
    total = len(data)
    num_blocks = (total + values_per_block - 1) // values_per_block
    with open(filepath, 'w') as f:
        for b in range(num_blocks):
            block_bytes = bytearray(64)
            for j in range(values_per_block):
                idx = b * values_per_block + j
                fp16 = int(data[idx]) & 0xFFFF if idx < total else 0
                byte_pos_hi = 62 - j * 2
                byte_pos_lo = 63 - j * 2
                block_bytes[byte_pos_hi] = (fp16 >> 8) & 0xFF
                block_bytes[byte_pos_lo] = fp16 & 0xFF
            f.write(block_bytes.hex() + '\n')
    print(f"Wrote {num_blocks} blocks to {filepath}")


# =========================================================================
# .mem 文件字节序工具
# -------------------------------------------------------------------------
# 项目内 .mem 存在两种互不兼容的字节序约定:
#   'py'  (write_fp16_mem / generate_input.py):  高字节在前, 块内 j=0 在右
#         -> 服务 RTL 仿真链路 ($readmemh 语义), 禁止改动
#   'cpp' (C++ write_mem_file / img2mem.py):     低字节在前, 块内 j=0 在左
#         -> 服务上板链路 (fwht_test 输出 fwht-output-board.mem 等)
# 读取方必须按文件实际字节序解析, 否则会把有限值误读成 inf/NaN。
# =========================================================================

def _swap16(x: int) -> int:
    """字节交换一个 16-bit 值 (低字节 <-> 高字节)。"""
    return ((x & 0xFF) << 8) | ((x >> 8) & 0xFF)


def _parse_fp16_cpp(lines: list) -> list:
    """按 C++ write_mem_file 格式解析: 每 4-hex 一组低字节在前, j=0 在左。"""
    data = []
    for line in lines:
        for j in range(32):
            u = int(line[j * 4:(j + 1) * 4], 16)
            data.append(_swap16(u))
    return data


def _parse_fp16_py(lines: list) -> list:
    """按 Python write_fp16_mem 格式解析: 高字节在前, 块内 j=0 在右。"""
    data = []
    for line in lines:
        blk = int(line, 16)
        for j in range(32):
            data.append((blk >> (16 * j)) & 0xFFFF)
    return data


def detect_mem_order(path: str) -> str:
    """检测 .mem 文件字节序: 返回 'cpp' 或 'py'。

    启发式: FWHT 激活数据应为有限值, 正确字节序不会产生 inf/NaN;
    错误字节序会把部分有限位模式误读成 exp=31 (inf/NaN)。
    若两种解析都不产生 inf/NaN (极端情况), 取非有限值更少的。
    """
    lines = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and len(line) == 128:
                lines.append(line)
    if not lines:
        raise ValueError(f"Empty or unrecognized .mem file: {path}")

    def bad_count(parser):
        return sum(1 for v in [fp16_to_float(x) for x in parser(lines)]
                   if v != v or v in (float('inf'), float('-inf')))

    n_cpp = bad_count(_parse_fp16_cpp)
    n_py = bad_count(_parse_fp16_py)
    order = "cpp" if n_cpp <= n_py else "py"
    if n_cpp != n_py:
        print(f"  [mem-order] {path.split('/')[-1]}: cpp_bad={n_cpp} py_bad={n_py} -> {order}")
    return order


def read_fp16_mem(path: str) -> list:
    """读取 .mem 文件为 float 列表 (自动检测字节序)。"""
    return [fp16_to_float(x) for x in read_fp16_mem_raw(path)]


def read_fp16_mem_raw(path: str) -> list:
    """读取 .mem 文件为 FP16 原始 16-bit 整数列表 (自动检测字节序)。"""
    order = detect_mem_order(path)
    lines = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and len(line) == 128:
                lines.append(line)
    parser = _parse_fp16_cpp if order == "cpp" else _parse_fp16_py
    return parser(lines)


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
    import argparse
    parser = argparse.ArgumentParser(description="FWHT Golden Model")
    parser.add_argument("--test", action="store_true", help="Run verification suite")
    parser.add_argument("--analyze", default=None, help="Analyze .mem file (768x30 format)")
    parser.add_argument("--output", "-o", default="fwht-golden-output.mem",
                        help="Output .mem for golden result")
    parser.add_argument("--vec-dim", type=int, default=768)
    parser.add_argument("--num-vectors", type=int, default=30)
    args = parser.parse_args()

    if args.analyze:
        # Read .mem file
        blocks = []
        with open(args.analyze) as f:
            for line in f:
                line = line.strip()
                if line and len(line) == 128:
                    blocks.append(int(line, 16))
        print(f"Read {len(blocks)} blocks from {args.analyze}")

        # Extract FP16 values: fp16[j] = (blk >> (16*j)) & 0xFFFF
        data = []
        for blk in blocks:
            for j in range(32):
                data.append((blk >> (16 * j)) & 0xFFFF)
        print(f"Extracted {len(data)} FP16 values")

        # Run golden and analyze
        output = fwht_768x30_fp16_analyze(data, vec_dim=args.vec_dim,
                                           num_vectors=args.num_vectors)

        # Write golden output
        write_fp16_mem(output, args.output)
        print(f"Golden output: {args.output}")

    elif args.test:
        print("=" * 60)
        print("FWHT Golden Model — Verification Suite")
        print("=" * 60)
        test_zeros()
        test_impulse()
        test_all_127()
        test_involution()
        test_fp16_vs_int8()
        test_random()
        print("\n" + "=" * 60)
        print("Done.")
    else:
        parser.print_help()
