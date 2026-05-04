#import "SyncObjCBridge.h"

static NSString * const KTBackgroundUploadErrorDomain = @"com.katafract.vault.bg-upload";

@implementation KTBackgroundUpload

+ (nullable NSURLSessionUploadTask *)
    safeUploadTaskOn:(NSURLSession *)session
              withRequest:(NSURLRequest *)request
                 fromFile:(NSURL *)fileURL
                    error:(NSError * _Nullable * _Nullable)error {
    @try {
        return [session uploadTaskWithRequest:request fromFile:fileURL];
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"NSException raised by uploadTaskWithRequest:fromFile:",
                @"NSExceptionName": exception.name ?: @"unknown",
                @"NSExceptionReason": exception.reason ?: @"",
            };
            *error = [NSError errorWithDomain:KTBackgroundUploadErrorDomain
                                         code:1
                                     userInfo:userInfo];
        }
        return nil;
    }
}

@end
