#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
实时开放域目标检测演示（Real-time Open-Vocabulary Detection）
- 使用本地 CLIP ONNX（text + vision），无需联网下载模型
- 支持摄像头实时画面与关键词热更新

运行示例：
python realtime_open_vocab_detection.py --camera 0 --score-thr 0.24 --infer-interval 2
"""

import argparse
import threading
from typing import Dict, List, Tuple

import cv2
import numpy as np
import onnxruntime as ort
from PIL import Image
from transformers import AutoProcessor

try:
    import tkinter as tk
except Exception:
    tk = None


class SharedQueryState:
    def __init__(self, initial_queries: List[str]):
        self._lock = threading.Lock()
        self._queries = [initial_queries[0] if initial_queries else "person"]
        self._version = 0

    def set_queries(self, queries: List[str]) -> None:
        clean = [q.strip() for q in queries if q.strip()]
        if not clean:
            return
        with self._lock:
            # 单目标模式：始终仅保留一个识别目标
            self._queries = [clean[0]]
            self._version += 1

    def get_snapshot(self) -> Tuple[List[str], int]:
        with self._lock:
            return list(self._queries), self._version


class QueryControlWindow:
    def __init__(self, state: SharedQueryState):
        self.state = state
        self.root = tk.Tk()
        self.root.title("Open-Vocabulary Query Control")
        self.root.geometry("520x180")

        self.info_var = tk.StringVar()
        self.info_var.set("输入单个目标文本，点击 Apply 即时生效")

        current_queries, _ = self.state.get_snapshot()
        self.entry_var = tk.StringVar(value=current_queries[0])

        tk.Label(self.root, text="Target:", anchor="w").pack(fill="x", padx=12, pady=(12, 2))
        tk.Entry(self.root, textvariable=self.entry_var).pack(fill="x", padx=12)
        tk.Button(self.root, text="Apply", command=self._apply).pack(pady=10)
        tk.Label(self.root, textvariable=self.info_var, fg="#2255aa", anchor="w").pack(fill="x", padx=12)
        tk.Label(
            self.root,
            text="提示: 摄像头窗口按 q 退出；此窗口关闭后程序继续运行。",
            fg="#666666",
            anchor="w",
        ).pack(fill="x", padx=12, pady=(6, 0))

    def _apply(self) -> None:
        raw = self.entry_var.get().strip()
        if not raw:
            self.info_var.set("关键词为空，已忽略。")
            return
        target = raw.split(",")[0].strip()
        if not target:
            self.info_var.set("关键词为空，已忽略。")
            return
        self.state.set_queries([target])
        self.info_var.set("已更新目标: " + target)

    def run(self) -> None:
        self.root.mainloop()


def _l2norm(x: np.ndarray, axis: int = -1, eps: float = 1e-8) -> np.ndarray:
    return x / (np.linalg.norm(x, axis=axis, keepdims=True) + eps)


def _nms(boxes: np.ndarray, scores: np.ndarray, iou_thr: float) -> List[int]:
    if boxes.shape[0] == 0:
        return []

    x1 = boxes[:, 0]
    y1 = boxes[:, 1]
    x2 = boxes[:, 2]
    y2 = boxes[:, 3]
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = scores.argsort()[::-1]

    keep = []
    while order.size > 0:
        i = int(order[0])
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])

        w = np.maximum(0.0, xx2 - xx1 + 1)
        h = np.maximum(0.0, yy2 - yy1 + 1)
        inter = w * h
        iou = inter / (areas[i] + areas[order[1:]] - inter + 1e-8)

        inds = np.where(iou <= iou_thr)[0]
        order = order[inds + 1]

    return keep


class OpenVocabDetector:
    def __init__(
        self,
        score_thr: float,
        processor_dir: str,
        text_onnx: str,
        vision_onnx: str,
        max_proposals: int,
        nms_iou: float,
        max_boxes: int,
        detector_input_size: int,
        ort_threads: int,
    ):
        self.score_thr = score_thr
        self.max_proposals = max_proposals
        self.nms_iou = nms_iou
        self.max_boxes = 1 if max_boxes > 1 else max_boxes
        self.detector_input_size = max(0, detector_input_size)
        self.last_query_key = None
        self.cached_text_embeds = None
        self.proposal_cache: Dict[Tuple[int, int, int], List[Tuple[int, int, int, int]]] = {}

        available = ort.get_available_providers()
        if "CUDAExecutionProvider" in available:
            providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
        else:
            providers = ["CPUExecutionProvider"]

        print(f"[INFO] Loading local processor from: {processor_dir}")
        self.processor = AutoProcessor.from_pretrained(processor_dir, local_files_only=True)

        print(f"[INFO] Loading local ONNX text encoder: {text_onnx}")
        text_sess_opts = ort.SessionOptions()
        text_sess_opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        if ort_threads > 0:
            text_sess_opts.intra_op_num_threads = ort_threads
            text_sess_opts.inter_op_num_threads = 1
        self.text_session = ort.InferenceSession(text_onnx, sess_options=text_sess_opts, providers=providers)
        self.text_input_names = [x.name for x in self.text_session.get_inputs()]

        print(f"[INFO] Loading local ONNX vision encoder: {vision_onnx}")
        vision_sess_opts = ort.SessionOptions()
        vision_sess_opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        if ort_threads > 0:
            vision_sess_opts.intra_op_num_threads = ort_threads
            vision_sess_opts.inter_op_num_threads = 1
        self.vision_session = ort.InferenceSession(vision_onnx, sess_options=vision_sess_opts, providers=providers)
        self.vision_input_names = [x.name for x in self.vision_session.get_inputs()]

        print(f"[INFO] ONNX providers: {self.vision_session.get_providers()}")

    def _encode_text(self, queries: List[str]) -> np.ndarray:
        key = tuple(queries)
        if self.last_query_key == key and self.cached_text_embeds is not None:
            return self.cached_text_embeds

        prompts = [f"a photo of {q}" for q in queries]
        text_inputs = self.processor(
            text=prompts,
            padding="max_length",
            max_length=77,
            truncation=True,
            return_tensors="np",
        )
        for k in text_inputs.keys():
            text_inputs[k] = text_inputs[k].astype(np.int64)

        ort_inputs = {name: text_inputs[name] for name in self.text_input_names}
        text_embeds = self.text_session.run(None, ort_inputs)[0]
        text_embeds = _l2norm(text_embeds)

        self.last_query_key = key
        self.cached_text_embeds = text_embeds
        return text_embeds

    def _build_proposals(self, h: int, w: int) -> List[Tuple[int, int, int, int]]:
        cache_key = (h, w, self.max_proposals)
        if cache_key in self.proposal_cache:
            return self.proposal_cache[cache_key]

        proposals = [(0, 0, w, h)]
        base = min(h, w)
        scales = [0.25, 0.35, 0.5, 0.7, 0.9]

        for s in scales:
            win = max(32, int(base * s))
            step = max(16, int(win * 0.45))

            for y in range(0, max(1, h - win + 1), step):
                for x in range(0, max(1, w - win + 1), step):
                    proposals.append((x, y, x + win, y + win))
                    if len(proposals) >= self.max_proposals:
                        self.proposal_cache[cache_key] = proposals
                        return proposals

        proposals = proposals[: self.max_proposals]
        self.proposal_cache[cache_key] = proposals
        return proposals

    def detect(self, frame_bgr: np.ndarray, queries: List[str]):
        text_embeds = self._encode_text(queries)
        h, w = frame_bgr.shape[:2]

        if self.detector_input_size > 0 and max(h, w) > self.detector_input_size:
            scale = self.detector_input_size / float(max(h, w))
            det_w = max(32, int(w * scale))
            det_h = max(32, int(h * scale))
            det_frame = cv2.resize(frame_bgr, (det_w, det_h), interpolation=cv2.INTER_AREA)
            sx = w / float(det_w)
            sy = h / float(det_h)
        else:
            det_frame = frame_bgr
            det_h, det_w = h, w
            sx = 1.0
            sy = 1.0

        proposals = self._build_proposals(det_h, det_w)
        frame_rgb = cv2.cvtColor(det_frame, cv2.COLOR_BGR2RGB)

        crops = []
        for x1, y1, x2, y2 in proposals:
            patch = frame_rgb[y1:y2, x1:x2]
            if patch.size == 0:
                patch = frame_rgb
            crops.append(Image.fromarray(patch))

        image_inputs = self.processor(images=crops, return_tensors="np")
        for k in image_inputs.keys():
            image_inputs[k] = image_inputs[k].astype(np.float32)

        vision_inputs = {name: image_inputs[name] for name in self.vision_input_names}
        image_embeds = self.vision_session.run(None, vision_inputs)[0]
        image_embeds = _l2norm(image_embeds)

        sim = np.matmul(image_embeds, text_embeds.T)
        best_idx = np.argmax(sim, axis=1)
        best_score = np.max(sim, axis=1)

        cls_boxes = {}
        cls_scores = {}
        for i, score in enumerate(best_score):
            if float(score) < self.score_thr:
                continue
            cls_id = int(best_idx[i])
            cls_name = queries[cls_id]
            cls_boxes.setdefault(cls_name, []).append(proposals[i])
            cls_scores.setdefault(cls_name, []).append(float(score))

        dets = []
        for cls_name in cls_boxes.keys():
            boxes = np.array(cls_boxes[cls_name], dtype=np.float32)
            scores = np.array(cls_scores[cls_name], dtype=np.float32)
            keep = _nms(boxes, scores, self.nms_iou)
            for k in keep:
                x1, y1, x2, y2 = boxes[k].astype(int).tolist()
                dets.append((x1, y1, x2, y2, float(scores[k]), cls_name))

        dets.sort(key=lambda x: x[4], reverse=True)
        if not dets:
            return []
        # 只保留置信度最高的一个目标
        x1, y1, x2, y2, score, cls_name = dets[0]
        x1 = int(np.clip(round(x1 * sx), 0, w - 1))
        y1 = int(np.clip(round(y1 * sy), 0, h - 1))
        x2 = int(np.clip(round(x2 * sx), 0, w - 1))
        y2 = int(np.clip(round(y2 * sy), 0, h - 1))
        return [(x1, y1, x2, y2, score, cls_name)]


def draw_detections(frame: np.ndarray, dets, query_text: str) -> np.ndarray:
    out = frame.copy()
    for x1, y1, x2, y2, score, cls in dets:
        color = (60, 220, 60)
        cv2.rectangle(out, (x1, y1), (x2, y2), color, 2)
        label = f"{cls}: {score:.2f}"
        cv2.putText(out, label, (x1, max(18, y1 - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2)

    title = f"Open-Vocab Detection | target: {query_text}"
    cv2.putText(out, title, (10, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 220, 220), 2)
    cv2.putText(out, "Press q to exit", (10, 50), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
    return out


def parse_args():
    parser = argparse.ArgumentParser(description="Real-time Open-Vocabulary Detection with Local CLIP ONNX")
    parser.add_argument("--camera", type=int, default=0, help="摄像头索引")
    parser.add_argument("--score-thr", type=float, default=0.24, help="相似度阈值（建议 0.20~0.35）")
    parser.add_argument("--infer-interval", type=int, default=4, help="每 N 帧推理一次，降低延迟")
    parser.add_argument("--processor-dir", type=str, default="./", help="本地 processor 目录")
    parser.add_argument("--text-onnx", type=str, default="./fmodel/text_model.onnx", help="本地 text ONNX")
    parser.add_argument("--vision-onnx", type=str, default="./fmodel/vision_model.onnx", help="本地 vision ONNX")
    parser.add_argument("--max-proposals", type=int, default=48, help="每帧滑窗候选框数量上限")
    parser.add_argument("--nms-iou", type=float, default=0.40, help="NMS IoU 阈值")
    parser.add_argument("--max-boxes", type=int, default=1, help="每帧最多显示框数（固定为 1）")
    parser.add_argument("--detector-input-size", type=int, default=320, help="检测分支输入长边尺寸，越小越快")
    parser.add_argument("--ort-threads", type=int, default=0, help="ONNXRuntime 线程数，0 表示自动")
    parser.add_argument(
        "--keywords",
        type=str,
        default="computer",
        help="初始目标文本（单目标）",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    initial_target = args.keywords.split(",")[0].strip() if args.keywords else ""
    initial_queries = [initial_target if initial_target else "person"]

    state = SharedQueryState(initial_queries)

    if tk is not None:
        ui_thread = threading.Thread(target=QueryControlWindow(state).run, daemon=True)
        ui_thread.start()
        print("[INFO] UI control window started.")
    else:
        print("[WARN] tkinter 不可用，无法弹出关键词输入窗口。")
        print("[WARN] 可用 --keywords 指定初始关键词。")

    detector = OpenVocabDetector(
        score_thr=args.score_thr,
        processor_dir=args.processor_dir,
        text_onnx=args.text_onnx,
        vision_onnx=args.vision_onnx,
        max_proposals=args.max_proposals,
        nms_iou=args.nms_iou,
        max_boxes=args.max_boxes,
        detector_input_size=args.detector_input_size,
        ort_threads=args.ort_threads,
    )

    cap = cv2.VideoCapture(args.camera)
    if not cap.isOpened():
        raise RuntimeError(f"无法打开摄像头: {args.camera}")

    print("[INFO] Camera started. Press q in video window to quit.")

    frame_idx = 0
    cached_dets = []
    last_query_version = -1

    while True:
        ok, frame = cap.read()
        if not ok:
            print("[WARN] 读取摄像头帧失败，结束。")
            break

        queries, version = state.get_snapshot()
        need_infer = (frame_idx % max(1, args.infer_interval) == 0) or (version != last_query_version)

        if need_infer:
            try:
                cached_dets = detector.detect(frame, queries)
            except Exception as e:
                print(f"[WARN] 推理失败: {e}")
            last_query_version = version

        rendered = draw_detections(frame, cached_dets, queries[0])
        cv2.imshow("Real-time Open-Vocabulary Detection", rendered)

        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            break

        frame_idx += 1

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
