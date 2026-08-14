import sys
import os
import yaml
import time
import numpy as np
from PIL import Image

sys.path.append(r"../../modelzoo")

from icraft.xir import *
from icraft.xrt import *
from icraft.zg330backend import *
from icraft.host_backend import *

from pyrtutils.icraft_utils import *
from pyrtutils.Netinfo import Netinfo
from pyrtutils.utils import *
from pyrtutils.et_device import *
from pyrtutils.calctime_utils import *

from transformers import CLIPTokenizer


TIME_RECORDS = []


def add_time_record(module, stage, elapsed_s, extra=""):
    """记录并打印一次计时结果。"""
    record = {
        "module": module,
        "stage": stage,
        "elapsed_s": float(elapsed_s),
        "elapsed_ms": float(elapsed_s) * 1000.0,
        "extra": str(extra),
    }
    TIME_RECORDS.append(record)
    print(f"[time] {module:<18s} {stage:<18s} {record['elapsed_ms']:.3f} ms ({record['elapsed_s']:.6f} s) {extra}")
    return record


def timed_forward(session, input_tensors, module, extra=""):
    """对一次 session.forward 调用计时。"""
    t0 = time.perf_counter()
    outputs = session.forward(input_tensors)
    elapsed_s = time.perf_counter() - t0
    add_time_record(module, "forward", elapsed_s, extra)
    return outputs


def save_time_report(out_dir):
    """将计时结果保存为 txt 和 csv，便于后续写报告或画图。"""
    os.makedirs(out_dir, exist_ok=True)
    txt_path = os.path.join(out_dir, "timing_report.txt")
    csv_path = os.path.join(out_dir, "timing_report.csv")

    with open(txt_path, "w", encoding="utf-8") as f:
        f.write("module\tstage\telapsed_ms\telapsed_s\textra\n")
        for r in TIME_RECORDS:
            f.write(
                f"{r['module']}\t{r['stage']}\t"
                f"{r['elapsed_ms']:.3f}\t{r['elapsed_s']:.6f}\t{r['extra']}\n"
            )

    with open(csv_path, "w", encoding="utf-8") as f:
        f.write("module,stage,elapsed_ms,elapsed_s,extra\n")
        for r in TIME_RECORDS:
            extra = r["extra"].replace("\"", "'")
            f.write(
                f"{r['module']},{r['stage']},"
                f"{r['elapsed_ms']:.3f},{r['elapsed_s']:.6f},\"{extra}\"\n"
            )

    print("saved timing report to:", txt_path)
    print("saved timing csv to:", csv_path)



def load_yaml(path):
    path = os.path.abspath(path)
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.load(f, Loader=yaml.FullLoader)
    return cfg, os.path.dirname(path)


def resolve_path(base_dir, path):
    if path is None:
        return None
    if os.path.isabs(path):
        return path
    return os.path.abspath(os.path.join(base_dir, path))


def l2_normalize(x, axis=-1, eps=1e-12):
    x = np.asarray(x, dtype=np.float32)
    norm = np.linalg.norm(x, axis=axis, keepdims=True)
    norm = np.maximum(norm, eps)
    return x / norm


def init_session_from_cfg(cfg, yaml_dir, name="model"):
    folder_path = cfg["imodel"]["dir"]
    stage = cfg["imodel"]["stage"]
    run_backend = cfg["imodel"]["runbackend"]
    cuda_mode = cfg["imodel"]["cudamode"]
    open_speed_mode = cfg["imodel"]["speedmode"]
    open_compress_ftmp = cfg["imodel"]["compressFtmp"]

    mmu_mode = True
    ocm_option = 0

    json_path, raw_path = getJrPath(folder_path, stage, run_backend)

    ip = str(cfg["imodel"]["ip"])

    print(f"\n========== init {name} ==========")
    print("run_backend =", run_backend)
    print("JSON_PATH =", json_path)
    print("RAW_PATH  =", raw_path)
    print("json exists =", os.path.isfile(json_path))
    print("raw exists  =", os.path.isfile(raw_path))

    network = loadNetwork(json_path, raw_path)
    print(f"{name}: load network done")
    print(f"{name}: network name =", network.name)

    netinfo = Netinfo(network)
    print(f"{name}: build netinfo done")

    device = openDevice(run_backend, ip, netinfo.mmu or mmu_mode, cuda_mode)
    print(f"{name}: open device done")

    session = initSession(
        run_backend,
        network,
        device,
        ocm_option,
        netinfo.mmu or mmu_mode,
        open_speed_mode,
        open_compress_ftmp
    )
    print(f"{name}: init session done")

    session.enableTimeProfile(True)
    session.apply()
    print(f"{name}: session apply done")
    print("=================================\n")

    return {
        "cfg": cfg,
        "yaml_dir": yaml_dir,
        "run_backend": run_backend,
        "network": network,
        "netinfo": netinfo,
        "device": device,
        "session": session,
    }


