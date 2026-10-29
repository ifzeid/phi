#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Builds an `AVCapturePhotoSettings` and applies dimensions, quality, flash, and preview inside
/// `@try`. Returns nil and writes `failure` when a setter raises. Swift cannot catch `NSException`.
AVCapturePhotoSettings * _Nullable PHIMakePhotoSettings(
    BOOL useRaw,
    OSType rawPixel,
    NSDictionary<NSString *, id> *processed,
    BOOL limitDimensions,
    int32_t width,
    int32_t height,
    NSInteger qualityPrioritization,
    BOOL setFlash,
    NSInteger flashMode,
    NSString * _Nullable * _Nullable failure
);

/// `capturePhotoWithSettings:delegate:` raises on a settings mismatch. Returns NO instead of aborting.
BOOL PHICapturePhoto(
    AVCapturePhotoOutput *output,
    AVCapturePhotoSettings *settings,
    id<AVCapturePhotoCaptureDelegate> delegate,
    NSString * _Nullable * _Nullable failure
);

NS_ASSUME_NONNULL_END
