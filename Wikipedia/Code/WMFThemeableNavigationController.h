#import <UIKit/UIKit.h>
@import WMF;
@class WMFThemeableNavigationController;


typedef NS_ENUM(NSUInteger, WMFThemeableNavigationControllerStyle) {
    WMFThemeableNavigationControllerStyleDefault = 0,
    WMFThemeableNavigationControllerStyleEditor = 1,
    WMFThemeableNavigationControllerStyleSheet = 2
};

NS_ASSUME_NONNULL_BEGIN

@protocol WMFThemeableNavigationControllerDelegate
- (void)themeableNavigationControllerTraitCollectionDidChange:(WMFThemeableNavigationController *)navigationController;
@end

@interface WMFThemeableNavigationController : UINavigationController <WMFThemeable>

@property (weak, nonatomic, nullable) NSObject<WMFThemeableNavigationControllerDelegate> *themeableNavigationControllerDelegate;

- (instancetype)initWithRootViewController:(UIViewController<WMFThemeable> *)rootViewController theme:(WMFTheme *)theme style:(WMFThemeableNavigationControllerStyle)style;

- (instancetype)initWithRootViewController:(UIViewController<WMFThemeable> *)rootViewController theme:(WMFTheme *)theme;

- (void)showSplashView;
- (void)showSplashViewIfNotShowing;
- (void)hideSplashViewAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
