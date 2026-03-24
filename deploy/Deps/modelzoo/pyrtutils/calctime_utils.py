import pandas as pd #need pandas version == 1.3.5
import numpy as np
import inspect
def run_once(func):
    seen_varnames = set()  # 用于存储已经传入的变量名
    def wrapper(*args, **kwargs):
        # 获取调用栈信息
        frame = inspect.currentframe().f_back
        arg_info = inspect.getargvalues(frame)

        # 提取调用时的变量名
        varnames = []
        for arg in args:
            # 查找当前帧中与 arg 对应的变量名
            for name, value in frame.f_locals.items():
                if value is arg:
                    varnames.append(name)
                    break

        # 将变量名转换为可哈希的键
        varnames_key = tuple(varnames)

        # 如果变量名没有被记录过，则执行函数
        if varnames_key not in seen_varnames:
            result = func(*args, **kwargs)
            seen_varnames.add(varnames_key)  # 记录变量名
            return result
        else:
            # print(f"函数 {func.__name__} 已经为变量名 {varnames_key} 执行过，跳过执行。")
            return None  # 或者返回一个默认值
    return wrapper


def save_time(network, times, filenames):
    # times为字典，"op_id":[总时间，传输时间, 硬件时间，余下时间]
    # 保存每一层op_id、op_name、op_type、时间
    list_keys = sorted(times.keys())
    ori_ops_list = []
    for op in network.ops:
        ori_ops_list.append(op.op_id)
    max_id = max(ori_ops_list)
    op_name= np.array([network.getOpById(op_id).name.replace("Node","")  if op_id <= max_id else "" for op_id in list_keys])
    op_type = np.array([network.getOpById(op_id).typeKey().replace("Node","") if op_id <= max_id else "icraft::xir::HardOp" for op_id in list_keys ])
    list_values  = np.array([list(times[op_id])  for op_id in list_keys])
    total_time = list_values[:,0]
    memcpy_time = list_values[:,1]
    hard_time = list_values[:,2]
    other_time = list_values[:,3]
    dict_time = {"op_id":list_keys,"op_name":op_name,"op_type":op_type,"total_time":total_time,"memcpy_time":memcpy_time,"hard_time":hard_time,"other_time":other_time}
    pf=pd.DataFrame(dict_time)
    
    if pd.__version__.startswith('1.'):
        file_path=pd.ExcelWriter(filenames)
        pf.to_excel(file_path, encoding='utf-8', index=False)
        file_path.save()
    elif pd.__version__.startswith('2.'):
        with pd.ExcelWriter(filenames) as file_path: 
            pf.to_excel(file_path, index=False)
    else:
        print('Please use pandas version 1.x or 2.x')
    return dict_time

