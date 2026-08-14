"""
Operator analysis wrapper for FWHT and Resize visualization.
Called by server.py WebSocket handlers; delegates to golden model / viz scripts.
"""

import sys
import os
import json
import base64
import subprocess
from pathlib import Path
from typing import Dict, Optional

_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
_SOFT_VERIFY  = _PROJECT_ROOT / "test" / "soft-verification"
_VISUALIZE    = _PROJECT_ROOT / "test" / "Visualization"
_INPUT_DATA   = _PROJECT_ROOT / "test" / "input-data"
_OUTPUT_DATA  = _PROJECT_ROOT / "test" / "output-data" / "hardware"
_SIM_DIR      = _PROJECT_ROOT / "sim"


def _run_py(script: Path, args: list, timeout: int = 120) -> str:
    """Run a Python script and return its stdout."""
    cp = subprocess.run(
        [sys.executable, str(script)] + args,
        cwd=str(_PROJECT_ROOT), capture_output=True, text=True, timeout=timeout
    )
    return cp.stdout + cp.stderr


def _png_b64(path: str) -> Optional[str]:
    """Read a PNG file and return its base64 data URI."""
    try:
        with open(path, "rb") as f:
            data = base64.b64encode(f.read()).decode()
        return f"data:image/png;base64,{data}"
    except Exception:
        return None


def run_fwht_analysis() -> dict:
    """Run FWHT golden + visualization, return {png_b64, stats}."""
    inp_mem  = str(_INPUT_DATA / "fwht-input-768x30.mem")
    gold_mem = str(_INPUT_DATA / "fwht-golden-768x30.mem")
    hw_mem   = str(_OUTPUT_DATA / "fwht-output-768x30.mem")
    wave_png = str(_VISUALIZE / "fwht_waveform.png")

    # 1. Golden model
    golden_script = _SOFT_VERIFY / "fwht_golden.py"
    _run_py(golden_script, ["--analyze", inp_mem, "-o", gold_mem])

    # 2. Waveform visualization
    viz_script = _VISUALIZE / "visualize_fwht.py"
    _run_py(viz_script, ["-i", inp_mem, "-g", gold_mem, "-w", hw_mem, "-o", wave_png])

    # 3. Read quant stats
    quant_script = _SOFT_VERIFY / "quant_analysis.py"
    stats_out = _run_py(quant_script, [])

    # Parse SNR from output
    stats = {"snr_int8_fwht": "N/A", "snr_gain": "N/A", "cv": "N/A"}
    for line in stats_out.split("\n"):
        if "INT8 SNR (after FWHT):" in line:
            stats["snr_int8_fwht"] = line.split(":")[-1].strip()
        elif "SNR gain" in line:
            stats["snr_gain"] = line.split("+")[-1].strip()
        elif "Channel Uniformity" in line and "CV" in line:
            stats["cv"] = line.split(":")[-1].strip()

    return {
        "png_b64": _png_b64(wave_png),
        "stats": stats,
    }


