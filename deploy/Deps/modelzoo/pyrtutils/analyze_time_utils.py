import os
import pandas as pd
import numpy as np
import shutil
from matplotlib import pyplot as plt
from openpyxl.styles import Border, Side
from openpyxl.utils import get_column_letter
from openpyxl.styles import Alignment
from openpyxl.styles import PatternFill

def sheet_style(writer,max_index):
    workbook = writer.book
    worksheet = workbook['Sheet1']
    # 定义无边框样式
    border_style = Border(
        left=Side(border_style=None),
        right=Side(border_style=None),
        top=Side(border_style=None),
        bottom=Side(border_style=None)
    )

    # 去掉所有单元格的边框
    for row in worksheet.iter_rows():
        for cell in row:
            cell.border = border_style

    ## 自动调整行宽
    for column in worksheet.columns:
        max_length = 4
        column_letter = get_column_letter(column[0].column)
        if column_letter == "B" : 
            for cell in column[:8]:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(cell.value)
                except:
                    pass
        elif column_letter == "C":
            max_length = 15
            for cell in column[:8]:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(cell.value)
                except:
                    pass
        else:
            for cell in column:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(cell.value)
                except:
                    pass
        adjusted_width = (max_length + 1) * 1.3
        worksheet.column_dimensions[column_letter].width = adjusted_width

    ## 居中对齐单元格内容
    alignment = Alignment(horizontal='center', vertical='center')
    for row in worksheet.iter_rows():
        for cell in row:
            cell.alignment = alignment


    # 设置填充区域
    fill_style1 = PatternFill(start_color="C4DFA3", end_color="C4DFA3", fill_type="solid")
    cell_range1 = worksheet['A1:C30']
    fill_style2 = PatternFill(start_color="D1EAF0", end_color="D1EAF0", fill_type="solid")
    cell_range2 = worksheet['E1:J30']
    if max_index<30:
        max_index = 30
    else:
        max_index +=4 
    fill_style3 = PatternFill(start_color="E6E6E6", end_color="E6E6E6", fill_type="solid")
    cell_range3 = worksheet['M1:T'+str(max_index)]

    # 设置填充颜色
    for row in cell_range1:
        for cell in row:
            cell.fill = fill_style1
    for row in cell_range2:
        for cell in row:
            cell.fill = fill_style2
    for row in cell_range3:
        for cell in row:
            cell.fill = fill_style3

    writer.save()
    writer.close()

def detect_file_type(filepath):
    _, ext = os.path.splitext(filepath)
    if ext.lower() == '.xlsx' or ext.lower() == '.xls':
        return 'excel'
    elif ext.lower() == '.txt':
        return 'txt'
    else:
        return 'unknown'
    
## 绘制各类hardop算子耗时堆叠柱状图
def draw_total_time(op_name,df_sum,filename,respath,resname):
    fig = plt.figure(figsize=(12, 8))
    plt.grid(ls="--", alpha=0.5)
    hard_time = list(df_sum["hard_time"])
    other_time = list(df_sum["other_time"])

    # 绘制堆叠柱状图
    plt.bar(op_name,hard_time,width=0.5,color="blue",label="hard_time")
    plt.bar(op_name,other_time,width=0.5,color="orange",label="other_time", bottom=hard_time)
    plt.xlabel('op_name')
    plt.ylabel('time(ms)')
    plt.legend()

    for i in range(len(op_name)):
        max_y = round(hard_time[i]+other_time[i],2)
        plt.text(op_name[i], max_y+0.2, max_y, va="bottom", ha="center")

    # 保存图片
    savepath = respath+filename+resname+'.png'
    plt.savefig(savepath, bbox_inches='tight')
    # plt.show()
    print("各类hardop算子耗时堆叠柱状图保存在", savepath)

## 绘制所有hardop算子耗时堆叠柱状图
def draw_per_op_time(op_id,df,filename,respath,resname):
    fig = plt.figure(figsize=(18, 10))
    plt.grid(ls="--", alpha=0.5)
    index = np.arange(len(op_id))
    width=0.5
    hard_time = list(df["hard_time"])
    other_time = list(df["other_time"])

    plt.bar(index,hard_time,width=width,color="blue",label="hard_time")
    plt.bar(index,other_time,width=width,color="orange",label="other_time",bottom=hard_time)#绘制柱状图

    plt.xticks(index, labels=op_id)
    plt.xticks(rotation= 45,fontsize=8)
    plt.xlabel('op_id')
    plt.ylabel('time(ms)')
    plt.legend()

    # 保存图片
    savepath = respath+filename+resname+'.png'
    plt.savefig(savepath, bbox_inches='tight')
    # plt.show()
    print("所有hardop算子的耗时堆叠柱状图保存在",savepath)

