"""
Analyze FWHT's role in activation quantization: FP16 -> INT8 -> INT4 cascade.
"""
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from fwht_golden import fp16_to_float, float_to_fp16, fwht_fp16

def read_mem(path):
    data = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and len(line) == 128:
                blk = int(line, 16)
                for j in range(32):
                    data.append((blk >> (16 * j)) & 0xFFFF)
    return data

def quant_snr(data, n_bits=8):
    """Per-channel quantization SNR (dB)."""
    d = np.array(data).reshape(30, -1)
    per_ch_max = np.max(np.abs(d), axis=0)
    step = 2 * per_ch_max / (2**n_bits)
    q = np.round(d / step[np.newaxis, :]) * step[np.newaxis, :]
    noise = d - q
    return 10 * np.log10(np.mean(d**2) / (np.mean(noise**2) + 1e-10))

VEC_DIM, NUM_VECTORS, GSZ = 768, 30, 64
inp_fp16 = read_mem('../input-data/fwht-input-768x30.mem')
inp = np.array([fp16_to_float(x) for x in inp_fp16])

print("=" * 60)
print("1. THE PROBLEM: Activation Outliers")
print("=" * 60)

ch_max = np.max(np.abs(inp.reshape(NUM_VECTORS, VEC_DIM)), axis=0)
print(f"  768 channels: P50={np.percentile(ch_max,50):.1f}  P99={np.percentile(ch_max,99):.1f}  Max={np.max(ch_max):.1f}")
print(f"  Outlier ratio (max/P50): {np.max(ch_max)/np.percentile(ch_max,50):.1f}x")
print(f"  INT8 SNR (no FWHT): {quant_snr(inp, 8):.1f} dB")
print(f"  INT4 SNR (no FWHT): {quant_snr(inp, 4):.1f} dB")

print("\n" + "=" * 60)
print("2. FP16 FWHT: Outlier Diffusion")
print("=" * 60)

fwht_out = []
for v in range(NUM_VECTORS):
    base = v * VEC_DIM
    for g in range(12):
        chunk = inp_fp16[base + g*64 : base + (g+1)*64]
        fwht_out.extend(fwht_fp16([int(x) for x in chunk]))
fwht_f = np.array([fp16_to_float(x) for x in fwht_out])
fwht_ch_max = np.max(np.abs(fwht_f.reshape(NUM_VECTORS, VEC_DIM)), axis=0)

inp_s = np.std(inp)
fwht_s = np.std(fwht_f)
n_in = np.sum(np.abs(inp) > 5 * inp_s)
n_out = np.sum(np.abs(fwht_f) > 5 * fwht_s)
osr = (n_in - n_out) / max(n_in, 1) * 100

print(f"  Outliers (>5sigma each): {n_in} -> {n_out}")
print(f"    Before: |val| > 5*{inp_s:.1f} = {5*inp_s:.0f}")
print(f"    After:  |val| > 5*{fwht_s:.1f} = {5*fwht_s:.0f} (std increased by {fwht_s/inp_s:.1f}x)")
print(f"  Channel max: P50={np.percentile(fwht_ch_max,50):.0f} Max={np.max(fwht_ch_max):.0f} (ratio {np.max(fwht_ch_max)/np.percentile(fwht_ch_max,50):.1f}x)")
print(f"  INT8 SNR (after FWHT): {quant_snr(fwht_f, 8):.1f} dB  (+{quant_snr(fwht_f,8)-quant_snr(inp,8):.1f} dB)")

print("\n" + "=" * 60)
print("3. METRICS for Hadamard Quality")
print("=" * 60)
cv = lambda x: np.std(np.max(np.abs(x.reshape(NUM_VECTORS,VEC_DIM)),axis=0)) / (np.mean(np.max(np.abs(x.reshape(NUM_VECTORS,VEC_DIM)),axis=0)) + 1e-10)
r50 = lambda x: np.max(np.abs(x.reshape(NUM_VECTORS,VEC_DIM)),axis=0)
mx_r = np.max(r50(fwht_f)) / np.percentile(r50(fwht_f), 50)
print(f"  1) Channel Uniformity (CV):          {cv(fwht_f):.2f}     [target <0.5]")
print(f"  2) INT8 Quantization SNR:            {quant_snr(fwht_f,8):.1f} dB [target >40 dB]")
print(f"  3) Max/P50 ratio:                    {mx_r:.1f}x   [target <5x]")
print(f"  4) SNR gain over no-FWHT:            +{quant_snr(fwht_f,8)-quant_snr(inp,8):.1f} dB")

print("\n" + "=" * 60)
print("4. INT8 Hadamard Cascade: FP16->INT8->INT4")
print("=" * 60)

# INT8 quantize after FP16 FWHT (round to INT8, then back to float for second FWHT)
step8 = 2 * np.max(np.abs(fwht_f)) / 256.0
int8_vals = np.round(fwht_f / step8).clip(-128, 127).astype(np.float64)

# INT8 FWHT (second stage): convert int values to FP16 encoding, run FWHT, decode
int8_fwht_f = []
for v in range(NUM_VECTORS):
    base = v * VEC_DIM
    for g in range(12):
        chunk_f = int8_vals[base + g*64 : base + (g+1)*64]
        fp16_enc = [float_to_fp16(float(x)) for x in chunk_f]
        int8_fwht_f.extend(fwht_fp16(fp16_enc))
int8_fwht_f = np.array([fp16_to_float(x) for x in int8_fwht_f])

print(f"  FP16 -> INT8 step:       {step8:.1f}")
print(f"  INT8 -> INT8 FWHT range: [{np.min(int8_fwht_f):.0f}, {np.max(int8_fwht_f):.0f}]")
print(f"  INT4 SNR via cascade:    {quant_snr(int8_fwht_f, 4):.1f} dB")
print(f"  INT4 SNR direct (no FWHT): {quant_snr(inp, 4):.1f} dB")

print("\n" + "=" * 60)
print("SUMMARY")
print("=" * 60)
print(f"""
  FP16 FWHT:  Eliminates channel outliers for INT8 quantization.
              OSR={osr:.0f}%, INT8 SNR gain +{quant_snr(fwht_f,8)-quant_snr(inp,8):.1f} dB

  INT8 FWHT:  Second smoothing stage enabling INT4 quantization.
              Cascade INT4 SNR: {quant_snr(int8_fwht_f, 4):.1f} dB vs direct {quant_snr(inp, 4):.1f} dB
""")
