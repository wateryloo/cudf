/*
 * Copyright 2018 BlazingDB, Inc.

 *     Copyright 2018 Cristhian Alberto Gonzales Castillo <cristhian@blazingdb.com>
 *     Copyright 2018 Alexander Ocsa <alexander@blazingdb.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <thrust/device_ptr.h>
#include <thrust/find.h>
#include <thrust/execution_policy.h>
#include <cub/cub.cuh>
#include <cudf/copying.hpp>
#include <cudf/replace.hpp>
#include <cudf/detail/replace.hpp>
#include <rmm/rmm.h>
#include <cudf/types.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <utilities/cudf_utils.h>
#include <utilities/cuda_utils.hpp>
#include <utilities/column_utils.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/column/column.hpp>
#include <cudf/utilities/bit.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/copying.hpp>
#include <cudf/utilities/traits.hpp>

namespace{ //anonymous

static constexpr int BLOCK_SIZE = 256;

// returns the block_sum using the given shared array of warp sums.
template <typename T>
__device__ T sum_warps(T* warp_smem)
{
  T block_sum = 0;

   if (threadIdx.x < cudf::experimental::detail::warp_size) {
    T my_warp_sum = warp_smem[threadIdx.x];
    __shared__ typename cub::WarpReduce<T>::TempStorage temp_storage;
    block_sum = cub::WarpReduce<T>(temp_storage).Sum(my_warp_sum);
  }
  return block_sum;
}

// return the new_value for output column at index `idx`
template<class T, bool replacement_has_nulls>
__device__ auto get_new_value(cudf::size_type         idx,
                           const T* __restrict__ input_data,
                           const T* __restrict__ values_to_replace_begin,
                           const T* __restrict__ values_to_replace_end,
                           const T* __restrict__       d_replacement_values,
                           cudf::bitmask_type const * __restrict__ replacement_valid)
   {
     auto found_ptr = thrust::find(thrust::seq, values_to_replace_begin,
                                      values_to_replace_end, input_data[idx]);
     T new_value{0};
     bool output_is_valid{true};

     if (found_ptr != values_to_replace_end) {
       auto d = thrust::distance(values_to_replace_begin, found_ptr);
       new_value = d_replacement_values[d];
       if (replacement_has_nulls) {
         output_is_valid = cudf::bit_is_set(replacement_valid, d);
       }
     } else {
       new_value = input_data[idx];
     }
     return thrust::make_pair(new_value, output_is_valid);
   }

  /* --------------------------------------------------------------------------*/
  /**
   * @brief Kernel that replaces elements from `output_data` given the following
   *        rule: replace all `values_to_replace[i]` in [values_to_replace_begin`,
   *        `values_to_replace_end`) present in `output_data` with `d_replacement_values[i]`.
   *
   * @tparam input_has_nulls `true` if output column has valid mask, `false` otherwise
   * @tparam replacement_has_nulls `true` if replacement_values column has valid mask, `false` otherwise
   * The input_has_nulls and replacement_has_nulls template parameters allows us to specialize
   * this kernel for the different scenario for performance without writing different kernel.
   *
   * @param[in] input_data Device array with the data to be modified
   * @param[in] input_valid Valid mask associated with input_data
   * @param[out] output_data Device array to store the data from input_data
   * @param[out] output_valid Valid mask associated with output_data
   * @param[out] output_valid_count #valid in output column
   * @param[in] nrows # rows in `output_data`
   * @param[in] values_to_replace_begin Device pointer to the beginning of the sequence
   * of old values to be replaced
   * @param[in] values_to_replace_end  Device pointer to the end of the sequence
   * of old values to be replaced
   * @param[in] d_replacement_values Device array with the new values
   * @param[in] replacement_valid Valid mask associated with d_replacement_values
   *
   * @returns
   */
  /* ----------------------------------------------------------------------------*/
  template <class T,
            bool input_has_nulls, bool replacement_has_nulls>
  __global__
  void replace_kernel(cudf::column_device_view input,
                      cudf::mutable_column_device_view output,
                      cudf::size_type * __restrict__    output_valid_count,
                      cudf::size_type                   nrows,
                      cudf::column_device_view values_to_replace,
                      cudf::column_device_view replacement)
  {
  const T* __restrict__ input_data = input.data<T>();
  cudf::bitmask_type const * __restrict__ input_valid = input.null_mask();
  T * __restrict__ output_data = output.data<T>();
  cudf::bitmask_type * __restrict__ output_valid = output.null_mask();
  const T* __restrict__ values_to_replace_begin = values_to_replace.data<T>();
  const T* __restrict__ values_to_replace_end = values_to_replace.data<T>() + values_to_replace.size();
  const T* __restrict__ d_replacement_values = replacement.data<T>();
  cudf::bitmask_type const * __restrict__ replacement_valid = replacement.null_mask();

  cudf::size_type i = blockIdx.x * blockDim.x + threadIdx.x;

  uint32_t active_mask = 0xffffffff;
  active_mask = __ballot_sync(active_mask, i < nrows);
  auto const lane_id{threadIdx.x % cudf::experimental::detail::warp_size};
  uint32_t valid_sum{0};

  while (i < nrows) {
    bool output_is_valid = true;
    uint32_t bitmask = 0xffffffff;

    if (input_has_nulls) {
      bool const input_is_valid{cudf::bit_is_set(input_valid, i)};
      output_is_valid = input_is_valid;

      bitmask = __ballot_sync(active_mask, input_is_valid);

      if (input_is_valid) {
        thrust::tie(output_data[i], output_is_valid)  =
            get_new_value<T, replacement_has_nulls>(i, input_data,
                                      values_to_replace_begin,
                                      values_to_replace_end,
                                      d_replacement_values,
                                      replacement_valid);
      }

    } else {
       thrust::tie(output_data[i], output_is_valid) =
            get_new_value<T, replacement_has_nulls>(i, input_data,
                                      values_to_replace_begin,
                                      values_to_replace_end,
                                      d_replacement_values,
                                      replacement_valid);
    }

    /* output valid counts calculations*/
    if (input_has_nulls or replacement_has_nulls){

      bitmask &= __ballot_sync(active_mask, output_is_valid);

      if(0 == lane_id){
        output_valid[cudf::word_index(i)] = bitmask;
        valid_sum += __popc(bitmask);
      }
    }

    i += blockDim.x * gridDim.x;
    active_mask = __ballot_sync(active_mask, i < nrows);
  }
  if(input_has_nulls or replacement_has_nulls){
    __syncthreads(); // waiting for the valid counts of each warp to be ready

    // Compute total valid count for this block and add it to global count
    uint32_t block_valid_count = cudf::experimental::detail::single_lane_block_sum_reduce<BLOCK_SIZE, 0>(valid_sum);
    // one thread computes and adds to output_valid_count
    if (threadIdx.x == 0) {
      atomicAdd(output_valid_count, block_valid_count);
    }
  }
}

  /* --------------------------------------------------------------------------*/
  /**
   * @brief Functor called by the `type_dispatcher` in order to invoke and instantiate
   *        `replace_kernel` with the appropriate data types.
   */
  /* ----------------------------------------------------------------------------*/
  struct replace_kernel_forwarder {
    template <typename col_type,
              std::enable_if_t<cudf::is_fixed_width<col_type>()>* = nullptr>
    std::unique_ptr<cudf::column> operator()(cudf::column_view const& input_col,
                                             cudf::column_view const& values_to_replace,
                                             cudf::column_view const& replacement_values,
                                             rmm::mr::device_memory_resource* mr,
                                             cudaStream_t stream = 0)
    {
      rmm::device_scalar<cudf::size_type> valid_counter(0);
      cudf::size_type *valid_count = valid_counter.data();

      auto replace = replace_kernel<col_type, true, true>;

      if (input_col.has_nulls()){
        if (replacement_values.has_nulls()){
          replace = replace_kernel<col_type, true, true>;
        }else{
          replace = replace_kernel<col_type, true, false>;
        }
      }else{
        if (replacement_values.has_nulls()){
          replace = replace_kernel<col_type, false, true>;
        }else{
          replace = replace_kernel<col_type, false, false>;
        }
      }

      std::unique_ptr<cudf::column> output;
      if (input_col.has_nulls() || replacement_values.has_nulls()) {
        output = cudf::experimental::allocate_like(input_col,
                                                   cudf::experimental::mask_allocation_policy::ALWAYS,
                                                   mr);
      }
      else {
        output = cudf::experimental::allocate_like(input_col,
                                                   cudf::experimental::mask_allocation_policy::NEVER,
                                                   mr);
      }

      cudf::mutable_column_view outputView = output->mutable_view();

      cudf::experimental::detail::grid_1d grid{outputView.size(), BLOCK_SIZE, 1};

      auto device_in = cudf::column_device_view::create(input_col);
      auto device_out = cudf::mutable_column_device_view::create(outputView);
      auto device_values_to_replace = cudf::column_device_view::create(values_to_replace);
      auto device_replacement_values = cudf::column_device_view::create(replacement_values);

      replace<<<grid.num_blocks, BLOCK_SIZE, 0, stream>>>(
                                             *device_in,
                                             *device_out,
                                             valid_count,
                                             outputView.size(),
                                             *device_values_to_replace,
                                             *device_replacement_values);

      cudaStreamSynchronize(stream);

      if(outputView.nullable()){
        output->set_null_count(output->size() - valid_counter.value());
      }
      return output;
    }
      template <typename col_type,
                std::enable_if_t<not cudf::is_fixed_width<col_type>()>* = nullptr>
      std::unique_ptr<cudf::column> operator()(cudf::column_view const& input_col,
                                               cudf::column_view const& values_to_replace,
                                               cudf::column_view const& replacement_values,
                                               rmm::mr::device_memory_resource* mr,
                                               cudaStream_t stream = 0){
     CUDF_FAIL("Non fixed-width types are not supported.");
    };
  };
 } //end anonymous namespace

