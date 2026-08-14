import sys
import os
import numpy as np
import yaml

# 先加 modelzoo_utils 路径，再导入 pyrtutils
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


if __name__ == "__main__":
    # -----------------------------
    # 1. 读取 yaml
    # -----------------------------
    Yaml_Path = "../cfg/clip_text.yaml"
    if len(sys.argv) < 2:
        mprint("Info: 未传入yaml参数, 读入默认yaml文件: {} 进行配置.".format(Yaml_Path), VERBOSE, 0)
    elif len(sys.argv) == 2:
        Yaml_Path = sys.argv[1]
        mprint("Info: 传入yaml文件: {} 进行配置.".format(Yaml_Path), VERBOSE, 0)
    else:
        mprint("Info: 传入参数数量错误, 请检查运行命令!", VERBOSE, 0)
        sys.exit(1)

    cfg = yaml.load(open(Yaml_Path, "r", encoding="utf-8"), Loader=yaml.FullLoader)

    # -----------------------------
    # 2. 模型与运行配置
    # -----------------------------
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

    # -----------------------------
    # 3. 文本配置
    # -----------------------------
    tokenizer_dir = cfg["text"]["tokenizer_dir"]
    prompt = cfg["text"]["prompt"]
    max_len = cfg["text"]["max_len"]

    # -----------------------------
    # 4. 特征保存配置（新增）
    # -----------------------------
    save_npy = cfg.get("save", {}).get("save_npy", True)
    save_dir = cfg.get("save", {}).get("save_dir", "./npy_out")
    save_prefix = cfg.get("save", {}).get("save_prefix", "clip_text")

    save_dir = os.path.abspath(save_dir)
    os.makedirs(save_dir, exist_ok=True)

    # -----------------------------
    # 5. tokenizer
    # -----------------------------
    print("step 1: load tokenizer")
    tokenizer = CLIPTokenizer.from_pretrained(
        tokenizer_dir,
        local_files_only=True
    )
    print("step 1 done")

    print("step 2: tokenize text")
    enc = tokenizer(
        prompt,
        padding="max_length",
        truncation=True,
        max_length=max_len
    )

    # 关键修改：当前 runtime 中 Gather 的 indices 实际按 fp32 传递
    input_ids = np.array([enc["input_ids"]], dtype=np.float32)

    print("prompt:", prompt)
    print("input_ids shape:", input_ids.shape)
    print(input_ids)
    print("bos_token_id:", tokenizer.bos_token_id)
    print("eos_token_id:", tokenizer.eos_token_id)
    print("pad_token_id:", tokenizer.pad_token_id)
    print("step 2 done")

    # -----------------------------
    # 6. 加载 network
    # -----------------------------
    print("step 3: load network")
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
    print("step 3 done")

    # -----------------------------
    # 7. Netinfo
    # -----------------------------
    print("step 4: build netinfo")
    netinfo = Netinfo(network)
    print("step 4 done")

    # -----------------------------
    # 8. 打开 device
    # -----------------------------
    print("step 5: open device")
    device = openDevice(runBackend, ip, netinfo.mmu or mmuMode, cudamode)
    print("step 5 done")

    # -----------------------------
    # 9. 初始化 session
    # -----------------------------
    print("step 6: init session")
    session = initSession(
        runBackend,
        network,
        device,
        ocmOption,
        netinfo.mmu or mmuMode,
        openSpeedmode,
        openCompressFtmp
    )
    print("step 6 done")

    # -----------------------------
    # 10. 打开计时
    # -----------------------------
    print("step 7: enable profile")
    session.enableTimeProfile(True)
    print("step 7 done")

    # -----------------------------
    # 11. apply
    # -----------------------------
    print("step 8: apply")
    session.apply()
    print("step 8 done")

    # -----------------------------
    # 12. numpy -> tensor
    # -----------------------------
    print("step 9: numpy2Tensor")
    input_tensor = numpy2Tensor(input_ids, network)
    print("step 9 done")

    # -----------------------------
    # 13. forward
    # -----------------------------
    print("step 10: forward")
    outputs = session.forward([input_tensor])
    print("step 10 done")

    # -----------------------------
    # 14. 打印输出 + 保存输出
    # -----------------------------
    print("step 11: print outputs")
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

        flat = out_np.flatten()
        print(f"output[{i}] first 10 values:", flat[:10])

        if save_npy:
            out_path = os.path.join(save_dir, f"{save_prefix}_output{i}.npy")
            np.save(out_path, out_np)
            print(f"saved output[{i}] to: {out_path}")

    # 额外保存最终文本特征 output[0]
    if save_npy and len(host_output_nps) > 0:
        feat_path = os.path.join(save_dir, f"{save_prefix}_feat.npy")
        np.save(feat_path, host_output_nps[0])
        print(f"saved final text feature to: {feat_path}")

    print("step 11 done")

    # -----------------------------
    # 15. dump 输出
    # -----------------------------
    if dump_output:
        print("step 12: dump output")
        dumpOutputFtmp(network, host_outputs, dump_format, log_path)
        print("step 12 done")

    # -----------------------------
    # 16. 板端计时
    # -----------------------------
    if runBackend != "host":
        print("step 13: device reset + calctime")
        device.reset(1)
        calctime_detail('zg330', session, network)
        print("step 13 done")

    # -----------------------------
    # 17. 关闭设备
    # -----------------------------
    if runBackend != "host":
        xrt.Device.Close(device)