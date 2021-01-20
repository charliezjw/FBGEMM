/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 * All rights reserved.
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */
#pragma once

#include <cuda.h>
#include "cub/block/block_reduce.cuh"

// Kernel for index hashing (template type scalar_t)
template <typename scalar_t>
__global__ void _index_hash_cuda_kernel(
    int64_t N,
    const scalar_t* __restrict__ indices,
    int64_t seed,
    int64_t modulo,
    scalar_t* __restrict__ hashed_indices) {
  int64_t idx = (int64_t)blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < N) {
    int8_t* bytes = (int8_t*)&(indices[idx]);
    scalar_t hashed = seed * 0xDEADBEEF;
    // The compiler can unroll the loop
    for (int i = 0; i < sizeof(scalar_t) / sizeof(int8_t); i++) {
      hashed = hashed * 65537 + bytes[i];
    }
    // We want the result of the modulo to be positive. This works under the
    // assumption that modulo_ > 0 which is enforced in the constructor.
    hashed_indices[idx] = (hashed % modulo + modulo) % modulo;
  }
}

// Kernel for calculating the offsets ranges
template <typename scalar_t>
__global__ void _offsets_range_cuda_kernel(
    int64_t N,
    int64_t range_size,
    const scalar_t* __restrict__ offsets_data,
    scalar_t* __restrict__ range_data) {
  int row_idx = blockIdx.x * blockDim.y + threadIdx.y;
  if (row_idx < N) {
    scalar_t row_start = offsets_data[row_idx];
    scalar_t row_end =
        (row_idx < N - 1 ? offsets_data[row_idx + 1] : range_size);
    if (blockDim.x == 32) {
      scalar_t i = row_start - (row_start & 31) + threadIdx.x;
      // unaligned part
      if (i >= row_start && i < row_end) {
        range_data[i] = i - row_start;
      }
      // aligned part
      for (i += 32; i < row_end; i += 32) {
        range_data[i] = i - row_start;
      }
    } else {
      for (scalar_t i = row_start + threadIdx.x; i < row_end; i += blockDim.x) {
        range_data[i] = i - row_start;
      }
    }
  }
}

// Kernel for bucketize lengths, with the Cyclic distribution (vs. block,
// block-cyclic distribution). Used for bucketize sparse feature with row-wise
// partition (sparse_feature is partitioned cyclically along the sparse
// dimension into my_size blocks)
template <typename scalar_t>
__global__ void _bucketize_sparse_features_cuda_kernel1(
    int lengths_size,
    int my_size,
    const scalar_t* __restrict__ offsets_data,
    const scalar_t* __restrict__ indices_data,
    scalar_t* __restrict__ new_lengths_data) {
  int r = (int)blockIdx.x * blockDim.x + threadIdx.x;
  if (r < lengths_size) {
    scalar_t rowstart = (r == 0 ? 0 : offsets_data[r - 1]);
    scalar_t rowend = offsets_data[r];
    for (scalar_t i = rowstart; i < rowend; ++i) {
      scalar_t idx = indices_data[i];
      scalar_t p = idx % my_size;
      new_lengths_data[p * lengths_size + r]++;
    }
  }
}

// Kernel for bucketize offsets, indices, and positional weights, with the
// Cyclic distribution (vs. block, block-cyclic distribution). Used for
// bucketize sparse feature with row-wise partition (sparse_feature is
// partitioned cyclically along the sparse dimension into my_size blocks)
template <
    bool has_weight,
    bool bucketize_pos,
    typename index_t,
    typename scalar_t>
__global__ void _bucketize_sparse_features_cuda_kernel2(
    int lengths_size,
    int my_size,
    const index_t* __restrict__ offsets_data,
    const index_t* __restrict__ indices_data,
    const scalar_t* __restrict__ weights_data,
    index_t* __restrict__ new_offsets_data,
    index_t* __restrict__ new_indices_data,
    scalar_t* __restrict__ new_weights_data,
    index_t* __restrict__ new_pos_data) {
  int r = (int)blockIdx.x * blockDim.x + threadIdx.x;
  if (r < lengths_size) {
    index_t rowstart = r == 0 ? 0 : offsets_data[r - 1];
    index_t rowend = offsets_data[r];
    for (index_t i = rowstart; i < rowend; ++i) {
      index_t idx = indices_data[i];
      index_t p = idx % my_size;
      index_t new_idx = idx / my_size;
      index_t pos = new_offsets_data[p * lengths_size + r];
      new_indices_data[pos] = new_idx;
      new_offsets_data[p * lengths_size + r]++;
      if (has_weight) {
        new_weights_data[pos] = weights_data[i];
      }
      if (bucketize_pos) {
        new_pos_data[pos] = i - rowstart;
      }
    }
  }
}

