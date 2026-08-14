import sys
import os
import time
import yaml
import cv2
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

    # 关键：你的文本模型当前要求 input_ids 按 float32 传入
    input_ids = np.array([enc["input_ids"]], dtype=np.float32)

    print("\n[text encoder]")
    print("prompt:", text)
    print("input_ids shape:", input_ids.shape)
    print("input_ids dtype:", input_ids.dtype)

    input_tensor = numpy2Tensor(input_ids, network)
    outputs = session.forward([input_tensor])

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
        rt = init_session_from_cfg(text_cfg, text_yaml_dir, name="text_encoder")

        features = []

        for i, text in enumerate(texts):
            print(f"\n---------- run text {i + 1}/{len(texts)} ----------")
            feat = run_text_encoder_one(rt, tokenizer, text, max_len)
            features.append(feat)

        text_features = np.stack(features, axis=0).astype(np.float32)

        return text_features

    finally:
        close_runtime(rt)


def preprocess_clip_image(image_path, input_h, input_w, mode="clip_float"):
    image = Image.open(image_path).convert("RGB")

    w, h = image.size

    scale = input_h / min(w, h)
    new_w = int(round(w * scale))
    new_h = int(round(h * scale))

    image = image.resize((new_w, new_h), Image.BICUBIC)

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
        img = np.transpose(img, (2, 0, 1))

        return img.astype(np.float32)

    else:
        raise ValueError(f"Unsupported preprocess mode: {mode}")


def capture_image_from_camera(save_dir, camera_id=0, width=1280, height=720):
    os.makedirs(save_dir, exist_ok=True)

    print("\n========== Camera Capture ==========")
    print("camera_id =", camera_id)
    print("按 空格 或 s 拍照")
    print("按 q 或 ESC 退出")
    print("====================================")

    if os.name == "nt":
        cap = cv2.VideoCapture(camera_id, cv2.CAP_DSHOW)
    else:
        cap = cv2.VideoCapture(camera_id)

    if not cap.isOpened():
        raise RuntimeError(f"无法打开摄像头 camera_id={camera_id}")

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)

    # 预热几帧
    for _ in range(5):
        cap.read()

    captured_frame = None

    while True:
        ret, frame = cap.read()

        if not ret or frame is None:
            print("Warning: 摄像头读取失败")
            continue

        preview = frame.copy()

        cv2.putText(
            preview,
            "Press SPACE or S to capture, Q/ESC to quit",
            (30, 40),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.9,
            (0, 255, 0),
            2,
            cv2.LINE_AA
        )

        cv2.imshow("CLIP Camera Capture", preview)

        key = cv2.waitKey(1) & 0xFF

        if key == ord("q") or key == 27:
            cap.release()
            cv2.destroyAllWindows()
            raise RuntimeError("用户取消拍照")

        if key == ord("s") or key == 32:
            captured_frame = frame.copy()
            break

    cap.release()
    cv2.destroyAllWindows()

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    image_path = os.path.join(save_dir, f"captured_{timestamp}.jpg")

    ok = cv2.imwrite(image_path, captured_frame)

    if not ok:
        raise RuntimeError(f"保存拍照图片失败: {image_path}")

    print("captured image saved to:", image_path)
    print("captured image shape:", captured_frame.shape)

    return image_path


def run_image_encoder(image_yaml_path, image_path_override=None):
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

        img = preprocess_clip_image(image_path, input_h, input_w, preprocess_mode)

        if layout == "NHWC":
            if preprocess_mode == "clip_float":
                img = np.transpose(img, (1, 2, 0))
            input_data = np.expand_dims(img, axis=0)
        else:
            if preprocess_mode == "raw_uint8":
                img = np.transpose(img, (2, 0, 1))
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
        outputs = session.forward([input_tensor])
        print("[image encoder] forward done")

        host_output_nps = []

        for i, out in enumerate(outputs):
            out_host = out.to(HostDevice.MemRegion())
            out_np = np.array(out_host).astype(np.float32)
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
    # python clip_full_pipeline_camera.py clip_text.yaml clip_img.yaml
    #
    # 程序会：
    # 1. 输入 5 个文本
    # 2. 跑文本编码器
    # 3. 打开摄像头，按空格或 s 拍照
    # 4. 跑图像编码器
    # 5. 输出相似度排名

    if len(sys.argv) < 3:
        print("Usage:")
        print("  python clip_full_pipeline_camera.py <clip_text.yaml> <clip_img.yaml>")
        sys.exit(1)

    text_yaml_path = sys.argv[1]
    image_yaml_path = sys.argv[2]

    labels = ask_five_texts()

    print("\n========== Input labels ==========")
    for i, label in enumerate(labels):
        print(f"[{i}] {label}")
    print("==================================\n")

    # 1. 文本编码器逐条运行
    text_features = run_text_encoder_batch(text_yaml_path, labels)
    print("all text_features shape =", text_features.shape)

    # 2. 打开摄像头，按键拍照
    out_dir = os.path.abspath("./clip_full_pipeline_out")
    os.makedirs(out_dir, exist_ok=True)

    captured_image_path = capture_image_from_camera(
        save_dir=out_dir,
        camera_id=0,
        width=1280,
        height=720
    )

    # 3. 图像编码器处理拍照图片
    image_feature = run_image_encoder(
        image_yaml_path=image_yaml_path,
        image_path_override=captured_image_path
    )

    print("image_feature shape =", image_feature.shape)

    # 4. 计算相似度排名
    ranking, scores = compute_ranking(
        image_feature=image_feature,
        text_features=text_features,
        labels=labels
    )

    print("\n========== CLIP cosine similarity ranking ==========")
    for rank, label, score in ranking:
        print(f"Top {rank:>2d}: {label:<30s} score = {score:.6f}")
    print("===================================================\n")

    # 5. 保存结果
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

    print("saved outputs to:", out_dir)
    print("  captured image:", captured_image_path)
    print("  text_features.npy")
    print("  image_feature.npy")
    print("  similarity_scores.npy")
    print("  clip_labels.txt")
    print("  clip_text_features.bin")
    print("  ranking.txt")