def simple_analyze_time(net_dict):
    cast_thresh = 0.001
    hardop_totaltime,hardop_memcpytime,hardop_hardtime = 0,0,0
    customops = {"customop_name":[], "total_time":[],"hard_time":[]}
    #网络各阶段耗时细则
    IMK,POST,WARP,CENTER_CUSTOMOP = False,False,False,False
    imk_customop_time, post_cutomop_time, other_customop_time, post_cast_time,CPUop_time = 0, 0, 0, 0, 0
    imk_list,post_list,warp_list,other_customop_list = [],[],[],[] #device
    for i in range(len(net_dict["op_type"])):
        # 统计所有hardop的totaltime&hardop_hardtime
        if net_dict["op_type"][i] == "icraft::xir::HardOp":
            hardop_totaltime += net_dict["total_time"][i]
            hardop_memcpytime += net_dict["memcpy_time"][i]
            hardop_hardtime += net_dict["hard_time"][i]
        # 统计所有customop的totaltime&hardop_hardtime
        elif net_dict["op_type"][i].split("::")[0] == "customop":
            op_name = net_dict["op_type"][i].split("::")[1]
            if op_name not in customops["customop_name"]:
                customops["customop_name"].append(op_name)
                customops["total_time"].append(net_dict["total_time"][i])
                customops["hard_time"].append(net_dict["hard_time"][i])
            else:
                index = customops["customop_name"].index(op_name)
                customops["total_time"][index] = net_dict["total_time"][i]
                customops["hard_time"][index] = net_dict["hard_time"][i]
            # 网络各阶段耗时细则
            if op_name == "ImageMake":
                IMK = True
                imk_list.append('DMA')
                imk_customop_time += net_dict["hard_time"][i]
            elif op_name[-4:] == "Post":
                POST = True
                post_list.append(op_name)
                post_cutomop_time += net_dict["total_time"][i]
            else:
                CENTER_CUSTOMOP = True
                other_customop_list.append(op_name)
                other_customop_time += net_dict["total_time"][i]
        # 其它CPU算子
        else:
            # print("CPU算子",net_dict["op_type"][i])
            CPUop_time += net_dict["total_time"][i]
        # 统计最后一个hardop后的cast搬数时间
        if net_dict["op_type"][i] == "icraft::xir::Cast" and net_dict["memcpy_time"][i] > cast_thresh:
            post_cast_time += net_dict["memcpy_time"][i]

    # 统计所有hardop的totaltime&hardop_hardtime
    hardop_totaltime -= hardop_memcpytime
    print("Hardop_TotalTime:{:.4f} ms, Hardop_HardTime:{:.4f} ms".format(hardop_totaltime,hardop_hardtime))
    
    # 统计所有customop的totaltime&hardop_hardtime
    for i in range(len(customops["customop_name"])):
        print("Customop:{}, TotalTime:{:.4f}ms, HardTime:{:.4f}ms".format(customops["customop_name"][i],customops["total_time"][i],customops["hard_time"][i]))

    # 网络各阶段耗时细则
    print("网络各阶段耗时细则：")
    # 若imk和post list为空，则为CDMA搬数
    if imk_list == []:
        imk_list.append("CDMA")
    if post_list == []:
        post_list.append("CDMA")

    # 获取输入icore的时间
    if IMK:
        icore_in_time = imk_customop_time
    else:
        icore_in_time = hardop_memcpytime
    print("数据传入时间:{:.4f}, Device:{}".format(icore_in_time,imk_list))
    # 获取icore的时间 
    icore_time = hardop_totaltime
    # 若网络中间含有其它customop,需加上该硬算子时间    
    if CENTER_CUSTOMOP:
        icore_time = icore_time + other_customop_time
        print("icore(NPU)时间:{:.4f}, Device: ['NPU' + {}]".format(icore_time,other_customop_list))
    else:
        print("icore(NPU)时间:{:.4f}, Device: ['NPU']".format(icore_time))
    # 获取icore输出的时间
    if POST:
        icore_out_time = post_cutomop_time
    else:
        icore_out_time = post_cast_time
    print("数据传出时间:{:.4f}, Device:{}".format(icore_out_time,post_list))
    # 纯CPU端算子耗时
    if POST:
        CPU_time = CPUop_time
    else:
        CPU_time = CPUop_time - icore_out_time
    print("Icraft-CPU算子耗时:{:.4f}, Device:['CPU']".format(CPU_time))



@run_once
def calctime_detail(sess, network, name="time_results.xlsx"):
    # 计算时间, 输入：session、network、保存表名
    result = sess.timeProfileResults() #获取时间，[总时间，传输时间, 硬件时间，余下时间]
    net_dict = save_time(network,result,name)
    # 统计所有op的各项时间
    time = np.array(list(result.values()))
    total_totaltime = np.sum(time[:,0])
    total_memcpytime = np.sum(time[:,1])
    total_hardtime = np.sum(time[:,2])
    total_othertime = np.sum(time[:,3])
    print("Total_TotalTime:{:.4f} ms, Total_MemcpyTime:{:.4f} ms, Total_HardTime:{:.4f} ms, Total_OtherTime:{:.4f} ms".format(total_totaltime,total_memcpytime,total_hardtime,total_othertime))
    # 简略版耗时分析
    simple_analyze_time(net_dict)
    print("For details about running time meassage of the network, check the ", name)
    