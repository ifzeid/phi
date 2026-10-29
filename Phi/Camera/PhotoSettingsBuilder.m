#import "PhotoSettingsBuilder.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

static NSString *PHIExceptionLine(NSException *exception) {
    NSString *name = exception.name.length > 0 ? exception.name : @"NSException";
    NSString *reason = exception.reason ?: @"";
    if (reason.length == 0) {
        return name;
    }
    return [NSString stringWithFormat:@"%@: %@", name, reason];
}

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
) {
    @try {
        AVCapturePhotoSettings *settings = nil;
        if (useRaw) {
            settings = [AVCapturePhotoSettings photoSettingsWithRawPixelFormatType:rawPixel
                                                                   processedFormat:processed];
        } else {
            settings = [AVCapturePhotoSettings photoSettingsWithFormat:processed];
        }
        if (limitDimensions) {
            settings.maxPhotoDimensions = (CMVideoDimensions){ width, height };
        }
        settings.photoQualityPrioritization = (AVCapturePhotoQualityPrioritization)qualityPrioritization;
        if (setFlash) {
            settings.flashMode = (AVCaptureDeviceFlashMode)flashMode;
        }
        NSArray<NSNumber *> *previews = settings.availablePreviewPhotoPixelFormatTypes;
        NSNumber *preview = previews.firstObject;
        if (preview != nil) {
            settings.previewPhotoFormat = @{
                (NSString *)kCVPixelBufferPixelFormatTypeKey: preview
            };
        }
        return settings;
    } @catch (NSException *exception) {
        if (failure != NULL) {
            *failure = PHIExceptionLine(exception);
        }
        return nil;
    }
}

BOOL PHICapturePhoto(
    AVCapturePhotoOutput *output,
    AVCapturePhotoSettings *settings,
    id<AVCapturePhotoCaptureDelegate> delegate,
    NSString * _Nullable * _Nullable failure
) {
    @try {
        [output capturePhotoWithSettings:settings delegate:delegate];
        return YES;
    } @catch (NSException *exception) {
        if (failure != NULL) {
            *failure = PHIExceptionLine(exception);
        }
        return NO;
    }
}
