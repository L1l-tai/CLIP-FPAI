import argparse
import torch
import open_clip
from pathlib import Path

# ---------- 方法注册表 ----------
METHODS = {
    'zero-shot':      'methods.zero_shot.zero_shot:eval_fn',
    'tip-adapter':    'methods.Tip_Adapter.tip_adapter:eval_fn',
    # 后续新方法直接加在这里
}

def import_method(name):
    """动态导入 eval_fn"""
    module, func = METHODS[name].split(':')
    mod = __import__(module, fromlist=[func])
    return getattr(mod, func)

def get_args():
    p = argparse.ArgumentParser()
    p.add_argument('--root',        type=str, required=True)
    p.add_argument('--dataset',     type=str, default='imagenet', choices=['imagenet'])
    p.add_argument('--method',      type=str, choices=list(METHODS.keys()), default='zero-shot')
    p.add_argument('--model',       type=str, default='ViT-B-16')
    p.add_argument('--pretrained',  type=str, default='./download/open_clip_pytorch_model.bin')
    p.add_argument('--batch-size',  type=int, default=256)
    p.add_argument('--num-workers', type=int, default=8)
    p.add_argument('--cuda',        type=int, default=0)
    p.add_argument('--config',      type=str, default=0)
    # ====== Tip-Adapter 相关可选参数 ======
    p.add_argument('--shots',       type=int, default=16, help='shots per class for Tip-Adapter')
    p.add_argument('--alpha',       type=float, default=0.4)
    p.add_argument('--beta',        type=float, default=10.0)
    p.add_argument('--train-epoch', type=int, default=20, help='only for tip-adapter-f')
    return p.parse_args()

def main():
    args = get_args()
    args.device = f'cuda:{args.cuda}' if torch.cuda.is_available() and args.cuda >= 0 else 'cpu'
    torch.cuda.set_device(args.device)

    # 加载 CLIP
    clip_model, _, preprocess = open_clip.create_model_and_transforms(
        args.model, pretrained=args.pretrained, device='cuda:0')
    clip_model.eval().requires_grad_(False)

    # 动态分发
    eval_fn = import_method(args.method)
    eval_fn(clip_model, preprocess, args)

if __name__ == '__main__':
    main()