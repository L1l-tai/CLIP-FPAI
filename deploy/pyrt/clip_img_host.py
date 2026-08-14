import sys
import os
import yaml
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


def l2_normalize(x, axis=-1, eps=1e-12):
    x = np.asarray(x, dtype=np.float32)
    norm = np.linalg.norm(x, axis=axis, keepdims=True)
    norm = np.maximum(norm, eps)
    return x / norm


def load_clip_labels(labels_path):
    if not os.path.isfile(labels_path):
        raise FileNotFoundError(f"Cannot find clip labels file: {labels_path}")

    labels = []
    with open(labels_path, "r", encoding="utf-8") as f:
        for line in f:
            label = line.strip()
            if label:
                labels.append(label)

    if len(labels) == 0:
        raise RuntimeError(f"clip_labels.txt is empty: {labels_path}")

    return labels


def load_clip_text_features(features_path, num_labels, feature_dim):
    if not os.path.isfile(features_path):
        raise FileNotFoundError(f"Cannot find clip text features file: {features_path}")

    text_features = np.fromfile(features_path, dtype=np.float32)

    expected = num_labels * feature_dim
    if text_features.size != expected:
        raise RuntimeError(
            "clip_text_features.bin size mismatch: "
            f"got {text_features.size} float32 values, "
            f"expected {num_labels} * {feature_dim} = {expected}. "
            f"file={features_path}"
        )

    text_features = text_features.reshape(num_labels, feature_dim)
    return text_features.astype(np.float32)


def compute_clip_similarity_ranking(image_feature, text_features, labels, topk=None):
    image_feature = np.asarray(image_feature, dtype=np.float32).reshape(-1)
    text_features = np.asarray(text_features, dtype=np.float32)

    if text_features.ndim != 2:
        raise RuntimeError(f"text_features should be 2D, got shape={text_features.shape}")

    num_labels, feature_dim = text_features.shape

    if image_feature.shape[0] != feature_dim:
        raise RuntimeError(
            f"image feature dim mismatch: image_feature dim={image_feature.shape[0]}, "
            f"text feature dim={feature_dim}"
        )

    if len(labels) != num_labels:
        raise RuntimeError(
            f"labels count mismatch: labels={len(labels)}, text_features rows={num_labels}"
        )

    image_feature = l2_normalize(image_feature, axis=0)
    text_features = l2_normalize(text_features, axis=1)

    scores = text_features @ image_feature
    order = np.argsort(-scores)

    if topk is not None:
        order = order[:topk]

    ranking = []
    for rank, idx in enumerate(order, start=1):
        ranking.append(
            {
                "rank": rank,
                "index": int(idx),
                "label": labels[idx],
                "score": float(scores[idx]),
            }
        )

    return ranking, scores