## 统计所有op的总耗时情况
def calculate_totaltime(writer,df,sheet_name,startcol=0,startrow=0):
    total_totaltime =  df["total_time"].sum()
    total_memcpytime =  df["memcpy_time"].sum()
    total_hardtime = df["hard_time"].sum()
    total_restime = df["other_time"].sum()

    df_total = df.copy()
    df_total.loc['total']=["","","",total_totaltime,total_memcpytime,total_hardtime,total_restime]
    df_total = df_total.round(4)

    # 写入excel
    title_row = pd.DataFrame(index=['内部数据：'])
    title_row.to_excel(writer, sheet_name=sheet_name, startcol=startcol, startrow=startrow)
    df_total.to_excel(writer, sheet_name=sheet_name, startcol=startcol, startrow=startrow+2)
    writer.save()
    

## 统计所有HardOP算子细则：按照算子类别分类、统计时间
def calculate_hardop_class_time(writer,df,sheet_name,startcol=12,startrow=0):
    df_class = df.groupby(["op_name"]).sum().iloc[:,1:]
    category_counts = df.groupby(["op_name"]).size().rename("op_nums")
    df_class.insert(0, "op_nums", category_counts)
    hardop_opnums = df_class["op_nums"].sum()
    hardop_totaltime = df_class["total_time"].sum()
    hardop_memcpytime = df_class["memcpy_time"].sum()
    hardop_hardtime = df_class["hard_time"].sum()
    hardop_restime = df_class["other_time"].sum()
    # 剔除soft中memcpy_time
    df_class["total_time"] = df_class["total_time"] - df_class["memcpy_time"]
    hardop_totaltime = hardop_totaltime - hardop_memcpytime
    df_class.drop(["memcpy_time"],axis=1,inplace=True)

    df_class.loc['total_hardop']=[hardop_opnums,hardop_totaltime,hardop_hardtime,hardop_restime]
    df_class = df_class.round(4)
    # 写入excel
    title_row = pd.DataFrame(index=['各类HardOP算子的耗时细则：'])
    title_row.to_excel(writer, sheet_name=sheet_name, startcol=startcol, startrow=startrow)
    df_class.to_excel(writer, sheet_name=sheet_name, startcol=startcol,startrow=startrow+2)
    writer.save()

## 统计各类硬算子的时间，如imk、hardop、detpost、segpost
def calculate_hardop_time(writer,df,sheet_name,startcol=12,startrow=15):
    df_types = df.groupby(["op_type"]).sum()
    op_type = df_types.index
    columns_to_keep =[col for col in op_type if col.split("::")[0] == "customop" or col.split("::")[-1] == "HardOp"]
    df_hardop = df_types.loc[columns_to_keep,["total_time","memcpy_time","hard_time","other_time"]]
    total_hard_totaltime = df_hardop["total_time"].sum()
    total_hard_memcpytime = df_hardop["memcpy_time"].sum()
    total_hard_hardtime = df_hardop["hard_time"].sum()
    total_hard_restime = df_hardop["other_time"].sum()
    # 剔除soft中memcpy_time
    df_hardop["total_time"] = df_hardop["total_time"] - df_hardop["memcpy_time"]
    total_hard_totaltime = total_hard_totaltime - total_hard_memcpytime
    df_hardop.drop(["memcpy_time"],axis=1,inplace=True)

    df_hardop.loc['total'] = [total_hard_totaltime,total_hard_hardtime,total_hard_restime]
    df_hardop = df_hardop.round(4)

    # 写入excel
    title_row = pd.DataFrame(index=['各类硬算子耗时统计结果:'])
    title_row.to_excel(writer, sheet_name=sheet_name, startcol=startcol, startrow=startrow)
    df_hardop.to_excel(writer, sheet_name=sheet_name, startcol=startcol,startrow=startrow+2)
    writer.save()

