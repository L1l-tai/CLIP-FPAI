#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
CLIP 图文匹配演示系统 - FastAPI WebSocket 服务端
提供: 实时视频流 / 推理控制 / 硬算子状态 / 性能统计 / 日志推送
"""

import asyncio
import argparse
import base64
import json
import time
import threading
import queue
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

import cv2
import numpy as np

from inference_engine import (
    CLIPInferenceEngine, HardOpSimulator, ReplayGenerator,
    InferenceResult, InferenceTiming, HardOpResult
)
try:
    from operator_analysis import run_fwht_analysis, run_resize_analysis, run_gather_analysis
    _ANALYSIS_AVAILABLE = True
except Exception as e:
    print(f"[WARN] operator_analysis import failed: {e}")
    _ANALYSIS_AVAILABLE = False
    run_fwht_analysis = None
    run_resize_analysis = None

# FastAPI
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
import uvicorn

# ============================================================
# App 初始化
# ============================================================

app = FastAPI(title="CLIP Demo System", version="1.0")

STATIC_DIR = Path(__file__).parent / "static"
STATIC_DIR.mkdir(exist_ok=True)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/")
async def root():
    return FileResponse(str(STATIC_DIR / "index.html"))


# ============================================================
# 系统状态管理
# ============================================================

class SystemState:
    def __init__(self):
        self.board_connected = False
        self.camera_running = False
        self.socket_connected = False
        self.text_encoder_ready = False
        self.image_encoder_running = False
        self.custom_op_enabled = False       # 硬算子是否启用（模拟为始终启用）
        self.current_mode = "pc"             # "board" | "pc" | "replay"
        self.inference_running = False
        self.model_loaded = False

    def to_dict(self):
        return {
            "board": "Connected" if self.board_connected else "Disconnected",
            "camera": "Running" if self.camera_running else "Offline",
            "socket": "Connected" if self.socket_connected else "Disconnected",
            "text_encoder": "Ready" if self.text_encoder_ready else "Not Ready",
            "image_encoder": "Running" if self.image_encoder_running else "Idle",
            "custom_op": "Enabled" if self.custom_op_enabled else "Disabled",
            "mode": {
                "pc": "PC摄像头",
                "board": "开发板摄像头",
                "replay": "回放演示",
            }.get(self.current_mode, self.current_mode),
            "inference": "Running" if self.inference_running else "Paused",
        }


state = SystemState()
log_queue: queue.Queue = queue.Queue()


def emit_log(msg: str, level: str = ""):
    """推一条日志"""
    timestamp = datetime.now().strftime("%H:%M:%S")
    entry = {"timestamp": timestamp, "message": msg, "level": level}
    log_queue.put(entry)
    print(f"[{timestamp}] {msg}")


# ============================================================
# 推理引擎
# ============================================================

engine = CLIPInferenceEngine()
default_labels = ["drone", "airplane", "bird", "helicopter", "balloon",
                  "person", "car", "dog", "cat", "bicycle"]

# ============================================================
# 摄像头管理
# ============================================================

class CameraManager:
    def __init__(self, camera_id: int = 0):
        self.camera_id = camera_id
        self.cap: Optional[cv2.VideoCapture] = None
        self._running = False
        self._lock = threading.Lock()

    def start(self, camera_id: int = None) -> bool:
        """启动摄像头。传入 camera_id 则切换设备。"""
        with self._lock:
            if camera_id is not None and camera_id != self.camera_id:
                self.camera_id = camera_id
                # 如果正在运行，先释放旧设备再开新的
                if self._running and self.cap:
                    self.cap.release()
                    self.cap = None
                    self._running = False
            if self._running:
                return True
            self.cap = cv2.VideoCapture(self.camera_id)
            if not self.cap.isOpened():
                self.cap = None
                return False
            self._running = True
            return True

    def stop(self):
        with self._lock:
            self._running = False
            if self.cap:
                self.cap.release()
                self.cap = None

    def current_id(self) -> int:
        return self.camera_id

    def read_frame(self) -> Optional[np.ndarray]:
        with self._lock:
            if not self._running or self.cap is None:
                return None
            ret, frame = self.cap.read()
            return frame if ret else None

    @property
    def is_running(self) -> bool:
        with self._lock:
            return self._running


camera: Optional[CameraManager] = None  # 在 main 中初始化

# ============================================================
# WebSocket 消息处理
# ============================================================

class ConnectionManager:
    def __init__(self):
        self.active: List[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)
        state.socket_connected = True
        emit_log("客户端已连接。")

    def disconnect(self, ws: WebSocket):
        if ws in self.active:
            self.active.remove(ws)
        if not self.active:
            state.socket_connected = False
        emit_log("客户端已断开。")

    async def broadcast(self, data: dict):
        dead = []
        for ws in self.active:
            try:
                await ws.send_json(data)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws)

    async def send_to(self, ws: WebSocket, data: dict):
        try:
            await ws.send_json(data)
        except Exception:
            self.disconnect(ws)


manager = ConnectionManager()


async def handle_message(ws: WebSocket, msg: dict):
    """处理客户端发来的控制消息"""
    msg_type = msg.get("type", "")

    # ---- 模型加载 ----
    if msg_type == "load_models":
        emit_log("正在加载 CLIP 模型...")
        loop = asyncio.get_running_loop()
        success = await loop.run_in_executor(None, engine.load_models)
        state.model_loaded = success
        if success:
            state.text_encoder_ready = True
            state.image_encoder_running = True
            state.custom_op_enabled = True
            emit_log("CLIP 模型加载成功。")
        else:
            emit_log("错误：CLIP 模型加载失败！")
        await manager.send_to(ws, {"type": "model_loaded", "success": success})
        await broadcast_system_status()

    # ---- 连接开发板 ----
    elif msg_type == "connect_board":
        emit_log("正在连接开发板...")
        await asyncio.sleep(0.3)
        # 模拟连接结果（真实场景下检查网络 / UART 连接）
        connected = msg.get("force", True)
        state.board_connected = connected
        if connected:
            emit_log("开发板已连接。")
        else:
            emit_log("错误：开发板连接失败！")
        await broadcast_system_status()

    # ---- 摄像头控制 ----
    elif msg_type == "start_camera":
        cam_id = msg.get("camera_id")
        if cam_id is not None:
            success = camera.start(camera_id=int(cam_id))
        else:
            success = camera.start()
        state.camera_running = success
        if success:
            emit_log(f"摄像头已启动（索引 {camera.current_id()}）。")
        else:
            emit_log(f"错误：无法打开摄像头（索引 {camera.current_id()}）！")
        await broadcast_system_status()

    elif msg_type == "stop_camera":
        camera.stop()
        state.camera_running = False
        state.inference_running = False
        emit_log("摄像头已停止。")
        await broadcast_system_status()

    # ---- 文本特征更新 ----
    elif msg_type == "update_text_features":
        labels = msg.get("labels", default_labels)
        if not labels:
            emit_log("警告：未提供候选文本，使用默认类别。")
            labels = default_labels
        emit_log(f"正在更新文本特征，共 {len(labels)} 个候选类别...")
        # 在线程池中运行 ONNX 推理，避免阻塞事件循环
        loop = asyncio.get_running_loop()
        _, stats = await loop.run_in_executor(None, engine.encode_text, labels)
        if stats.get("error"):
            emit_log(f"错误：{stats['error']}")
        else:
            state.text_encoder_ready = True
            emit_log(
                f"文本特征已更新：{stats['labels_count']} 个类别，"
                f"维度={stats['feature_dim']}"
            )
            gather = stats.get("gather")
            if gather:
                await manager.send_to(ws, {
                    "type": "hard_op_update",
                    "op": "gather",
                    "data": _hard_op_to_dict(gather),
                })
        await broadcast_system_status()

    # ---- 推理控制 ----
    elif msg_type == "start_inference":
        if not state.camera_running:
            ok = camera.start()
            state.camera_running = ok
            if not ok:
                emit_log("错误：无法启动摄像头进行推理！")
                await broadcast_system_status()
                return
        state.inference_running = True
        emit_log("实时推理已开始。")

    elif msg_type == "pause_inference":
        state.inference_running = False
        emit_log("推理已暂停。")

    elif msg_type == "single_inference":
        emit_log("已触发单帧推理。")

    elif msg_type == "switch_mode":
        mode = msg.get("mode", "pc")
        old = state.current_mode
        state.current_mode = mode
        emit_log(f"运行模式切换：{old} → {mode}")
        await broadcast_system_status()

    elif msg_type == "verify_hard_ops":
        emit_log("已触发硬算子验证。")
        # 模拟一次硬算子验证
        dummy = np.zeros((224, 224, 3), dtype=np.uint8) + 128
        _, rc = HardOpSimulator.resize_crop(
            np.zeros((480, 640, 3), dtype=np.uint8) + 128
        )
        gather = HardOpSimulator.gather(np.zeros((1, 77), dtype=np.int64))
        _, fwht = HardOpSimulator.fwht(np.random.randn(1, 512).astype(np.float32))

        for op in [rc, gather, fwht]:
            await manager.send_to(ws, {
                "type": "hard_op_update",
                "op": op.name.lower().replace("/", "_"),
                "data": _hard_op_to_dict(op),
            })
        emit_log("硬算子验证完成。")

    # ---- 文本搜图（T2I Retrieval） ----
    elif msg_type == "list_images":
        folder = msg.get("folder", "")
        if not folder or not Path(folder).is_dir():
            await manager.send_to(ws, {
                "type": "image_list",
                "folder": folder,
                "images": [],
                "error": "文件夹不存在或不可访问",
            })
            return
        exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
        images = sorted([
            str(p) for p in Path(folder).iterdir()
            if p.suffix.lower() in exts and not p.name.startswith(".")
        ])
        emit_log(f"列出图片文件夹：{folder}，共 {len(images)} 张")
        await manager.send_to(ws, {
            "type": "image_list",
            "folder": folder,
            "images": images,
            "count": len(images),
        })

    elif msg_type == "search_images":
        query = msg.get("query", "")
        folder = msg.get("folder", "")
        top_k = int(msg.get("top_k", 5))

        if not query:
            await manager.send_to(ws, {
                "type": "search_result",
                "error": "请输入查询文本",
            })
            return
        if not folder or not Path(folder).is_dir():
            await manager.send_to(ws, {
                "type": "search_result",
                "error": "图片文件夹无效",
            })
            return

        # 收集图片路径
        exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
        image_paths = sorted(
            str(p) for p in Path(folder).iterdir()
            if p.suffix.lower() in exts and not p.name.startswith(".")
        )
        if not image_paths:
            await manager.send_to(ws, {
                "type": "search_result",
                "error": "文件夹中没有图片",
            })
            return

        emit_log(f"文本搜图：\"{query}\" ← {folder}（共 {len(image_paths)} 张）")
        loop = asyncio.get_running_loop()

        # 进度回调
        def progress_cb(current, total):
            pass  # 非异步上下文，暂不推送中间进度

        result = await loop.run_in_executor(
            None,
            lambda: engine.search_images(query, image_paths, top_k=top_k, progress_callback=progress_cb)
        )

        if "error" in result:
            await manager.send_to(ws, {"type": "search_result", "error": result["error"]})
            return

        # 读取 Top-K 图片为 base64
        top_results = []
        for r in result["results"]:
            try:
                with open(r["path"], "rb") as f:
                    img_bytes = f.read()
                b64 = base64.b64encode(img_bytes).decode("utf-8")
                # 判断 MIME
                ext = Path(r["path"]).suffix.lower()
                mime = {"jpg": "jpeg", "jpeg": "jpeg", "png": "png", "bmp": "bmp", "webp": "webp"}.get(ext.lstrip("."), "jpeg")
                top_results.append({
                    "path": r["path"],
                    "name": Path(r["path"]).name,
                    "cosine": r.get("cosine", 0),
                    "score": r["score"],
                    "base64": f"data:image/{mime};base64,{b64}",
                })
            except Exception as e:
                emit_log(f"读取图片失败：{r['path']} - {e}")

        await manager.send_to(ws, {
            "type": "search_result",
            "query": result["query"],
            "total_images": result["total_images"],
            "valid_results": result["valid_results"],
            "text_encode_ms": result["text_encode_ms"],
            "total_time_ms": result["total_time_ms"],
            "results": top_results,
        })
        emit_log(
            f"搜图完成：Top-1={top_results[0]['name'] if top_results else 'N/A'} "
            f"({top_results[0]['score']:.4f})，总耗时 {result['total_time_ms']:.0f}ms"
        )

    elif msg_type == "run_fwht_analysis":
        if not _ANALYSIS_AVAILABLE:
            emit_log("算子分析模块未加载，请检查依赖", "error")
        else:
            emit_log("开始 FWHT 算子分析...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_fwht_analysis)
                await ws.send_json({"type": "fwht_result", "data": result})
                emit_log(f"FWHT 分析完成")
            except Exception as e:
                emit_log(f"FWHT 分析失败: {e}", "error")

    elif msg_type == "run_resize_analysis":
        if not _ANALYSIS_AVAILABLE:
            emit_log("算子分析模块未加载，请检查依赖", "error")
        else:
            emit_log("开始 Resize 算子分析...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_resize_analysis)
                await ws.send_json({"type": "resize_result", "data": result})
                emit_log(f"Resize 分析完成")
            except Exception as e:
                emit_log(f"Resize 分析失败: {e}", "error")

    elif msg_type == "run_gather_analysis":
        if not _ANALYSIS_AVAILABLE:
            emit_log("算子分析模块未加载", "error")
        else:
            emit_log("开始 Gather 算子分析...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_gather_analysis)
                await ws.send_json({"type": "gather_result", "data": result})
                emit_log("Gather 分析完成")
            except Exception as e:
                emit_log(f"Gather 分析失败: {e}", "error")

    elif msg_type == "get_system_status":
        await broadcast_system_status()

    else:
        emit_log(f"未知消息类型：{msg_type}")


def _hard_op_to_dict(op: HardOpResult) -> dict:
    return {
        "name": op.name,
        "location": op.location,
        "function": op.function,
        "status": op.status,
        "latency_ms": op.latency_ms,
        "detail": op.detail,
    }


async def broadcast_system_status():
    await manager.broadcast({"type": "system_status", "data": state.to_dict()})


# ============================================================
# 后台任务：帧采集与推理
# ============================================================

async def inference_loop(ws: WebSocket):
    """
    后台循环：只要摄像头开着就推送预览帧，推理开关控制是否执行 CLIP
    每个 WebSocket 客户端一个循环
    """
    frame_id = 0
    infer_interval = 2  # 每 N 帧推理一次

    while ws in manager.active:
        # 摄像头没开就不循环
        if not state.camera_running:
            await asyncio.sleep(0.2)
            continue

        # 读取帧
        t_frame = time.perf_counter()
        frame = camera.read_frame()

        if frame is None:
            await asyncio.sleep(0.05)
            continue

        # 始终推送预览帧（JPEG）
        _, jpeg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
        jpeg_b64 = base64.b64encode(jpeg).decode("utf-8")

        await manager.send_to(ws, {
            "type": "frame",
            "data": jpeg_b64,
            "frame_id": frame_id,
            "fps_preview": round(1.0 / max(0.001, time.perf_counter() - t_frame), 1),
        })

        # 推理开关打开 + 每隔 infer_interval 帧推理一次
        if state.inference_running and (frame_id % infer_interval == 0):
            if state.current_mode == "replay":
                result = ReplayGenerator.generate_mock_result(frame_id, engine.labels or default_labels)
            else:
                if engine.is_loaded and engine.text_embeddings is not None:
                    result = engine.infer_frame(frame, frame_id)
                else:
                    if not engine.is_loaded:
                        emit_log("模型未加载，使用模拟结果。请先点击 Load Models", "warning")
                    elif engine.text_embeddings is None:
                        emit_log("文本特征未初始化，使用模拟结果。请点击 更新文本特征", "warning")
                    result = ReplayGenerator.generate_mock_result(frame_id, default_labels)

            await send_pipeline_update(ws, result)
            await manager.send_to(ws, {
                "type": "inference_result",
                "data": infer_result_to_dict(result),
            })

            if not state.image_encoder_running:
                state.image_encoder_running = True
                await broadcast_system_status()

            emit_log(
                f"推理完成 帧号={frame_id}，Top-1={result.top1_label}，"
                f"相似度={result.top1_score:.3f}，总延迟={result.timing.total_ms:.1f}ms"
            )

        frame_id += 1
        await asyncio.sleep(0.03)


def infer_result_to_dict(r: InferenceResult) -> dict:
    return {
        "top1_label": r.top1_label,
        "top1_score": round(r.top1_score, 4),
        "top_k": [{"label": l, "score": round(s, 4)} for l, s in r.top_k],
        "frame_id": r.frame_id,
        "timing": {
            "resize_crop_ms": r.timing.resize_crop_ms,
            "gather_ms": r.timing.gather_ms,
            "fwht_ms": r.timing.fwht_ms,
            "image_encode_ms": round(r.timing.image_encode_ms, 1),
            "similarity_ms": round(r.timing.similarity_ms, 2),
            "total_ms": round(r.timing.total_ms, 1),
        },
        "hard_ops": {k: _hard_op_to_dict(v) for k, v in r.hard_ops.items()},
        "text_feature_status": r.text_feature_status,
    }


async def send_pipeline_update(ws: WebSocket, result: InferenceResult):
    """根据推理结果生成流水线各阶段状态"""
    stages = [
        {"name": "Camera Input", "status": "Done", "time": ""},
        {
            "name": "Resize/Crop",
            "status": result.hard_ops.get("resize_crop", HardOpResult("", "", "", "Waiting", 0)).status,
            "time": f"{result.timing.resize_crop_ms:.1f} ms",
        },
        {"name": "CLIP Image Encoder", "status": "Done", "time": f"{result.timing.image_encode_ms:.1f} ms"},
        {
            "name": "FWHT",
            "status": result.hard_ops.get("fwht", HardOpResult("", "", "", "Waiting", 0)).status,
            "time": f"{result.timing.fwht_ms * 1000:.0f} μs",
        },
        {"name": "Image Feature", "status": "Done", "time": ""},
        {"name": "Similarity Calc", "status": "Done", "time": f"{result.timing.similarity_ms:.1f} ms"},
        {"name": "Top-K Result", "status": "Done", "time": ""},
    ]
    await manager.send_to(ws, {"type": "pipeline_state", "stages": stages})


# ============================================================
# 后台任务：日志推送
# ============================================================

async def log_pusher(ws: WebSocket):
    """定时将日志队列中的消息推送给客户端"""
    while ws in manager.active:
        while not log_queue.empty():
            entry = log_queue.get_nowait()
            await manager.send_to(ws, {"type": "log", **entry})
            log_queue.task_done()
        await asyncio.sleep(0.2)


# ============================================================
# WebSocket 主入口
# ============================================================

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await manager.connect(ws)

    # 先推送当前系统状态
    await broadcast_system_status()
    emit_log("系统就绪，等待操作指令...")

    # 启动后台任务
    log_task = asyncio.create_task(log_pusher(ws))
    inference_task = asyncio.create_task(inference_loop(ws))

    try:
        while True:
            raw = await ws.receive_text()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                emit_log("警告：收到无效 JSON 数据。")
                continue
            await handle_message(ws, msg)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        emit_log(f"WebSocket 错误：{e}")
    finally:
        log_task.cancel()
        inference_task.cancel()
        manager.disconnect(ws)


# ============================================================
# 启动
# ============================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="CLIP 图文匹配演示系统")
    parser.add_argument("--camera", type=int, default=0, help="摄像头设备索引（默认 0）")
    parser.add_argument("--port", type=int, default=8888, help="服务端口（默认 8888）")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="绑定地址")
    args = parser.parse_args()

    camera = CameraManager(args.camera)
    print("=" * 55)
    print("  CLIP 图文匹配演示系统")
    print(f"  摄像头索引: {args.camera}")
    print(f"  浏览器打开 http://127.0.0.1:{args.port}")
    print("=" * 55)
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
