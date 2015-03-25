#import "MSAIPersistence.h"
#import "MSAIEnvelope.h"
#import "MSAICrashData.h"
#import "AppInsightsPrivate.h"
#import "MSAIHelper.h"

NSString *const kHighPrioString = @"highPrio";
NSString *const kRegularPrioString = @"regularPrio";
NSString *const kCrashTemplateString = @"crashTemplate";
NSString *const kFileBaseString = @"app-insights-bundle-";

NSString *const kMSAIPersistenceSuccessNotification = @"MSAIPersistenceSuccessNotification";
char const *kPersistenceQueueString = "com.microsoft.appInsights.persistenceQueue";
NSUInteger const defaultFileCount = 50;

@implementation MSAIPersistence{
  BOOL _maxFileCountReached;
}


#pragma mark - Public

+ (instancetype)sharedInstance{
  static MSAIPersistence *sharedInstance;
  static dispatch_once_t onceToken;
  
  dispatch_once(&onceToken, ^{
    sharedInstance = [MSAIPersistence new];
    [sharedInstance createApplicationSupportDirectoryIfNeeded];
  });
  return sharedInstance;
}

- (instancetype)init{
  self = [super init];
  if ( self ) {
    _persistenceQueue = dispatch_queue_create(kPersistenceQueueString, DISPATCH_QUEUE_SERIAL);
    _requestedBundlePaths = [NSMutableArray new];
    _maxFileCount = defaultFileCount;
    
    // Evantually there are old files on disk, the flag will be updated before the first event gets created
    _maxFileCountReached = YES;
  }
  return self;
}

//TODO remove the completion block and implement notification-handling in MSAICrashManager
- (void)persistBundle:(NSArray *)bundle ofType:(MSAIPersistenceType)type withCompletionBlock:(void (^)(BOOL success))completionBlock {
  [self persistBundle:bundle ofType:type enableNotifications:YES withCompletionBlock:completionBlock];
}

/**
 * Creates a serial background queue that saves the Bundle using NSKeyedArchiver and NSData's writeToFile:atomically
 * In case if type MSAIPersistenceTypeCrashTemplate, we don't send out a kMSAIPersistenceSuccessNotification.
 *
 */
- (void)persistBundle:(NSArray *)bundle ofType:(MSAIPersistenceType)type enableNotifications:(BOOL)sendNotifications withCompletionBlock:(void (^)(BOOL success))completionBlock {
  
  if(bundle && bundle.count > 0) {
    NSString *fileURL = [self newFileURLForPriority:type];
    
    NSData *data = [self dataForBundle:bundle withPersistenceTye:type];
    
    if(data) {
      __weak typeof(self) weakSelf = self;
      dispatch_async(self.persistenceQueue, ^{
        typeof(self) strongSelf = weakSelf;
        BOOL success = [data writeToFile:fileURL atomically:YES];
        if(success) {
          MSAILog(@"Wrote %@", fileURL);
          if(sendNotifications && type != MSAIPersistenceTypeCrashTemplate) {
            [strongSelf sendBundleSavedNotification];
          }
        }
        
        if(completionBlock) {
          completionBlock(success);
        }
      });
    }
    else if(completionBlock != nil) {
      MSAILog(@"Unable to write %@", fileURL);
      completionBlock(NO);
    }
    else {
      MSAILog(@"Unable to write %@", fileURL);
      //TODO send out a fail notification?
    }
  }
}

- (BOOL)isFreeSpaceAvailable{
  return !_maxFileCountReached;
}

- (NSString *)requestNextPath {
  __block NSString *path = nil;
  __weak typeof(self) weakSelf = self;
  dispatch_sync(self.persistenceQueue, ^() {
    typeof(self) strongSelf = weakSelf;
    
    path = [strongSelf nextURLWithPriority:MSAIPersistenceTypeHighPriority];
    if(!path) {
      path = [strongSelf nextURLWithPriority:MSAIPersistenceTypeRegular];
    }
    
    if(path){
      [self.requestedBundlePaths addObject:path];
    }
  });
  return path;
}

/**
 * Method used to persist the "fake" crash reports. Crash templates are handled but are similar to the other bundle
 * types under the hood.
 */
- (void)persistCrashTemplateBundle:(NSArray *)bundle {
  [self persistBundle:bundle ofType:MSAIPersistenceTypeCrashTemplate withCompletionBlock:nil];
}

