/* Copyright © 2018 Apple Inc. All rights reserved.
 *
 * Use of this source code is governed by a BSD-3-clause license that can
 * be found in the LICENSE.txt file or at https://opensource.org/licenses/BSD-3-Clause
 */

#include <unity/toolkits/neural_net/mps_image_augmentation.hpp>

#include <logger/assertions.hpp>
#include <platform/parallel/lambda_omp.hpp>
#include <random/random.hpp>

#import <Accelerate/Accelerate.h>

namespace turi {
namespace neural_net {

namespace {

/**
 * Returns a transform that converts a normalized rect with origin at top-left
 * to a rect in Core Image coordinates (with origin at bottom left).
 */
CGAffineTransform transform_to_core_image(CGSize size) {
  return CGAffineTransformConcat(
      CGAffineTransformMakeScale(size.width, -size.height),
      CGAffineTransformMakeTranslation(0, size.height));
}

/**
 * Returns the inverse of the transform returned by transform_to_core_image.
 */
CGAffineTransform transform_from_core_image(CGSize size) {
  return CGAffineTransformInvert(transform_to_core_image(size));
}

CIImage *convert_to_core_image(const image_type& source) {

  ASSERT_TRUE(!source.is_decoded());

  // Wrap the image with shared_ptr for memory management by NSData below.
  __block auto shared_image = std::make_shared<image_type>(source);

  // Wrap the (shared) image data with NSData.
  auto deallocator = ^(void *bytes, NSUInteger length) {
    shared_image.reset();
  };
  void* data = const_cast<unsigned char*>(shared_image->get_image_data());
  NSData *imageData =
      [[NSData alloc] initWithBytesNoCopy: data
                                   length: shared_image->m_image_data_size
                              deallocator: deallocator];

  // Let CIImage inspect the file format and decode it.
  CIImage* result = [CIImage imageWithData:imageData];

  if (!result) {
    log_and_throw("Image decoding error");
  }
  return result;
}

API_AVAILABLE(macos(10.13))
NSArray<TCMPSImageAnnotation *> *convert_to_core_image(
    const std::vector<image_annotation>& source, CGSize size) {

  NSMutableArray<TCMPSImageAnnotation *> *result =
      [NSMutableArray arrayWithCapacity:source.size()];
  for (const image_annotation& src_annotation : source) {

    TCMPSImageAnnotation *resultAnnotation = [TCMPSImageAnnotation new];

    resultAnnotation.identifier = src_annotation.identifier;
    resultAnnotation.confidence = src_annotation.confidence;

    // Convert to CoreImage coordinates.
    CGRect sourceBoundingBox = CGRectMake(
        src_annotation.bounding_box.x, src_annotation.bounding_box.y,
        src_annotation.bounding_box.width, src_annotation.bounding_box.height);
    resultAnnotation.boundingBox = CGRectApplyAffineTransform(
        sourceBoundingBox, transform_to_core_image(size));

    [result addObject:resultAnnotation];
  }

  return result;
}

API_AVAILABLE(macos(10.13))
TCMPSLabeledImage *convert_to_core_image(const labeled_image& source) {

  TCMPSLabeledImage *result = [TCMPSLabeledImage new];

  CIImage *sourceImage = convert_to_core_image(source.image);

  // For intermediate values, use an image with infinite extent, for smoother
  // sampling behavior at the intended image boundaries.
  result.image = [sourceImage imageByClampingToExtent];

  // The (integral) extent of the original CIImage is the original image size.
  result.bounds = sourceImage.extent;

  result.annotations = convert_to_core_image(source.annotations,
                                             result.bounds.size);

  return result;
}

void convert_from_core_image(CIImage *source, CIContext *context,
                             size_t output_width, size_t output_height,
                             float* out, size_t out_size) {

  ASSERT_EQ(output_width * output_height * 3, out_size);

  // Render the image into a bitmap. CoreImage supports RGBA but not RGB...
  size_t rgba_data_size = output_height * output_width * 4;
  std::unique_ptr<float[]> rgba_data(new float[rgba_data_size]);
  [context render: source
         toBitmap: rgba_data.get()
         rowBytes: output_width * 4 * sizeof(float)
           bounds: CGRectMake(0.f, 0.f, output_width, output_height)
           format: kCIFormatRGBAf
       colorSpace: nil];

  // Copy the RGB portion to the output buffer using Accelerate.
  auto wrap_float_data = [=](float* data, size_t num_channels) {
    vImage_Buffer buffer;
    buffer.data = data;
    buffer.width = output_width;
    buffer.height = output_height;
    buffer.rowBytes = output_width * num_channels * sizeof(float);
    return buffer;
  };
  vImage_Buffer rgba_buffer = wrap_float_data(rgba_data.get(), 4);
  vImage_Buffer out_buffer = wrap_float_data(out, 3);
  vImage_Error err = vImageConvert_RGBAFFFFtoRGBFFF(
      &rgba_buffer, &out_buffer, kvImageDoNotTile);
  if (err != kvImageNoError) {
    log_and_throw("Unexpected error converting RGBA bitmap to RGB.");
  }
}

API_AVAILABLE(macos(10.13))
std::vector<image_annotation> convert_from_core_image(
    NSArray<TCMPSImageAnnotation *> *source, CGSize size) {

  std::vector<image_annotation> result;
  result.reserve(source.count);
  for (TCMPSImageAnnotation *sourceAnnotation : source) {

    image_annotation dest_annotation;
    dest_annotation.identifier = static_cast<int>(sourceAnnotation.identifier);
    dest_annotation.confidence = sourceAnnotation.confidence;

    // The input annotation is normalized with origin at top-left.
    // Convert from CoreImage coordinates.
    CGRect boundingBox = CGRectApplyAffineTransform(
        sourceAnnotation.boundingBox, transform_from_core_image(size));
    dest_annotation.bounding_box.x = boundingBox.origin.x;
    dest_annotation.bounding_box.y = boundingBox.origin.y;
    dest_annotation.bounding_box.width = boundingBox.size.width;
    dest_annotation.bounding_box.height = boundingBox.size.height;

    result.push_back(dest_annotation);
  }
  return result;
}

API_AVAILABLE(macos(10.13))
void convert_from_core_image(TCMPSLabeledImage *source, CIContext *context,
                             size_t output_width, size_t output_height,
                             float* out, size_t out_size,
                             std::vector<image_annotation>* annotations_out) {

  // Render the CIImage into the provided float buffer.
  convert_from_core_image(source.image, context, output_width, output_height,
                          out, out_size);

  // Convert the annotations.
  *annotations_out = convert_from_core_image(
      source.annotations, CGSizeMake(output_width, output_height));
}

}  // namespace

mps_image_augmenter::mps_image_augmenter(
    const options& opts, std::function<float(float,float)> rng_fn):
  opts_(opts) {

  NSDictionary *contextOptions = @{

    // Assume for now that we can keep the GPU busy with the actual NN training.
    kCIContextUseSoftwareRenderer : @true,

    // Disable any color management.
    kCIContextWorkingColorSpace   : [NSNull null],
  };
  context_ = [CIContext contextWithOptions:contextOptions];

  NSMutableArray<id <TCMPSImageAugmenting>> *augmentations =
      [[NSMutableArray alloc] init];
  TCMPSUniformRandomNumberGenerator rngBlock;
  if (rng_fn) {
    rngBlock = ^(CGFloat lower, CGFloat upper) {
      return static_cast<CGFloat>(rng_fn(lower, upper));
    };
  } else {
    rngBlock = ^(CGFloat lower, CGFloat upper) {
      if (lower < upper) {
        return turi::random::fast_uniform(lower, upper);
      } else {
        return lower;
      }
    };
  }

  if (opts.crop_prob > 0.f) {

    // Enable random crops.
    TCMPSRandomCropAugmenter *cropAug =
        [[TCMPSRandomCropAugmenter alloc] initWithRNG:rngBlock];
    cropAug.skipProbability = 1.f - opts.crop_prob;
    cropAug.minAspectRatio = opts.crop_opts.min_aspect_ratio;
    cropAug.maxAspectRatio = opts.crop_opts.max_aspect_ratio;
    cropAug.minAreaFraction = opts.crop_opts.min_area_fraction;
    cropAug.maxAreaFraction = opts.crop_opts.max_area_fraction;
    cropAug.minObjectCovered = opts.crop_opts.min_object_covered;
    cropAug.maxAttempts = opts.crop_opts.max_attempts;
    cropAug.minEjectCoverage = opts.crop_opts.min_eject_coverage;

    [augmentations addObject:cropAug];
  }

  if (opts.pad_prob > 0.f) {

    // Enable random padding.
    TCMPSRandomPadAugmenter *padAug =
        [[TCMPSRandomPadAugmenter alloc] initWithRNG:rngBlock];
    padAug.skipProbability = 1.f - opts.pad_prob;
    padAug.minAspectRatio = opts.pad_opts.min_aspect_ratio;
    padAug.maxAspectRatio = opts.pad_opts.max_aspect_ratio;
    padAug.minAreaFraction = opts.pad_opts.min_area_fraction;
    padAug.maxAreaFraction = opts.pad_opts.max_area_fraction;
    padAug.maxAttempts = opts.pad_opts.max_attempts;

    [augmentations addObject:padAug];
  }

  if (opts.horizontal_flip_prob > 0.f) {

    // Enable mirror images.
    TCMPSHorizontalFlipAugmenter *horizontalFlipAug =
        [[TCMPSHorizontalFlipAugmenter alloc] initWithRNG:rngBlock];
    horizontalFlipAug.skipProbability = 1.f - opts.horizontal_flip_prob;
    [augmentations addObject:horizontalFlipAug];
  }

  if (opts.brightness_max_jitter > 0.f ||
      opts.contrast_max_jitter > 0.f ||
      opts.saturation_max_jitter > 0.f) {

    // Enable color controls.
    TCMPSColorControlAugmenter *colorAug =
        [[TCMPSColorControlAugmenter alloc] initWithRNG:rngBlock];
    colorAug.maxBrightnessDelta = opts.brightness_max_jitter;
    colorAug.maxContrastProportion = opts.contrast_max_jitter;
    colorAug.maxSaturationProportion = opts.saturation_max_jitter;
    [augmentations addObject:colorAug];
  }

  if (opts.hue_max_jitter > 0.f) {

    // Enable color rotation.
    TCMPSHueAdjustAugmenter *hueAug =
        [[TCMPSHueAdjustAugmenter alloc] initWithRNG:rngBlock];
    hueAug.maxHueAdjust = opts.hue_max_jitter;
    [augmentations addObject:hueAug];
  }

  // Always resize to the fixed image size expected by the neural network.
  CGSize outputSize;
  outputSize.width = static_cast<CGFloat>(opts_.output_width);
  outputSize.height = static_cast<CGFloat>(opts_.output_height);
  [augmentations addObject:[[TCMPSResizeAugmenter alloc] initWithSize:outputSize]];

  augmentations_ = augmentations;
}

mps_image_augmenter::result mps_image_augmenter::prepare_images(
    std::vector<labeled_image> source_batch) {

  const size_t n = source_batch.size();
  const size_t h = opts_.output_height;
  const size_t w = opts_.output_width;
  constexpr size_t c = 3;

  result res;
  res.annotations_batch.resize(n);

  // Allocate a float vector large enough to contain the entire image batch.
  const size_t result_array_stride = h * w * c;
  std::vector<float> result_array(n * result_array_stride);

  // Define the work to perform for each image.
  auto apply_augmentations_for_image = [&](size_t i) {
    
    const labeled_image& source = source_batch[i];

    // Convert from turi::image_type to CIImage.
    TCMPSLabeledImage *labeledImage = convert_to_core_image(source);

    // Apply all augmentations.
    for (id <TCMPSImageAugmenting> aug : augmentations_) {
      labeledImage = [aug imageAugmentedFromImage:labeledImage];
    }

    // Convert from CIImage to float array.
    float* float_out = result_array.data() + i * result_array_stride;
    convert_from_core_image(labeledImage, context_, w, h, float_out,
                            result_array_stride, &res.annotations_batch[i]);
  };

  // Distribute work across threads, each writing into different regions of
  // result_array and res.annotations_batch.
  parallel_for(0, n, apply_augmentations_for_image);

  // Wrap and return the results.
  res.image_batch = shared_float_array::wrap(std::move(result_array),
                                             { n, h, w, c});
  return res;
}

}  // neural_net
}  // turi
