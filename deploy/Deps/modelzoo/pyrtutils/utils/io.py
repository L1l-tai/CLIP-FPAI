import msgpack
import os
import re

try:
    from .debug import *
    from .tools import *
except:
    from debug import *
    from tools import *


def packData(data, filename=None):
    if filename is None:
        filename = (
            "./" + tname() + ".res"
        )
    packed_data = msgpack.packb(data)
    with open(filename, "ab") as file:
        file.write(packed_data)


def unPack(filename):
    loaded_data = []
    with open(filename, "rb") as file:
        unpacker = msgpack.Unpacker(file)
        for i in unpacker:
            loaded_data.append(i)
    return loaded_data


def checkResPath(filename, delold=False):
    name = re.search(R"[/\\]([^/\\]+\.[^/.]+)$", filename)
    assert (
        name
    ), f"respath should be a file path(ex. xx/xx/xx.res), but not a dir:{filename}"
    match = re.search(R".*[/\\]", filename)
    dir = match.group()
    assert dir, "res path wrong"

    if os.path.exists(filename):
        res = unPack(filename)
        num = len(res)
        if delold:
            mprint(
                Rf"num of obj in exist file is {num}; {filename} will be remove",
                VERBOSE,
                1,
            )
            os.remove(filename)
        else:
            mprint(
                Rf"current file is exist, do you mean to continue write. num of obj is {num}",
                VERBOSE,
                1,
            )
    else:
        if not os.path.exists(dir):
            mprint(Rf"{dir} -> res dir not exist, make new tree", VERBOSE, 1)
            os.makedirs(dir)
    return dir


if __name__ == "__main__":
    file = R"D:\Icraft\workspace_v3.0\icraft3.0\modelzoo_v3.0\demo_yolov5_7.0\py_script\io\output\yolov5s.res"
    print(len(unPack(file)))
