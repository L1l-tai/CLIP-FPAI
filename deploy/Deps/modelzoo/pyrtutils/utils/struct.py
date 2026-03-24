class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y


class Box:
    def __init__(self, *args, **kwargs):
        self.mode = ""
        # self.px=0
        # self.py=0
        # self.pw=0
        # self.ph=0
        # self.ptl=Point(0,0)
        # self.pbr=Point(0,0)
        if len(args) == 4:  # 通过 xywh 初始化
            self.px, self.py, self.pw, self.ph = args
            self.mode = "xywh"
        elif len(args) == 2:  # 通过 tlbr 初始化
            self.ptl = args[0]
            self.pbr = args[1]
            self.mode = "tlbr"
        else:
            raise ValueError("Invalid arguments")

    @property
    def x(self):
        if self.mode == "xywh":
            return self.px
        if self.mode == "tlbr":
            return (self.ptl.x + self.pbr.x) / 2

    @property
    def y(self):
        if self.mode == "xywh":
            return self.py
        if self.mode == "tlbr":
            return (self.ptl.y + self.pbr.y) / 2

    @property
    def w(self):
        if self.mode == "xywh":
            return self.pw
        if self.mode == "tlbr":
            return self.pbr.x - self.ptl.x

    @property
    def h(self):
        if self.mode == "xywh":
            return self.ph
        if self.mode == "tlbr":
            return self.pbr.y - self.ptl.y

    @property
    def tl(self):
        if self.mode == "tlbr":
            return self.ptl
        if self.mode == "xywh":
            return Point(self.px - self.pw / 2, self.py - self.ph / 2)

    @property
    def br(self):
        if self.mode == "tlbr":
            return self.pbr
        if self.mode == "xywh":
            return Point(self.px + self.pw / 2, self.py + self.ph / 2)


def iou_calc(box1: Box, box2: Box):
    x1 = max(box1.tl.x, box2.tl.x)
    y1 = max(box1.tl.y, box2.tl.y)
    x2 = min(box1.br.x, box2.br.x)
    y2 = min(box1.br.y, box2.br.y)
    intersection_area = max(0, x2 - x1) * max(0, y2 - y1)
    box1_area = box1.w * box1.h
    box2_area = box2.w * box2.h
    union_area = box1_area + box2_area - intersection_area
    iou = intersection_area / union_area
    return iou


class Cubic:
    def __init__(self, h, w, c):
        self.h = h
        self.w = w
        self.c = c


if __name__ == "__main__":
    # 测试
    import numpy as np

    arr = np.array([1, 2, 3, 4])
    box1 = Box(*arr)
    print("x:", box1.x)
    print("y:", box1.y)
    print("w:", box1.w)
    print("h:", box1.h)
    print("tl.x:", box1.tl.x)
    print("tl.y:", box1.tl.y)
    print("br.x:", box1.br.x)
    print("br.y:", box1.br.y)

    box2 = Box(Point(50, 60), Point(100, 120))
    print("x:", box2.x)
    print("y:", box2.y)
    print("w:", box2.w)
    print("h:", box2.h)
    print("tl.x:", box2.tl.x)
    print("tl.y:", box2.tl.y)
    print("br.x:", box2.br.x)
    print("br.y:", box2.br.y)