def close_runtime(rt):
    if rt is None:
        return

    run_backend = rt["run_backend"]
    device = rt["device"]

    if run_backend != "host":
        try:
            xrt.Device.Close(device)
        except Exception as e:
            print("warning: Device.Close failed:", repr(e))


def run_text_encoder_one(rt, tokenizer, text, max_len):
    network = rt["network"]
    session = rt["session"]

    enc = tokenizer(
        text,
        padding="max_length",
        truncation=True,
        max_length=max_len
    )

    # 注意：你的原文本编码器里这里必须是 float32
    # 当前 runtime 中 Gather 的 indices 实际按 fp32 传递
    input_ids = np.array([enc["input_ids"]], dtype=np.float32)

    print("\n[text encoder]")
    print("prompt:", text)
    print("input_ids shape:", input_ids.shape)
    print("input_ids dtype:", input_ids.dtype)

    input_tensor = numpy2Tensor(input_ids, network)
    outputs = timed_forward(session, [input_tensor], "text_encoder", extra=f"prompt={text}")

    out_host = outputs[0].to(HostDevice.MemRegion())
    out_np = np.array(out_host).astype(np.float32)

    feature = out_np.reshape(-1)

    print("text feature shape:", out_np.shape)
    print("text feature dim:", feature.shape[0])
    print("text feature first 8:", feature[:8])

    return feature


def run_text_encoder_batch(text_yaml_path, texts):
    text_cfg, text_yaml_dir = load_yaml(text_yaml_path)

    tokenizer_dir = text_cfg["text"]["tokenizer_dir"]
    tokenizer_dir = resolve_path(text_yaml_dir, tokenizer_dir)

    max_len = int(text_cfg["text"]["max_len"])

    print("load tokenizer from:", tokenizer_dir)
    tokenizer = CLIPTokenizer.from_pretrained(
        tokenizer_dir,
        local_files_only=True
    )
    print("tokenizer loaded")
    print("bos_token_id:", tokenizer.bos_token_id)
    print("eos_token_id:", tokenizer.eos_token_id)
    print("pad_token_id:", tokenizer.pad_token_id)

    rt = None

    try:
        batch_t0 = time.perf_counter()
        rt = init_session_from_cfg(text_cfg, text_yaml_dir, name="text_encoder")

        features = []
        for i, text in enumerate(texts):
            print(f"\n---------- run text {i + 1}/{len(texts)} ----------")
            feat = run_text_encoder_one(rt, tokenizer, text, max_len)
            features.append(feat)

        text_features = np.stack(features, axis=0).astype(np.float32)
        batch_elapsed = time.perf_counter() - batch_t0
        add_time_record(
            "text_encoder",
            "total",
            batch_elapsed,
            extra=f"num_texts={len(texts)}, avg={batch_elapsed / max(len(texts), 1) * 1000.0:.3f} ms/text"
        )

        return text_features

    finally:
        close_runtime(rt)


def preprocess_clip_image(image_path, input_h, input_w, mode="clip_float"):
    image = Image.open(image_path).convert("RGB")

    w, h = image.size

    # 先把短边缩放到目标尺寸
    scale = input_h / min(w, h)
    new_w = int(round(w * scale))
    new_h = int(round(h * scale))
    image = image.resize((new_w, new_h), Image.BICUBIC)

    # 再中心裁剪到目标尺寸
    left = (new_w - input_w) // 2
    top = (new_h - input_h) // 2
    image = image.crop((left, top, left + input_w, top + input_h))

    img = np.array(image)

    if mode == "raw_uint8":
        return img.astype(np.uint8)

    elif mode == "clip_float":
        mean = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
        std = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)

        img = img.astype(np.float32) / 255.0
        img = (img - mean) / std
        img = np.transpose(img, (2, 0, 1))  # HWC -> CHW
        return img.astype(np.float32)

    else:
        raise ValueError(f"Unsupported preprocess mode: {mode}")


