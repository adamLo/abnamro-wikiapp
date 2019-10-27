
#ifndef WMFLoadingFlowControllerProtocols_h
#define WMFLoadingFlowControllerProtocols_h


#import <Foundation/Foundation.h>
@protocol LoadingFlowControllerArticle;
@class LoadingFlowController;

@protocol WMFLoadingFlowControllerChildProtocol <NSObject, WMFThemeable>

@required
@property (nonatomic, strong, readonly) UIViewController<WMFThemeable> * _Nullable customNavAnimationHandler;
@property (nonatomic, weak) LoadingFlowController * _Nullable loadingFlowController;
- (BOOL)handleCustomSuccessWithArticle:(id<LoadingFlowControllerArticle> _Nonnull)article url:(NSURL * _Nonnull)url;
- (void)showDefaultLinkFailureWithError:(NSError * _Nonnull)error;

@end

@protocol WMFLoadingFlowControllerFetchDelegate <NSObject>

- (NSURLSessionTask * _Nullable)linkPushFetchWithUrl:(NSURL * _Nonnull)url successHandler:(void (^ _Nonnull)(id<LoadingFlowControllerArticle> _Nonnull, NSURL * _Nonnull))successHandler errorHandler:(void (^ _Nonnull)(NSError * _Nonnull))errorHandler;

@end


#endif /* WMFLoadingFlowControllerProtocols_h */
