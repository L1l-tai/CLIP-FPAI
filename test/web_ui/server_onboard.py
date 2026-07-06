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
import subprocess
import re
import os

import cv2
import numpy as np

from inference_engine import (
    CLIPInferenceEngine, HardOpSimulator, ReplayGenerator,
    InferenceResult, InferenceTiming, HardOpResult
)
try:
    from operator_analysis_onboard import (
        run_fwht_hardware, run_fwht_visualize,
        run_resize_hardware, run_resize_visualize,
        run_gather_hardware, run_gather_visualize
    )
    _ANALYSIS_AVAILABLE = True
except Exception as e:
    print(f"[WARN] operator_analysis import failed: {e}")
    _ANALYSIS_AVAILABLE = False
    run_fwht_hardware = None; run_fwht_visualize = None
    run_resize_hardware = None; run_resize_visualize = None
    run_gather_hardware = None; run_gather_visualize = None

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
    return FileResponse(str(STATIC_DIR / "index_onboard.html"))


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


# ============================================================
# clip_app 子进程管理
# ============================================================

class ClipAppProcess:
    """管理 clip_app_web 子进程，通过 stdin/stdout 通信"""
    def __init__(self, exe="./clip_app_web", config="app_config.yaml"):
        self.exe = exe
        self.config = config
        self.proc = None
        self.lock = threading.Lock()
        self.ready = False          # [WEB] READY 收到后置 True

    def start(self) -> bool:
        if self.proc is not None:
            return True
        try:
            # stderr 合并到 stdout，所有输出统一从 stdout 读取
            self.proc = subprocess.Popen(
                [self.exe, self.config],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )
            self.ready = False
            emit_log(f"clip_app 已启动: {self.exe} {self.config}")
            return True
        except Exception as e:
            emit_log(f"clip_app 启动失败: {e}", "error")
            return False

    def send_cmd(self, cmd: str):
        if not self.proc or self.proc.stdin is None:
            emit_log("clip_app 未运行，无法发送命令", "warning")
            return
        if not self.ready:
            emit_log(f"clip_app 未就绪，命令已丢弃: {cmd}", "warning")
            return
        with self.lock:
            try:
                self.proc.stdin.write(cmd + "\n")
                self.proc.stdin.flush()
            except Exception as e:
                emit_log(f"clip_app 命令失败: {e}", "error")

    def read_line(self) -> Optional[str]:
        if not self.proc or self.proc.stdout is None:
            return None
        try:
            return self.proc.stdout.readline()
        except Exception:
            return None

    def stop(self):
        if self.proc:
            try:
                self.proc.stdin.write("\n")  # 空行退出
                self.proc.stdin.flush()
                self.proc.wait(timeout=3)
            except Exception:
                self.proc.kill()
            self.proc = None
            self.ready = False


clip_app: Optional[ClipAppProcess] = None


def parse_web_line(line: str) -> Optional[dict]:
    """解析 [WEB] 结构化输出行，返回 dict 或 None"""
    if not line.startswith("[WEB]"):
        return None
    content = line[6:]  # strip "[WEB] " prefix
    content = content.strip()

    if content.startswith("RESULT"):
        m = re.search(r'top1=(\S+)\s+score=([\d.]+)', content)
        if m:
            return {"type": "clip_result", "top1": m.group(1), "score": float(m.group(2))}
    elif content.startswith("LABELS"):
        labels_str = content[7:].strip()  # after "LABELS "
        labels = [l.strip() for l in labels_str.split(",") if l.strip()]
        return {"type": "clip_labels", "labels": labels}
    elif content.startswith("SEARCH"):
        m = re.search(r'query=(\S+)\s+top1_idx=(\d+)\s+score=([\d.]+)', content)
        if m:
            return {"type": "clip_search", "query": m.group(1),
                    "top1_idx": int(m.group(2)), "score": float(m.group(3))}
    elif content.startswith("MODE"):
        mode = content[5:].strip()
        return {"type": "clip_mode", "mode": mode}
    elif content.startswith("READY"):
        return {"type": "clip_ready"}
    return None


