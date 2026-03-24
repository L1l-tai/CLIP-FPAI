import numpy as np


def sigmoid(array, scale=1):
    def sig(x):
        return 1 / (1 + np.exp(-x * scale))
    # vec = np.vectorize(sig)
    return sig(array)


def border(x, min, max):
    if x < min:
        x = min
    if x > max:
        x = max
    return x


if __name__ == "__main__":
    import ctypes

    # int8_t = ctypes.c_int8
    # uint8_t=ctypes.c_uint8
    # a = np.array([-128, -128], dtype=np.int8)
    # b = a[0]
    # # b=uint8_t(b)
    # # b=b&0xff
    # print(b)
    # print(bin(b))
    # binary_str = bin(b & 0xFF)[2:].zfill(8)

    # print(binary_str)  # 输出: '11111011'
    # xlow = np.uint8(np.int16(a[0]))
    # xhigh = a[1].astype(np.uint8)
    # x = xhigh * 256 + xlow
    # print(xlow)
    # print(xhigh)
    # print(x)