if __name__ == "__main__":
    # --------------------------------------------------
    # 1. 读取 yaml
    # --------------------------------------------------
    Yaml_Path = "../cfg/clip_img.yaml"

    if len(sys.argv) < 2:
        mprint("Info: 未传入yaml参数, 读入默认yaml文件: {} 进行配置.".format(Yaml_Path), VERBOSE, 0)
    elif len(sys.argv) == 2:
        Yaml_Path = sys.argv[1]
        mprint("Info: 传入yaml文件: {} 进行配置.".format(Yaml_Path), VERBOSE, 0)
    else:
        mprint("Info: 传入参数数量错误, 请检查运行命令!", VERBOSE, 0)
        sys.exit(1)

    Yaml_Path = os.path.abspath(Yaml_Path)
    yaml_dir = os.path.dirname(Yaml_Path)

    cfg = yaml.load(open(Yaml_Path, "r", encoding="utf-8"), Loader=yaml.FullLoader)

    # --------------------------------------------------
    # 2. 模型与运行配置
    # --------------------------------------------------
    folderPath = cfg["imodel"]["dir"]
    stage = cfg["imodel"]["stage"]
    runBackend = cfg["imodel"]["runbackend"]
    cudamode = cfg["imodel"]["cudamode"]
    openSpeedmode = cfg["imodel"]["speedmode"]
    openCompressFtmp = cfg["imodel"]["compressFtmp"]

    mmuMode = True
    ocmOption = 0

    JSON_PATH, RAW_PATH = getJrPath(folderPath, stage, runBackend)

    ip = str(cfg["imodel"]["ip"])
    dump_output = cfg["imodel"]["dump_output"]
    dump_format = cfg["imodel"]["dump_format"]
    log_path = os.path.abspath(cfg["imodel"]["log_path"])

    # --------------------------------------------------
    # 3. 图像配置
    # --------------------------------------------------
    image_path = cfg["image"]["image_path"]
    preprocess_mode = cfg["image"]["preprocess_mode"]

    if not os.path.isabs(image_path):
        image_path = os.path.abspath(os.path.join(yaml_dir, image_path))

    # --------------------------------------------------
    # 4. 特征保存配置
    # --------------------------------------------------
    save_npy = cfg.get("save", {}).get("save_npy", True)
    save_dir = cfg.get("save", {}).get("save_dir", "./npy_out")
    save_prefix = cfg.get("save", {}).get("save_prefix", "clip_img")

    if not os.path.isabs(save_dir):
        save_dir = os.path.abspath(os.path.join(yaml_dir, save_dir))

    os.makedirs(save_dir, exist_ok=True)

    # --------------------------------------------------
    # 5. CLIP 文本标签与文本特征
    # --------------------------------------------------
    labels_path = os.path.join(yaml_dir, "clip_labels.txt")
    text_features_path = os.path.join(yaml_dir, "clip_text_features.bin")

    print("CLIP labels path        =", labels_path)
    print("CLIP text features path =", text_features_path)

    labels = load_clip_labels(labels_path)
    print(f"loaded {len(labels)} clip labels:")
    for i, label in enumerate(labels):
        print(f"  [{i}] {label}")

    # --------------------------------------------------
    # 6. 加载 network
    # --------------------------------------------------
    print("step 1: load network")
    print("JSON_PATH =", JSON_PATH)
    print("RAW_PATH  =", RAW_PATH)
    print("json exists =", os.path.isfile(JSON_PATH))
    print("raw exists  =", os.path.isfile(RAW_PATH))

    if os.path.isfile(JSON_PATH):
        print("json size =", os.path.getsize(JSON_PATH))
    if os.path.isfile(RAW_PATH):
        print("raw size  =", os.path.getsize(RAW_PATH))

    network = loadNetwork(JSON_PATH, RAW_PATH)
    print("load network done")
    print("network name:", network.name)
    print("step 1 done")

    # --------------------------------------------------
    # 7. Netinfo
    # --------------------------------------------------
    print("step 2: build netinfo")
    netinfo = Netinfo(network)
    print("step 2 done")

    print("")
    print("========== Runtime / NetInfo Debug ==========")
    print("runBackend          =", runBackend)
    print("ip                  =", ip)
    print("cudamode            =", cudamode)
    print("ocmOption           =", ocmOption)
    print("cfg speedmode       =", openSpeedmode)
    print("cfg compressFtmp    =", openCompressFtmp)
    print("script mmuMode      =", mmuMode)
    print("netinfo.mmu         =", getattr(netinfo, "mmu", None))
    print("passed mmu          =", getattr(netinfo, "mmu", False) or mmuMode)
    print("ImageMake_on        =", getattr(netinfo, "ImageMake_on", None))
    print("DetPost_on          =", getattr(netinfo, "DetPost_on", None))
    print("inp_shape_opid      =", getattr(netinfo, "inp_shape_opid", None))
    print("i_shape             =", getattr(netinfo, "i_shape", None))
    print("i_cubic             =", getattr(netinfo, "i_cubic", None))

    if hasattr(netinfo, "ImageMakes_"):
        print("ImageMakes_ len     =", len(netinfo.ImageMakes_))
        for i, imk in enumerate(netinfo.ImageMakes_):
            print("  ImageMake[{}].op_id = {}".format(i, getattr(imk, "op_id", None)))

    print("=============================================")
    print("")

    # --------------------------------------------------
    # 8. 打印输入输出信息
    # --------------------------------------------------
    print("network inputs:")
    net_inputs = network.inputs()
    net_outputs = network.outputs()

    for i, inp in enumerate(net_inputs):
        print(f"  input[{i}] shape =", inp.tensorType().shape)

    print("network outputs:")
    for i, out in enumerate(net_outputs):
        print(f"  output[{i}] shape =", out.tensorType().shape)

    # --------------------------------------------------
    # 9. 推断输入尺寸与布局
    # --------------------------------------------------
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

    print("inferred layout =", layout)
    print("input_h =", input_h, "input_w =", input_w)

    # --------------------------------------------------
    # 10. 图像预处理
    # --------------------------------------------------
    print("step 3: preprocess image")
    print("image_path =", image_path)

    if not os.path.isfile(image_path):
        raise FileNotFoundError(f"image_path not found: {image_path}")

    img = preprocess_clip_image(image_path, input_h, input_w, preprocess_mode)

    if layout == "NHWC":
        if preprocess_mode == "clip_float":
            img = np.transpose(img, (1, 2, 0))  # CHW -> HWC
        input_data = np.expand_dims(img, axis=0)
    else:
        if preprocess_mode == "raw_uint8":
            img = np.transpose(img, (2, 0, 1))  # HWC -> CHW
        input_data = np.expand_dims(img, axis=0)

    print("input_data shape =", input_data.shape)
    print("input_data dtype =", input_data.dtype)
    print("input min/max =", input_data.min(), input_data.max())
    print("step 3 done")

    input_save_path = os.path.join(save_dir, f"{save_prefix}_input.npy")
    np.save(input_save_path, input_data)
    print(f"saved input to: {input_save_path}")

    # --------------------------------------------------
    # 11. 打开 device
    # --------------------------------------------------
    print("step 4: open device")
    device = openDevice(runBackend, ip, netinfo.mmu or mmuMode, cudamode)
    print("step 4 done")

    # --------------------------------------------------
    # 12. 初始化 session
    # --------------------------------------------------
    print("step 5: init session")

    passed_mmu = netinfo.mmu or mmuMode

    print("========== initSession Args ==========")
    print("runBackend       =", runBackend)
    print("network          =", network.name)
    print("ocmOption        =", ocmOption)
    print("mmu              =", passed_mmu)
    print("openSpeedmode    =", openSpeedmode)
    print("openCompressFtmp =", openCompressFtmp)
    print("======================================")

    session = initSession(
        runBackend,
        network,
        device,
        ocmOption,
        passed_mmu,
        openSpeedmode,
        openCompressFtmp
    )

    print("step 5 done")

    print("step 6: enable profile")
    session.enableTimeProfile(True)
    print("step 6 done")

    print("step 7: apply")
    session.apply()
    print("step 7 done")

    # --------------------------------------------------
    # 13. numpy -> tensor
    # --------------------------------------------------
    print("step 8: numpy2Tensor")
    input_tensor = numpy2Tensor(input_data, network)
    print("step 8 done")

    # --------------------------------------------------
    # 14. forward
    # --------------------------------------------------
    print("step 9: forward")
    outputs = session.forward([input_tensor])
    print("step 9 done")

    # --------------------------------------------------
    # 15. 打印输出 + 保存输出
    # --------------------------------------------------
    print("step 10: print outputs")
    host_outputs = []
    host_output_nps = []

    for i, out in enumerate(outputs):
        out_host = out.to(HostDevice.MemRegion())
        out_np = np.array(out_host)
        host_outputs.append(out_host)
        host_output_nps.append(out_np)

        print(f"output[{i}] shape:", out_np.shape)
        print(f"output[{i}] dtype:", out_np.dtype)
        print(f"output[{i}] min={out_np.min()}, max={out_np.max()}, mean={out_np.mean()}")
        print(f"output[{i}] first 10 values:", out_np.flatten()[:10])

        if save_npy:
            out_path = os.path.join(save_dir, f"{save_prefix}_output{i}.npy")
            np.save(out_path, out_np)
            print(f"saved output[{i}] to: {out_path}")

    if len(host_output_nps) == 0:
        raise RuntimeError("No outputs returned by session.forward")

    image_feature = host_output_nps[0].astype(np.float32).reshape(-1)
    feature_dim = image_feature.shape[0]

    print("image feature dim =", feature_dim)

    if save_npy:
        feat_path = os.path.join(save_dir, f"{save_prefix}_feat.npy")
        np.save(feat_path, image_feature)
        print(f"saved final image feature to: {feat_path}")

    print("step 10 done")

    # --------------------------------------------------
    # 16. 加载文本特征并计算余弦相似度排名
    # --------------------------------------------------
    print("step 11: load text features and compute cosine similarity")

    text_features = load_clip_text_features(
        text_features_path,
        num_labels=len(labels),
        feature_dim=feature_dim
    )

    ranking, scores = compute_clip_similarity_ranking(
        image_feature=image_feature,
        text_features=text_features,
        labels=labels,
        topk=len(labels)
    )

    print("")
    print("========== CLIP cosine similarity ranking ==========")
    for item in ranking:
        print(
            "Top {:>2d}: {:<20s} score = {:.6f}".format(
                item["rank"],
                item["label"],
                item["score"]
            )
        )
    print("===================================================")
    print("")

    sim_save_path = os.path.join(save_dir, f"{save_prefix}_similarity_scores.npy")
    np.save(sim_save_path, scores)
    print(f"saved similarity scores to: {sim_save_path}")

    rank_save_path = os.path.join(save_dir, f"{save_prefix}_ranking.txt")
    with open(rank_save_path, "w", encoding="utf-8") as f:
        for item in ranking:
            f.write(
                "Top {:>2d}: {:<20s} score = {:.6f}\n".format(
                    item["rank"],
                    item["label"],
                    item["score"]
                )
            )
    print(f"saved ranking to: {rank_save_path}")

    print("step 11 done")

    # --------------------------------------------------
    # 17. dump 输出
    # --------------------------------------------------
    if dump_output:
        print("step 12: dump output")
        dumpOutputFtmp(network, host_outputs, dump_format, log_path)
        print("step 12 done")

    # --------------------------------------------------
    # 18. 板端计时
    # --------------------------------------------------
    if runBackend != "host":
        print("step 13: calctime")
        try:
            calctime_detail(runBackend, session, network)
        except Exception as e:
            import traceback
            print("warning: calctime skipped.")
            print("reason:", repr(e))
            traceback.print_exc()

        try:
            device.reset(1)
        except Exception as e:
            print("warning: device reset skipped.")
            print("reason:", repr(e))

        print("step 13 done")

    # --------------------------------------------------
    # 19. 关闭设备
    # --------------------------------------------------
    if runBackend != "host":
        xrt.Device.Close(device)