namespace cudf{
namespace detail {
  std::unique_ptr<cudf::column> find_and_replace_all(cudf::column_view const& input_col,
                                                     cudf::column_view const& values_to_replace,
                                                     cudf::column_view const& replacement_values,
                                                     rmm::mr::device_memory_resource* mr,
                                                     cudaStream_t stream) {
    if (0 == input_col.size() )
    {
      return std::make_unique<cudf::column>(input_col);
    }

    CUDF_EXPECTS(values_to_replace.size() == replacement_values.size(),
                     "values_to_replace and replacement_values size mismatch.");

    if (0 == values_to_replace.size())
    {
      return std::make_unique<cudf::column>(input_col);
    }


    CUDF_EXPECTS(input_col.type() == values_to_replace.type() &&
                 input_col.type() == replacement_values.type(),
                 "Columns type mismatch.");
    CUDF_EXPECTS(values_to_replace.nullable() == false,
                 "Nulls are in values_to_replace column.");

    return cudf::experimental::type_dispatcher(input_col.type(),
                                               replace_kernel_forwarder { },
                                               input_col,
                                               values_to_replace,
                                               replacement_values,
                                               mr,
                                               stream);
  }

} //end details
namespace experimental {
/* --------------------------------------------------------------------------*/
/**
 * @brief Replace elements from `input_col` according to the mapping `values_to_replace` to
 *        `replacement_values`, that is, replace all `values_to_replace[i]` present in `input_col`
 *        with `replacement_values[i]`.
 *
 * @param[in] col gdf_column with the data to be modified
 * @param[in] values_to_replace gdf_column with the old values to be replaced
 * @param[in] replacement_values gdf_column with the new values
 *
 * @returns output gdf_column with the modified data
 */
/* ----------------------------------------------------------------------------*/
  std::unique_ptr<cudf::column> find_and_replace_all(cudf::column_view const& input_col,
                                                     cudf::column_view const& values_to_replace,
                                                     cudf::column_view const& replacement_values,
                                                     rmm::mr::device_memory_resource* mr){
    return cudf::detail::find_and_replace_all(input_col, values_to_replace, replacement_values, mr, 0);
  }
} //end experimental
} //end cudf

