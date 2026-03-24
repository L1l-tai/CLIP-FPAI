import icraft
from icraft import xir,xrt,host_backend,buyibackend
from icraft.host_backend import *
from icraft.buyibackend import *
from icraft.zg330backend import *
import os
import platform
from .utils import *
import logging
import re
import sys
STAGE = {
    "p": "parsed",
    "o": "optimized",
    "q": "quantized",
    "a": "adapted",
    "g": "BY/ZG",
}

def checkBackend(run_backend):
    if run_backend not in ["host", "buyi", "zg330"]:
        raise Exception(f"The backend parameter passed to function openDevice <{run_backend}> is not supported.\
            \nEnsure that you pass the correct backend parameter!\
            \nThe backend parameter can only accept host, buyi, and zg330!")

def getJrPath(folderPath,stage,run_backend):
    current_os = platform.system()
    current_arch = platform.machine()
    is_dev_env = current_os == "Windows" or (current_os == "Linux" and "x86" in current_arch)

    logging.info(f"Searching for model file in {folderPath}...")

    if run_backend == "buyi":
        stage = "BY.json"
    elif run_backend == "zg330":
        stage = "ZG.json"
    elif run_backend == "host":
        if is_dev_env:
            if stage in STAGE:
                if stage == "g":
                    for entry in os.scandir(folderPath):
                        if entry.is_file() and ("BY.json" in entry.name or "ZG.json" in entry.name):
                            logging.info(f"Found model file at {entry.path}")
                            raw_path = re.sub("json$", "raw", entry.path)
                            mprint("Info:imodel file found at:‌{}".format(entry.path), VERBOSE, 0)
                            return entry.path, raw_path
                    raise RuntimeError("imodel path not right ,please check yaml:imodel:dir")
                else:
                    stage = f"{STAGE[stage]}.json"
            else:
                raise RuntimeError("imodel stage not right ,please check yaml:imodel:dir")
        # For aarch64 linux with host backend, it will fall through to the file search loop
    else:
        checkBackend(run_backend)  # Recovers the check for invalid backends

    for entry in os.scandir(folderPath):
        if entry.is_file() and stage in entry.name:
            logging.info(f"Found model file at {entry.path}")
            raw_path = re.sub("json$", "raw", entry.path)
            mprint("Info:imodel file found at:‌{}".format(entry.path), VERBOSE, 0)     
            return entry.path, raw_path

    raise RuntimeError("imodel path not right ,please check yaml:imodel:dir")


def loadNetwork(JSON_PATH, RAW_PATH):
    network = icraft.xir.Network.CreateFromJsonFile(JSON_PATH)
    network.lazyLoadParamsFromFile(RAW_PATH)
    return network


def openDevice(run_backend,ip,mmu_Mode = True,cuda_Mode= False,npu_addr = "0x40000000", dma_addr = "0x80000000"):
    logging.info(f"Opening device for backend {run_backend}...")
    checkBackend(run_backend)
    current_os = platform.system()
    current_arch = platform.machine()
    is_dev_env = current_os == "Windows" or (current_os == "Linux" and "x86" in current_arch)

    DEVICE_URL = None
    if is_dev_env:  # Windows or x86 Linux
        if run_backend == "host":
            if cuda_Mode:
                return host_backend.CudaDevice.Default()
            return xrt.HostDevice.Default()
        elif run_backend == "buyi":
            DEVICE_URL = f"socket://ql100aiu@{ip}:9981?npu={npu_addr}&dma={dma_addr}"
        elif run_backend == "zg330":
            DEVICE_URL = f"socket://zg330aiu@{ip}:9981?npu={npu_addr}&dma={dma_addr}"
    else:  # aarch64 Linux
        if run_backend == "host":
            if cuda_Mode:
                return host_backend.CudaDevice.Default()
            return xrt.HostDevice.Default()
        elif run_backend == "buyi":
            DEVICE_URL = f"axi://ql100aiu?npu={npu_addr}&dma={dma_addr}"
        elif run_backend == "zg330":
            DEVICE_URL = f"axi://zg330aiu?npu={npu_addr}&dma={dma_addr}"

    if DEVICE_URL is None:
        # This case handles zg330 on aarch64 which is not yet implemented
        raise NotImplementedError(f"Device URL not set for backend '{run_backend}' on this platform.")

    device = xrt.Device.Open(DEVICE_URL)
    if run_backend == "buyi": xrt.BuyiDevice(device).mmuModeSwitch(mmu_Mode)
    return device


def initsimSession(network):
    session = xrt.Session.Create( [host_backend.HostBackend],network, [xrt.HostDevice.Default() ])
    return session