## 统计数据传入icore时间、icore耗时、传出icore时间、纯CPU端算子耗时
def calculate_detailtime(writer,df,sheet_name,startcol=12,startrow=25):
    cast_thresh = 0.001
    op_type = df.groupby(["op_type"]).sum().index
    # 从网络中获取IMK,POST
    IMK,POST,WARP,CENTER_CUSTOMOP = False,False,False,False
    pre_customop_time, other_customop_time= 0, 0
    imk_list,post_list,warp_list,other_customop_list = [],[],[],[]
    for col in op_type:
        a,b = col.split("::")[0],col.split("::")[-1]
        if a == "customop":
            if b == "ImageMake":
                IMK = True
                imk_list.append(col)
                print("network with IMK:",col)
            elif b[-4:] == "Post":
                POST = True
                post_list.append(col)
                print("network with POST:",col)
            # elif "WarpAffine" in b:
            #     WARP = True
            #     warp_list.append(col)
            #     print("network with PRE:",col)
            #     pre_customop_time += df.loc[df["op_type"]==col, "total_time"].values[0]
            else:
                CENTER_CUSTOMOP = True
                other_customop_list.append(col)
                other_customop_time += df.loc[df["op_type"]==col, "total_time"].values[0]
        else:
                continue
        
    # 若imk和post list为空，则为cdma搬数
    if imk_list == []:
        imk_list.append("cdma")
    if post_list == []:
        post_list.append("cdma")


    # 获取输入icore的时间
    if IMK:
        icore_in_time = df.loc[df["op_type"] == "customop::ImageMake", "hard_time"].values[0]
    else:
        icore_in_time = df.loc[df["op_type"] == "icraft::xir::HardOp", "memcpy_time"].sum()
       
    # 获取icore输出的时间   
    if POST:
        icore_out_time = df.loc[df["op_type"].str.split("::").str[-1].str[-4:] == "Post", "total_time"].values[0]
    else:
        filtered_cast_df = df[(df["op_type"] == "icraft::xir::Cast") & (df["memcpy_time"] > cast_thresh)]
        icore_out_time = filtered_cast_df["memcpy_time"].sum()
    
    # 获取icore的时间 
    if IMK:
        icore_time = df.loc[df["op_type"] == "icraft::xir::HardOp", "total_time"].sum()
    else:
        icore_time = df.loc[df["op_type"] == "icraft::xir::HardOp", "total_time"].sum() - icore_in_time

    # 若网络中间含有其它customop,需加上该硬算子时间    
    if CENTER_CUSTOMOP:
            icore_time = icore_time + other_customop_time
    
    # 纯CPU端算子耗时
    df_cpu = df[(df["op_type"] != "icraft::xir::HardOp") & (~df["op_type"].str.startswith("customop::"))]
    if POST:
        cpu_time = df_cpu["total_time"].sum()
    else:
        cpu_time = df_cpu["total_time"].sum() - icore_out_time

    # 后处理耗时
    post_time = 0

    # 呈现给用户的时间
    row_names = ["数据传入时间", "icore(npu)时间","数据传出时间","Icraft-CPU算子耗时","后处理耗时(自行填写)"]
    column_data = [icore_in_time, icore_time, icore_out_time, cpu_time, post_time]
    df_detailtime = pd.DataFrame(column_data, index=row_names,columns=['time(ms)'])
    # df_detailtime.columns.name = '网络各阶段耗时细则'
    df_detailtime = df_detailtime.round(4)
    df_detailtime['Device'] =[imk_list,other_customop_list,post_list,"null","null"]

    # 延时
    delay_time = '=SUM(Sheet1!B4:B8)'
    # 吞吐率
    fps = '=1000/MAX(Sheet1!B4:B8)'

    row_names_res = ["单帧延时(ms)","极限fps"]
    column_data_res = [delay_time, fps]
    df_res = pd.DataFrame(column_data_res, index=row_names_res,columns=['results'])
    df_res["耗时瓶颈"]=['=INDEX(A4:A8,MATCH(MAX(B4:B8),B4:B8,0))','=INDEX(A4:A8,MATCH(MAX(B4:B8),B4:B8,0))']
    
    # for print
    delay_time = icore_in_time + icore_time + icore_out_time + cpu_time + post_time
    fps = 1000/max(icore_in_time,icore_time,icore_out_time,cpu_time,post_time)
    df_res_print = pd.DataFrame([delay_time, fps], index=row_names_res,columns=['results'])
    df_res_print["耗时瓶颈"]=[df_detailtime['time(ms)'].idxmax(),df_detailtime['time(ms)'].idxmax()]

    # 打印细则
    print("统计分析结果如下:")
    print(df_detailtime)
    print("="*60)

    # 打印预估情况
    print("网络单帧延时、吞吐率分析结果如下：")
    print(df_res_print)
    print("="*60)

    # 写入excel
    title_row = pd.DataFrame(index=['统计分析结果如下:'])
    title_row.to_excel(writer, sheet_name=sheet_name, startcol=startcol, startrow=startrow)
    df_detailtime.to_excel(writer, sheet_name=sheet_name, startcol=startcol,startrow=startrow+2)
    title_row2 = pd.DataFrame(index=['单帧延时、吞吐率分析结果如下:'])
    title_row2.to_excel(writer, sheet_name=sheet_name, startcol=startcol, startrow=startrow+10)
    df_res.to_excel(writer, sheet_name=sheet_name, startcol=startcol,startrow=startrow+12)
    writer.save()

    