def run_image_encoder(image_yaml_path, image_path_override=None):
    image_total_t0 = time.perf_counter()
    image_cfg, image_yaml_dir = load_yaml(image_yaml_path)

    image_path = image_path_override
    if image_path is None:
        image_path = image_cfg["image"]["image_path"]

    image_path = resolve_path(image_yaml_dir, image_path)
    preprocess_mode = image_cfg["image"]["preprocess_mode"]

    save_npy = image_cfg.get("save", {}).get("save_npy", True)
    save_dir = image_cfg.get("save", {}).get("save_dir", "./npy_out")
    save_prefix = image_cfg.get("save", {}).get("save_prefix", "clip_img")

    save_dir = resolve_path(image_yaml_dir, save_dir)
    os.makedirs(save_dir, exist_ok=True)

    rt = None

    try:
        rt = init_session_from_cfg(image_cfg, image_yaml_dir, name="image_encoder")

        network = rt["network"]
        session = rt["session"]

        net_inputs = network.inputs()
        net_outputs = network.outputs()

        print("image encoder inputs:")
        for i, inp in enumerate(net_inputs):
            print(f"  input[{i}] shape =", inp.tensorType().shape)

        print("image encoder outputs:")
        for i, out in enumerate(net_outputs):
            print(f"  output[{i}] shape =", out.tensorType().shape)

        in_shape = net_inputs[0].tensorType().shape
        if len(in_shape) != 4:
            raise RuntimeError(f"Unexpected image encoder input rank: {len(in_shape)}, shape={in_shape}")

        if in_shape[-1] == 3:
            layout = "NHWC"
            input_h, input_w = int(in_shape[1]), int(in_shape[2])
        elif in_shape[1] == 3:
            layout = "NCHW"
            input_h, input_w = int(in_shape[2]), int(in_shape[3])
        else:
            raise RuntimeError(f"Cannot infer input layout from shape={in_shape}")

        print("inferred image layout =", layout)
        print("input_h =", input_h, "input_w =", input_w)
        print("image_path =", image_path)

        if not os.path.isfile(image_path):
            raise FileNotFoundError(f"image_path not found: {image_path}")

        preprocess_t0 = time.perf_counter()
        img = preprocess_clip_image(image_path, input_h, input_w, preprocess_mode)
        add_time_record("image_encoder", "preprocess", time.perf_counter() - preprocess_t0, extra=os.path.basename(image_path))

        if layout == "NHWC":
            if preprocess_mode == "clip_float":
                img = np.transpose(img, (1, 2, 0))  # CHW -> HWC
            input_data = np.expand_dims(img, axis=0)
        else:
            if preprocess_mode == "raw_uint8":
                img = np.transpose(img, (2, 0, 1))  # HWC -> CHW
            input_data = np.expand_dims(img, axis=0)

        print("image input_data shape =", input_data.shape)
        print("image input_data dtype =", input_data.dtype)
        print("image input min/max =", input_data.min(), input_data.max())

        if save_npy:
            input_save_path = os.path.join(save_dir, f"{save_prefix}_input.npy")
            np.save(input_save_path, input_data)
            print(f"saved image input to: {input_save_path}")

        input_tensor = numpy2Tensor(input_data, network)

        print("\n[image encoder] forward")
        outputs = timed_forward(session, [input_tensor], "image_encoder", extra=os.path.basename(image_path))
        print("[image encoder] forward done")

        host_outputs = []
        host_output_nps = []

        for i, out in enumerate(outputs):
            out_host = out.to(HostDevice.MemRegion())
            out_np = np.array(out_host).astype(np.float32)
            host_outputs.append(out_host)
            host_output_nps.append(out_np)

            print(f"image output[{i}] shape:", out_np.shape)
            print(f"image output[{i}] dtype:", out_np.dtype)
            print(f"image output[{i}] min={out_np.min()}, max={out_np.max()}, mean={out_np.mean()}")
            print(f"image output[{i}] first 10 values:", out_np.flatten()[:10])

            if save_npy:
                out_path = os.path.join(save_dir, f"{save_prefix}_output{i}.npy")
                np.save(out_path, out_np)
                print(f"saved image output[{i}] to: {out_path}")

        if len(host_output_nps) == 0:
            raise RuntimeError("image encoder returned no outputs")

        image_feature = host_output_nps[0].reshape(-1).astype(np.float32)

        if save_npy:
            feat_path = os.path.join(save_dir, f"{save_prefix}_feat.npy")
            np.save(feat_path, image_feature)
            print(f"saved final image feature to: {feat_path}")

        add_time_record("image_encoder", "total", time.perf_counter() - image_total_t0, extra=os.path.basename(image_path))
        return image_feature

    finally:
        close_runtime(rt)


