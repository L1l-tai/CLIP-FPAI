import platform
import time
import pandas as pd
import numpy as np 
import shutil
from matplotlib import pyplot as plt
import os
def is_arm():
    machine = platform.machine()
    return machine=='aarch64'

def tname():
    timestamp = int(time.time())
    s=time.strftime("%Y%m%d_%H%M_%S", time.localtime(timestamp))
    return s





if __name__ == "__main__":
    print(platform.machine())
    print(platform.system())