// Kernel for bucketize lengths, with the Block distribution (vs. cyclic,
// block-cyclic distribution). Used for bucketize sparse feature, especially for
// checkpointing with row-wise partition (sparse_feature is partitioned
// continuously along the sparse dimension into my_size blocks)
template <typename index_t>
__global__ void _block_bucketize_sparse_features_cuda_kernel1(
    int32_t lengths_size,
    int32_t B,
    const index_t* __restrict__ block_sizes_data,
    int my_size,
    const index_t* __restrict__ offsets_data,
    const index_t* __restrict__ indices_data,
    index_t* __restrict__ new_lengths_data) {
  int32_t b_t = (int32_t)blockIdx.x * blockDim.x + threadIdx.x;
  if (b_t >= lengths_size) {
    return;
  }
  int32_t t = b_t / B;
  index_t blk_size = block_sizes_data[t];
  index_t rowstart = (b_t == 0 ? 0 : offsets_data[b_t - 1]);
  index_t rowend = offsets_data[b_t];
  for (index_t i = rowstart; i < rowend; ++i) {
    index_t idx = indices_data[i];
    index_t p = idx / blk_size;
    new_lengths_data[p * lengths_size + b_t]++;
  }
}

// Kernel for bucketize offsets, indices, and positional weights, with the Block
// distribution (vs. cyclic, block-cyclic distribution). Used for bucketize
// sparse feature, especially for checkpointing with row-wise partition
// (sparse_feature is partitioned continuously along the sparse dimension into
// my_size blocks)
template <
    bool has_weight,
    bool bucketize_pos,
    typename index_t,
    typename scalar_t>
__global__ void _block_bucketize_sparse_features_cuda_kernel2(
    int lengths_size,
    int32_t B,
    const index_t* __restrict__ block_sizes_data,
    int my_size,
    const index_t* __restrict__ offsets_data,
    const index_t* __restrict__ indices_data,
    const scalar_t* __restrict__ weights_data,
    index_t* __restrict__ new_offsets_data,
    index_t* __restrict__ new_indices_data,
    scalar_t* __restrict__ new_weights_data,
    index_t* __restrict__ new_pos_data) {
  int32_t b_t = (int32_t)blockIdx.x * blockDim.x + threadIdx.x;
  if (b_t >= lengths_size) {
    return;
  }
  int32_t t = b_t / B;
  index_t blk_size = block_sizes_data[t];
  index_t rowstart = (b_t == 0 ? 0 : offsets_data[b_t - 1]);
  index_t rowend = offsets_data[b_t];
  for (index_t i = rowstart; i < rowend; ++i) {
    index_t idx = indices_data[i];
    index_t p = idx / blk_size;
    index_t new_idx = idx % blk_size;
    index_t pos = new_offsets_data[p * lengths_size + b_t];
    new_indices_data[pos] = new_idx;
    new_offsets_data[p * lengths_size + b_t]++;
    if (has_weight) {
      new_weights_data[pos] = weights_data[i];
    }
    if (bucketize_pos) {
      new_pos_data[pos] = i - rowstart;
    }
  }
}

// Kernel for calculating the segmented sum for sparse matrix with CSR format.
// See https://moderngpu.github.io/segreduce.html
template <typename scalar_t>
__global__ void _segment_sum_csr_cuda_kernel(
    int num_segments,
    int batch_size,
    const int* csr_seg_data,
    const scalar_t* values_data,
    scalar_t* output_data) {
  typedef cub::BlockReduce<scalar_t, 256> BlockReduce;
  __shared__ typename BlockReduce::TempStorage temp_storage;
  int seg_start = csr_seg_data[blockIdx.x] * batch_size;
  int seg_end = csr_seg_data[blockIdx.x + 1] * batch_size;
  scalar_t sum = 0;
  for (int i = seg_start; i < seg_end; i += blockDim.x) {
    scalar_t thread_data;
    if (threadIdx.x < seg_end - i) {
      thread_data = values_data[i + threadIdx.x];
    }
    scalar_t aggregate =
        BlockReduce(temp_storage).Sum(thread_data, seg_end - i);
    __syncthreads();
    if (threadIdx.x == 0) {
      sum += aggregate;
    }
  }
  if (threadIdx.x == 0) {
    output_data[blockIdx.x] = sum;
  }
}