async def handle_message(ws: WebSocket, msg: dict):
    """处理客户端发来的控制消息"""
    msg_type = msg.get("type", "")

    # ---- 启动 clip_app ----
    if msg_type == "load_models":
        global clip_app
        emit_log("正在启动 clip_app...")
        if clip_app is None or clip_app.proc is None:
            exe = os.environ.get("CLIP_APP_EXE", "../clip_app_web")
            cfg = os.environ.get("CLIP_APP_CONFIG", "./configs/app_config.yaml")
            clip_app = ClipAppProcess(exe, cfg)
        success = clip_app.start()
        state.model_loaded = success
        if success:
            state.text_encoder_ready = True
            state.image_encoder_running = True
            state.custom_op_enabled = True
            emit_log("clip_app 启动成功。")
        else:
            emit_log("错误：clip_app 启动失败！")
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

    # ---- 文本特征更新 (通过 clip_app add 命令) ----
    elif msg_type == "update_text_features":
        labels = msg.get("labels", default_labels)
        if not labels:
            emit_log("警告：未提供候选文本，使用默认类别。")
            labels = default_labels
        if clip_app is None or clip_app.proc is None:
            emit_log("错误：clip_app 未启动", "error")
        elif not clip_app.ready:
            emit_log("错误：clip_app 未就绪，请等待加载完成", "error")
        else:
            emit_log(f"通过 clip_app 更新文本特征，共 {len(labels)} 个类别...")
            clip_app.send_cmd("mode dual")
            await asyncio.sleep(0.1)
            for label in labels:
                clip_app.send_cmd(f"add {label}")
                await asyncio.sleep(0.05)
            state.text_encoder_ready = True
            emit_log(f"文本特征已发送到 clip_app：{len(labels)} 个类别")
        await broadcast_system_status()

    # ---- 推理控制 ----
    elif msg_type == "start_inference":
        if clip_app is None or clip_app.proc is None:
            emit_log("错误：clip_app 未启动")
        elif not clip_app.ready:
            emit_log("错误：clip_app 未就绪，请等待加载完成", "error")
        else:
            clip_app.send_cmd("mode dual")
            state.inference_running = True
            emit_log("推理已开始 (clip_app mode dual)")

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

    # ---- 文本搜图 (通过 clip_app search 模式) ----
    elif msg_type == "search_images":
        query = msg.get("query", "")
        if not query:
            await manager.send_to(ws, {"type": "search_result", "error": "请输入查询文本"})
            return
        if clip_app is None or clip_app.proc is None:
            await manager.send_to(ws, {"type": "search_result", "error": "clip_app 未启动"})
        elif not clip_app.ready:
            await manager.send_to(ws, {"type": "search_result", "error": "clip_app 未就绪，请等待加载完成"})
        else:
            emit_log(f"clip_app 搜图: \"{query}\"")
            clip_app.send_cmd("mode search")
            await asyncio.sleep(0.1)
            clip_app.send_cmd(query)
            await manager.send_to(ws, {
                "type": "search_result",
                "query": query,
                "note": "查询已发送到 clip_app，结果将在 HDMI 显示"
            })

    # ---- clip_app 直接命令 ----
    elif msg_type == "clip_cmd":
        cmd = msg.get("cmd", "")
        if not cmd:
            emit_log("clip_cmd: 空命令", "warning")
        elif clip_app is None or clip_app.proc is None:
            emit_log("clip_app 未启动", "error")
        elif not clip_app.ready:
            emit_log(f"clip_app 未就绪，命令已拒绝: {cmd}", "warning")
        else:
            clip_app.send_cmd(cmd)
            emit_log(f"clip_cmd: {cmd}")

    # ---- Onboard: FWHT hardware + visualize ----
    elif msg_type == "run_fwht_hardware":
        if not _ANALYSIS_AVAILABLE: emit_log("模块未加载", "error")
        else:
            emit_log("FPGA FWHT 启动...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_fwht_hardware)
                await ws.send_json({"type": "fwht_hw_result", "data": result})
                emit_log(f"FWHT 完成: {result.get('cycles',0)} cycles, {result.get('us',0)} us")
            except Exception as e:
                emit_log(f"FWHT 失败: {e}", "error")

    elif msg_type == "run_fwht_visualize":
        if not _ANALYSIS_AVAILABLE: emit_log("模块未加载", "error")
        else:
            emit_log("FWHT 可视化生成...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_fwht_visualize)
                await ws.send_json({"type": "fwht_result", "data": result})
                emit_log("FWHT 可视化完成")
            except Exception as e:
                emit_log(f"FWHT 可视化失败: {e}", "error")

    # ---- Onboard: Resize hardware + visualize ----
    elif msg_type == "run_resize_hardware":
        if not _ANALYSIS_AVAILABLE: emit_log("模块未加载", "error")
        else:
            emit_log("FPGA Resize 启动...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_resize_hardware)
                await ws.send_json({"type": "resize_hw_result", "data": result})
                emit_log(f"Resize 完成: {result.get('cycles',0)} cycles, {result.get('us',0)} us")
            except Exception as e:
                emit_log(f"Resize 失败: {e}", "error")

    elif msg_type == "run_resize_visualize":
        if not _ANALYSIS_AVAILABLE: emit_log("模块未加载", "error")
        else:
            emit_log("Resize 可视化生成...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_resize_visualize)
                await ws.send_json({"type": "resize_result", "data": result})
                emit_log("Resize 可视化完成")
            except Exception as e:
                emit_log(f"Resize 可视化失败: {e}", "error")

    # ---- Onboard: Gather hardware + visualize ----
    elif msg_type == "run_gather_hardware":
        if not _ANALYSIS_AVAILABLE: emit_log("模块未加载", "error")
        else:
            emit_log("FPGA Gather 启动...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_gather_hardware)
                await ws.send_json({"type": "gather_hw_result", "data": result})
                emit_log(f"Gather 完成: {result.get('cycles',0)} cycles, {result.get('us',0)} us")
            except Exception as e:
                emit_log(f"Gather 失败: {e}", "error")

    elif msg_type == "run_gather_visualize":
        if not _ANALYSIS_AVAILABLE: emit_log("模块未加载", "error")
        else:
            emit_log("Gather 可视化生成...")
            try:
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(None, run_gather_visualize)
                await ws.send_json({"type": "gather_result", "data": result})
                emit_log("Gather 可视化完成")
            except Exception as e:
                emit_log(f"Gather 可视化失败: {e}", "error")

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

        # 推理由 clip_app 处理 (结果通过 clip_stdout_reader 推送)

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
# 后台任务：读取 clip_app stdout
# ============================================================

def strip_ansi(text: str) -> str:
    """移除 ANSI 终端转义序列（颜色、光标控制等）"""
    return re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', text)

# 匹配仅含 ANSI 序列的行（如 ESC[2K 清行）
_ANSI_ONLY = re.compile(r'^(\x1b\[[0-9;]*[a-zA-Z])+$')

async def clip_stdout_reader(ws: WebSocket):
    """持续读取 clip_app stdout，解析 [WEB] 行并推送给客户端"""
    global clip_app
    while ws in manager.active:
        if clip_app is None or clip_app.proc is None:
            await asyncio.sleep(0.5)
            continue
        loop = asyncio.get_running_loop()
        line = await loop.run_in_executor(None, clip_app.read_line)
        if line is None:
            await asyncio.sleep(0.1)
            continue
        line = line.strip()
        if not line:
            continue
        # 过滤纯 ANSI 控制行（如 ESC[2K 清行），不输出
        if _ANSI_ONLY.match(line):
            continue
        # [WEB] 结构化行 → 解析并推送（先剥离 ANSI 再匹配）
        clean = strip_ansi(line)
        if clean.startswith("[WEB]"):
            parsed = parse_web_line(clean)
            if parsed:
                if parsed["type"] == "clip_ready":
                    clip_app.ready = True
                    emit_log("clip_app 就绪，可以接收命令")
                await manager.send_to(ws, parsed)
            continue
        # 非 [WEB] 行 → 剥离 ANSI 后转发为控制台日志
        if clean:
            emit_log(clean)


# ============================================================
# WebSocket 主入口
# ============================================================

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    global clip_app
    await manager.connect(ws)

    # 先推送当前系统状态
    await broadcast_system_status()
    emit_log("系统就绪，等待操作指令...")

    # 启动后台任务
    log_task = asyncio.create_task(log_pusher(ws))
    clip_reader_task = asyncio.create_task(clip_stdout_reader(ws))
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
        clip_reader_task.cancel()
        inference_task.cancel()
        manager.disconnect(ws)
        # 注意：不在这里 stop clip_app，因为可能还有其他客户端


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
    print(f"  浏览器打开 http://192.168.137.10:{args.port}")
    print("=" * 55)
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
