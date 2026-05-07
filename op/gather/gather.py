import numpy as np


def gather_host_style(data: np.ndarray, indices: np.ndarray, axis: int = 0) -> np.ndarray:
    """
    与当前 C++ Host Gather 实现对应的 Python 版本

    当前约束：
    - data: embedding table / Params
    - indices: 2D，形状 [1, N]
    - axis: 默认 0
    - output_shape: data_shape 的 axis 维替换为 indices_shape[1]

    例如：
        data.shape    = [49408, 512]
        indices.shape = [1, 77]
        axis = 0
        output.shape  = [77, 512]
    """
    data = np.asarray(data, dtype=np.float32)
    indices = np.asarray(indices, dtype=np.int64)

    if data.ndim == 0:
        raise ValueError("data rank must be > 0")

    if indices.ndim != 2:
        raise ValueError(f"Current implementation only supports 2D indices, got rank={indices.ndim}")

    data_rank = data.ndim
    if axis < 0:
        axis += data_rank
    if not (0 <= axis < data_rank):
        raise ValueError(f"axis {axis} out of range for rank {data_rank}")

    data_shape = data.shape
    indices_shape = indices.shape

    # 与 C++ tinfer / forward 保持一致
    output_shape = list(data_shape)
    output_shape[axis] = indices_shape[1]
    output = np.empty(output_shape, dtype=data.dtype)

    indices_total = int(np.prod(indices_shape))

    pre_shape = 1
    for i in range(axis):
        pre_shape *= data_shape[i]

    post_shape = 1
    for i in range(axis + 1, data_rank):
        post_shape *= data_shape[i]

    # 拉平成便于和 C++ 的 src_idx / dst_idx 对齐
    data_flat = data.reshape(-1)
    output_flat = output.reshape(-1)
    indices_flat = indices.reshape(-1)

    axis_dim = data_shape[axis]

    for pre_idx in range(pre_shape):
        for idx_idx in range(indices_total):
            gather_idx = int(indices_flat[idx_idx])

            if not (0 <= gather_idx < axis_dim):
                raise IndexError(
                    f"Gather index {gather_idx} out of range [0, {axis_dim})"
                )

            for post_idx in range(post_shape):
                src_idx = (
                    pre_idx * (axis_dim * post_shape)
                    + gather_idx * post_shape
                    + post_idx
                )

                dst_idx = (
                    pre_idx * (indices_total * post_shape)
                    + idx_idx * post_shape
                    + post_idx
                )

                output_flat[dst_idx] = data_flat[src_idx]

    return output


def gather_reference(data: np.ndarray, indices: np.ndarray, axis: int = 0) -> np.ndarray:
    """
    参考实现，使用 numpy.take
    语义上与 gather_host_style 对齐
    """
    data = np.asarray(data, dtype=np.float32)
    indices = np.asarray(indices, dtype=np.int64)

    if axis < 0:
        axis += data.ndim

    return np.take(data, indices.reshape(-1), axis=axis)


def test_small_case():
    print("=" * 60)
    print("test_small_case")
    print("=" * 60)

    data = np.array([
        [1, 2, 3, 4],
        [10, 20, 30, 40],
        [100, 200, 300, 400],
        [1000, 2000, 3000, 4000],
    ], dtype=np.float32)  # shape [4, 4]

    indices = np.array([[0, 2, 3]], dtype=np.int64)  # shape [1, 3]

    out1 = gather_host_style(data, indices, axis=0)
    out2 = gather_reference(data, indices, axis=0)

    print("data.shape   =", data.shape)
    print("indices.shape=", indices.shape)
    print("out.shape    =", out1.shape)
    print(out1)

    assert np.allclose(out1, out2), "host_style 与 reference 不一致"
    print("✓ test_small_case passed\n")


def test_clip_like_case():
    print("=" * 60)
    print("test_clip_like_case")
    print("=" * 60)

    vocab_size = 49408
    hidden_dim = 512
    seq_len = 77

    # 模拟 embedding table
    rng = np.random.default_rng(0)
    data = rng.standard_normal((vocab_size, hidden_dim), dtype=np.float32)

    # 模拟 tokenizer 输出
    indices = np.array([[
        49406, 320, 1125, 539, 320, 1769, 4629,
        49407, 49407, 49407, 49407, 49407, 49407, 49407, 49407,
        49407, 49407, 49407, 49407, 49407, 49407, 49407, 49407,
        49407, 49407, 49407, 49407, 49407, 49407, 49407, 49407,
        49407, 49407, 49407, 49407, 49407, 49407, 49407, 49407,
        49407, 49407, 49407, 49407, 49407, 49407, 49407, 49407,
        49407, 49407, 49407, 49407, 49407, 49407, 49407, 49407,
        49407, 49407, 49407, 49407, 49407, 49407, 49407, 49407,
        49407, 49407, 49407, 49407, 49407, 49407, 49407, 49407,
        49407, 49407, 49407, 49407, 49407
    ]], dtype=np.int64)

    assert indices.shape == (1, seq_len)

    out1 = gather_host_style(data, indices, axis=0)
    out2 = gather_reference(data, indices, axis=0)

    print("data.shape   =", data.shape)
    print("indices.shape=", indices.shape)
    print("out.shape    =", out1.shape)
    print("out min/max  =", out1.min(), out1.max())
    print("out mean     =", out1.mean())
    print("first token first 10 values =", out1[0, :10])

    assert out1.shape == (seq_len, hidden_dim)
    assert np.allclose(out1, out2), "host_style 与 reference 不一致"
    print("✓ test_clip_like_case passed\n")


if __name__ == "__main__":
    test_small_case()
    test_clip_like_case()
    print("=" * 60)
    print("all tests passed")
    print("=" * 60)