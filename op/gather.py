import numpy as np
import torch

def gather_naive(data: np.ndarray, indices: np.ndarray, axis: int = 0) -> np.ndarray:
    """
    Gather 算子的基础实现（易于理解）
    
    参数:
        data: 输入数据张量，形状任意
        indices: 索引张量，形状任意
        axis: 沿哪个轴进行 gather，默认 0
    
    返回:
        output: gather 后的张量
    
    示例:
        data = [[1, 2, 3],      # shape: [3, 3]
                [4, 5, 6],
                [7, 8, 9]]
        
        indices = [0, 2]        # shape: [2]
        
        output = gather(data, indices, axis=0)
        # output = [[1, 2, 3],   # shape: [2, 3]
        #           [7, 8, 9]]
    """
    # 1. 验证 axis 合法性
    axis = axis % data.ndim  # 支持负数 axis
    assert 0 <= axis < data.ndim, f"axis {axis} 超出范围 [0, {data.ndim})"
    
    # 2. 获取维度信息
    data_shape = data.shape
    indices_shape = indices.shape
    
    # 3. 计算输出形状
    # output_shape = data_shape[:axis] + indices_shape + data_shape[axis+1:]
    output_shape = data_shape[:axis] + indices_shape + data_shape[axis+1:]
    
    # 4. 创建输出张量
    output = np.zeros(output_shape, dtype=data.dtype)
    
    # 5. 逐元素 gather（基础版本，易于理解）
    if indices.ndim == 0:
        # indices 是标量
        idx = indices.item()
        # 构建切片对象
        slices = [slice(None)] * data.ndim
        slices[axis] = idx
        output = data[tuple(slices)]
    else:
        # indices 是张量，需要遍历
        for idx in np.ndindex(indices_shape):
            # 获取当前索引位置的值
            index_val = indices[idx]
            
            # 构建输出张量的索引
            # output 的索引 = indices 的索引 + data 其他维度的索引
            output_slices = []
            data_slices = []
            
            # axis 之前的维度：使用 indices 的索引
            for i in range(axis):
                output_slices.append(idx[i] if i < len(idx) else 0)
                data_slices.append(slice(None))
            
            # axis 维度：使用 indices 的值
            output_slices.append(slice(None) if axis < len(idx) else idx)
            data_slices.append(index_val)
            
            # axis 之后的维度：使用 indices 的索引
            for i in range(axis + 1, data.ndim):
                if len(idx) > i:
                    output_slices.append(idx[i])
                data_slices.append(slice(None))
            
            # 简化：直接使用 numpy 高级索引
            slices = [slice(None)] * data.ndim
            slices[axis] = index_val
            
            # 计算 output 中的位置
            output_idx = idx if axis >= len(indices_shape) else idx
            
            output[output_idx] = data[tuple(slices)]
    
    return output
    
def gather_vectorized(data: np.ndarray, indices: np.ndarray, axis: int = 0) -> np.ndarray:
    """
    Gather 算子的向量化实现（高效，推荐）
    
    利用 NumPy 的高级索引功能，避免 Python 循环
    
    参数:
        data: 输入数据张量
        indices: 索引张量
        axis: 沿哪个轴进行 gather
    
    返回:
        output: gather 后的张量
    """
    # 1. 验证 axis
    axis = axis % data.ndim
    assert 0 <= axis < data.ndim, f"axis {axis} 超出范围"
    
    # 2. 使用 np.take 实现（最简洁）
    output = np.take(data, indices, axis=axis)
    
    return output


def gather_manual(data: np.ndarray, indices: np.ndarray, axis: int = 0) -> np.ndarray:
    """
    Gather 算子的手动实现（深入理解原理）
    
    不依赖 np.take，手动实现索引逻辑
    """
    # 1. 验证
    axis = axis % data.ndim
    indices = np.asarray(indices)
    
    # 2. 计算输出形状
    data_shape = list(data.shape)
    indices_shape = list(indices.shape)
    output_shape = data_shape[:axis] + indices_shape + data_shape[axis+1:]
    
    # 3. 转置 data，使 axis 维度移到第 0 维
    if axis != 0:
        # 将 axis 维度移到最前面
        perm = [axis] + list(range(0, axis)) + list(range(axis+1, data.ndim))
        data_transposed = np.transpose(data, perm)
    else:
        data_transposed = data
    
    # 4. 使用 data_transposed[indices] 进行 gather
    # 此时 indices 索引的是第 0 维
    output_transposed = data_transposed[indices]
    
    # 5. 转置回原始顺序
    if axis != 0:
        # 计算逆置换
        inv_perm = [0] * data.ndim
        for i, p in enumerate(perm):
            inv_perm[p] = i
        # output_transposed 的形状是 [indices_shape] + [data_shape 去掉 axis]
        # 需要重新排列
        new_perm = list(range(len(indices_shape), len(indices_shape) + axis)) + \
                   list(range(0, len(indices_shape))) + \
                   list(range(len(indices_shape) + axis, data.ndim - 1 + len(indices_shape)))
        output = np.transpose(output_transposed, new_perm)
    else:
        output = output_transposed
    
    return output

def test_gather_basic():
    """测试基础功能"""
    print("=" * 60)
    print("测试 1: 基础 Gather (axis=0)")
    print("=" * 60)
    
    data = np.array([[1, 2, 3],
                     [4, 5, 6],
                     [7, 8, 9]])
    indices = np.array([0, 2])
    
    output = gather_vectorized(data, indices, axis=0)
    
    print(f"data 形状：{data.shape}")
    print(f"indices 形状：{indices.shape}")
    print(f"output 形状：{output.shape}")
    print(f"output:\n{output}")
    
    expected = np.array([[1, 2, 3],
                         [7, 8, 9]])
    assert np.array_equal(output, expected), "测试失败！"
    print("✓ 测试通过\n")


def test_gather_axis():
    """测试不同 axis"""
    print("=" * 60)
    print("测试 3: 不同 axis 参数")
    print("=" * 60)
    
    data = np.arange(36).reshape(3, 3, 4)
    indices = np.array([0, 2])
    
    for axis in range(3):
        output = gather_vectorized(data, indices, axis=axis)
        print(f"axis={axis}: data{data.shape} + indices{indices.shape} → output{output.shape}")
    
    print("✓ 测试通过\n")


def test_gather_consistency():
    """验证不同实现的一致性"""
    print("=" * 60)
    print("测试 4: 不同实现的一致性")
    print("=" * 60)
    
    data = np.random.randn(10, 20, 30).astype(np.float32)
    indices = np.random.randint(0, 10, (5, 8))
    
    output_naive = gather_naive(data, indices, axis=0)
    output_vec = gather_vectorized(data, indices, axis=0)
    output_manual = gather_manual(data, indices, axis=0)
    
    assert np.allclose(output_naive, output_vec), "naive vs vectorized 不一致"
    assert np.allclose(output_vec, output_manual), "vectorized vs manual 不一致"
    
    print("✓ 所有实现结果一致\n")


# ============================================================================
# 主函数
# ============================================================================

if __name__ == '__main__':
    print("\n" + "=" * 60)
    print("ONNX Gather 算子 Python 实现测试")
    print("=" * 60 + "\n")
    
    test_gather_basic()
    test_gather_axis()
    test_gather_consistency()
    
    print("=" * 60)
    print("所有测试完成！")
    print("=" * 60 + "\n")
