/*
 * Copyright (c) 2024 by SageAttention team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once
#include <cuda.h>
#include <cuda_bf16.h>
#include <cuda_fp8.h>
#include <cassert>

#include "../wgmma.cuh"
#include "../math.cuh"
#include "attn_utils.cuh"

#if (!defined(__CUDA_ARCH__) || (__CUDA_ARCH__ >= 900))
#define SM90_ENABLED
#endif

#if defined(__CUDA_ARCH__)
#define RUNTIME_ASSERT(x) __brkpt()
#else
#include <assert.h>
#define RUNTIME_ASSERT(x) assert(0 && x)
#endif

template <int BlockMajorSize, int BlockMinorSize, bool swizzle=true, CUtensorMapL2promotion_enum promotion_mode=CU_TENSOR_MAP_L2_PROMOTION_NONE, typename T>
CUtensorMap create_tensor_map_4D(T* gmem_ptr, int d1, int d2, int d3, int d4, int stride1, int stride2, int stride3)
{
  constexpr int smem_stride = BlockMinorSize * sizeof(T);
  static_assert(sizeof(T) == 2 || sizeof(T) == 1);
  static_assert(smem_stride == 32 || smem_stride == 64 || smem_stride == 128);
  
  CUtensorMap tma_map;
  void* gmem_address = (void*)gmem_ptr;
  uint64_t gmem_prob_shape[5] = {(uint64_t)d4, (uint64_t)d3, (uint64_t)d2, (uint64_t)d1, 1};
  uint64_t gmem_prob_stride[5] = {(uint64_t)stride3 * sizeof(T), (uint64_t)stride2 * sizeof(T), (uint64_t)stride1 * sizeof(T), 0, 0};
  uint32_t smem_box_shape[5] = {uint32_t(BlockMinorSize), uint32_t(BlockMajorSize), 1, 1, 1};
  uint32_t smem_box_stride[5] = {1, 1, 1, 1, 1};

  CUresult result = cuTensorMapEncodeTiled(
    &tma_map, (sizeof(T) == 2) ? CU_TENSOR_MAP_DATA_TYPE_BFLOAT16 : CU_TENSOR_MAP_DATA_TYPE_UINT8, 4, gmem_address, gmem_prob_shape,
    gmem_prob_stride, smem_box_shape, smem_box_stride, CU_TENSOR_MAP_INTERLEAVE_NONE,
    (swizzle == false) ? CU_TENSOR_MAP_SWIZZLE_NONE : (smem_stride == 128) ? CU_TENSOR_MAP_SWIZZLE_128B : (smem_stride == 64) ? CU_TENSOR_MAP_SWIZZLE_64B : CU_TENSOR_MAP_SWIZZLE_32B, 
    promotion_mode, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE);

  assert(result == CUDA_SUCCESS);

  return tma_map;
}


#ifdef SM90_ENABLED
__device__ __forceinline__ void init_barrier(uint64_t* bar, int thread_count)
{
  uint32_t bar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar)); 
  asm volatile (
    "mbarrier.init.shared::cta.b64 [%0], %1;\n"
    :: "r"(bar_ptr), "r"(thread_count)
  );
}

template <uint32_t bytes>
__device__ __forceinline__ void expect_bytes(uint64_t* bar)
{
  uint32_t bar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar)); 
  asm volatile ("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], %1;\n"
    :: "r"(bar_ptr), "n"(bytes));
}

template <typename T>
__device__ __forceinline__ void load_async_4D(T* dst, void const* src_tma_map, uint64_t* bar, int s0, int s1, int s2, int s3)
{
  uint64_t tma_ptr  = reinterpret_cast<uint64_t>(src_tma_map);
  uint32_t mbar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar));
  uint32_t dst_ptr  = static_cast<uint32_t>(__cvta_generic_to_shared(dst));

  asm volatile (
    "cp.async.bulk.tensor.4d.shared::cluster.global.tile.mbarrier::complete_tx::bytes"
    " [%0], [%1, {%3, %4, %5, %6}], [%2];"
    :
    : "r"(dst_ptr), "l"(tma_ptr), "r"(mbar_ptr),
    "r"(s0), "r"(s1), "r"(s2), "r"(s3)
    : "memory"
  );
}

template <typename T>
__device__ __forceinline__ void store_async_4D(void const* dst_tma_map, T* src, int global_token_idx, int global_head_idx, int global_batch_idx)
{
  uint64_t tma_ptr  = reinterpret_cast<uint64_t>(dst_tma_map);
  uint32_t src_ptr  = static_cast<uint32_t>(__cvta_generic_to_shared(src));

  asm volatile (
    "cp.async.bulk.tensor.4d.global.shared::cta.tile.bulk_group"
    " [%0, {%2, %3, %4, %5}], [%1];"
    :
    : "l"(tma_ptr), "r"(src_ptr),
    "n"(0), "r"(global_token_idx), "r"(global_head_idx), "r"(global_batch_idx)
    : "memory"
  );
}

__device__ __forceinline__ void wait(uint64_t* bar, int kPhaseBit)
{
  uint32_t mbar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar)); 
  asm volatile (
    "{\n"
    ".reg .pred                P1;\n"
    "LAB_WAIT:\n"
    "mbarrier.try_wait.parity.shared::cta.b64 P1, [%0], %1;\n"
    "@P1                       bra.uni DONE;\n"
    "bra.uni                   LAB_WAIT;\n"
    "DONE:\n"
    "}\n"
    :: "r"(mbar_ptr),
    "r"(kPhaseBit)
  );
}

template <uint32_t count = 1>
__device__ __forceinline__ void arrive(uint64_t* bar)
{
  uint32_t mbar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar)); 
  asm volatile (
    "mbarrier.arrive.release.cta.shared::cta.b64 _, [%0], %1;\n"
    :
    : "r"(mbar_ptr), "n"(count)
    : "memory"
  );
}
#else
__device__ __forceinline__ void init_barrier(uint64_t* bar, int thread_count){
  RUNTIME_ASSERT("Unsupported CUDA architecture for init_barrier instruction");
}

template <uint32_t bytes>
__device__ __forceinline__ void expect_bytes(uint64_t* bar){
  RUNTIME_ASSERT("Unsupported CUDA architecture for expect_bytes instruction");
}

template <typename T>
__device__ __forceinline__ void load_async_4D(T* dst, void const* src_tma_map, uint64_t* bar, int s0, int s1, int s2, int s3){
  RUNTIME_ASSERT("Unsupported CUDA architecture for load_async_4D instruction");
}

template <typename T>
__device__ __forceinline__ void store_async_4D(void const* dst_tma_map, T* src, int global_token_idx, int global_head_idx, int global_batch_idx){
  RUNTIME_ASSERT("Unsupported CUDA architecture for store_async_4D instruction");
}

__device__ __forceinline__ void wait(uint64_t* bar, int kPhaseBit){
  RUNTIME_ASSERT("Unsupported CUDA architecture for wait instruction");
}

template <uint32_t count = 1>
__device__ __forceinline__ void arrive(uint64_t* bar){
  RUNTIME_ASSERT("Unsupported CUDA architecture arrive instruction");
}
    
#endif

template<uint32_t CTA_Q, uint32_t CTA_K, uint32_t NUM_THREADS, uint32_t head_dim, QuantGranularity Q_GRAN, QuantGranularity K_GRAN, PVThresholdMode pv_threashold_mode, typename DTypeOut, MaskMode mask_mode = MaskMode::kNone, bool fuse_v_scale = false, bool return_pv_count = false>
__global__ void qk_int8_sv_f8_attn_kernel(const __grid_constant__ CUtensorMap tensorMapQ, 
                                        const __grid_constant__ CUtensorMap tensorMapK,
                                        const __grid_constant__ CUtensorMap tensorMapV,
                                        float *__restrict__ Q_scale, float *__restrict__ K_scale, float *__restrict__ V_scale,
                                        DTypeOut* O, int32_t *__restrict__ PV_Count, int32_t *__restrict__ Lut, int32_t *__restrict__ Valid_Block_Num, float *__restrict__ PV_Threshold,
                                        uint32_t stride_bz_o, uint32_t stride_h_o, uint32_t stride_seq_o,
                                        const uint32_t qo_len, const uint32_t kv_len, const uint32_t num_kv_groups,
                                        float sm_scale)
{
  static_assert(NUM_THREADS == 128);
  static_assert(CTA_Q <= CTA_K);
  
  const uint32_t warp_idx = (threadIdx.x % 128) / 32;
  const uint32_t lane_id = threadIdx.x % 32;

  constexpr uint32_t num_tiles_q = CTA_Q / 64;
  constexpr uint32_t num_tiles_k = CTA_K / 16;
  constexpr uint32_t num_tiles_qk_inner = head_dim / 32;
  constexpr uint32_t num_tiles_v = head_dim / 16;
  constexpr uint32_t num_tiles_pv_inner = CTA_K / 32;

  const uint32_t batch_id = blockIdx.z;
  const uint32_t bx = blockIdx.x;
  const uint32_t head_id = blockIdx.y;
  const uint32_t num_qo_heads = gridDim.y;
  const uint32_t kv_head_id = head_id / num_kv_groups;

  sm_scale *= math::log2e;

  float pv_threshold;
  int pv_count = 0;

  if constexpr (pv_threashold_mode != PVThresholdMode::kNone)
  {
    pv_threshold = PV_Threshold[head_id];
  }

  extern __shared__ __align__(128) int8_t smem_[];

  int8_t *sQ = (int8_t*)smem_;
  int8_t *sK = (int8_t*)(smem_ + CTA_Q * head_dim * sizeof(int8_t));
  int8_t *sV = (int8_t*)(smem_ + CTA_Q * head_dim * sizeof(int8_t) + CTA_K * head_dim * sizeof(int8_t));
  half *sO = (half*)smem_;

  int32_t RS[num_tiles_q][num_tiles_k][8];
  float RO[num_tiles_q][num_tiles_v][8];
  float m[num_tiles_q][2];
  float d[num_tiles_q][2];

  uint32_t q_scale_idx, k_scale_idx;

  if constexpr (Q_GRAN == QuantGranularity::kPerBlock)
  {
    const uint32_t num_block_q = gridDim.x;
    q_scale_idx = batch_id * num_qo_heads * num_block_q + head_id * num_block_q + bx;
  }
  else if constexpr (Q_GRAN == QuantGranularity::kPerWarp)
  {
    const uint32_t num_warp_block_q = gridDim.x * 4;
    q_scale_idx = batch_id * num_qo_heads * num_warp_block_q + head_id * num_warp_block_q + bx * 4 + warp_idx;
  }
  else if constexpr (Q_GRAN == QuantGranularity::kPerThread)
  {
    const uint32_t num_warp_block_q = gridDim.x * 4;
    q_scale_idx = batch_id * num_qo_heads * (num_warp_block_q * 8) + head_id * (num_warp_block_q * 8) + bx * (4 * 8) + warp_idx * 8 + lane_id / 4;
  }

  if constexpr (K_GRAN == QuantGranularity::kPerBlock || K_GRAN == QuantGranularity::kPerWarp)
  {
    const uint32_t num_block_k = div_ceil(kv_len, CTA_K);
    k_scale_idx = batch_id * (num_qo_heads / num_kv_groups) * num_block_k + (head_id / num_kv_groups) * num_block_k;
  }
  else if constexpr (K_GRAN == QuantGranularity::kPerThread)
  {
    const uint32_t num_block_k = div_ceil(kv_len, CTA_K);
    k_scale_idx = batch_id * (num_qo_heads / num_kv_groups) * (num_block_k * 4) + (head_id / num_kv_groups) * (num_block_k * 4) + lane_id % 4;
  }

  constexpr uint32_t k_scale_advance_offset = (K_GRAN == QuantGranularity::kPerBlock || K_GRAN == QuantGranularity::kPerWarp) ? 1 : 4;

  uint32_t Q_idx_lane_base = bx * CTA_Q + warp_idx * 16 + lane_id / 4;

#pragma unroll
  for (uint32_t fq = 0; fq < num_tiles_q; fq++)
  {
    m[fq][0] = -5000000.0f;
    m[fq][1] = -5000000.0f;
    d[fq][0] = 1.0f;
    d[fq][1] = 1.0f;
  }

#pragma unroll
  for (uint32_t fq = 0; fq < num_tiles_q; fq++)
  {
#pragma unroll
    for (uint32_t fv = 0; fv < num_tiles_v; fv++)
    {
#pragma unroll
      for (uint32_t k = 0; k < 8; k++)
      {
        RO[fq][fv][k] = 0.0f;
      }
    }
  }

  __shared__ __align__(8) uint64_t barrier_Q;
  __shared__ __align__(8) uint64_t barrier_K;
  __shared__ __align__(8) uint64_t barrier_V;

  if (threadIdx.x == 0)
  {
    init_barrier(&barrier_Q, 1);
    init_barrier(&barrier_K, 1);
    init_barrier(&barrier_V, 1);
  }

  __syncthreads();

  const uint32_t num_block_q = gridDim.x;
  const uint32_t num_iterations = Valid_Block_Num[batch_id * num_qo_heads * num_block_q + head_id * num_block_q + bx];

  if (num_iterations == 0)
  {
      return;
  }

  // move Lut to the correct place
  const uint32_t num_block_k = div_ceil(kv_len, CTA_K);
  Lut += batch_id * num_qo_heads * num_block_q * num_block_k + head_id * num_block_q * num_block_k + bx * num_block_k;

  uint32_t KV_block_idx = Lut[0];

  // load Q, K, V
  if (threadIdx.x == 0)
  {
    expect_bytes<(CTA_Q * head_dim) * sizeof(int8_t)>(&barrier_Q);
    expect_bytes<(CTA_K * head_dim) * sizeof(int8_t)>(&barrier_K);
    expect_bytes<(CTA_K * head_dim) * sizeof(int8_t)>(&barrier_V);
    load_async_4D(sQ, &tensorMapQ, &barrier_Q, 0, bx * CTA_Q, head_id, batch_id);
    load_async_4D(sK, &tensorMapK, &barrier_K, 0, KV_block_idx * CTA_K, kv_head_id, batch_id);
    load_async_4D(sV, &tensorMapV, &barrier_V, KV_block_idx * CTA_K, 0, kv_head_id, batch_id);
  }

  float q_scale = Q_scale[q_scale_idx];
  float original_sm_scale = sm_scale;

  // wait for Q
  wait(&barrier_Q, 0);

  int p = 1;
  for (uint32_t iter = 1; iter < num_iterations; iter++)
  { 
    p ^= 1;

    float dequant_scale = q_scale * K_scale[k_scale_idx + KV_block_idx * k_scale_advance_offset];
    sm_scale = original_sm_scale * dequant_scale;
    KV_block_idx += Lut[iter];

    // wait for K
    wait(&barrier_K, p);

    // compute QK^T
    wgmma::warpgroup_arrive();
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
      int8_t *sQ_local = sQ + fq * 64 * head_dim;
      wgmma::wgmma_s8s8s32<CTA_K, 0, head_dim>(RS[fq], sQ_local, sK);
#pragma unroll
      for (int k_it = 1; k_it < num_tiles_qk_inner; k_it++)
      {
        wgmma::wgmma_s8s8s32<CTA_K, 1, head_dim>(RS[fq], &sQ_local[k_it*32], &sK[k_it*32]);
      }
    }
    wgmma::warpgroup_commit_batch();
    wgmma::warpgroup_wait<0>();

    // load K
    if (threadIdx.x == 0)
    {
      expect_bytes<(CTA_K * head_dim) * sizeof(int8_t)>(&barrier_K);
      load_async_4D(sK, &tensorMapK, &barrier_K, 0, KV_block_idx * CTA_K, kv_head_id, batch_id);
    }

    // convert RS to float
    float RS_f32[num_tiles_q][num_tiles_k][8];
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          RS_f32[fq][fk][k] = __int2float_rz(RS[fq][fk][k]);
        }
      }
    }

    if constexpr (pv_threashold_mode != PVThresholdMode::kNone)
    {
      float local_max_diff = update_mo<num_tiles_q, num_tiles_k, num_tiles_v, false, false, false>(RS_f32, RO, m, d, sm_scale);
      
      // reduce max diff in a warp
      local_max_diff = max(local_max_diff, __shfl_xor_sync(0xffffffff, local_max_diff, 0x4));
      local_max_diff = max(local_max_diff, __shfl_xor_sync(0xffffffff, local_max_diff, 0x8));
      local_max_diff = max(local_max_diff, __shfl_xor_sync(0xffffffff, local_max_diff, 0x10));

      if constexpr (pv_threashold_mode == PVThresholdMode::kPerBlock)
      {
        constexpr uint32_t num_warps = 4;

        // reduce max diff in a block
        static __shared__ float reduced_buffer[num_warps * 32];
        reduced_buffer[lane_id + warp_idx * 32] = local_max_diff;
        __syncthreads();

        if constexpr (num_warps == 4)
        {
          local_max_diff = reduced_buffer[(lane_id % 4) * 32 + lane_id];
          local_max_diff = max(local_max_diff, __shfl_xor_sync(0xffffffff, local_max_diff, 0x1));
          local_max_diff = max(local_max_diff, __shfl_xor_sync(0xffffffff, local_max_diff, 0x2));
        }
      }

      // wait for V
      wait(&barrier_V, p);

      // skip the computation on warp level
      if (local_max_diff + pv_threshold > 0)
      {
        if constexpr (return_pv_count)
        {
          pv_count++;
        }

        exponentiate_r<num_tiles_q, num_tiles_k, true>(RS_f32, m, sm_scale);

        // accumulate d on thread basis
        #pragma unroll
        for (uint32_t fq = 0; fq < num_tiles_q; fq++)
        {
  #pragma unroll
          for (uint32_t fk = 0; fk < num_tiles_k; fk++)
          {
            d[fq][0] += (RS_f32[fq][fk][0] + RS_f32[fq][fk][1] + RS_f32[fq][fk][4] + RS_f32[fq][fk][5]);
            d[fq][1] += (RS_f32[fq][fk][2] + RS_f32[fq][fk][3] + RS_f32[fq][fk][6] + RS_f32[fq][fk][7]);
          }
        }
    
        uint32_t RS_f8[num_tiles_q][num_tiles_pv_inner][4];
        RS_32_to_8<num_tiles_q, num_tiles_k>(RS_f32, RS_f8);

        float RO_temp[num_tiles_q][num_tiles_v][8];
        wgmma::warpgroup_arrive();
#pragma unroll
        for (uint32_t fq = 0; fq < num_tiles_q; fq++)
        {
          wgmma::wgmma_f8f8f32<head_dim, 0, CTA_K>(RO_temp[fq], RS_f8[fq][0], &sV[0]);
#pragma unroll
          for (uint32_t v_it = 1; v_it < num_tiles_pv_inner; v_it++)
          {
            wgmma::wgmma_f8f8f32<head_dim, 1, CTA_K>(RO_temp[fq], RS_f8[fq][v_it], &sV[v_it * 32]);
          }
        }
    
        wgmma::warpgroup_commit_batch();
        wgmma::warpgroup_wait<0>();
      
#pragma unroll
        for (uint32_t fq = 0; fq < num_tiles_q; fq++)
        {
#pragma unroll
          for (uint32_t fv = 0; fv < num_tiles_v; fv++)
          {
#pragma unroll
            for (uint32_t k = 0; k < 8; k++)
            {
              RO[fq][fv][k] += RO_temp[fq][fv][k];
            }
          }
        }
      }
    }
    else // if we don't use pv_threshold, we just do the computation
    {
      if constexpr (return_pv_count)
      {
        pv_count++;
      }

      update_mdo<num_tiles_q, num_tiles_k, num_tiles_v, false, true, false>(RS_f32, RO, m, d, sm_scale);

      // accumulate d on thread basis
#pragma unroll
      for (uint32_t fq = 0; fq < num_tiles_q; fq++)
      {
#pragma unrol
        for (uint32_t fk = 0; fk < num_tiles_k; fk++)
        {
          d[fq][0] += (RS_f32[fq][fk][0] + RS_f32[fq][fk][1] + RS_f32[fq][fk][4] + RS_f32[fq][fk][5]);
          d[fq][1] += (RS_f32[fq][fk][2] + RS_f32[fq][fk][3] + RS_f32[fq][fk][6] + RS_f32[fq][fk][7]);
        }
      }
  
      uint32_t RS_f8[num_tiles_q][num_tiles_pv_inner][4];
      RS_32_to_8<num_tiles_q, num_tiles_k>(RS_f32, RS_f8);
  
      // wait for V
      wait(&barrier_V, p);

      float RO_temp[num_tiles_q][num_tiles_v][8];
      wgmma::warpgroup_arrive();
#pragma unroll
      for (uint32_t fq = 0; fq < num_tiles_q; fq++)
      {
        wgmma::wgmma_f8f8f32<head_dim, 0, CTA_K>(RO_temp[fq], RS_f8[fq][0], &sV[0]);
#pragma unroll
        for (uint32_t v_it = 1; v_it < num_tiles_pv_inner; v_it++)
        {
          wgmma::wgmma_f8f8f32<head_dim, 1, CTA_K>(RO_temp[fq], RS_f8[fq][v_it], &sV[v_it * 32]);
        }
      }
  
      wgmma::warpgroup_commit_batch();
      wgmma::warpgroup_wait<0>();
  
#pragma unroll
      for (uint32_t fq = 0; fq < num_tiles_q; fq++)
      {
#pragma unroll
        for (uint32_t fv = 0; fv < num_tiles_v; fv++)
        {
#pragma unroll
          for (uint32_t k = 0; k < 8; k++)
          {
            RO[fq][fv][k] += RO_temp[fq][fv][k];
          }
        }
      }
    }

//     update_mdo<num_tiles_q, num_tiles_k, num_tiles_v, false, true, false>(RS_f32, RO, m, d, sm_scale);

//     // accumulate d on thread basis
// #pragma unroll
//     for (uint32_t fq = 0; fq < num_tiles_q; fq++)
//     {
// #pragma unrol
//       for (uint32_t fk = 0; fk < num_tiles_k; fk++)
//       {
//         d[fq][0] += (RS_f32[fq][fk][0] + RS_f32[fq][fk][1] + RS_f32[fq][fk][4] + RS_f32[fq][fk][5]);
//         d[fq][1] += (RS_f32[fq][fk][2] + RS_f32[fq][fk][3] + RS_f32[fq][fk][6] + RS_f32[fq][fk][7]);
//       }
//     }

//     uint32_t RS_f8[num_tiles_q][num_tiles_pv_inner][4];
//     RS_32_to_8<num_tiles_q, num_tiles_k>(RS_f32, RS_f8);

//     // wait for V
//     wait(&barrier_V, p);

//     float RO_temp[num_tiles_q][num_tiles_v][8];
//     wgmma::warpgroup_arrive();
// #pragma unroll
//     for (uint32_t fq = 0; fq < num_tiles_q; fq++)
//     {
//       wgmma::wgmma_f8f8f32<head_dim, 0, CTA_K>(RO_temp[fq], RS_f8[fq][0], &sV[0]);
// #pragma unroll
//       for (uint32_t v_it = 1; v_it < num_tiles_pv_inner; v_it++)
//       {
//         wgmma::wgmma_f8f8f32<head_dim, 1, CTA_K>(RO_temp[fq], RS_f8[fq][v_it], &sV[v_it * 32]);
//       }
//     }

//     wgmma::warpgroup_commit_batch();
//     wgmma::warpgroup_wait<0>();

// #pragma unroll
//     for (uint32_t fq = 0; fq < num_tiles_q; fq++)
//     {
// #pragma unroll
//       for (uint32_t fv = 0; fv < num_tiles_v; fv++)
//       {
// #pragma unroll
//         for (uint32_t k = 0; k < 8; k++)
//         {
//           RO[fq][fv][k] += RO_temp[fq][fv][k];
//         }
//       }
//     }

    // load V
    if (threadIdx.x == 0)
    {
      expect_bytes<(CTA_K * head_dim) * sizeof(int8_t)>(&barrier_V);
      load_async_4D(sV, &tensorMapV, &barrier_V, KV_block_idx * CTA_K, 0, kv_head_id, batch_id);
    }
  }

  { 
    p ^= 1;

    float dequant_scale = q_scale * K_scale[k_scale_idx + KV_block_idx * k_scale_advance_offset];
    sm_scale = original_sm_scale;

    // wait for K
    wait(&barrier_K, p);

    // compute QK^T
    wgmma::warpgroup_arrive();
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
      int8_t *sQ_local = sQ + fq * 64 * head_dim;
      wgmma::wgmma_s8s8s32<CTA_K, 0, head_dim>(RS[fq], sQ_local, sK);
#pragma unroll
      for (int k_it = 1; k_it < num_tiles_qk_inner; k_it++)
      {
        wgmma::wgmma_s8s8s32<CTA_K, 1, head_dim>(RS[fq], &sQ_local[k_it*32], &sK[k_it*32]);
      }
    }
    wgmma::warpgroup_commit_batch();
    wgmma::warpgroup_wait<0>();

    // convert RS to float
    float RS_f32[num_tiles_q][num_tiles_k][8];
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          RS_f32[fq][fk][k] = __int2float_rz(RS[fq][fk][k]) * dequant_scale;
        }
      }
    }

    if constexpr (return_pv_count)
    {
      pv_count++;
    }

    // masking
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          const uint32_t q_idx = Q_idx_lane_base + fq * 64 + 8 * ((k % 4) / 2);
          const uint32_t k_idx = KV_block_idx * CTA_K + fk * 16 + 2 * (lane_id % 4) + 8 * (k / 4) + k % 2;

          bool is_out_of_bounds;

          if constexpr (mask_mode == MaskMode::kCausal)
          {
            is_out_of_bounds = (k_idx > q_idx) || (k_idx >= kv_len);
          }
          else
          {
            is_out_of_bounds = (k_idx >= kv_len);
          }

          if (is_out_of_bounds)
          {
            RS_f32[fq][fk][k] = -5000000.0f;
          }
        }
      }
    }

    update_mdo<num_tiles_q, num_tiles_k, num_tiles_v, false, true, false>(RS_f32, RO, m, d, sm_scale);

    // accumulate d on thread basis
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unrol
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
        d[fq][0] += (RS_f32[fq][fk][0] + RS_f32[fq][fk][1] + RS_f32[fq][fk][4] + RS_f32[fq][fk][5]);
        d[fq][1] += (RS_f32[fq][fk][2] + RS_f32[fq][fk][3] + RS_f32[fq][fk][6] + RS_f32[fq][fk][7]);
      }
    }

    uint32_t RS_f8[num_tiles_q][num_tiles_pv_inner][4];
    RS_32_to_8<num_tiles_q, num_tiles_k>(RS_f32, RS_f8);

    // wait for V
    wait(&barrier_V, p);

    float RO_temp[num_tiles_q][num_tiles_v][8];
    wgmma::warpgroup_arrive();
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
      wgmma::wgmma_f8f8f32<head_dim, 0, CTA_K>(RO_temp[fq], RS_f8[fq][0], &sV[0]);
#pragma unroll
      for (uint32_t v_it = 1; v_it < num_tiles_pv_inner; v_it++)
      {
        wgmma::wgmma_f8f8f32<head_dim, 1, CTA_K>(RO_temp[fq], RS_f8[fq][v_it], &sV[v_it * 32]);
      }
    }

    wgmma::warpgroup_commit_batch();
    wgmma::warpgroup_wait<0>();

#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fv = 0; fv < num_tiles_v; fv++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          RO[fq][fv][k] += RO_temp[fq][fv][k];
        }
      }
    }
  }

  if constexpr (return_pv_count)
  {

    if (lane_id == 0)
    {
      PV_Count[batch_id * num_qo_heads * num_block_q * 4 + head_id * num_block_q * 4 + bx * 4 + warp_idx] = pv_count;
    }

    __syncthreads();
  }

  normalize_d<num_tiles_q, num_tiles_v, ComputeUnit::kCudaCore>(RO, m, d);

  if constexpr (fuse_v_scale)
  {
    float v_scale[4];
    float *V_scale_base_ptr = V_scale +  batch_id * (num_qo_heads / num_kv_groups) * head_dim + (head_id / num_kv_groups) * head_dim + (lane_id % 4 ) * 2;
  #pragma unroll
    for (uint32_t fv = 0; fv < num_tiles_v; fv++)
    {
      ((float2*)v_scale)[0] = *((float2*)(V_scale_base_ptr + fv * 16));
      ((float2*)v_scale)[1] = *((float2*)(V_scale_base_ptr + fv * 16 + 8));

  #pragma unroll
      for (uint32_t fq = 0; fq < num_tiles_q; fq++)
      {
        RO[fq][fv][0] *= v_scale[0];
        RO[fq][fv][1] *= v_scale[1];
        RO[fq][fv][2] *= v_scale[0];
        RO[fq][fv][3] *= v_scale[1];
        RO[fq][fv][4] *= v_scale[2];
        RO[fq][fv][5] *= v_scale[3];
        RO[fq][fv][6] *= v_scale[2];
        RO[fq][fv][7] *= v_scale[3];
      }
    }
  }

  DTypeOut *O_lane_ptr = O + batch_id * stride_bz_o + head_id * stride_h_o + (bx * CTA_Q + warp_idx * 16 + (lane_id / 4)) * stride_seq_o + (lane_id % 4) * 2 ;
#pragma unroll
  for (uint32_t fq = 0; fq < num_tiles_q; fq++)
  {
#pragma unroll
    for (uint32_t fv = 0; fv < head_dim/16; fv++)
    { 
      if (Q_idx_lane_base + fq * 64 < qo_len)
      {
        if constexpr (std::is_same<DTypeOut, half>::value)
        {
          ((half2*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16))[0] = __float22half2_rn(((float2*)(RO[fq][fv]))[0]);
          ((half2*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8))[0] = __float22half2_rn(((float2*)(RO[fq][fv]))[2]);
        }
        else
        {
          ((nv_bfloat162*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16))[0] = __float22bfloat162_rn(((float2*)(RO[fq][fv]))[0]);
          ((nv_bfloat162*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8))[0] = __float22bfloat162_rn(((float2*)(RO[fq][fv]))[2]);  
        }
      }
      
      if (Q_idx_lane_base + fq * 64 + 8 < qo_len)
      {
        if constexpr (std::is_same<DTypeOut, half>::value)
        {
          ((half2*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8 * stride_seq_o))[0] = __float22half2_rn(((float2*)(RO[fq][fv]))[1]);
          ((half2*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8 + 8 * stride_seq_o))[0] = __float22half2_rn(((float2*)(RO[fq][fv]))[3]);
        }
        else
        {
          ((nv_bfloat162*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8 * stride_seq_o))[0] = __float22bfloat162_rn(((float2*)(RO[fq][fv]))[1]);
          ((nv_bfloat162*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8 + 8 * stride_seq_o))[0] = __float22bfloat162_rn(((float2*)(RO[fq][fv]))[3]);      
        }
      }
    }
  }
}

template<uint32_t CTA_Q, uint32_t CTA_K, uint32_t NUM_THREADS, uint32_t head_dim, uint32_t qk_quant_gran, uint32_t pv_threashold_mode, typename DTypeOut, bool is_causal, bool fuse_v_scale, bool return_pv_count>
void SpargeAttentionSM90Dispatched(
  int8_t* Q, int8_t* K, __nv_fp8_e4m3* V, DTypeOut* O,
  int32_t* PV_Count, int32_t *__restrict__ Lut, int32_t *__restrict__ Valid_Block_Num, float *__restrict__ PV_Threshold,
  float* Q_scale, float* K_scale, float* V_scale,
  const uint32_t batch_size, const uint32_t qo_len, const uint32_t kv_len, const uint32_t padded_kv_len, const uint32_t num_qo_heads, const uint32_t num_kv_heads,
  const uint32_t stride_bz_q, const uint32_t stride_seq_q, const uint32_t stride_h_q,
  const uint32_t stride_bz_k, const uint32_t stride_seq_k, const uint32_t stride_h_k,
  const uint32_t stride_bz_v, const uint32_t stride_h_v, const uint32_t stride_d_v,
  const uint32_t stride_bz_o, const uint32_t stride_seq_o, const uint32_t stride_h_o,
  float sm_scale)
{
  constexpr MaskMode mask_mode = is_causal ? MaskMode::kCausal : MaskMode::kNone;

  CUtensorMap tma_map_Q = create_tensor_map_4D<CTA_Q, head_dim>(Q, batch_size, num_qo_heads, qo_len, head_dim, stride_bz_q, stride_h_q, stride_seq_q);
  CUtensorMap tma_map_K = create_tensor_map_4D<CTA_K, head_dim>(K, batch_size, num_kv_heads, kv_len, head_dim, stride_bz_k, stride_h_k, stride_seq_k);
  CUtensorMap tma_map_V = create_tensor_map_4D<head_dim, CTA_K>(V, batch_size, num_kv_heads, head_dim, padded_kv_len, stride_bz_v, stride_h_v, stride_d_v);

  auto* kernel = qk_int8_sv_f8_attn_kernel<CTA_Q, CTA_K, NUM_THREADS, head_dim, static_cast<QuantGranularity>(qk_quant_gran), static_cast<QuantGranularity>(qk_quant_gran), static_cast<PVThresholdMode>(pv_threashold_mode), DTypeOut, mask_mode, fuse_v_scale, return_pv_count>;
  size_t sMemSize = CTA_Q * head_dim * sizeof(int8_t) + CTA_K * head_dim * sizeof(int8_t) + CTA_K * head_dim * sizeof(int8_t);
  cudaFuncSetAttribute(
      kernel,
      cudaFuncAttributeMaxDynamicSharedMemorySize, sMemSize);
  
  dim3 grid(div_ceil(qo_len, CTA_Q), num_qo_heads, batch_size);
  kernel<<<grid, NUM_THREADS, sMemSize>>>(
    tma_map_Q,
    tma_map_K,
    tma_map_V,
    Q_scale,
    K_scale,
    V_scale,
    O,
    PV_Count,
    Lut,
    Valid_Block_Num,
    PV_Threshold,
    stride_bz_o, stride_h_o, stride_seq_o,
    qo_len, kv_len, num_qo_heads / num_kv_heads, sm_scale);
}