namespace{ //anonymous

template <typename Type, typename iter>
__global__
void replace_nulls(cudf::size_type size,
                   const Type* __restrict__ in_data,
                   const cudf::bitmask_type* __restrict__ in_valid,
                   iter replacement,
                   Type* __restrict__ out_data)
{
  int tid = threadIdx.x;
  int blkid = blockIdx.x;
  int blksz = blockDim.x;
  int gridsz = gridDim.x;

  int start = tid + blkid * blksz;
  int step = blksz * gridsz;

  for (int i=start; i<size; i+=step) {
    out_data[i] = cudf::bit_is_set(in_valid, i)? in_data[i] : replacement[i];
  }
}

/* --------------------------------------------------------------------------*/
/**
 * @brief Functor called by the `type_dispatcher` in order to invoke and instantiate
 *        `replace_nulls` with the appropriate data types.
 */
/* ----------------------------------------------------------------------------*/
struct replace_nulls_column_kernel_forwarder {
  template <typename col_type,
            std::enable_if_t<cudf::is_fixed_width<col_type>()>* = nullptr>
  std::unique_ptr<cudf::column> operator()(cudf::column_view const& input,
                                           cudf::column_view const& replacement,
                                           rmm::mr::device_memory_resource* mr,
                                           cudaStream_t stream = 0)
  {
    cudf::size_type nrows = input.size();
    cudf::experimental::detail::grid_1d grid{nrows, BLOCK_SIZE};

    std::unique_ptr<cudf::column> output = cudf::experimental::allocate_like(input,
                                                                             cudf::experimental::mask_allocation_policy::NEVER,
                                                                             mr);
    auto output_view = output->mutable_view();

    replace_nulls<<<grid.num_blocks, BLOCK_SIZE, 0, stream>>>(nrows,
                                                              input.data<col_type>(),
                                                              input.null_mask(),
                                                              replacement.data<col_type>(),
                                                              output_view.data<col_type>());
    cudaStreamSynchronize(stream);
    return output;
  }
  template <typename col_type,
            std::enable_if_t<not cudf::is_fixed_width<col_type>()>* = nullptr>
  std::unique_ptr<cudf::column> operator()(cudf::column_view const& input,
                                           cudf::column_view const& replacement,
                                           rmm::mr::device_memory_resource* mr,
                                           cudaStream_t stream = 0) {
    CUDF_FAIL("Non-fixed-width types are not supported for replace.");
  }
};


/* --------------------------------------------------------------------------*/
/**
 * @brief Functor called by the `type_dispatcher` in order to invoke and instantiate
 *        `replace_nulls` with the appropriate data types.
 */
/* ----------------------------------------------------------------------------*/
struct replace_nulls_scalar_kernel_forwarder {
  template <typename col_type,
            std::enable_if_t<cudf::is_fixed_width<col_type>()>* = nullptr>
  std::unique_ptr<cudf::column> operator()(cudf::column_view const& input,
                                           cudf::scalar const& replacement,
                                           rmm::mr::device_memory_resource* mr,
                                           cudaStream_t stream = 0)
  {
    cudf::size_type nrows = input.size();
    cudf::experimental::detail::grid_1d grid{nrows, BLOCK_SIZE};

    std::unique_ptr<cudf::column> output = cudf::experimental::allocate_like(input,
                                                                             cudf::experimental::mask_allocation_policy::NEVER,
                                                                             mr);
    auto output_view = output->mutable_view();

    using ScalarType = cudf::experimental::scalar_type_t<col_type>;
    auto s1 = static_cast<ScalarType const&>(replacement);

    replace_nulls<<<grid.num_blocks, BLOCK_SIZE, 0, stream>>>(nrows,
                                                              input.data<col_type>(),
                                                              input.null_mask(),
                                                              thrust::make_constant_iterator(s1.value()),
                                                              output_view.data<col_type>());
    cudaStreamSynchronize(stream);
    return output;
  }

