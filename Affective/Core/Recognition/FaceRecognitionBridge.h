#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AFFaceEmbeddingResult : NSObject

@property(nonatomic, readonly) NSInteger faceCount;
@property(nonatomic, readonly) double detectionScore;
@property(nonatomic, readonly) NSArray<NSNumber *> *embedding;

- (instancetype)initWithFaceCount:(NSInteger)faceCount
                   detectionScore:(double)detectionScore
                         embedding:(NSArray<NSNumber *> *)embedding NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface AFFaceRecognitionBridge : NSObject

- (AFFaceEmbeddingResult *)embeddingForImageAtPath:(NSString *)imagePath
                                     detectorModel:(NSString *)detectorModelPath
                                   recognizerModel:(NSString *)recognizerModelPath
                                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
