#!/usr/bin/env python
# -*- coding: UTF-8 -*-
"""
CLIP ViT Vision Encoder ONNX Hadamard 变换优化导出工具（修正版）
流程：ONNX 加载 -> 校准图像收集 -> 异常值检测 -> Hadamard 变换 -> 激活值旋转层插入 -> ONNX 导出
"""

import os
os.environ['HF_ENDPOINT'] = 'https://hf-mirror.com'
import torch
import numpy as np
from typing import Dict, List, Tuple, Optional
from scipy.linalg import hadamard, block_diag
import json
import os
from PIL import Image
import requests
import onnx
from onnx import numpy_helper, helper, TensorProto
import onnxruntime as ort
from transformers import CLIPImageProcessor


# ============================================================================
# 步骤 1-3: 模型加载、校准数据收集、异常值检测（与之前相同）
# ============================================================================

def load_onnx_model(onnx_path: str):
    """加载 ONNX 模型并分析结构"""
    print("=" * 60)
    print("步骤 1: 加载 ONNX 模型")
    print("=" * 60)
    
    model = onnx.load(onnx_path)
    onnx.checker.check_model(model)
    print(f"✓ ONNX 模型加载完成：{onnx_path}")
    
    print(f"\n模型信息：")
    print(f"  输入：{[inp.name for inp in model.graph.input]}")
    print(f"  输出：{[out.name for out in model.graph.output]}")
    print(f"  节点数：{len(model.graph.node)}")
    
    linear_count = 0
    for node in model.graph.node:
        if node.op_type in ['MatMul', 'Gemm']:
            linear_count += 1
    print(f"  Linear 层数量（MatMul/Gemm）: {linear_count}")
    
    providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']
    session = ort.InferenceSession(onnx_path, providers=providers)
    
    print(f"✓ ONNX Runtime 会话创建完成，设备：{session.get_providers()[0]}")
    
    return model, session, providers


def extract_weights_from_onnx(onnx_model: onnx.ModelProto) -> Dict[str, np.ndarray]:
    """从 ONNX 模型中提取权重"""
    weights = {}
    for initializer in onnx_model.graph.initializer:
        weight_array = numpy_helper.to_array(initializer)
        weights[initializer.name] = weight_array
    return weights