  template <typename col_type,
            std::enable_if_t<not cudf::is_fixed_width<col_type>()>* = nullptr>
  std::unique_ptr<cudf::column> operator()(cudf::column_view const& input,
                                           cudf::scalar const& replacement,
                                           rmm::mr::device_memory_resource* mr,
                                           cudaStream_t stream = 0) {
    CUDF_FAIL("Non-fixed-width types are not supported for replace.");
  }
};

} //end anonymous namespace


namespace cudf {
namespace detail {

std::unique_ptr<cudf::column> replace_nulls(cudf::column_view const& input,
                                            cudf::column_view const& replacement,
                                            rmm::mr::device_memory_resource* mr,
                                            cudaStream_t stream)
{
  if (input.size() == 0) {
    return cudf::experimental::empty_like(input);
  }

  if (!input.has_nulls()) {
    return std::make_unique<cudf::column>(input);
  }

  CUDF_EXPECTS(input.type() == replacement.type(), "Data type mismatch");
  CUDF_EXPECTS(replacement.size() == input.size(), "Column size mismatch");
  CUDF_EXPECTS(!replacement.has_nulls(), "Invalid replacement data");

  return cudf::experimental::type_dispatcher(input.type(),
                                             replace_nulls_column_kernel_forwarder{},
                                             input,
                                             replacement,
                                             mr,
                                             stream);
}


std::unique_ptr<cudf::column> replace_nulls(cudf::column_view const& input,
                                            cudf::scalar const& replacement,
                                            rmm::mr::device_memory_resource* mr,
                                            cudaStream_t stream)
{
  if (input.size() == 0) {
    return cudf::experimental::empty_like(input);
  }

  if (!input.has_nulls()) {
    return std::make_unique<cudf::column>(input, stream, mr);
  }

  CUDF_EXPECTS(input.type() == replacement.type(), "Data type mismatch");
  CUDF_EXPECTS(true == replacement.is_valid(stream), "Invalid replacement data");

  return cudf::experimental::type_dispatcher(input.type(),
                                             replace_nulls_scalar_kernel_forwarder{},
                                             input,
                                             replacement,
                                             mr,
                                             stream);
}

}  // namespace detail

namespace experimental {

std::unique_ptr<cudf::column> replace_nulls(cudf::column_view const& input,
                                            cudf::column_view const& replacement,
                                            rmm::mr::device_memory_resource* mr)
{
  return cudf::detail::replace_nulls(input, replacement, mr, 0);
}


std::unique_ptr<cudf::column> replace_nulls(cudf::column_view const& input,
                                            cudf::scalar const& replacement,
                                            rmm::mr::device_memory_resource* mr)
{
  return cudf::detail::replace_nulls(input, replacement, mr, 0);
}
} //end experimental
}  // namespace cudf