def compute_ranking(image_feature, text_features, labels):
    image_feature = image_feature.reshape(-1).astype(np.float32)
    text_features = text_features.astype(np.float32)

    if text_features.ndim != 2:
        raise RuntimeError(f"text_features should be 2D, got {text_features.shape}")

    if image_feature.shape[0] != text_features.shape[1]:
        raise RuntimeError(
            f"feature dim mismatch: image dim={image_feature.shape[0]}, "
            f"text dim={text_features.shape[1]}"
        )

    image_feature_n = l2_normalize(image_feature, axis=0)
    text_features_n = l2_normalize(text_features, axis=1)

    scores = text_features_n @ image_feature_n
    order = np.argsort(-scores)

    ranking = []
    for rank, idx in enumerate(order, start=1):
        ranking.append((rank, labels[idx], float(scores[idx])))

    return ranking, scores


def ask_five_texts():
    texts = []
    print("\n请输入 5 个候选文本，每次输入一个。")
    for i in range(5):
        while True:
            text = input(f"text[{i}] = ").strip()
            if text:
                texts.append(text)
                break
            print("文本不能为空，请重新输入。")
    return texts


if __name__ == "__main__":
    # 用法：
    # python clip_full_pipeline.py clip_text.yaml clip_img.yaml image.jpg
    #
    # image.jpg 可以不传，不传则使用 clip_img.yaml 里的 image.image_path

    if len(sys.argv) < 3:
        print("Usage:")
        print("  python clip_full_pipeline.py <clip_text.yaml> <clip_img.yaml> [image_path]")
        sys.exit(1)

    text_yaml_path = sys.argv[1]
    image_yaml_path = sys.argv[2]

    image_path_override = None
    if len(sys.argv) >= 4:
        image_path_override = sys.argv[3]

    # 1. 上位机输入 5 个文本
    labels = ask_five_texts()

    print("\n========== Input labels ==========")
    for i, label in enumerate(labels):
        print(f"[{i}] {label}")
    print("==================================\n")

    pipeline_t0 = time.perf_counter()

    # 2. 文本编码器逐条运行
    text_features = run_text_encoder_batch(text_yaml_path, labels)
    print("all text_features shape =", text_features.shape)

    # 3. 图像编码器运行
    image_feature = run_image_encoder(image_yaml_path, image_path_override)
    print("image_feature shape =", image_feature.shape)

    # 4. 计算相似度排名
    ranking_t0 = time.perf_counter()
    ranking, scores = compute_ranking(
        image_feature=image_feature,
        text_features=text_features,
        labels=labels
    )
    add_time_record("postprocess", "ranking", time.perf_counter() - ranking_t0, extra=f"num_labels={len(labels)}")
    add_time_record("full_pipeline", "total", time.perf_counter() - pipeline_t0, extra="after label input")

    print("\n========== CLIP cosine similarity ranking ==========")
    for rank, label, score in ranking:
        print(f"Top {rank:>2d}: {label:<30s} score = {score:.6f}")
    print("===================================================\n")

    # 5. 保存结果
    out_dir = os.path.abspath("./clip_full_pipeline_out")
    os.makedirs(out_dir, exist_ok=True)

    np.save(os.path.join(out_dir, "text_features.npy"), text_features)
    np.save(os.path.join(out_dir, "image_feature.npy"), image_feature)
    np.save(os.path.join(out_dir, "similarity_scores.npy"), scores)

    with open(os.path.join(out_dir, "clip_labels.txt"), "w", encoding="utf-8") as f:
        for label in labels:
            f.write(label + "\n")

    text_features_norm = l2_normalize(text_features, axis=1).astype(np.float32)
    text_features_norm.tofile(os.path.join(out_dir, "clip_text_features.bin"))

    with open(os.path.join(out_dir, "ranking.txt"), "w", encoding="utf-8") as f:
        for rank, label, score in ranking:
            f.write(f"Top {rank:>2d}: {label:<30s} score = {score:.6f}\n")

    save_time_report(out_dir)

    print("saved outputs to:", out_dir)
    print("  text_features.npy")
    print("  image_feature.npy")
    print("  similarity_scores.npy")
    print("  clip_labels.txt")
    print("  clip_text_features.bin")
    print("  ranking.txt")