import torch 
from torchvision import transforms
import numpy as np
import yaml
import os 
import logging
level = logging.INFO
logging.basicConfig(level=level, format='%(asctime)s - [%(levelname)s] - %(message)s')
from torch.utils.data import DataLoader
from tqdm import tqdm
from PIL import Image

import sys 
deploy_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if deploy_dir not in sys.path:
    sys.path.append(deploy_dir)
from modelzoo_utils.pyrtutils import *
from icraft import xrt


def mask_to_image(mask):
    return Image.fromarray((mask * 255).astype(np.uint8))
def inspect_img(img):
    if isinstance(img, torch.Tensor):
        print("Type: PyTorch Tensor")
        print("Shape:", img.shape)  # 格式：(C, H, W) 或 (B, C, H, W)
        print("Data type:", img.dtype)
        print("Device:", img.device)  # 检查是否在GPU上
    elif isinstance(img, np.ndarray):
        print("Type: NumPy Array")
        print("Shape:", img.shape)  # 格式：(H, W, C) 或 (B, H, W, C)
        print("Data type:", img.dtype)
    else:
        print("Unknown type:", type(img))
def main(config_path) -> None:
    # 从yaml里读入配置
    cfg = yaml.load(open(config_path, "r"), Loader=yaml.FullLoader)
    folderPath = cfg["imodel"]["dir"]
    stage = cfg["imodel"]["stage"]
    runBackend = cfg["imodel"]["run_backend"]
    checkBackend(runBackend)
    cudamode = cfg["imodel"]["cudamode"]
    openSpeedmode = cfg["imodel"]["speedmode"]
    openCompressFtmp = cfg["imodel"]["compressFtmp"]

    mmuMode = True
    ocmOption = 4
    if runBackend == "buyi": mmuMode = cfg["imodel"]["mmuMode"]
    if runBackend == "zg330": ocmOption = cfg["imodel"]["ocm_option"]

    JSON_PATH, RAW_PATH = getJrPath(folderPath,stage,runBackend)
    

    ip = str(cfg["imodel"]["ip"])
    save = cfg["imodel"]["save"]
    show = cfg["imodel"]["show"]
    timeAnalysis = cfg["imodel"]['timeRes']
    imgRoot = os.path.abspath(cfg["dataset"]["dir"])
    testList = os.path.abspath(cfg["dataset"]["list"])
    
    resRoot = cfg["dataset"]["res"]
    # dump_output配置
    dump_output =  cfg["imodel"]["dump_output"]
    log_path = os.path.abspath(cfg["imodel"]["log_path"])
    
    threshold = cfg["params"]["threshold"]
    print(dump_output)
    print(log_path)
    
    
    # 加载network
    network = loadNetwork(JSON_PATH, RAW_PATH)
    print('INFO: Load network!')
    # 初始化netinfo
    netinfo = Netinfo(network)
    # 打开device
    device = openDevice(runBackend, ip, netinfo.mmu or mmuMode, cudamode)
    print('INFO: Open Device!')
    # 初始化session
    session = initSession(runBackend, network, device, ocmOption, netinfo.mmu or mmuMode, openSpeedmode, openCompressFtmp)
    #开启计时功能
    session.enableTimeProfile(True)
	#session执行前必须进行apply部署操作
    session.apply()
    print('INFO: Session Apply!')
    # prepare transforms for post_process
    tf = transforms.Compose(
    [
        transforms.ToPILImage(),
        transforms.Resize(572),
        transforms.ToTensor()
    ])
    for img_name in os.listdir(imgRoot):
        if img_name.lower().endswith(('.jpg', '.jpeg', '.png', '.bmp', '.tiff')):
            try:         
                input_path = os.path.join(imgRoot, img_name)
                # Load image and preprocess 
                full_img = Image.open(input_path)
                img_trans = np.array(full_img)
                if len(img_trans.shape) == 2:
                    img_trans = np.expand_dims(img_trans, axis=2)

                img = torch.from_numpy(img_trans)
                img = img.unsqueeze(0)
                img = img.to(device='cpu', dtype=torch.float32)
                img = img.numpy()

                input_tensor = numpy2Tensor(img, network)
                print('INFO: load test image')
                # dma init(if use imk)
                dmaInit(runBackend,netinfo.ImageMake_on, netinfo.i_shape[0][1:],input_tensor, device)
                
                output = session.forward([input_tensor])
                # 重置设备
                if runBackend != "host": device.reset(1)
                # post_process
                output_ = torch.from_numpy(np.array(output[0])).permute(0,3,1,2)
                print('output_anchor_0 shape =',np.array(output[0]).shape)
                # post process 
                probs = torch.sigmoid(output_)
                probs = probs.squeeze(0)

                probs = tf(probs.cpu())
                full_mask = probs.squeeze().cpu().numpy()
               

                mask = full_mask > threshold
                result = Image.fromarray((mask * 255).astype(np.uint8))
                # save_result
                if(save):
                    # save_result to resRoot
                    os.makedirs(resRoot, exist_ok=True)
                    res_path = resRoot+'/'+img_name
                    result.save(res_path)
                    print(f" Result saved at {res_path}.")
                # dump output
                if(dump_output):
                    # dumpOutput ftmp to log_path
                    dumpOutputFtmp(network,output,dump_format= cfg["imodel"]["dump_format"],log_path=log_path)
                    print(f" Output ftmp saved at {log_path}.")
                # 模型时间信息统计
                if runBackend != "host" and timeAnalysis:
                    print("*"*40,"TIME RESULTS","*"*40)
                    TIME_PATH = R'./time_results.xlsx'
                    calctime_detail(session,network, name=TIME_PATH)#获取时间信息并保存时间结果
                    print('Time result save at',TIME_PATH)

            except Exception as e:
               print(f"Error occurs with {img_name}: {e}")
        # 关闭设备
        xrt.Device.Close(device) 
    


if __name__ == '__main__':
    # YAML_CONFIG_PATH = R'../cfg/TDNN.yaml'
    Yaml_Path = sys.argv[1]
    # Yaml_Path = "../cfg/TDNN.yaml"
    if len(sys.argv) < 2:
        print("Info:未传入yaml参数,读入默认yaml文件:‌{}进行相关配置.".format(Yaml_Path), VERBOSE, 0)        
    if len(sys.argv) == 2:
        Yaml_Path = sys.argv[1]
        print("info:传入yaml文件:‌{}进行相关配置.".format(Yaml_Path), VERBOSE, 0)        
    if len(sys.argv) > 2:
        print("info:传入参数数量错误,请检查运行命令!", VERBOSE, 0)        
        sys.exit(1)
    main(Yaml_Path)