def run_resize_analysis() -> dict:
    """Run Resize golden + HW comparison, return images and similarity metrics."""
    import numpy as np
    from pathlib import Path as _Path

    sys.path.insert(0, str(_SOFT_VERIFY))
    from resize_golden import resize_crop_golden, blocks_to_image as r_blocks_to_image

    inp_mem  = str(_INPUT_DATA / "resize-input-640x480.mem")
    hw_mem   = str(_OUTPUT_DATA / "resize-output-640x480.mem")
    inp_png  = str(_INPUT_DATA / "resize-input-640x480-final.png")
    hw_png   = str(_OUTPUT_DATA / "resize-output-640x480-v5.png")
    gold_png = str(_OUTPUT_DATA / "resize-golden-640x480.png")

    SRC_W, SRC_H = 640, 480
    DST_W, DST_H = 224, 224

    viz_script = _VISUALIZE / "visualize_data.py"

    # Generate input PNG if missing
    if not _Path(inp_png).exists():
        _run_py(viz_script, ["-f", inp_mem, "-W", str(SRC_W), "-o", inp_png])

    # Generate hardware output PNG if missing
    if not _Path(hw_png).exists():
        _run_py(viz_script, ["-f", hw_mem, "-W", str(DST_W), "-o", hw_png])

    # ---- Golden model ----
    # Read input blocks
    src_blocks = []
    with open(inp_mem) as f:
        for line in f:
            line = line.strip()
            if line and len(line) == 128:
                src_blocks.append(int(line, 16))

    # Run golden model
    golden_blocks = resize_crop_golden(src_blocks, SRC_W, SRC_H, DST_W, DST_H, crop_enable=True)

    # Read hardware output blocks
    hw_blocks = []
    with open(hw_mem) as f:
        for line in f:
            line = line.strip()
            if line and len(line) == 128:
                hw_blocks.append(int(line, 16))

    # ---- Similarity metrics ----
    g_img = r_blocks_to_image(golden_blocks, DST_W).astype(np.float64).flatten()
    h_img = r_blocks_to_image(hw_blocks, DST_W).astype(np.float64).flatten()

    eps = 1e-10
    cosine = float(np.dot(g_img, h_img) / (np.linalg.norm(g_img) * np.linalg.norm(h_img) + eps))
    mse    = float(np.mean((g_img - h_img) ** 2))
    psnr   = float(10 * np.log10((255**2) / (mse + eps)))
    max_err = float(np.max(np.abs(g_img - h_img)))
    mae     = float(np.mean(np.abs(g_img - h_img)))

    # ---- Write golden PNG ----
    import struct
    golden_pixels = r_blocks_to_image(golden_blocks, DST_W).astype(np.uint8)
    g_h, g_w = golden_pixels.shape[:2]
    _golden_rgb = np.zeros((g_h, g_w, 3), dtype=np.uint8)
    _golden_rgb[:,:,0] = golden_pixels[:,:,0]  # R
    _golden_rgb[:,:,1] = golden_pixels[:,:,1]  # G
    _golden_rgb[:,:,2] = golden_pixels[:,:,2]  # B
    try:
        import cv2
        cv2.imwrite(gold_png, _golden_rgb[:,:,::-1])  # RGB -> BGR for cv2
    except ImportError:
        from PIL import Image
        Image.fromarray(_golden_rgb).save(gold_png)

    return {
        "input_b64":  _png_b64(inp_png),
        "golden_b64": _png_b64(gold_png),
        "hw_b64":     _png_b64(hw_png),
        "cosine":     round(cosine, 6),
        "psnr":       round(psnr, 1),
        "max_err":    round(max_err, 1),
        "mae":        round(mae, 2),
        "params": {
            "src": f"{SRC_W}x{SRC_H}",
            "crop": "480x480 (offset_x=80)",
            "dst": f"{DST_W}x{DST_H}",
        }
    }


def run_gather_analysis() -> dict:
    """Generate synthetic gather demo: 256x256 matrix -> 77 indices -> 77x256 output."""
    import io, base64 as _b64
    import numpy as np
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    rng = np.random.RandomState(42)
    N, D = 256, 256
    M = 77  # CLIP text tokens

    # Generate matrix with per-row gradient colors (rainbow sine pattern)
    # Each row has a distinct hue, making gather visually obvious
    x = np.linspace(0, 3 * np.pi, D)
    matrix = np.zeros((N, D), dtype=np.float64)
    for i in range(N):
        phase = i * 2 * np.pi / N  # unique phase per row (rainbow)
        matrix[i] = np.sin(x + phase) * 0.6 + np.sin(2 * x + phase * 1.7) * 0.3 + np.sin(3 * x + phase * 0.5) * 0.1
        matrix[i] = (matrix[i] + 1.0) / 2.0  # normalize to [0,1]

    # Random indices with repeats
    indices = rng.randint(0, N, size=M)
    output = matrix[indices]

    def _fig_to_b64(fig):
        buf = io.BytesIO()
        fig.savefig(buf, format='png', dpi=100, bbox_inches='tight')
        plt.close(fig)
        buf.seek(0)
        return f"data:image/png;base64,{_b64.b64encode(buf.read()).decode()}"

    # ---- 1. Input heatmap (no highlights, rows are naturally distinct) ----
    fig, ax = plt.subplots(figsize=(6, 6))
    ax.imshow(matrix, aspect='auto', cmap='turbo', interpolation='nearest')
    ax.set_title(f'Input Matrix ({N}x{D})')
    ax.set_xlabel('Dimension'); ax.set_ylabel('Row index')
    input_b64 = _fig_to_b64(fig)

    # ---- 2. Index map scatter ----
    fig, ax = plt.subplots(figsize=(6, 3))
    ax.scatter(range(M), indices, c='orange', s=8, alpha=0.8)
    ax.set_xlim(0, M); ax.set_ylim(0, N)
    ax.set_title(f'Index Mapping ({M} indices, {len(set(indices.tolist()))} unique)')
    ax.set_xlabel('Output position'); ax.set_ylabel('Input row index')
    index_b64 = _fig_to_b64(fig)

    # ---- 3. Output heatmap ----
    fig, ax = plt.subplots(figsize=(6, 2.5))
    ax.imshow(output, aspect='auto', cmap='turbo', interpolation='nearest')
    ax.set_title(f'Output Matrix ({M}x{D})')
    ax.set_xlabel('Dimension'); ax.set_ylabel('Output row')
    output_b64 = _fig_to_b64(fig)

    unique = len(set(indices.tolist()))
    return {
        "input_b64": input_b64,
        "index_b64": index_b64,
        "output_b64": output_b64,
        "unique_rows": unique,
        "total_rows": N,
        "output_rows": M,
    }