def initSession(run_backend, network, device, ocm_option=4, mmuMode=True, open_speedmode=True, open_compressFtmp=True):
    checkBackend(run_backend)
    current_os = platform.system()
    current_arch = platform.machine()
    is_dev_env = current_os == "Windows" or (current_os == "Linux" and "x86" in current_arch)

    # The session creation logic appears to be the same for both environments
    # but uses different classes (e.g., xrt.Session vs Session).
    # We will maintain the separation based on the original code's OS check.
    if is_dev_env and current_os == "Windows": # Original "Windows" block
        if run_backend == "host":
            session = xrt.Session.Create([host_backend.HostBackend], network.view(0), [device])
        elif run_backend == "buyi":
            session = xrt.Session.Create([buyibackend.BuyiBackend, host_backend.HostBackend], network.view(0), [device, xrt.HostDevice.Default()])
            if not mmuMode:
                buyi_backend = buyibackend.BuyiBackend(session.backends[0])
                if open_compressFtmp:
                    buyi_backend.compressFtmp()
                if open_speedmode:
                    buyi_backend.speedMode()
        elif run_backend == "zg330":
            session = xrt.Session.Create([ZG330Backend, host_backend.HostBackend], network.view(0), [device, xrt.HostDevice.Default()])
            zg_backend = ZG330Backend(session.backends[0])
            if not open_compressFtmp:
                zg_backend.disableEtmOptimize()
            if not open_speedmode:
                zg_backend.disableMergeHardOp()
            if ocm_option != 4:
                ocm_options = {
                    3: OcmOpt.OPTION3,
                    2: OcmOpt.OPTION2,
                    1: OcmOpt.OPTION1,
                    0: OcmOpt.NONE,
                }
                if ocm_option in ocm_options:
                    zg_backend.ocmOptimize(ocm_options[ocm_option])
                else:
                    raise Exception(f"The ocm_option parameter passed to initSession <{ocm_option}> is not supported.")
        return session
    else: # aarch64 Linux and x86 Linux
        if run_backend == "host":
            session = xrt.Session.Create([host_backend.HostBackend], network.view(0), [device])
        elif run_backend == "buyi":
            session = xrt.Session.Create([buyibackend.BuyiBackend, host_backend.HostBackend], network.view(0), [device, xrt.HostDevice.Default()])
            if not mmuMode:
                buyi_backend = buyibackend.BuyiBackend(session.backends[0])
                if open_compressFtmp:
                    buyi_backend.compressFtmp()
                if open_speedmode:
                    buyi_backend.speedMode()
        elif run_backend == "zg330":
            session = xrt.Session.Create([ZG330Backend, host_backend.HostBackend], network.view(0), [device, xrt.HostDevice.Default()])
            zg_backend = ZG330Backend(session.backends[0])
            if not open_compressFtmp:
                zg_backend.disableEtmOptimize()
            if not open_speedmode:
                zg_backend.disableMergeHardOp()
            if ocm_option != 4:
                ocm_options = {
                    3: OcmOpt.OPTION3,
                    2: OcmOpt.OPTION2,
                    1: OcmOpt.OPTION1,
                    0: OcmOpt.NONE,
                }
                if ocm_option in ocm_options:
                    zg_backend.ocmOptimize(ocm_options[ocm_option])
                else:
                    raise Exception(f"The ocm_option parameter passed to initSession <{ocm_option}> is not supported.")
        return session


def numpy2Tensor(input_array: np.ndarray,message) -> icraft.xrt.Tensor:
    if isinstance(message, xir.Network):
        network = message
        if "InputNode" in network.ops[0].typeKey():
            input_value = network.ops[0].outputs[0]
        else:
            input_value = network.ops[0].inputs[0]
    elif(isinstance(message, xir.Value)):
        input_value = message
    else:
        raise Exception("Error:输入numpy2Tensor的参数2类型错误,只能是Network类型和Value")
    input_tensortype = input_value.tensorType()
    # input_dtype = input_value.dtype.getStorageType()
    input_dtype = input_tensortype.getStorageType()
    input_tensortype.setShape(list(input_array.shape))

    if str(input_dtype) == '"@fp(32)"':
        input_array = input_array.astype(np.float32)
    elif str(input_dtype) == '"@fp(16)"':
        input_array = input_array.astype(np.float16)
    elif str(input_dtype) == '"@uint(8)"':
        input_array = input_array.astype(np.uint8)
    elif str(input_dtype) == '"@uint(16)"':
        input_array = input_array.astype(np.uint16)
    elif str(input_dtype) == '"@sint(8)"':
        input_array = input_array.astype(np.int8)
    elif str(input_dtype) == '"@sint(16)"':
        if input_array.dtype==np.uint16: print('warnning : 你的输入是uint16，但我们仅支持int16，现在将其强转成int16输入')
        input_array = input_array.astype(np.int16)
    return  xrt.Tensor(input_array,input_tensortype)

# 当传入network 或者networkview时候适用于单输入的网络去构造输入tensor 
# 若传入value时候适用于构造网络中任意位置的tensor
# v3.7.0
# def numpy2Tensor(input_array: np.ndarray,message) -> Tensor:
#     if isinstance(message, Network) or isinstance(message, NetworkView) :
#         network = message
#         if "InputNode" in network.ops[0].typeKey():
#             input_value = network.ops[0].outputs[0]
#         else:
#             input_value = network.ops[0].inputs[0]
#     elif(isinstance(message, Value)):
#         input_value = message
#     input_tensortype = input_value.tensorType()
#     # input_dtype = input_value.dtype.getStorageType()
#     input_dtype = input_tensortype.getStorageType()
#     if input_dtype.isFP32():
#         input_array = input_array.astype(np.float32)
#     elif input_dtype.isFP16():
#         input_array = input_array.astype(np.float16)
#     elif input_dtype.isUInt8():
#         input_array = input_array.astype(np.uint8)
#     elif input_dtype.isUInt16():
#         input_array = input_array.astype(np.uint16)
#     elif input_dtype.isSInt8():
#         input_array = input_array.astype(np.int8)
#     elif input_dtype.isSInt16():
#         input_array = input_array.astype(np.int16)
#     return  Tensor(input_array,input_tensortype)
def dumpOutputFtmp(network,output_tensors,dump_format,log_path):
    try :
        if not os.path.exists(log_path):
            os.makedirs(log_path)
    except OSError as e:
        print(f"Error: 无法创建路径 {log_path} - {e}", file=sys.stderr)
        return False
    # dump网络output算子的输出
    network_outp = network.outputs()
    for i in range(len(network_outp)):
        filename =  str(i)+".ftmp"
        with open(os.path.join(log_path, filename),'wb') as f:
            output_tensors[i].dump(f,dump_format)