def load_calibration_images(image_dir: str = None, num_samples: int = 500, use_coco: bool = True):
    """加载校准图像"""
    print("\n" + "=" * 60)
    print("步骤 2: 收集校准图像")
    print("=" * 60)
    
    images = []
    
    if image_dir and os.path.exists(image_dir):
        image_files = [f for f in os.listdir(image_dir) 
                      if f.lower().endswith(('.png', '.jpg', '.jpeg', '.bmp'))]
        for i, img_file in enumerate(image_files[:num_samples]):
            img_path = os.path.join(image_dir, img_file)
            try:
                img = Image.open(img_path).convert('RGB')
                images.append(img)
            except Exception as e:
                print(f"  ⚠ 跳过 {img_file}: {e}")
        print(f"✓ 从本地加载 {len(images)} 张图像")
    elif use_coco:
        print("  从 COCO 验证集下载示例图像...")
        coco_val_urls = [
            "http://images.cocodataset.org/val2017/000000039769.jpg",
            "http://images.cocodataset.org/val2017/000000000724.jpg",
            "http://images.cocodataset.org/val2017/000000000136.jpg",
        ]
        for i, url in enumerate(coco_val_urls * (num_samples // 3 + 1)):
            if len(images) >= num_samples:
                break
            try:
                response = requests.get(url, stream=True, timeout=10)
                img = Image.open(response.raw).convert('RGB')
                images.append(img)
            except Exception as e:
                print(f"  ⚠ 下载失败：{e}")
        print(f"✓ 从 COCO 加载 {len(images)} 张图像")
    else:
        print("  生成随机校准图像...")
        for i in range(num_samples):
            img = Image.new('RGB', (224, 224), color=(
                np.random.randint(0, 255),
                np.random.randint(0, 255),
                np.random.randint(0, 255)
            ))
            images.append(img)
        print(f"✓ 生成 {len(images)} 张随机图像")
    
    return images


def collect_activation_stats_onnx(onnx_path: str, images: List[Image.Image], 
                                   processor: CLIPImageProcessor, device: str = 'cpu', batch_size: int = 16):
    print("\n" + "=" * 60)
    print("步骤 2.1: 收集激活值统计 (ONNX + 中间层输出)")
    print("=" * 60)
    
    # 加载 ONNX 模型
    onnx_model = onnx.load(onnx_path)
    
    # 找出所有 MatMul/Gemm 节点（对应 Linear 层）
    linear_nodes = []
    for node in onnx_model.graph.node:
        if node.op_type in ['MatMul', 'Gemm']:
            linear_nodes.append({
                'name': node.name,
                'output': node.output[0],
                'input' : node.input[0],
                'weight': node.input[1]
            })
    print(f"找到 {len(linear_nodes)} 个 Linear 层")
    
    # 创建修改后的模型（添加所有中间层为输出）
    modified_model = onnx.ModelProto()
    modified_model.CopyFrom(onnx_model)
    
    # 添加中间层输出
    for node_info in linear_nodes:  # 限制前 20 层，避免输出太多
        graph_output = modified_model.graph.output.add()
        graph_output.name = node_info['input']
        
        # 获取张量类型
        for value_info in modified_model.graph.value_info:
            if value_info.name == node_info['input']:
                graph_output.type.CopyFrom(value_info.type)
                break
    
    # 保存临时模型
    import tempfile
    with tempfile.NamedTemporaryFile(suffix='.onnx', delete=False) as tmp_file:
        onnx.save(modified_model, tmp_file.name)
        temp_onnx_path = tmp_file.name
    
    # 创建会话
    providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']
    session = ort.InferenceSession(temp_onnx_path, providers=providers)
    
    # 收集激活值
    activation_stats = {}
    
    print("\n正在收集激活值...")
    for i in range(0, len(images), batch_size):
        batch_images = images[i:i + batch_size]
        inputs = processor(images=batch_images, return_tensors="np")
        pixel_values = inputs['pixel_values']
        
        outputs = session.run(None, {'pixel_values': pixel_values})
        
        # 保存输出
        for j, output in enumerate(outputs):
            output_name = session.get_outputs()[j].name
            if output_name not in activation_stats:
                activation_stats[output_name] = []
            activation_stats[output_name].append(output)
        
        if (i // batch_size + 1) % 10 == 0:
            print(f"  已处理 {min(i + batch_size, len(images))}/{len(images)} 图像")
    
    # 清理临时文件
    os.unlink(temp_onnx_path)
    
    # 计算统计信息
    print("\n正在计算统计信息...")
    stats_summary = {}
    
    for layer_name, activations in activation_stats.items():
        # 合并所有 batch 的激活值
        activations = np.concatenate(activations, axis=0)
        original_shape = activations.shape
        
        # 展平为 [batch*seq, hidden]
        if len(activations.shape) == 3:
            activations = activations.reshape(-1, activations.shape[-1])
        
        # ========== 关键修正：逐通道统计 ==========
        # 每通道的统计（沿 batch*seq 维度）
        act_min = np.min(activations, axis=0)      # [hidden_dim] 每通道最小值
        act_max = np.max(activations, axis=0)      # [hidden_dim] 每通道最大值
        act_mean = np.mean(activations, axis=0)    # [hidden_dim] 每通道均值
        act_std = np.std(activations, axis=0)      # [hidden_dim] 每通道标准差
        
        # ========== 修正 1: 基于 max 的异常值检测 ==========
        # 计算所有通道 max 的分布特性
        max_median = np.median(act_max)
        max_mean = np.mean(act_max)
        max_std = np.std(act_max)
        
        # 计算所有通道 min 的分布特性
        min_median = np.median(act_min)
        min_mean = np.mean(act_min)
        min_std = np.std(act_min)
        
        # 检测异常值通道（多种方法组合）
        # 方法 A: max 超过中位数 + k*std
        k_sigma = 5.0  # 3 倍标准差
        outlier_mask_max = act_max > (max_median + k_sigma * max_std)
        
        # 方法 B: min 低于中位数 - k*std
        outlier_mask_min = act_min < (min_median - k_sigma * min_std)
        
        # 方法 C: max/min 的绝对值超过中位数的 k 倍（捕捉极端异常值）
        k_ratio = 20.0  # 10 倍
        max_abs_median = np.median(np.abs(act_max))
        outlier_mask_ratio = np.abs(act_max) > (k_ratio * max_abs_median)
        
        # 方法 D: 通道的 max-min 范围异常（原方法，作为补充）
        act_range = act_max - act_min
        range_median = np.median(act_range)
        outlier_mask_range = act_range > (k_ratio * range_median)
        
        # 合并所有检测方法（任意一个检测到即标记为异常）
        outlier_mask = (
            outlier_mask_max | 
            outlier_mask_min | 
            outlier_mask_ratio |
            outlier_mask_range
        )
        
        outlier_ratio = np.mean(outlier_mask.astype(float))
        weight = None

        for node in linear_nodes:
            if layer_name == node['input']:
                layer_name = node['name']
                weight = node['weight']
                break 
        
        stats_summary[layer_name] = {
            'outlier_ratio': outlier_ratio,
            'shape': list(original_shape),
            'hidden_dim': activations.shape[-1],
            'weight': weight
        }
        
        print(f"  {layer_name}: 形状={list(original_shape)}, 异常值比例 = {outlier_ratio:.2%}")
    
    return stats_summary


def analyze_outliers(activation_stats: Dict[str, Dict], threshold: float = 0.05):
    """分析哪些层需要应用 Hadamard 变换"""
    print("\n" + "=" * 60)
    print("步骤 3: 异常值检测与分析")
    print("=" * 60)
    
    layers_need_rotation = []
    for layer_name, stats in activation_stats.items():
        outlier_ratio = stats['outlier_ratio']
        if outlier_ratio > threshold:
            layers_need_rotation.append({
                'name': layer_name,
                'outlier_ratio': outlier_ratio,
                'shape': stats['shape'],
                'hidden_dim': stats['hidden_dim'],
                'weight': stats['weight']
            })
            print(f"  ✓ {layer_name}: 异常值 {outlier_ratio:.2%} > {threshold:.2%}，需要变换")
        else:
            print(f"  ✗ {layer_name}: 异常值 {outlier_ratio:.2%} ≤ {threshold:.2%}，跳过")
    
    print(f"\n总计：{len(layers_need_rotation)} 层需要 Hadamard 变换")
    return layers_need_rotation


def expand_qkv_rotation_layers(
    onnx_model: onnx.ModelProto,
    layers_need_rotation: List[Dict],
    weights: Dict[str, np.ndarray],
) -> List[Dict]:
    """当 q/k/v 共享输入时，若其中任一层入选，则同组 q/k/v 全部纳入旋转列表。"""
    node_by_name = {
        node.name: node for node in onnx_model.graph.node if node.op_type in ['MatMul', 'Gemm']
    }

    input_to_qkv = {}
    for node in onnx_model.graph.node:
        if node.op_type not in ['MatMul', 'Gemm']:
            continue
        if len(node.input) < 2:
            continue
        if ('/self_attn/q_proj/' not in node.name and
                '/self_attn/k_proj/' not in node.name and
                '/self_attn/v_proj/' not in node.name):
            continue
        input_to_qkv.setdefault(node.input[0], []).append(node)

    by_name = {item['name']: dict(item) for item in layers_need_rotation}

    seeded_inputs = {}
    for item in layers_need_rotation:
        name = item['name']
        node = node_by_name.get(name)
        if not node or len(node.input) < 2:
            continue
        if ('/self_attn/q_proj/' in name or
                '/self_attn/k_proj/' in name or
                '/self_attn/v_proj/' in name):
            seeded_inputs[node.input[0]] = item

    added = 0
    for input_name, seed in seeded_inputs.items():
        for node in input_to_qkv.get(input_name, []):
            if node.name in by_name:
                continue

            weight_name = node.input[1]
            hidden_dim = seed.get('hidden_dim', 0)
            if weight_name in weights and getattr(weights[weight_name], 'ndim', 0) >= 2:
                hidden_dim = int(weights[weight_name].shape[0])

            by_name[node.name] = {
                'name': node.name,
                'outlier_ratio': seed.get('outlier_ratio', 0.0),
                'shape': seed.get('shape', []),
                'hidden_dim': hidden_dim,
                'weight': weight_name,
            }
            added += 1

    if added > 0:
        print(f"\n扩展 q/k/v 共享输入分支：新增 {added} 层（确保 q/k/v 同步插入 Hadamard）")

    ordered = []
    for node in onnx_model.graph.node:
        if node.name in by_name:
            ordered.append(by_name[node.name])
    return ordered


# ============================================================================
# 步骤 4: Hadamard 变换应用（修正版：权重 + 激活值）
# ============================================================================

def get_hadamard_matrix(n: int) -> np.ndarray:
    """生成 Hadamard 矩阵"""
    n_pow2 = 1
    while n_pow2 < n:
        n_pow2 *= 2
    H = hadamard(n_pow2)[:n, :n]
    return H.astype(np.float32)

def get_hadamard_matrix_glr(n: int, group_size: int = 128) -> Tuple[np.ndarray, List[np.ndarray]]:
    # 确保 group_size 是 2 的幂
    assert group_size & (group_size - 1) == 0, "group_size 必须是 2 的幂"
    
    # 计算组数
    num_groups = n // group_size
    remainder = n % group_size
    
    print(f"维度 {n} 分解为：{num_groups} 组 × {group_size} 通道")
    if remainder > 0:
        print(f"  剩余 {remainder} 通道（需要特殊处理）")
    
    hadamard_blocks = []
    
    # 为每组生成 Hadamard 矩阵
    for i in range(num_groups):
        H = hadamard(group_size).astype(np.float32)
        hadamard_blocks.append(H)
    
    # 处理剩余维度（如果不是整除）
    if remainder > 0:
        # 找到不超过 remainder 的最大 2 的幂
        pow2 = 1
        while pow2 * 2 <= remainder:
            pow2 *= 2
        
        H_remainder = hadamard(pow2)[:remainder, :remainder].astype(np.float32)
        hadamard_blocks.append(H_remainder)
        print(f"  剩余部分使用 {pow2}×{pow2} Hadamard 矩阵裁剪到 {remainder}×{remainder}")
    
    # 构造分块对角矩阵
    H_block = block_diag(*hadamard_blocks)
    
    return H_block#, hadamard_blocks

def insert_hadamard_rotation_layer(
    onnx_model: onnx.ModelProto,
    layers_need_rotation: List[Dict],
    weights: Dict[str, np.ndarray],
    group_size: int = 128
) -> Tuple[onnx.ModelProto, Dict]:
    """
    在 ONNX 模型中插入 Hadamard 旋转层（用于旋转激活值）
    
    关键修正：不仅旋转权重，还要在推理时旋转激活值
    """
    print("\n" + "=" * 60)
    print("步骤 4: 应用 Hadamard 变换（权重 + 激活值旋转）")
    print("=" * 60)
    
    rotation_config = {
        'layers': [],
        'hadamard_depth': {},
        'hadamard_matrices': {},
        'model_type': 'CLIP-ViT-Patch-32-ONNX'
    }
    
    # 创建修改后的模型
    modified_model = onnx.ModelProto()
    modified_model.CopyFrom(onnx_model)

    # 预构建索引，避免按形状模糊匹配导致串层
    node_by_name = {node.name: node for node in modified_model.graph.node}
    init_by_name = {initializer.name: initializer for initializer in modified_model.graph.initializer}
    inserted_rotation_nodes = set()
    
    # 对每个需要变换的层
    for layer_info in layers_need_rotation:
        layer_name = layer_info['name']
        layer_weight = layer_info['weight']

        if layer_name not in node_by_name:
            raise RuntimeError(f"目标层不存在于图中: {layer_name}")

        target_node = node_by_name[layer_name]
        if target_node.op_type not in ['MatMul', 'Gemm']:
            raise RuntimeError(f"目标层不是 MatMul/Gemm: {layer_name} ({target_node.op_type})")

        if len(target_node.input) < 2:
            raise RuntimeError(f"目标层输入数量异常，无法获取权重: {layer_name}")
        
        # 查找对应的权重
        weight_name = layer_weight if layer_weight else target_node.input[1]
        if weight_name not in weights and target_node.input[1] in weights:
            weight_name = target_node.input[1]

        if weight_name not in weights:
            raise RuntimeError(f"{layer_name}: 未找到权重 {weight_name}")

        if weight_name not in init_by_name:
            raise RuntimeError(f"{layer_name}: 权重不在 initializer 中 {weight_name}")
        
        weight = weights[weight_name]
        out_features, in_features = weight.shape
        
        if out_features % group_size != 0:
            print(f"⚠️ 跳过层 '{layer_name}': 输出维度 {out_features} 不能被 group_size ({group_size}) 整除，无法应用分组 Hadamard 变换。")
            continue

        # 生成 Hadamard 矩阵
        H = get_hadamard_matrix_glr(out_features, group_size=group_size)
        h_transpose = H.T.copy()
        
        # ========== 修正 1: 旋转权重（离线）==========
        rotated_weight = (h_transpose / group_size) @ weight
        weights[weight_name] = rotated_weight.astype(np.float32)
        print(f"  ✓ {layer_name} ({weight_name}): 权重已旋转 W' = H @ W")
        
        # ========== 修正 2: 保存 Hadamard 矩阵（用于激活值旋转）==========
        h_matrix_name = f"{weight_name}_hadamard"
        #h_initializer = numpy_helper.from_array(H, h_matrix_name)
        #modified_model.graph.initializer.append(h_initializer)
        
        # ========== 修正 3: 在模型中插入 MatMul 层（旋转激活值）==========
        # 创建激活值旋转的 MatMul 节点
        h_name = f"{weight_name}_hadamard"
        if h_name in init_by_name:
            raise RuntimeError(f"重复的 Hadamard initializer 名称: {h_name}")

        h_initializer = numpy_helper.from_array(H, h_name)
        modified_model.graph.initializer.append(h_initializer)
        init_by_name[h_name] = h_initializer

        # 创建新的 MatMul 节点（在目标节点之前）
        activation_rotated_output = f"{target_node.name}_hadamard_rotated_output"

        hadamard_matmul_node = helper.make_node(
            'MatMul',
            inputs=[target_node.input[0], h_name],
            outputs=[activation_rotated_output],
            name=f"{target_node.name}_hadamard_rotation"
        )

        # 更新目标节点的输入
        target_node.input[0] = activation_rotated_output

        # 插入新节点
        node_idx = list(modified_model.graph.node).index(target_node)
        modified_model.graph.node.insert(node_idx, hadamard_matmul_node)
        inserted_rotation_nodes.add(hadamard_matmul_node.name)

        print(f"  ✓ {layer_name}: 已插入激活值旋转层 X' = X @ H^T")
        
        # 记录配置
        rotation_config['layers'].append({
            'name': layer_name,
            'weight_name': weight_name,
            'hidden_dim': layer_info['hidden_dim'],
            'outlier_ratio': layer_info['outlier_ratio'],
            'hadamard_matrix_name': h_matrix_name
        })
        rotation_config['hadamard_depth'][weight_name] = int(np.log2(H.shape[0]))
        rotation_config['hadamard_matrices'][h_matrix_name] = {
            'shape': list(H.shape),
            'dtype': 'float32'
        }

    # 结构性校验：rotation_config 中声明的每一层都必须有对应插入节点
    expected_inserted = set(f"{x['name']}_hadamard_rotation" for x in rotation_config['layers'])
    missing = sorted(expected_inserted - inserted_rotation_nodes)
    if missing:
        raise RuntimeError(f"以下层声明已旋转但未找到插入节点: {missing}")
    
    # 更新权重
    for initializer in modified_model.graph.initializer:
        if initializer.name in weights:
            new_weight = weights[initializer.name]
            new_initializer = numpy_helper.from_array(new_weight, initializer.name)
            initializer.CopyFrom(new_initializer)
    
    return modified_model, rotation_config


# ============================================================================
# 步骤 5: 验证与 ONNX 导出
# ============================================================================

def verify_transformation_onnx(original_session: ort.InferenceSession,
                                modified_session: ort.InferenceSession,
                                images: List[Image.Image],
                                processor: CLIPImageProcessor,
                                tolerance: float = 1e-2,
                                num_test: int = 10):
    """验证变换前后模型输出的一致性"""
    print("\n" + "=" * 60)
    print("步骤 5.1: 验证变换一致性")
    print("=" * 60)
    
    max_diff = 0.0
    
    for i in range(min(num_test, len(images))):
        img = [images[i]]
        inputs = processor(images=img, return_tensors="np")
        pixel_values = inputs['pixel_values']
        
        output_original = original_session.run(None, {'pixel_values': pixel_values})
        output_rotated = modified_session.run(None, {'pixel_values': pixel_values})
        
        for j in range(len(output_original)):
            diff = np.abs(output_original[j] - output_rotated[j]).max()
            max_diff = max(max_diff, diff)
            
            if diff > tolerance:
                print(f"  ⚠ 图像 {i}, 输出 {j}: 差异 = {diff:.6f} > {tolerance}")
    
    is_consistent = max_diff <= tolerance
    print(f"\n最大差异：{max_diff:.6f}，容差：{tolerance}")
    print(f"✓ 一致性验证：{'通过' if is_consistent else '失败'}")
    
    return is_consistent


def export_onnx_model(model: onnx.ModelProto, rotation_config: Dict, save_path: str, processor: CLIPImageProcessor):
    """导出 ONNX 模型"""
    print("\n" + "=" * 60)
    print("步骤 5.2: 导出 ONNX 模型")
    print("=" * 60)
    
    os.makedirs(os.path.dirname(save_path), exist_ok=True)
    
    onnx.save(model, save_path)
    print(f"✓ ONNX 模型已保存：{save_path}")
    
    config_path = save_path.replace('.onnx', '_rotation_config.json')
    with open(config_path, 'w', encoding='utf-8') as f:
        json.dump(rotation_config, f, indent=2, ensure_ascii=False)
    print(f"✓ 旋转配置已保存：{config_path}")
    
    processor_path = os.path.join(os.path.dirname(save_path), 'processor')
    os.makedirs(processor_path, exist_ok=True)
    processor.save_pretrained(processor_path)
    print(f"✓ Processor 已保存：{processor_path}")
    
    onnx.checker.check_model(model)
    print(f"✓ ONNX 模型验证通过")


# ============================================================================
# 主流程
# ============================================================================

def main():
    """完整流程"""
    print("\n" + "=" * 60)
    print("CLIP ViT Vision Encoder ONNX Hadamard 变换优化导出工具（修正版）")
    print("=" * 60)
    
    CONFIG = {
        'onnx_model_path': './fmodel/vision_model.onnx',
        'processor_path': './processor',
        'calib_image_dir': './qtset/coco',
        'num_calib_samples': 10,
        'outlier_threshold': 0.01,
        'save_path': './fmodel/vision_model_hadamard.onnx',
        'device': 'cpu',
        'batch_size': 4,
        'tolerance': 1e-2
    }
    
    # 步骤 1: ONNX 模型加载
    onnx_model, session, providers = load_onnx_model(CONFIG['onnx_model_path'])
    weights = extract_weights_from_onnx(onnx_model)
    
    # 步骤 2: 校准数据收集
    calib_images = load_calibration_images(CONFIG['calib_image_dir'], CONFIG['num_calib_samples'])
    #processor = CLIPImageProcessor.from_pretrained(CONFIG['processor_path'])
    processor = CLIPImageProcessor.from_pretrained(CONFIG['processor_path'])
    activation_stats = collect_activation_stats_onnx(CONFIG['onnx_model_path'], calib_images, processor, CONFIG['device'], CONFIG['batch_size'])
    
    # 步骤 3: 异常值检测与分析
    layers_need_rotation = analyze_outliers(activation_stats, CONFIG['outlier_threshold'])
    layers_need_rotation = expand_qkv_rotation_layers(onnx_model, layers_need_rotation, weights)
    
    if len(layers_need_rotation) == 0:
        print("\n⚠ 没有层需要 Hadamard 变换，流程结束")
        return
    
    # 步骤 4: Hadamard 变换应用（权重 + 激活值）
    modified_model, rotation_config = insert_hadamard_rotation_layer(onnx_model, layers_need_rotation, weights)
    
    # 步骤 5: 验证与导出
    import tempfile

    tmp_fd, temp_onnx_path = tempfile.mkstemp(suffix='.onnx')
    #export_onnx_model(modified_model, rotation_config, CONFIG['save_path'], processor)
    try:
        # 关闭文件描述符
        os.close(tmp_fd)
    
        # 保存模型
        onnx.save(modified_model, temp_onnx_path)
    
        # 创建 session（文件必须存在）
        modified_session = ort.InferenceSession(temp_onnx_path, providers=providers)
    
        # 验证...
        is_consistent = verify_transformation_onnx(session, modified_session, calib_images, processor, CONFIG['tolerance'])
    
        if not is_consistent:
            print("\n⚠ 一致性验证失败，请检查变换逻辑")
            return
 
    finally:
    # 验证完成后删除
        if os.path.exists(temp_onnx_path):
           os.unlink(temp_onnx_path)
    
    export_onnx_model(modified_model, rotation_config, CONFIG['save_path'], processor)
    
    print("\n" + "=" * 60)
    print("流程完成！")
    print("=" * 60)
    print(f"导出文件：{CONFIG['save_path']}")
    print(f"配置文件：{CONFIG['save_path'].replace('.onnx', '_rotation_config.json')}")
    print("\n✓ 修正说明：")
    print("  1. 权重旋转：W' = H @ W（离线完成）")
    print("  2. 激活值旋转：X' = X @ H^T（ONNX 模型中插入 MatMul 层）")
    print("  3. 推理时直接使用优化后的 ONNX 模型，无需额外代码")
    print("=" * 60 + "\n")


if __name__ == '__main__':
    main()