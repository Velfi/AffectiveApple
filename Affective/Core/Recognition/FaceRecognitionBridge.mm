#import "FaceRecognitionBridge.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#import <opencv2/imgcodecs.hpp>
#import <opencv2/objdetect.hpp>
#pragma clang diagnostic pop

static NSString *const AFFaceRecognitionErrorDomain = @"AFFaceRecognitionErrorDomain";

@implementation AFFaceEmbeddingResult

- (instancetype)initWithFaceCount:(NSInteger)faceCount
                   detectionScore:(double)detectionScore
                         embedding:(NSArray<NSNumber *> *)embedding {
  self = [super init];
  if (self) {
    _faceCount = faceCount;
    _detectionScore = detectionScore;
    _embedding = [embedding copy];
  }
  return self;
}

@end

@implementation AFFaceRecognitionBridge

- (AFFaceEmbeddingResult *)embeddingForImageAtPath:(NSString *)imagePath
                                     detectorModel:(NSString *)detectorModelPath
                                   recognizerModel:(NSString *)recognizerModelPath
                                             error:(NSError **)error {
  @try {
    NSData *imageData = [NSData dataWithContentsOfFile:imagePath];
    if (!imageData || imageData.length == 0) {
      [self writeError:error code:1 message:[NSString stringWithFormat:@"could not read image: %@", imagePath]];
      return nil;
    }
    std::vector<uchar> bytes((const uchar *)imageData.bytes, (const uchar *)imageData.bytes + imageData.length);
    cv::Mat image = cv::imdecode(bytes, cv::IMREAD_COLOR);
    if (image.empty()) {
      [self writeError:error code:1 message:[NSString stringWithFormat:@"could not decode image: %@", imagePath]];
      return nil;
    }

    cv::Ptr<cv::FaceDetectorYN> detector = cv::FaceDetectorYN::create(
      detectorModelPath.UTF8String,
      "",
      cv::Size(image.cols, image.rows),
      0.7f,
      0.3f,
      5000
    );
    cv::Mat faces;
    detector->detect(image, faces);
    NSInteger faceCount = faces.empty() ? 0 : faces.rows;
    if (faceCount != 1) {
      return [[AFFaceEmbeddingResult alloc] initWithFaceCount:faceCount
                                               detectionScore:0
                                                     embedding:@[]];
    }

    float score = faces.at<float>(0, 14);
    if (!std::isfinite(score) || score < 0.0f || score > 1.0f) {
      [self writeError:error code:2 message:[NSString stringWithFormat:@"invalid face detection score for image: %@", imagePath]];
      return nil;
    }

    cv::Ptr<cv::FaceRecognizerSF> recognizer = cv::FaceRecognizerSF::create(
      recognizerModelPath.UTF8String,
      ""
    );
    cv::Mat aligned;
    recognizer->alignCrop(image, faces.row(0), aligned);

    cv::Mat feature;
    recognizer->feature(aligned, feature);
    feature = feature.reshape(1, 1);
    feature.convertTo(feature, CV_32F);
    double norm = cv::norm(feature, cv::NORM_L2);
    if (!std::isfinite(norm) || norm == 0.0) {
      [self writeError:error code:3 message:[NSString stringWithFormat:@"empty face embedding for image: %@", imagePath]];
      return nil;
    }

    NSMutableArray<NSNumber *> *embedding = [NSMutableArray arrayWithCapacity:(NSUInteger)feature.cols];
    for (int i = 0; i < feature.cols; ++i) {
      float value = feature.at<float>(0, i) / (float)norm;
      [embedding addObject:@(value)];
    }
    return [[AFFaceEmbeddingResult alloc] initWithFaceCount:1
                                             detectionScore:score
                                                   embedding:embedding];
  } @catch (NSException *exception) {
    [self writeError:error code:4 message:exception.reason ?: @"OpenCV face recognition failed"];
    return nil;
  }
}

- (BOOL)writeError:(NSError **)error code:(NSInteger)code message:(NSString *)message {
  if (!error) { return NO; }
  *error = [NSError errorWithDomain:AFFaceRecognitionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
  return YES;
}

@end