/*
 * @Returns a bundle that includes a crash template.
 */
- (NSArray *)crashTemplateBundle {
  NSString *path = [self nextURLWithPriority:MSAIPersistenceTypeCrashTemplate];
  if(path && [path isKindOfClass:[NSString class]] && path.length > 0) {
    NSArray *bundle = [self bundleAtPath:path];
    if(bundle) {
      return bundle;
    }
  }
  return nil;
}

/**
 * Deserializes a bundle from disk using NSKeyedUnarchiver and deletes it from disk
 * @return a bundle of data or nil
 */
- (NSArray *)bundleAtPath:(NSString *)path {
  NSArray *bundle = nil;
  if(path && [path rangeOfString:kFileBaseString].location != NSNotFound) {
    bundle = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
  }
  return bundle;
}

- (NSData *)dataAtPath:(NSString *)path {
  NSData *data = nil;
  
  if(path && [path rangeOfString:kFileBaseString].location != NSNotFound) {
    data = [NSData dataWithContentsOfFile:path];
  }
  return data;
}

/**
 * Deletes a file at the given path.
 */
- (void)deleteFileAtPath:(NSString *)path {
  __weak typeof(self) weakSelf = self;
  dispatch_sync(self.persistenceQueue, ^() {
    typeof(self) strongSelf = weakSelf;
    if([path rangeOfString:kFileBaseString].location != NSNotFound) {
      NSError *error = nil;
      [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
      if(error) {
        MSAILog(@"Error deleting file at path %@", path);
      }
      else {
        MSAILog(@"Successfully deleted file at path %@", path);
        [strongSelf.requestedBundlePaths removeObject:path];
      }
    }else {
      MSAILog(@"Empty path, so nothing can be deleted");
    }
  });
  
}

- (void)giveBackRequestedPath:(NSString *) path {
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.persistenceQueue, ^() {
    typeof(self) strongSelf = weakSelf;
    
    [strongSelf.requestedBundlePaths removeObject:path];
  });
}

#pragma mark - Private

/**
 * Creates the path for a file depending on the MSAIPersistenceType.
 * The filename includes the timestamp.
 * For each MSAIPersistenceType, we create a folder within the app's Application Support directory directory
 */
- (NSString *)newFileURLForPriority:(MSAIPersistenceType)type {
  
  NSString *applicationSupportDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject];
  NSString *uuid = msai_UUID();
  NSString *fileName = [NSString stringWithFormat:@"%@%@", kFileBaseString, uuid];
  NSString *filePath;
  
  switch(type) {
    case MSAIPersistenceTypeHighPriority: {
      [self createFolderAtPathIfNeeded:[applicationSupportDir stringByAppendingPathComponent:kHighPrioString]];
      filePath = [[applicationSupportDir stringByAppendingPathComponent:kHighPrioString] stringByAppendingPathComponent:fileName];
      break;
    };
    case MSAIPersistenceTypeCrashTemplate: {
      [self createFolderAtPathIfNeeded:[applicationSupportDir stringByAppendingPathComponent:kCrashTemplateString]];
      filePath = [[applicationSupportDir stringByAppendingPathComponent:kCrashTemplateString] stringByAppendingPathComponent:kCrashTemplateString];
      break;
    };
    default: {
      [self createFolderAtPathIfNeeded:[applicationSupportDir stringByAppendingPathComponent:kRegularPrioString]];
      filePath = [[applicationSupportDir stringByAppendingPathComponent:kRegularPrioString] stringByAppendingPathComponent:fileName];
      break;
    };
  }
  
  return filePath;
}

/**
 * create a folder within at the given path
 */
- (void)createFolderAtPathIfNeeded:(NSString *)path {
  if(path && ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:&error];
    if(error) {
      MSAILog(@"Error while creating folder at: %@, with error: %@", path, error);
    }
  }
}

/**
 * Create ApplicationSupport directory if necessary and exclude it from iCloud Backup
 */
