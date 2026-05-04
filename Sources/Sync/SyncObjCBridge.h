#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Obj-C shim that lets Swift catch the NSException that
/// -[__NSURLBackgroundSession _uploadTaskWithTaskForClass:] raises when its
/// internal validation rejects a (request, fromFile) pair. Swift cannot
/// catch Obj-C exceptions; without this shim such an exception propagates
/// straight to __cxa_throw → abort() and the app crashes (Vaultyx 1.0.5
/// builds 521 + 522 on iOS 26.5).
///
/// Returns the upload task on success. Returns nil and populates `error`
/// (with the NSException's name + reason) on failure. The caller treats the
/// nil return as a "back off and retry" signal — the row stays claimable.
@interface KTBackgroundUpload : NSObject

+ (nullable NSURLSessionUploadTask *)
    safeUploadTaskOn:(NSURLSession *)session
              withRequest:(NSURLRequest *)request
                 fromFile:(NSURL *)fileURL
                    error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
