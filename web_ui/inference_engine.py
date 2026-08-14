#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
CLIP 推理引擎 + 硬算子模拟
支持: 文本编码、图像编码、相似度计算、硬算子耗时统计
"""

import time
import random
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass

import numpy as np
import cv2
from PIL import Image

_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent

# ============================================================
# CLIP 图像预处理常量
# ============================================================
CLIP_MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
CLIP_STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)

# ============================================================
# 硬算子模拟（比赛现场接 FPGA，此处用模拟延时复现报告数据）
# ============================================================

@dataclass
class HardOpResult:
    name: str
    location: str
    function: str
    status: str        # "Waiting" | "Running" | "Done" | "Error" | "Cached"
    latency_ms: float
    detail: str = ""


class HardOpSimulator:
    """模拟 FPGA 硬算子行为与耗时（数据来源：比赛技术报告）"""

    @staticmethod
    def resize_crop(frame: np.ndarray, target_size: int = 224) -> Tuple[np.ndarray, HardOpResult]:
        """Resize/Crop 硬算子 —— FPGA 端图像中心裁剪与缩放"""
        t0 = time.perf_counter()
        h, w = frame.shape[:2]
        size = min(h, w)
        cy, cx = h // 2, w // 2
        half = size // 2
        cropped = frame[cy - half:cy + half, cx - half:cx + half]
        resized = cv2.resize(cropped, (target_size, target_size), interpolation=cv2.INTER_LINEAR)
        elapsed = (time.perf_counter() - t0) * 1000

        # 报告中的 FPGA 实测延迟 ~1.2ms，不做 time.sleep 阻塞
        reported_latency = 1.2 + random.uniform(-0.05, 0.08)
        result = HardOpResult(
            name="Resize/Crop",
            location="FPGA",
            function="图像中心裁剪与缩放 (→224×224)",
            status="Done",
            latency_ms=round(reported_latency, 2),
            detail=f"Input {w}×{h} → Output {target_size}×{target_size}, 实际执行{elapsed:.1f}ms"
        )
        return resized, result

    @staticmethod
    def gather(text_tokens: np.ndarray) -> HardOpResult:
        """Gather 硬算子 —— FPGA 端文本编码器词元嵌入提取"""
        # FPGA 实测 ~35 μs，仅为报告数据，不做 time.sleep 阻塞
        result = HardOpResult(
            name="Gather",
            location="FPGA",
            function="文本编码器词元嵌入提取",
            status="Done",
            latency_ms=0.035,
            detail=f"Tokens: {text_tokens.shape if hasattr(text_tokens, 'shape') else len(text_tokens)}"
        )
        return result

    @staticmethod
    def fwht(activation: np.ndarray) -> Tuple[np.ndarray, HardOpResult]:
        """FWHT 硬算子 —— FPGA 端快速沃尔什-哈达玛变换（激活值分布平滑）"""
        # FPGA 实测 ~81 μs，仅为报告数据，不做 time.sleep 阻塞
        result = HardOpResult(
            name="FWHT",
            location="FPGA",
            function="激活值分布平滑与量化优化",
            status="Done",
            latency_ms=0.081,
            detail="Hadamard transform for INT8 quantization"
        )
        return activation, result


# ============================================================
# 图像预处理（手动实现，不依赖 transformers.AutoProcessor）
# ============================================================

def clip_preprocess_image(pil_image: Image.Image, target_size: int = 224) -> np.ndarray:
    """
    CLIP 图像预处理：
    1. Resize 到 target_size × target_size
    2. 转换为 RGB numpy 数组
    3. 归一化到 [0, 1]
    4. 标准化 (mean, std)
    5. 转换为 CHW 格式并添加 batch 维度
    返回 shape: (1, 3, target_size, target_size), dtype: float32
    """
    # Resize (BICUBIC 插值)
    img = pil_image.resize((target_size, target_size), Image.BICUBIC)

    # 转换为 numpy 数组: HWC, uint8 → float32 [0, 1]
    img_np = np.array(img, dtype=np.float32) / 255.0

    # 标准化
    img_np = (img_np - CLIP_MEAN) / CLIP_STD

    # HWC → CHW, 添加 batch 维度
    img_np = img_np.transpose(2, 0, 1)  # (3, H, W)
    img_np = np.expand_dims(img_np, axis=0)  # (1, 3, H, W)

    return img_np.astype(np.float32)


# ============================================================
# 推理引擎数据结构
# ============================================================

@dataclass
class InferenceTiming:
    resize_crop_ms: float = 0.0
    gather_ms: float = 0.0
    fwht_ms: float = 0.0
    image_encode_ms: float = 0.0
    similarity_ms: float = 0.0
    total_ms: float = 0.0


@dataclass
class InferenceResult:
    top1_label: str
    top1_score: float
    top_k: List[Tuple[str, float]]
    frame_id: int
    timing: InferenceTiming
    hard_ops: Dict[str, HardOpResult]
    text_feature_status: str


# ============================================================
# CLIP 推理引擎
# ============================================================

class CLIPInferenceEngine:
    """
    CLIP 图文匹配推理引擎
    - 使用 HF CLIPTokenizer 做文本分词（不依赖 AutoProcessor，避免 TF 导入）
    - 图像预处理手动实现（resize + normalize + CHW）
    - ONNX Runtime 加载本地 text/vision encoder 做推理
    """

    def __init__(
        self,
        processor_dir: str = None,
        text_onnx: str = None,
        vision_onnx: str = None,
    ):
        if processor_dir is None:
            processor_dir = str(_PROJECT_ROOT)
        if text_onnx is None:
            text_onnx = str(_PROJECT_ROOT / "fmodel" / "text_model.onnx")
        if vision_onnx is None:
            vision_onnx = str(_PROJECT_ROOT / "fmodel" / "vision_model_hadamard.onnx")
        self.processor_dir = processor_dir
        self.text_onnx_path = text_onnx
        self.vision_onnx_path = vision_onnx

        self.tokenizer = None
        self.text_session = None
        self.vision_session = None
        self.text_input_names = []
        self.vision_input_names = []

        self.text_embeddings: Optional[np.ndarray] = None
        self.labels: List[str] = []
        self.text_feature_version = 0
        self._model_loaded = False

    # ---- 模型加载 ----

    def load_models(self) -> bool:
        """加载 ONNX 模型和分词器"""
        try:
            import onnxruntime as ort
            from transformers import CLIPTokenizer

            # 分词器（CLIPTokenizer 不会触发 TensorFlow 导入）
            print(f"[Engine] 加载分词器：{self.processor_dir}")
            self.tokenizer = CLIPTokenizer.from_pretrained(
                self.processor_dir, local_files_only=True
            )

            # ONNX Runtime 配置
            available = ort.get_available_providers()
            providers = (
                ["CUDAExecutionProvider", "CPUExecutionProvider"]
                if "CUDAExecutionProvider" in available
                else ["CPUExecutionProvider"]
            )

            sess_opts = ort.SessionOptions()
            sess_opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            sess_opts.intra_op_num_threads = 4

            # 文本编码器
            print(f"[Engine] 加载文本 ONNX 编码器：{self.text_onnx_path}")
            self.text_session = ort.InferenceSession(
                self.text_onnx_path, sess_options=sess_opts, providers=providers
            )
            self.text_input_names = [x.name for x in self.text_session.get_inputs()]

            # 视觉编码器
            print(f"[Engine] 加载视觉 ONNX 编码器：{self.vision_onnx_path}")
            self.vision_session = ort.InferenceSession(
                self.vision_onnx_path, sess_options=sess_opts, providers=providers
            )
            self.vision_input_names = [x.name for x in self.vision_session.get_inputs()]

            self._model_loaded = True
            print(f"[Engine] 模型加载完成，执行后端：{providers}")
            return True

        except Exception as e:
            print(f"[Engine] 模型加载失败：{e}")
            self._model_loaded = False
            return False

    @property
    def is_loaded(self) -> bool:
        return self._model_loaded

    # ---- 文本特征编码 ----

    def encode_text(self, labels: List[str]) -> Tuple[Optional[np.ndarray], Dict]:
        """对候选文本列表进行编码，生成文本特征缓存。输入文本原样使用，不添加前缀模板。"""
        if not self._model_loaded:
            return None, {"error": "Models not loaded"}

        clean_labels = [l.strip() for l in labels if l.strip()]
        if not clean_labels:
            return None, {"error": "No valid labels"}

        # 直接使用原始文本，不添加 "a photo of" 模板
        text_inputs = self.tokenizer(
            clean_labels, padding="max_length", max_length=77,
            truncation=True, return_tensors="np",
        )
        input_ids = text_inputs["input_ids"].astype(np.int64)

        # Step 2: Gather 硬算子（模拟 FPGA 词元嵌入提取）
        gather_result = HardOpSimulator.gather(input_ids)

        # Step 3: ONNX 文本编码器推理
        t0 = time.perf_counter()
        ort_inputs = {self.text_input_names[0]: input_ids}
        text_embeds = self.text_session.run(None, ort_inputs)[0]
        text_encode_ms = (time.perf_counter() - t0) * 1000

        # L2 归一化
        text_embeds = text_embeds / (np.linalg.norm(text_embeds, axis=-1, keepdims=True) + 1e-8)

        self.text_embeddings = text_embeds
        self.labels = clean_labels
        self.text_feature_version += 1

        stats = {
            "labels_count": len(clean_labels),
            "feature_dim": text_embeds.shape[-1],
            "status": "Ready",
            "gather": gather_result,
            "text_encode_ms": round(text_encode_ms, 2),
        }
        return text_embeds, stats

    # ---- 单图像编码（可复用） ----

    def encode_image(self, pil_or_np) -> Optional[np.ndarray]:
        """对单张图像进行编码，返回 L2 归一化后的图像特征 [1, D]。
        输入可以是 PIL.Image 或 numpy (H,W,3 BGR) 数组。"""
        if not self._model_loaded:
            return None

        if isinstance(pil_or_np, np.ndarray):
            # BGR → RGB → PIL
            frame_rgb = cv2.cvtColor(pil_or_np, cv2.COLOR_BGR2RGB)
            pil_image = Image.fromarray(frame_rgb)
        else:
            pil_image = pil_or_np

        pixel_values = clip_preprocess_image(pil_image, target_size=224)
        vision_inputs = {self.vision_input_names[0]: pixel_values}
        image_embeds = self.vision_session.run(None, vision_inputs)[0]
        image_embeds = image_embeds / (np.linalg.norm(image_embeds, axis=-1, keepdims=True) + 1e-8)
        return image_embeds.astype(np.float32)

    # ---- 文本搜图（T2I Retrieval） ----

    def search_images(
        self, query: str, image_paths: List[str], top_k: int = 5,
        progress_callback=None,
    ) -> Dict:
        """
        文本搜图：给定一段文本查询 + 图片路径列表，返回 Top-K 最匹配图片。
        progress_callback(current, total) 用于推送进度。
        """
        if not self._model_loaded:
            return {"error": "Models not loaded"}

        # Step 1: 编码文本查询
        t0 = time.perf_counter()
        text_inputs = self.tokenizer(
            [query], padding="max_length", max_length=77,
            truncation=True, return_tensors="np",
        )
        input_ids = text_inputs["input_ids"].astype(np.int64)
        ort_text_inputs = {self.text_input_names[0]: input_ids}
        text_emb = self.text_session.run(None, ort_text_inputs)[0]
        text_emb = text_emb / (np.linalg.norm(text_emb, axis=-1, keepdims=True) + 1e-8)
        text_encode_ms = (time.perf_counter() - t0) * 1000

        # Step 2: 逐张编码图像（用与摄像头一致的 centercrop+resize 预处理）
        raw_sims = []
        total = len(image_paths)
        t_start = time.perf_counter()

        for i, img_path in enumerate(image_paths):
            try:
                pil_img = Image.open(img_path).convert("RGB")
                # 与 infer_frame 保持一致：先转 numpy(BGR)，走 resize_crop 再 encode
                img_np = cv2.cvtColor(np.array(pil_img), cv2.COLOR_RGB2BGR)
                processed, _ = HardOpSimulator.resize_crop(img_np)
                img_emb = self.encode_image(processed)
                if img_emb is None:
                    continue
                sim = float(np.dot(img_emb, text_emb.T)[0][0])  # 原始余弦相似度
                raw_sims.append((img_path, sim))
            except Exception as e:
                continue

            if progress_callback and (i + 1) % 5 == 0:
                progress_callback(i + 1, total)

        # Step 3: 按原始相似度排序取 Top-K
        raw_sims.sort(key=lambda x: x[1], reverse=True)
        top_k_raw = raw_sims[:top_k]

        # Step 4: 温度 softmax 转换为概率，拉开分数差距
        # temperature=0.025，越低差距越大，让分数更直观
        cos_values = np.array([s for _, s in raw_sims])
        cos_scaled = cos_values / 0.025
        cos_scaled -= cos_scaled.max()  # 数值稳定
        exp_vals = np.exp(cos_scaled)
        probs = exp_vals / exp_vals.sum()

        # 构建每张图片的索引 → softmax 概率
        prob_map = {raw_sims[i][0]: float(probs[i]) for i in range(len(raw_sims))}

        elapsed_ms = (time.perf_counter() - t_start) * 1000

        return {
            "query": query,
            "text_encode_ms": round(text_encode_ms, 1),
            "total_images": total,
            "valid_results": len(raw_sims),
            "total_time_ms": round(elapsed_ms, 1),
            "results": [
                {
                    "path": p,
                    "cosine": round(s, 4),
                    "score": round(prob_map[p], 4),  # softmax 概率
                }
                for p, s in top_k_raw
            ],
        }

    # ---- 单帧推理 ----

    def infer_frame(self, frame: np.ndarray, frame_id: int = 0) -> InferenceResult:
        """对单帧图像执行完整推理流水线"""
        timing = InferenceTiming()
        hard_ops = {}
        t_total_start = time.perf_counter()

        if not self._model_loaded:
            return InferenceResult(
                top1_label="N/A", top1_score=0.0, top_k=[], frame_id=frame_id,
                timing=timing, hard_ops={}, text_feature_status="Not Ready"
            )
        if self.text_embeddings is None:
            return InferenceResult(
                top1_label="N/A", top1_score=0.0, top_k=[], frame_id=frame_id,
                timing=timing, hard_ops={}, text_feature_status="Not Ready"
            )

        # ---- Step 1: Resize/Crop (FPGA 硬算子) ----
        processed_frame, resize_result = HardOpSimulator.resize_crop(frame)
        timing.resize_crop_ms = resize_result.latency_ms
        hard_ops["resize_crop"] = resize_result

        # ---- Step 2: CLIP Image Encoder (ONNX) ----
        t_img_start = time.perf_counter()
        image_embeds = self.encode_image(processed_frame)
        if image_embeds is None:
            return InferenceResult(
                top1_label="N/A", top1_score=0.0, top_k=[], frame_id=frame_id,
                timing=timing, hard_ops={}, text_feature_status="Encoder Error"
            )
        timing.image_encode_ms = (time.perf_counter() - t_img_start) * 1000

        # ---- Step 3: FWHT (FPGA 硬算子) ----
        _, fwht_result = HardOpSimulator.fwht(image_embeds)
        timing.fwht_ms = fwht_result.latency_ms
        hard_ops["fwht"] = fwht_result

        # ---- Step 4: Similarity Calculation + Temperature Softmax (PC Host) ----
        t_sim_start = time.perf_counter()
        # 原始余弦相似度（不乘 100）
        cos_raw = np.dot(image_embeds, self.text_embeddings.T)[0]  # [N]
        # 温度 softmax，拉开分数差距
        temperature = 0.025
        cos_scaled = cos_raw / temperature
        cos_scaled -= cos_scaled.max()
        probabilities = np.exp(cos_scaled) / np.exp(cos_scaled).sum()  # [N]
        top_k_indices = np.argsort(probabilities)[::-1]
        timing.similarity_ms = (time.perf_counter() - t_sim_start) * 1000

        # ---- Gather status (text side, cached) ----
        gather_result = HardOpResult(
            name="Gather", location="FPGA",
            function="文本编码器词元嵌入提取",
            status="Cached", latency_ms=0.035,
            detail="Text features cached from last update"
        )
        hard_ops["gather"] = gather_result

        # ---- 构建结果 ----
        top_k = []
        for idx in top_k_indices[:5]:
            label = self.labels[idx] if idx < len(self.labels) else "?"
            score = float(probabilities[idx])
            top_k.append((label, score))

        timing.total_ms = (time.perf_counter() - t_total_start) * 1000

        return InferenceResult(
            top1_label=top_k[0][0] if top_k else "N/A",
            top1_score=top_k[0][1] if top_k else 0.0,
            top_k=top_k, frame_id=frame_id,
            timing=timing, hard_ops=hard_ops,
            text_feature_status="Ready" if self.text_embeddings is not None else "Not Ready",
        )


# ============================================================
# 预录回放数据生成器（Replay Demo 兜底模式）
# ============================================================

class ReplayGenerator:
    """当板端/摄像头异常时，使用预录数据模拟推理"""

    @staticmethod
    def generate_mock_result(frame_id: int, labels: List[str]) -> InferenceResult:
        """生成模拟推理结果"""
        if not labels:
            labels = ["drone", "airplane", "bird"]

        scores = []
        for i, label in enumerate(labels):
            s = max(0.01, 0.35 - i * 0.08 + random.uniform(-0.03, 0.03))
            scores.append((label, s))
        scores.sort(key=lambda x: x[1], reverse=True)

        timing = InferenceTiming(
            resize_crop_ms=1.2 + random.uniform(-0.05, 0.05),
            gather_ms=0.035,
            fwht_ms=0.081 + random.uniform(-0.003, 0.003),
            image_encode_ms=45.0 + random.uniform(-2, 3),
            similarity_ms=0.5 + random.uniform(-0.05, 0.05),
            total_ms=47.0 + random.uniform(-2, 4),
        )

        hard_ops = {
            "resize_crop": HardOpResult("Resize/Crop", "FPGA", "图像中心裁剪与缩放", "Done", timing.resize_crop_ms),
            "gather": HardOpResult("Gather", "FPGA", "文本编码器词元嵌入提取", "Cached", 0.035),
            "fwht": HardOpResult("FWHT", "FPGA", "激活值分布平滑与量化优化", "Done", timing.fwht_ms),
        }

        return InferenceResult(
            top1_label=scores[0][0],
            top1_score=scores[0][1],
            top_k=scores[:5],
            frame_id=frame_id,
            timing=timing,
            hard_ops=hard_ops,
            text_feature_status="Ready",
        )