- (void)createApplicationSupportDirectoryIfNeeded {
  NSString *appplicationSupportDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject];
  if(![[NSFileManager defaultManager] fileExistsAtPath:appplicationSupportDir isDirectory:NULL]) {
    NSError *error = nil;
    if(![[NSFileManager defaultManager] createDirectoryAtPath:appplicationSupportDir withIntermediateDirectories:YES attributes:nil error:&error]) {
      MSAILog(@"%@", error.localizedDescription);
    }
    else {
      NSURL *url = [NSURL fileURLWithPath:appplicationSupportDir];
      if(![url setResourceValue:@YES
                         forKey:NSURLIsExcludedFromBackupKey
                          error:&error]) {
        MSAILog(@"Error excluding %@ from backup %@", url.lastPathComponent, error.localizedDescription);
      }
      else {
        MSAILog(@"Exclude %@ from backup", url);
      }
    }
  }
}

/**
 * @returns the URL to the next file depending on the specified type. If there's no file, return nil.
 */
- (NSString *)nextURLWithPriority:(MSAIPersistenceType)type {
  
  NSString *directoryPath = [self folderPathForPersistenceType:type];
  NSError *error;
  NSArray *fileNames = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directoryPath]
                                                     includingPropertiesForKeys:[NSArray arrayWithObject:NSURLNameKey]
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                          error:&error];
  
  // each track method asks, if space is still available. Getting the file count for each event would be too expensive,
  // so let's get it here
  if(type == MSAIPersistenceTypeRegular){
    _maxFileCountReached = fileNames.count >= _maxFileCount;
  }
  
  if(fileNames && fileNames.count > 0) {
    for(NSURL *filename in fileNames){
      NSString *absolutePath = filename.path;
      if(![self.requestedBundlePaths containsObject:absolutePath]){
        return absolutePath;
      }
    }
  }
  return nil;
}

- (NSString *)folderPathForPersistenceType:(MSAIPersistenceType)type {
  static NSString *documentFolder;
  static dispatch_once_t documentFolderToken;
  dispatch_once(&documentFolderToken, ^{
    documentFolder = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject];
  });
  
  NSString *subfolderPath;
  
  switch(type) {
    case MSAIPersistenceTypeHighPriority: {
      subfolderPath = kHighPrioString;
      break;
    };
    case MSAIPersistenceTypeCrashTemplate: {
      subfolderPath = kCrashTemplateString;
      break;
    };
    case MSAIPersistenceTypeRegular: {
      subfolderPath = kRegularPrioString;
      break;
    }
  }
  NSString *path = [documentFolder stringByAppendingPathComponent:subfolderPath];
  
  return path;
}

- (NSData *)dataForBundle:(NSArray *)bundle withPersistenceTye:(MSAIPersistenceType)persistenceType{
  NSData *data = nil;
  
  if(persistenceType == MSAIPersistenceTypeCrashTemplate){
    data = [NSKeyedArchiver archivedDataWithRootObject:bundle];
  }else{
    NSError *error = nil;
    data = [NSJSONSerialization dataWithJSONObject:bundle options:NSJSONWritingPrettyPrinted error:&error];
    if(error){
      MSAILog(@"Unable to convert JSON to NSData: %@", [error localizedDescription]);
    }
  }
  return data;
}

/**
 * Send a kMSAIPersistenceSuccessNotification to the main thread to notify observers that we have successfully saved a file
 * This is typocally used to trigger sending.
 */
- (void)sendBundleSavedNotification{
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:kMSAIPersistenceSuccessNotification
                                                        object:nil
                                                      userInfo:nil];
  });
}

- (BOOL)crashReportLockFilePresent {
  NSString *analyzerInProgressFile = [msai_settingsDir() stringByAppendingPathComponent:kMSAICrashAnalyzer];

  return [[NSFileManager defaultManager] fileExistsAtPath:analyzerInProgressFile];
}

- (void)createCrashReporterLockFile {
  NSString *analyzerInProgressFile = [msai_settingsDir() stringByAppendingPathComponent:kMSAICrashAnalyzer];

  [[NSFileManager defaultManager] createFileAtPath:analyzerInProgressFile contents:nil attributes:nil];
}

- (void)deleteCrashReporterLockFile {
  NSString *analyzerInProgressFile = [msai_settingsDir() stringByAppendingPathComponent:kMSAICrashAnalyzer];
  NSError *error = NULL;
  if([[NSFileManager defaultManager] fileExistsAtPath:analyzerInProgressFile]) {
    [[NSFileManager defaultManager] removeItemAtPath:analyzerInProgressFile error:&error];
  }
}

@end
