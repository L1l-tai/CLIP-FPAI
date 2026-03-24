from .utils import *
import icraft
from icraft import xir 
from icraft import xrt
from icraft.buyibackend import *
from icraft.host_backend import *
class Cubic:
    def __init__(self, h, w, c):
        self.h = h
        self.w = w
        self.c = c
class Netinfo:
    """
    i_shape: [[input1 dims],[input2 dims],...]
    o_shape: [[output1 dims],[output2 dims],...]
    o_scale: [[output1 scale],[output2 scale],...]
    fpga_op: [str:cutomop1_name,str:cutomop2_name,...]
    i_cubic: [Cubic:input1,Cubic:input2,...]
    o_cubic: [Cubic:output1,Cubic:output2,...]
    """

    def __init__(self, network):
        self.network = network
        self.i_shape = []
        self.o_shape = []
        self.o_scale = []
        self.fpga_op = []
        self.i_cubic = []
        self.o_cubic = []
        self.inp_shape_opid = 0
        self.bit = 32
        self.detpost_bit = 32
        self.resize_on = False
        self.swaporder_on = False
        self.ImageMake_on = False
        self.DetPost_on = False
        self.ImageMake_ = xir.Operation(xir.ObjectRef())
        self.DetPost_ = xir.Operation(xir.ObjectRef())
        self.mmu = False


        self.getNetInfo()
        self.getCubic()

        if self.mmu :
            mprint("The speedmode or compressFtmp of input model is enabled, The device must enable mmu mode.", VERBOSE, 0)        
        else :
            mprint("Neither speedmode nor compressFtmp of input model is enabled, You can decide whether to enable the mmu mode of the device by using the configuration item mmu in the yaml file", VERBOSE, 0)


    def fpgaOPlist(self):
        # only used in adapt&by stage
        customop_set = set()
        oplist = self.network.ops
        for op in oplist:
            if "Resize" in op.typeKey():
                self.resize_on = True
            if "SwapOrder" in op.typeKey():
                self.SwapOrder = True
            if "ImageMakeNode" in op.typeKey():
                self.ImageMake_on = True
                self.ImageMake_ = op
            if "DetPostNode" in op.typeKey():
                self.DetPost_on = True
                self.DetPost_ = op                
            if "customop" in op.typeKey():
                customop_set.add(op.typeKey())
        self.fpga_op = list(customop_set)
    def getNetInfo(self):

        self.fpgaOPlist()
        if self.resize_on: self.inp_shape_opid = self.inp_shape_opid+1
        # if self.swaporder_on: self.inp_shape_opid = self.inp_shape_opid+1
        # if self.network.getTag("speedmode"):
        speedmode = xir.Bool(self.network.getTag("speedmode")).__bool__()
        compressFtmp = xir.Bool(self.network.getTag("speedmode")).__bool__()
        self.mmu = speedmode or compressFtmp
            # self.mmu = False
        if self.DetPost_on:
            self.detpost_bit = self.DetPost_.outputs[0].dtype.getStorageType().bits()
            for i in self.DetPost_.inputs:
                self.o_scale.append(i.tensorType().element_dtype.getNormratio().data[0])
        oplist = self.network.ops
        for i in oplist[self.inp_shape_opid].outputs:
            self.i_shape.append(i.tensorType().shape)
        for i in oplist[-1].inputs:
            self.o_shape.append(i.tensorType().shape)
            # try:
            #     self.o_scale.append(
            #         i.tensorType().element_dtype.getNormratio().data[0]
            #     )
            # except:
            #     # mprint("no scale or format bug", VERBOSE, 1)
            #     pass
        # Network network = Network()
        # network.ops[-1].inputs[0].tensorType().element_dtype.getNormratio()[0]
        # network.ops[-1].type_key

        for op in oplist:
            if "buyit" in  str(op.compile_target) or "fpgat" in  str(op.compile_target):
                self.bit = op.outputs[0].dtype.getStorageType().bits()
                break


    def getCubic(self):
        for i in self.i_shape:
            if len(i) == 4:
                self.i_cubic.append(Cubic(i[1], i[2], i[3]))
        for o in self.o_shape:
            if len(o) == 4:
                self.o_cubic.append(Cubic(o[1], o[2], o[3]))