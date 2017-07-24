from __future__ import print_function
import ctypes

import pytest

import numpy as np
from numba import cuda

from libgdf_cffi import ffi, libgdf

from .utils import new_column, unwrap_devary, get_dtype


@pytest.mark.parametrize('dtype', [np.int32, np.int64, np.float32, np.float64])
def test_innerjoin(dtype):
    cuda.current_context()
    # Make data
    left = np.array([0, 0, 1, 2, 3], dtype=dtype)
    d_left = cuda.to_device(left)
    col_left = new_column()
    libgdf.gdf_column_view(col_left, unwrap_devary(d_left), ffi.NULL,
                           left.size, get_dtype(d_left.dtype))

    right = np.array([0, 1, 2, 2, 3], dtype=dtype)
    d_right = cuda.to_device(right)
    col_right = new_column()
    libgdf.gdf_column_view(col_right, unwrap_devary(d_right), ffi.NULL,
                           right.size, get_dtype(d_right.dtype))

    join_result_ptr = ffi.new("gdf_join_result_type**", None)

    libgdf.gdf_inner_join_generic(col_left, col_right, join_result_ptr)
    join_result = join_result_ptr[0]
    print('join_result', join_result)

    dataptr = libgdf.gdf_join_result_data(join_result)
    print(dataptr)
    datasize = libgdf.gdf_join_result_size(join_result)
    print(datasize)

    addr = ctypes.c_uint64(int(ffi.cast("uintptr_t", dataptr)))
    print(hex(addr.value))
    memptr = cuda.driver.MemoryPointer(context=cuda.current_context(),
                                       pointer=addr, size=2 * 4 * datasize)
    print(memptr)
    ary = cuda.devicearray.DeviceNDArray(shape=(2 * datasize,), strides=(4,),
                                         dtype=np.dtype(np.int32),
                                         gpu_data=memptr)

    joined_idx = ary.reshape(datasize, 2).copy_to_host()

    libgdf.gdf_join_result_free(join_result)
    # Check answer
    # Can be generated by:
    # In [56]: df = pd.DataFrame()
    # In [57]: df = pd.DataFrame()
    # In [58]: df['a'] = list(range(5))
    # In [59]: df1 = df.set_index(np.array([0, 0, 1, 2, 3]))
    # In [60]: df2 = df.set_index(np.array([0, 1, 2, 2, 3]))
    # In [61]: df1.join(df2, lsuffix='_left', rsuffix='_right', how='inner')
    # Out[61]:
    #    a_left  a_right
    # 0       0        0
    # 0       1        0
    # 1       2        1
    # 2       3        2
    # 2       3        3
    # 3       4        4
    left_idx, right_idx = zip(*[(left[a], right[b]) for a, b in joined_idx])
    assert left_idx == right_idx
    left_pos, right_pos = zip(*joined_idx)
    # left_pos == a_left
    assert left_pos == (0, 1, 2, 3, 3, 4)
    # right_pos == a_right
    assert right_pos == (0, 0, 1, 2, 3, 4)


@pytest.mark.parametrize('dtype', [np.int32, np.int64, np.float32, np.float64])
def test_leftjoin(dtype):
    cuda.current_context()
    # Make data
    left = np.array([0, 0, 4, 5, 5], dtype=dtype)
    d_left = cuda.to_device(left)
    col_left = new_column()
    libgdf.gdf_column_view(col_left, unwrap_devary(d_left), ffi.NULL,
                           left.size, get_dtype(d_left.dtype))

    right = np.array([0, 0, 2, 3, 5], dtype=dtype)
    d_right = cuda.to_device(right)
    col_right = new_column()
    libgdf.gdf_column_view(col_right, unwrap_devary(d_right), ffi.NULL,
                           right.size, get_dtype(d_right.dtype))

    join_result_ptr = ffi.new("gdf_join_result_type**", None)

    libgdf.gdf_left_join_generic(col_left, col_right, join_result_ptr)
    join_result = join_result_ptr[0]
    print('join_result', join_result)

    dataptr = libgdf.gdf_join_result_data(join_result)
    print(dataptr)
    datasize = libgdf.gdf_join_result_size(join_result)
    print(datasize)

    addr = ctypes.c_uint64(int(ffi.cast("uintptr_t", dataptr)))
    print(hex(addr.value))
    memptr = cuda.driver.MemoryPointer(context=cuda.current_context(),
                                       pointer=addr, size=2 * 4 * datasize)
    print(memptr)
    ary = cuda.devicearray.DeviceNDArray(shape=(2 * datasize,), strides=(4,),
                                         dtype=np.dtype(np.int32),
                                         gpu_data=memptr)

    joined_idx = ary.reshape(datasize, 2).copy_to_host()

    libgdf.gdf_join_result_free(join_result)
    # Check answer
    # Can be generated by:
    # In [75]: df = pd.DataFrame()
    # In [76]: df['a'] = list(range(5))
    # In [77]: df1 = df.set_index(np.array([0, 0, 4, 5, 5]))
    # In [78]: df2 = df.set_index(np.array([0, 0, 2, 3, 5]))
    # In [79]: df1.join(df2, lsuffix='_left', rsuffix='_right', how='left')
    # Out[79]:
    #    a_left  a_right
    # 0       0      0.0
    # 0       0      1.0
    # 0       1      0.0
    # 0       1      1.0
    # 4       2      NaN
    # 5       3      4.0
    # 5       4      4.0
    left_idx, right_idx = zip(*[(left[a], right[b] if b != -1 else None) for a, b in joined_idx])
    assert left_idx == (0, 0, 0, 0, 4, 5, 5)
    assert right_idx == (0, 0, 0, 0, None, 5, 5)
    left_pos, right_pos = zip(*joined_idx)
    # left_pos == a_left
    assert left_pos == (0, 0, 1, 1, 2, 3, 4)
    # right_pos == a_right
    assert right_pos == (0, 1, 0, 1, -1, 4, 4)