def analyze_time(filepath,res_root="./res/",mergeOps=True):
    """
    输入:
    filepath 表示输入文件路径，通常为 modelname.xlsx(python 时间测试结果) 或 modelname.txt(C++ 时间测试结果)
    res_root="./res/"  , 表示保存文件路径
    mergeOps = True or False , 表示network是否合并算子
    输出：
    mergeOps=True:
        分析结果modelname_res.xlsx
    mergeOps=False:
        分析结果modelname_res.xlsx、柱状堆叠图
    """
    filename = filepath.split("/")[-1].split(".")[0]
    respath = res_root+filename+"/"
    if not os.path.exists(respath):
        os.makedirs(respath)
        print("文件夹已创建")
    else:
        shutil.rmtree(respath)
        os.makedirs(respath)
        print("文件夹已存在")
    
    filetype = detect_file_type(filepath)
    if filetype == "excel":
        input_data = pd.read_excel(filepath, sheet_name=None)
    elif filetype == "txt":
        data = []
        with open(filepath, 'r',encoding="utf-8") as file:
            for line in file:
                line = line.strip()
                line_data = {}
                if line[:5]=="*****":
                    break
                else:
                    for item in line.split(', '):
                        key, value = item.split(': ')
                        if key == "op_type" or key == "op_name":
                            value = value.replace("Node","")
                        if value == "":
                            value  = np.nan
                        try:
                            line_data[key] = float(value)
                        except ValueError:
                            line_data[key] = value
                    data.append(line_data)
        input_data = {'Sheet1': pd.DataFrame(data)}
    else:
        print("not support current file type")
    res_name = respath + filename+"_res.xlsx"

    writer = pd.ExcelWriter(res_name, engine='openpyxl')
    max_index = 0
    if mergeOps:
        for sheet_name, df_origin in input_data.items():
            df = df_origin.sort_values(by="op_id",ascending=True)
            df = df.reset_index(drop=True)
            max_index = len(df.index)

            # 统计数据传入icore时间、icore耗时、传出icore时间、纯CPU端算子耗时
            calculate_detailtime(writer,df,sheet_name,startcol=0,startrow=0)  

            # 统计各类硬算子的时间，如imk、hardop、detpost、segpost
            calculate_hardop_time(writer,df,sheet_name,startcol=4,startrow=0)

            # 统计所有op的总耗时情况
            calculate_totaltime(writer,df,sheet_name,startcol=12,startrow=0) 
    else:
        for sheet_name, df_origin in input_data.items():
            df = df_origin.sort_values(by="op_id",ascending=True)
            df = df.reset_index(drop=True)
            max_index = len(df.index)

            # 统计数据传入icore时间、icore耗时、传出icore时间、纯CPU端算子耗时
            calculate_detailtime(writer,df,sheet_name,startcol=0,startrow=0)

            # 统计各类硬算子的时间，如imk、hardop、detpost、segpost
            calculate_hardop_time(writer,df,sheet_name,startcol=4,startrow=0)

            # 统计所有HardOP算子细则：按照算子类别分类、统计时间
            calculate_hardop_class_time(writer,df,sheet_name,startcol=4,startrow=8)

            # 统计所有op的总耗时情况
            calculate_totaltime(writer,df,sheet_name,startcol=12,startrow=0)
            
            df_sum = df.groupby(["op_name"]).sum()
            op_name = [tmp.split('::')[-1] for tmp in df_sum.index]

            # 绘制各类hardop算子的耗时直方图
            draw_total_time(op_name,df_sum,filename,respath,"各类hardop算子的耗时直方图")
            
            # 绘制所有算子的耗时直方图
            df_filtered = df[df["op_type"]=="icraft::xir::HardOp"]#数据筛选,只保留op_type=hard_op
            op_id = df_filtered["op_id"]
            draw_per_op_time(op_id,df_filtered,filename,respath,"所有hardop算子的耗时直方图")

    sheet_style(writer,max_index)
    print("时间分析结果保存在 ", res_name)