namespace {  // anonymous

template <typename T>
struct normalize_nans_and_zeros_lambda {
   cudf::column_device_view in;
   T __device__ operator()(cudf::size_type i)
   {
      auto e = in.element<T>(i);
      if (isnan(e)) {
         return std::numeric_limits<T>::quiet_NaN();
      }
      if (T{0.0} == e) {
         return T{0.0};
      }
      return e;
   }
};

/* --------------------------------------------------------------------------*/
/**
* @brief Functor called by the `type_dispatcher` in order to invoke and instantiate
*        `normalize_nans_and_zeros` with the appropriate data types.
*/
/* ----------------------------------------------------------------------------*/
struct normalize_nans_and_zeros_kernel_forwarder {
   // floats and doubles. what we really care about.
   template <typename T, std::enable_if_t<std::is_floating_point<T>::value>* = nullptr>
   void operator()(  cudf::column_device_view in,
                     cudf::mutable_column_device_view out,
                     cudaStream_t stream)
   {
      thrust::transform(rmm::exec_policy(stream)->on(stream),
                        thrust::make_counting_iterator(0),
                        thrust::make_counting_iterator(in.size()),
                        out.head<T>(), normalize_nans_and_zeros_lambda<T>{in});
   }

   // if we get in here for anything but a float or double, that's a problem.
   template <typename T, std::enable_if_t<not std::is_floating_point<T>::value>* = nullptr>
   void operator()(  cudf::column_device_view in,
                     cudf::mutable_column_device_view out,
                     cudaStream_t stream)
   {
      CUDF_FAIL("Unexpected non floating-point type.");
   }
};

} // end anonymous namespace

namespace cudf {
namespace detail {

void normalize_nans_and_zeros(mutable_column_view in_out,
                              cudaStream_t stream = 0)
{
   if(in_out.size() == 0){
      return;
   }
   CUDF_EXPECTS(in_out.type() == data_type(FLOAT32) || in_out.type() == data_type(FLOAT64), "Expects float or double input");

   // wrapping the in_out data in a column_view so we can call the same lower level code.
   // that we use for the non in-place version.
   column_view input = in_out;

   // to device. unique_ptr which gets automatically cleaned up when we leave
   auto device_in = column_device_view::create(input);

   // from device. unique_ptr which gets automatically cleaned up when we leave.
   auto device_out = mutable_column_device_view::create(in_out);

    // invoke the actual kernel.
   cudf::experimental::type_dispatcher(input.type(),
                                       normalize_nans_and_zeros_kernel_forwarder{},
                                       *device_in,
                                       *device_out,
                                       stream);
}

}  // namespace detail

/*
 * @brief Makes all NaNs and zeroes positive.
 *
 * Converts floating point values from @p input using the following rules:
 *        Convert  -NaN  -> NaN
 *        Convert  -0.0  -> 0.0
 *
 * @throws cudf::logic_error if column does not have floating point data type.
 * @param[in] column_view representing input data
 * @param[in] device_memory_resource allocator for allocating output data
 *
 * @returns new column with the modified data
 */
std::unique_ptr<column> normalize_nans_and_zeros( column_view const& input,
                                                  rmm::mr::device_memory_resource *mr)
{
   // output. copies the input
   std::unique_ptr<column> out = std::make_unique<column>(input, (cudaStream_t)0, mr);
   // from device. unique_ptr which gets automatically cleaned up when we leave.
   auto out_view = out->mutable_view();

   detail::normalize_nans_and_zeros(out_view, 0);

   return out;
}

/*
 * @brief Makes all Nans and zeroes positive.
 *
 * Converts floating point values from @p in_out using the following rules:
 *        Convert  -NaN  -> NaN
 *        Convert  -0.0  -> 0.0
 *
 * @throws cudf::logic_error if column does not have floating point data type.
 * @param[in, out] mutable_column_view representing input data. data is processed in-place
 */
void normalize_nans_and_zeros(mutable_column_view& in_out)
{
   detail::normalize_nans_and_zeros(in_out, 0);
}

}
