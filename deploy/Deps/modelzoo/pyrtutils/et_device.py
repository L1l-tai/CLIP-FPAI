import icraft
from icraft.xir import *
from icraft.xrt import *
from icraft.buyibackend import *
from icraft.host_backend import *
import time


def dmaInit(runBackend,has_ImageMake, shape,input_tensor,device):
    if runBackend == "buyi" and has_ImageMake:
        h,w,c=shape[0],shape[1],shape[2]
        demo_reg_base = 0x1000C0000
        uregion_=device.getMemRegion("udma")

        input_dtype = input_tensor.dtype().element_dtype

        utensor = input_tensor.to(uregion_)#data transfer ps->udma + IMK(udma->pl)
        ImageMakeRddrBase = utensor.data().addr()
        flag_8 = str(input_dtype) == '"@uint(8)"'
        flag_16 = str(input_dtype) == '"@sint(16)"'
        assert (flag_8|flag_16), 'dma only support uint8 and int16'

        if flag_16:
            device.defaultRegRegion().write(0x1000C0000 + 0x20, 0x2, True)
            totalBytes = h * w * c * 2
            minBlocks = (totalBytes+7)//8
            ImageMakeRlen = ((minBlocks + 2) // 3) * 3
            pixelsPer24Bytes = 24 // (2 * c)
            totalPixels = w * h
            ImageMakeLastSft = totalPixels - (ImageMakeRlen // 3 - 1) * pixelsPer24Bytes
        else:
            ImageMakeRlen = ((w * h - 1) // (24 // c) + 1) * 3
            ImageMakeLastSft = w * h - (ImageMakeRlen - 3) // 3 * (24 // c)
            device.defaultRegRegion().write(demo_reg_base + 0x20, 0, True)

        device.defaultRegRegion().write(demo_reg_base + 0x4, ImageMakeRddrBase, True)
        device.defaultRegRegion().write(demo_reg_base + 0x8, ImageMakeRlen, True)
        device.defaultRegRegion().write(demo_reg_base + 0xC, ImageMakeLastSft, True)
        device.defaultRegRegion().write(demo_reg_base + 0x10, c, True)
        device.defaultRegRegion().write(demo_reg_base + 0x1C, 1, True)
        # imk start
        device.defaultRegRegion().write(demo_reg_base, 1, True)
    return 0


def plddr_memcpy(read_bottom,read_top,write_bottom,write_top,device,show_log =False,reg_base = 0x100041000):
    if show_log: print("Begin plddr memcpy...")
    device.defaultRegRegion().write(reg_base + 0x18, read_bottom, True)  # src base
    device.defaultRegRegion().write(reg_base + 0x1C, read_top, True)  # src end
    device.defaultRegRegion().write(reg_base + 0x20, write_bottom, True)  # dest base
    device.defaultRegRegion().write(reg_base + 0x24, write_top, True)  # dest end

    if show_log: 
        aa = device.defaultRegRegion().read(reg_base + 0x18, True)
        bb = device.defaultRegRegion().read(reg_base + 0x1C, True)
        cc = device.defaultRegRegion().read(reg_base + 0x20, True)
        dd = device.defaultRegRegion().read(reg_base + 0x24, True)
        print("read_form: {}, read_to: {}, write_from: {}, write_to: {}".format(aa, bb, cc, dd))
        ee = device.defaultRegRegion().read(reg_base + 0x84, True) # 启动后轮询，全0表示done
        print("begin status: {}".format(ee))
    #启动数据传输
    device.defaultRegRegion().write(reg_base + 0x04, 1, True)
    device.defaultRegRegion().write(reg_base + 0x04, 0, True)
    waitPLDMADone(device, reg_base + 0x84, 10000, "PLDMA")

def waitPLDMADone(device, addr, wait_time, module_name):
    start = time.time()
    while True:
        reg_done = device.defaultRegRegion().read(addr, True)
        duration = (time.time() - start)*1000000
        if reg_done==0b0000:
            # print(f"(inner) {module_name} time cost: {duration}us")
            return True
        if duration > wait_time:
            print(f"{module_name} time out")
            return False
