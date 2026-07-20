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
        self.warmup_done = False             # 模型预热是否完成
        self.warmup_running = False          # 预热是否正在运行
        self.current_mode_clip = ""          # clip_app 当前模式 dual/search

        # ---- 编码器细粒度状态 ----
        self.text_encoder_busy = False       # 正在编码文本
        self.text_encoder_current = ""       # 当前正在编码的文本
        self.text_enc_count = 0              # 已编码文本次数
        self.text_gather_us_last = 0         # 最近一次 Gather 硬算子耗时(us)
        self.text_gather_us_avg = 0          # 平均 Gather 耗时(us)

        self.image_enc_count = 0             # 已编码图像帧数
        self.image_resize_us_last = 0        # 最近一次 Resize 硬算子耗时(us)
        self.image_resize_us_avg = 0         # 平均 Resize 耗时(us)
        self.image_frame_ms_last = 0         # 最近单帧总耗时(ms)
        self.fwht_us_last = 0               # 最近一次 FWHT 耗时(us)
        self.fwht_us_avg = 0                # 平均 FWHT 耗时(us)

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
            "warmup": "Done" if self.warmup_done else ("Running" if self.warmup_running else "Idle"),
            # 编码器细粒度
            "encoder_detail": {
                "text": {
                    "ready": self.text_encoder_ready,
                    "busy": self.text_encoder_busy,
                    "current": self.text_encoder_current,
                    "count": self.text_enc_count,
                    "gather_us_last": round(self.text_gather_us_last, 1),
                    "gather_us_avg": round(self.text_gather_us_avg, 1),
                },
                "image": {
                    "running": self.image_encoder_running,
                    "count": self.image_enc_count,
                    "resize_us_last": round(self.image_resize_us_last, 1),
                    "resize_us_avg": round(self.image_resize_us_avg, 1),
                    "frame_ms_last": round(self.image_frame_ms_last, 1),
                    "fwht_us_last": round(self.fwht_us_last, 1),
                    "fwht_us_avg": round(self.fwht_us_avg, 1),
                },
            },
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

    # ---- 实时分类 Top-K: RESULT topk=cat:0.82,dog:0.21,... ----
    # 注意: label 可能带空格(如 "a photo of a cat"), 所以抓 topk= 到行尾, 不能用 \S+
    if content.startswith("RESULT"):
        idx = content.find("topk=")
        if idx >= 0:
            payload = content[idx + 5:].strip()  # topk= 之后的整段
            topk = []
            for item in payload.split(","):
                item = item.strip()
                if ":" in item:
                    lbl, sc = item.rsplit(":", 1)  # 从右边分, label 里的空格不受影响
                    try:
                        topk.append({"label": lbl.strip(), "score": float(sc)})
                    except ValueError:
                        pass
            return {"type": "clip_result", "topk": topk}
        # 兼容旧格式 top1=x score=y
        m = re.search(r'top1=(.+?)\s+score=([\d.]+)', content)
        if m:
            return {"type": "clip_result",
                    "topk": [{"label": m.group(1).strip(), "score": float(m.group(2))}]}

    # ---- 标签列表 ----
    elif content.startswith("LABELS"):
        labels_str = content[7:].strip()
        labels = [l.strip() for l in labels_str.split(",") if l.strip()]
        return {"type": "clip_labels", "labels": labels}

    # ---- 搜图结果: SEARCH n=N results=path:cos;path:cos;... query=xxx ----
    elif content.startswith("SEARCH"):
        # query= 在最后(可能含空格); results= 在 query= 之前
        q_idx = content.find("query=")
        query = content[q_idx + 6:].strip() if q_idx >= 0 else ""
        r_idx = content.find("results=")
        results = []
        if r_idx >= 0:
            # results= 之后, 到 query= 之前(若有)
            r_end = q_idx if q_idx > r_idx else len(content)
            payload = content[r_idx + 8:r_end].strip()
            for item in payload.split(";"):
                item = item.strip()
                if ":" in item:
                    path, sc = item.rsplit(":", 1)
                    try:
                        results.append({"path": path.strip(), "score": float(sc)})
                    except ValueError:
                        pass
        return {"type": "clip_search", "query": query, "results": results}

    # ---- 编码器状态事件 ----
    elif content.startswith("ENC"):
        # ENC text start <prompt>
        # ENC text done <prompt> gather_us=X count=N avg_us=Y
        # ENC image frame=N resize_hw_us=X resize_avg_us=Y vis_fwd_ms=Z count=C
        parts = content.split()
        if len(parts) >= 2 and parts[1] == "text":
            if len(parts) >= 3 and parts[2] == "start":
                prompt = " ".join(parts[3:]) if len(parts) > 3 else ""
                return {"type": "clip_enc", "encoder": "text",
                        "phase": "start", "prompt": prompt}
            elif len(parts) >= 3 and parts[2] == "done":
                d = {"type": "clip_enc", "encoder": "text", "phase": "done"}
                for kv in parts[3:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        try: d[k] = float(v)
                        except ValueError: d[k] = v
                return d
        elif len(parts) >= 2 and parts[1] == "image":
            d = {"type": "clip_enc", "encoder": "image", "phase": "frame"}
            for kv in parts[2:]:
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    try: d[k] = float(v)
                    except ValueError: d[k] = v
            return d

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

    # ---- 模型预热 (开机后运行一次, 预编译 text+vision) ----
    elif msg_type == "run_warmup":
        if state.warmup_running:
            emit_log("模型预热已在运行中", "warning")
        elif state.warmup_done:
            emit_log("模型预热已完成，无需重复运行")
        else:
            state.warmup_running = True
            await broadcast_system_status()
            emit_log("模型预热启动...")

            exe = os.environ.get("CLIP_WARMUP_EXE", "../clip_warmup")
            cfg = os.environ.get("CLIP_WARMUP_CONFIG", "./configs/app_config.yaml")
            emit_log(f"执行: {exe} {cfg}")
            try:
                loop = asyncio.get_running_loop()
                proc = await loop.run_in_executor(None, lambda: subprocess.Popen(
                    [exe, cfg], stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1))
                # 等待 [WEB] WARMUP_DONE
                for line in proc.stdout:
                    line = strip_ansi(line).strip()
                    if not line:
                        continue
                    emit_log(line)
                    if "[WEB] WARMUP_DONE" in line:
                        state.warmup_done = True
                        await broadcast_system_status()
                        emit_log("模型预热完成！")
                # 等待进程自然退出
                await loop.run_in_executor(None, proc.wait)
            except FileNotFoundError:
                emit_log(f"可执行文件未找到: {exe}", "error")
            except Exception as e:
                emit_log(f"预热异常: {e}", "error")
            state.warmup_running = False
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
        if clip_app is None or clip_app.proc is None:
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
        try:
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
                    ptype = parsed["type"]
                    if ptype == "clip_ready":
                        clip_app.ready = True
                        emit_log("clip_app 就绪，可以接收命令")
                        state.text_encoder_ready = True
                    elif ptype == "clip_search":
                        # 读取每个命中项的 jpg → base64, 附加到结果
                        try:
                            parsed = await enrich_search_images(parsed)
                        except Exception as e:
                            emit_log(f"搜图读图失败(已忽略): {e}", "warning")
                    elif ptype == "clip_enc":
                        update_encoder_state(parsed)
                        await broadcast_system_status()
                    elif ptype == "clip_result":
                        # 有推理结果 → 图像编码器运行中
                        if not state.image_encoder_running:
                            state.image_encoder_running = True
                            await broadcast_system_status()
                    elif ptype == "clip_mode":
                        state.current_mode_clip = parsed.get("mode", "")
                    await manager.send_to(ws, parsed)
                continue
            # 非 [WEB] 行 → 剥离 ANSI 后转发为控制台日志
            if clean:
                emit_log(clean)
        except Exception as e:
            # 任何单行处理异常都不能让 reader 协程死掉, 否则后续输出全丢
            emit_log(f"stdout 处理异常(已忽略, 继续读取): {e}", "warning")
            continue


async def enrich_search_images(parsed: dict) -> dict:
    """搜图结果: 读取每个命中项的 jpg 文件 → base64, 供前端显示

    clip_app 输出的 path 是相对 clip_app 工作目录的.
    clip_app 由本 server 以 subprocess 启动并继承本 server 的 cwd,
    因此默认直接按原 path 读取; 若读不到, 尝试用 CLIP_APP_CWD 拼接.
    """
    app_cwd = os.environ.get("CLIP_APP_CWD", "")
    THUMB_MAX = 160        # 缩略图最大边(px)
    JPEG_Q = 50            # 缩略图 JPEG 质量
    MAX_ITEMS = 10         # 单条消息最多附带的图数量, 防止库过大撑爆消息

    def resolve(p: str) -> Optional[str]:
        if not p:
            return None
        if Path(p).is_file():
            return p
        if app_cwd:
            cand = str(Path(app_cwd) / p)
            if Path(cand).is_file():
                return cand
        return None

    def make_thumb_b64(real: str) -> Optional[str]:
        """读图 → 缩略 → jpg base64. 失败返回 None."""
        img = cv2.imread(real, cv2.IMREAD_COLOR)
        if img is None:
            return None
        h, w = img.shape[:2]
        scale = THUMB_MAX / max(h, w)
        if scale < 1.0:
            img = cv2.resize(img, (max(1, int(w * scale)), max(1, int(h * scale))),
                             interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, JPEG_Q])
        if not ok:
            return None
        b64 = base64.b64encode(buf.tobytes()).decode("utf-8")
        return f"data:image/jpeg;base64,{b64}"

    results = parsed.get("results", [])
    enriched = []
    for idx, r in enumerate(results):
        path = r.get("path", "")
        item = {"path": path, "name": Path(path).name if path else "",
                "score": r.get("score", 0)}
        # 关键: 存的 jpg 是全尺寸 HDMI 帧, 多张全尺寸 base64 会让单条 WebSocket
        # 消息达几 MB 导致连接被断开. 这里统一缩略后编码.
        if idx < MAX_ITEMS:
            real = resolve(path)
            if real:
                try:
                    b64 = make_thumb_b64(real)
                    if b64:
                        item["base64"] = b64
                    else:
                        emit_log(f"搜图图片解码失败: {real}", "warning")
                except Exception as e:
                    emit_log(f"搜图缩略失败(已忽略): {real} - {e}", "warning")
            else:
                emit_log(f"搜图图片不存在: {path}", "warning")
        enriched.append(item)
    parsed["results"] = enriched
    return parsed


