#import "MSAIContext.h"
#import "MSAIContextPrivate.h"
#import "MSAIHelper.h"

@implementation MSAIContext

@synthesize isAppStoreEnvironment = _isAppStoreEnvironment;
@synthesize osVersion = _osVersion;
@synthesize osName = _osName;
@synthesize instrumentationKey = _instrumentationKey;
@synthesize deviceModel = _deviceModel;
@synthesize deviceType = _deviceType;
@synthesize appVersion = _appVersion;

- (instancetype)initWithInstrumentationKey:(NSString *)instrumentationKey isAppStoreEnvironment:(BOOL)isAppStoreEnvironment{
  
  if ((self = [self init])) {
    _instrumentationKey = instrumentationKey;
    _isAppStoreEnvironment = isAppStoreEnvironment;
    _deviceModel = msai_devicePlatform();
    _deviceType = msai_deviceType();
    _osName = msai_osName();
    _osVersion = msai_osVersion();
    _appVersion = msai_appVersion();
  }
  return self;
}
@end