// Kernel for permuting the indices and weights. Used for permutation of sparse
// features.
template <bool has_weight, typename index_t, typename scalar_t>
__global__ void permute_indices_weights_kernel(
    int32_t len,
    int32_t T,
    int32_t B,
    const index_t* __restrict__ indices,
    const scalar_t* __restrict__ weights,
    const int32_t* __restrict__ permute,
    const index_t* __restrict__ input_offsets,
    const index_t* __restrict__ output_offsets,
    index_t* __restrict__ permuted_indices,
    scalar_t* __restrict__ permuted_weights) {
  int32_t b_t = blockIdx.x * blockDim.y + threadIdx.y;
  int32_t b = b_t % B;
  int32_t t = b_t / B;
  index_t output_start = output_offsets[b_t];
  index_t segment_length;
  if (b_t < B * T) {
    if (b_t == B * T - 1) {
      segment_length = len - output_offsets[b_t];
    } else {
      segment_length = output_offsets[b_t + 1] - output_offsets[b_t];
    }
    index_t input_start = input_offsets[permute[t] * B + b];
    for (int32_t i = threadIdx.x; i < segment_length; i += blockDim.x) {
      permuted_indices[output_start + i] = indices[input_start + i];
      if (has_weight) {
        permuted_weights[output_start + i] = weights[input_start + i];
      }
    }
  }
}

// Kernel for permuting the lengths. Used for permutation of sparse features.
template <typename index_t>
__global__ void permute_lengths_kernel(
    int32_t T,
    int32_t B,
    const index_t* __restrict__ lengths,
    const int32_t* __restrict__ permute,
    index_t* __restrict__ permuted_lengths) {
  int32_t b_t = blockIdx.x * blockDim.x + threadIdx.x;
  int32_t b = b_t % B;
  int32_t t = b_t / B;
  if (b_t < B * T) {
    permuted_lengths[b_t] = lengths[permute[t] * B + b];
  }
}

// Construct the 1D offset (T * B + 1, the global offset starts at 0 from Table
// 0) from 2D batched offsets for each table (T * B, in each table, the offsets
// starts at 0).
template <typename index_t>
__global__ void construct_offsets_kernel(
    const index_t* __restrict__ batch_offsets_per_table, // 2D, T x B
    const index_t* __restrict__ total_indices_per_table, // 1D, T
    index_t* __restrict__ output, // 1D, T * B + 1
    const int64_t T,
    const int64_t B) {
  // do warp-per-D (so only need warp reduction)
  index_t b_t = blockIdx.x * blockDim.x + threadIdx.x;
  index_t b = b_t % B;
  index_t t = b_t / B;
  if (t < T) {
    index_t upper = 0;
    if (b != B - 1) {
      upper = batch_offsets_per_table[t * B + b + 1];
    } else {
      upper = total_indices_per_table[t];
    }
    index_t lower = batch_offsets_per_table[t * B + b];
    output[1 + t * B + b] = upper - lower;
  }
}

// Kernel for recat the embedding gradient output with the mixed dimension
// support
template <typename scalar_t>
__global__ void recat_copy_async_kernel(
    const int64_t* __restrict__ dim_sum_per_rank, // 1D, dim_num
    const int64_t* __restrict__ cum_dim_sum_per_rank, // 1D, dim_num
    const scalar_t* __restrict__ go, // 2D, B x sum(mixed_D)
    scalar_t* __restrict__ sgo, // 1D, B * sum(mixed_D)
    const int64_t dim_num,
    const int64_t B,
    const int64_t dim_sum) {
  auto b_w = blockIdx.x * blockDim.y + threadIdx.y;
  auto dim_id = b_w % dim_num;
  auto b = b_w / dim_num;
  if (b >= B) {
    return;
  }
  auto D_current = dim_sum_per_rank[dim_id];
  const auto tgt_base_addr = B * cum_dim_sum_per_rank[dim_id];
  const auto src_base_addr = cum_dim_sum_per_rank[dim_id];
  for (int32_t d = threadIdx.x; d < D_current; d += blockDim.x) {
    sgo[tgt_base_addr + b * D_current + d] =
        go[b * dim_sum + src_base_addr + d];
  }
}