def update_encoder_state(parsed: dict):
    """根据 clip_app 编码事件更新 SystemState 的编码器细粒度状态"""
    enc = parsed.get("encoder")
    phase = parsed.get("phase")
    if enc == "text":
        if phase == "start":
            state.text_encoder_ready = True
            state.text_encoder_busy = True
            state.text_encoder_current = parsed.get("prompt", "")
        elif phase == "done":
            state.text_encoder_busy = False
            state.text_encoder_current = ""
            state.text_gather_us_last = parsed.get("gather_us", 0)
            state.text_gather_us_avg = parsed.get("avg_us", 0)
            state.text_enc_count = int(parsed.get("count", 0))
    elif enc == "image":
        state.image_encoder_running = True
        state.image_resize_us_last = parsed.get("resize_hw_us", 0)
        state.image_resize_us_avg = parsed.get("resize_avg_us", 0)
        state.image_frame_ms_last = parsed.get("vis_fwd_ms", 0)
        state.fwht_us_last = parsed.get("fwht_us", 0)
        state.fwht_us_avg = parsed.get("fwht_avg_us", 0)
        state.image_enc_count = int(parsed.get("count", 0))


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
    # ws_max_size: 提高 WebSocket 单条消息上限(默认约 1MB), 配合缩略图双保险,
    # 避免搜图结果(多张 base64 图)/算子可视化大图超限导致连接被断开.
    # ws_ping_interval/timeout=None: 关闭 keepalive ping. 局域网直连不需要保活;
    # 且发大图时 keepalive ping 与数据写入并发会触发 websockets 库 _drain 断言崩溃
    # (keepalive ping failed / AssertionError), 关掉即可根治, 不影响功能.
    uvicorn.run(app, host=args.host, port=args.port, log_level="info",
                ws_max_size=16 * 1024 * 1024,
                ws_ping_interval=None, ws_ping_timeout=None)
