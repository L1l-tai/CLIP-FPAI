global VERBOSE
VERBOSE = True

RESET = "\033[0m"  # 重置所有属性到默认值
PURPLE = "\033[35m"  # 设置前景色为紫色
BLUE = "\033[34m"
RED = "\033[31m"
YELLOW = "\033[33m"


def count_calls(func):
    def wrapper(*args, **kwargs):
        wrapper.count += 1
        return func(*args, **kwargs)

    wrapper.count = 0
    return wrapper


@count_calls
def mprint(x, verbose=False, mode=0):
    """
    mode:
    0: common
    1: warnning
    2: error
    """
    idx = mprint.count
    message = "tools.py -> mprint mode errr!"

    if mode == 0:
        message = f"{PURPLE}msg.{idx} {BLUE}common:\n {x}{RESET}\n------------"

    if mode == 1:
        message = f"{PURPLE}msg.{idx} {YELLOW}warn:\n {x}{RESET}\n------------"

    if mode == 2:
        message = f"{PURPLE}msg.{idx} {RED}error:\n {x}{RESET}\n------------"

    if verbose:
        print(message)


if __name__ == "__main__":
    # mprint("aaa",True,0)
    # mprint("bbb",True,1)
    # mprint("bbb",True,2)
    pass
