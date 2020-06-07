/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBIDBCommandExecutor.h"

#import <FBSimulatorControl/FBSimulatorControl.h>

#import "FBIDBStorageManager.h"
#import "FBIDBError.h"
#import "FBIDBLogger.h"
#import "FBIDBPortsConfiguration.h"
#import "FBStorageUtils.h"
#import "FBTemporaryDirectory.h"

@interface FBIDBCommandExecutor ()

@property (nonatomic, strong, readonly) id<FBiOSTarget> target;
@property (nonatomic, strong, readonly) FBIDBLogger *logger;
@property (nonatomic, strong, readonly) FBIDBPortsConfiguration *ports;

@end

@implementation FBIDBCommandExecutor

#pragma mark Initializers

+ (instancetype)commandExecutorForTarget:(id<FBiOSTarget>)target storageManager:(FBIDBStorageManager *)storageManager temporaryDirectory:(FBTemporaryDirectory *)temporaryDirectory ports:(FBIDBPortsConfiguration *)ports logger:(FBIDBLogger *)logger
{
  return [[self alloc] initWithTarget:target storageManager:storageManager temporaryDirectory:temporaryDirectory ports:ports logger:[logger withName:@"grpc_handler"]];
}

- (instancetype)initWithTarget:(id<FBiOSTarget>)target storageManager:(FBIDBStorageManager *)storageManager temporaryDirectory:(FBTemporaryDirectory *)temporaryDirectory ports:(FBIDBPortsConfiguration *)ports logger:(FBIDBLogger *)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _target = target;
  _storageManager = storageManager;
  _temporaryDirectory = temporaryDirectory;
  _ports = ports;
  _logger = logger;

  return self;
}

#pragma mark Installation

- (FBFuture<NSDictionary<FBInstalledApplication *, id> *> *)list_apps
{
  return [[FBFuture
    futureWithFutures:@[
      [self.target installedApplications],
      [self.target runningApplications],
    ]]
    onQueue:self.target.workQueue map:^(NSArray<id> *results) {
      NSArray<FBInstalledApplication *> *installed = results[0];
      NSDictionary<NSString *, NSNumber *> *running = results[1];
      NSMutableDictionary<FBInstalledApplication *, id> *listing = NSMutableDictionary.dictionary;
      for (FBInstalledApplication *application in installed) {
        listing[application] = running[application.bundle.identifier] ?: NSNull.null;
      }
      return listing;
    }];
}

- (FBFuture<FBInstalledArtifact *> *)install_app_file_path:(NSString *)filePath
{
  return [self installExtractedApplication:[FBBundleDescriptor onQueue:self.target.asyncQueue findOrExtractApplicationAtPath:filePath logger:self.logger]];
}

- (FBFuture<FBInstalledArtifact *> *)install_app_stream:(FBProcessInput *)input
{
  return [self installExtractedApplication:[FBBundleDescriptor onQueue:self.target.asyncQueue extractApplicationFromInput:input logger:self.logger]];
}

- (FBFuture<FBInstalledArtifact *> *)install_xctest_app_file_path:(NSString *)filePath
{
  return [self installXctestFilePath:[FBFutureContext futureContextWithFuture:[FBFuture futureWithResult:[NSURL fileURLWithPath:filePath]]]];
}

- (FBFuture<FBInstalledArtifact *> *)install_xctest_app_stream:(FBProcessInput *)stream
{
  return [self installXctest:[self.temporaryDirectory withArchiveExtractedFromStream:stream]];
}

- (FBFuture<FBInstalledArtifact *> *)install_dylib_file_path:(NSString *)filePath
{
  return [self installFile:[FBFutureContext futureContextWithFuture:[FBFuture futureWithResult:[NSURL fileURLWithPath:filePath]]] intoStorage:self.storageManager.dylib];
}

- (FBFuture<FBInstalledArtifact *> *)install_dylib_stream:(FBProcessInput *)input name:(NSString *)name
{
  return [self installFile:[self.temporaryDirectory withGzipExtractedFromStream:input name:name] intoStorage:self.storageManager.dylib];
}

- (FBFuture<FBInstalledArtifact *> *)install_framework_file_path:(NSString *)filePath
{
  return [self installBundle:[FBFutureContext futureContextWithFuture:[FBFuture futureWithResult:[NSURL fileURLWithPath:filePath]]] intoStorage:self.storageManager.framework];
}

- (FBFuture<FBInstalledArtifact *> *)install_framework_stream:(FBProcessInput *)input
{
  return [self installBundle:[self.temporaryDirectory withArchiveExtractedFromStream:input] intoStorage:self.storageManager.framework];
}

- (FBFuture<FBInstalledArtifact *> *)install_dsym_file_path:(NSString *)filePath
{
  return [self installFile:[FBFutureContext futureContextWithFuture:[FBFuture futureWithResult:[NSURL fileURLWithPath:filePath]]] intoStorage:self.storageManager.dsym];
}

- (FBFuture<FBInstalledArtifact *> *)install_dsym_stream:(FBProcessInput *)input
{
  return [self installFile:[self.temporaryDirectory withArchiveExtractedFromStream:input] intoStorage:self.storageManager.dsym];
}

#pragma mark Public Methods

- (FBFuture<NSData *> *)take_screenshot:(FBScreenshotFormat)format
{
  return [[self
    screenshotCommands]
    onQueue:self.target.workQueue fmap:^(id<FBScreenshotCommands> commands) {
        return [commands takeScreenshot:format];
    }];
}

- (FBFuture<NSNull *> *)create_directory:(NSString *)directoryPath in_container_of_application:(NSString *)bundleID
{
  return [[self
    applicationDataContainerCommands:bundleID]
    onQueue:self.target.workQueue fmap:^(id<FBiOSTargetFileCommands> targetApplicationData) {
      return [targetApplicationData createDirectory:directoryPath];
    }];
}

- (FBFuture<NSArray<NSDictionary<NSString *, id> *> *> *)accessibility_info_at_point:(nullable NSValue *)value
{
  return [[[self
    connectToSimulatorConnection]
    onQueue:self.target.workQueue fmap:^(FBSimulatorConnection *connection) {
      return [connection connectToBridge];
    }]
    onQueue:self.target.workQueue fmap:^ FBFuture * (FBSimulatorBridge *bridge) {
      if (value) {
        return [bridge accessibilityElementAtPoint:value.pointValue];
      } else {
        return [bridge accessibilityElements];
      }
  }];
}

- (FBFuture<NSArray<NSDictionary<NSString *, id> *> *> *)accessibility_info
{
  return [self accessibility_info_at_point:nil];
}

- (FBFuture<NSNull *> *)add_media:(NSArray<NSURL *> *)filePaths
{
  return [self.mediaCommands
    onQueue:self.target.asyncQueue fmap:^FBFuture *(id<FBSimulatorMediaCommands> commands) {
      return [commands addMedia:filePaths];
    }];
}

- (FBFuture<NSNull *> *)move_paths:(NSArray<NSString *> *)originPaths to_path:(NSString *)destinationPath in_container_of_application:(NSString *)bundleID
{
  return [[self
    applicationDataContainerCommands:bundleID]
    onQueue:self.target.workQueue fmap:^(id<FBiOSTargetFileCommands> commands) {
      return [commands movePaths:originPaths toDestinationPath:destinationPath];
    }];
}

- (FBFuture<NSNull *> *)push_file_from_tar:(NSData *)tarData to_path:(NSString *)destinationPath in_container_of_application:(NSString *)bundleID
{
  return [[self.temporaryDirectory
    withArchiveExtracted:tarData]
    onQueue:self.target.workQueue pop:^FBFuture *(NSURL *extractionDirectory) {
      NSError *error;
      NSArray<NSURL *> *paths = [NSFileManager.defaultManager contentsOfDirectoryAtURL:extractionDirectory includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:&error];
      if (!paths) {
        return [FBFuture futureWithError:error];
      }
      return [self push_files:paths to_path:destinationPath in_container_of_application:bundleID];
   }];
}

- (FBFuture<NSNull *> *)push_files:(NSArray<NSURL *> *)paths to_path:(NSString *)destinationPath in_container_of_application:(NSString *)bundleID
{
  return [FBFuture
    onQueue:self.target.asyncQueue resolve:^FBFuture<NSNull *> *{
      return [[self
        applicationDataContainerCommands:bundleID]
        onQueue:self.target.workQueue fmap:^FBFuture *(id<FBiOSTargetFileCommands> targetApplicationsData) {
          return [targetApplicationsData copyPathsOnHost:paths toDestination:destinationPath];
        }];
  }];
}

- (FBFuture<NSString *> *)pull_file_path:(NSString *)path destination_path:(NSString *)destinationPath in_container_of_application:(NSString *)bundleID
{
  return [[self
    applicationDataContainerCommands:bundleID]
    onQueue:self.target.workQueue fmap:^FBFuture *(id<FBiOSTargetFileCommands> commands) {
      return [commands copyItemInContainer:path toDestinationOnHost:destinationPath];
    }];
}

- (FBFuture<NSData *> *)pull_file:(NSString *)path in_container_of_application:(NSString *)bundleID
{
  __block NSString *tempPath;

  return [[[[self.temporaryDirectory
    withTemporaryDirectory]
    onQueue:self.target.workQueue pend:^(NSURL *url) {
      tempPath = [url.path stringByAppendingPathComponent:path.lastPathComponent];
      return [self applicationDataContainerCommands:bundleID];
    }]
    onQueue:self.target.workQueue pend:^(id<FBiOSTargetFileCommands> commands) {
      return [commands copyItemInContainer:path toDestinationOnHost:tempPath];
    }]
    onQueue:self.target.workQueue pop:^(id _) {
      return [FBArchiveOperations createGzippedTarDataForPath:tempPath queue:self.target.workQueue logger:self.target.logger];
    }];
}

- (FBFuture<NSNull *> *)hid:(FBSimulatorHIDEvent *)event
{
  return [self.connectToHID
    onQueue:self.target.workQueue fmap:^FBFuture *(FBSimulatorHID *hid) {
      return [event performOnHID:hid];
    }];
}

- (FBFuture<NSNull *> *)remove_paths:(NSArray<NSString *> *)paths in_container_of_application:(NSString *)bundleID
{
  return [[self
    applicationDataContainerCommands:bundleID]
    onQueue:self.target.workQueue fmap:^FBFuture *(id<FBiOSTargetFileCommands> commands) {
      return [commands removePaths:paths];
    }];
}

- (FBFuture<NSArray<NSString *> *> *)list_path:(NSString *)path in_container_of_application:(NSString *)bundleID
{
  return [[self
    applicationDataContainerCommands:bundleID]
    onQueue:self.target.workQueue fmap:^FBFuture *(id<FBiOSTargetFileCommands> commands) {
      return [commands contentsOfDirectory:path];
    }];
}

- (FBFuture<NSNull *> *)set_location:(double)latitude longitude:(double)longitude
{
  return [self.connectToSimulatorBridge
    onQueue:self.target.workQueue fmap:^FBFuture<NSNull *> *(FBSimulatorBridge *bridge) {
      return [bridge setLocationWithLatitude:latitude longitude:longitude];
    }];
}

- (FBFuture<NSNull *> *)clear_keychain
{
  return [self.keychainCommands
    onQueue:self.target.workQueue fmap:^FBFuture *(id<FBSimulatorKeychainCommands> commands) {
      return [commands clearKeychain];
    }];
}

- (FBFuture<NSNull *> *)approve:(NSSet<FBSettingsApprovalService> *)services for_application:(NSString *)bundleID
{
  return [self.settingsCommands
    onQueue:self.target.workQueue fmap:^FBFuture *(id<FBSimulatorSettingsCommands> commands) {
      return [commands grantAccess:[NSSet setWithObject:bundleID] toServices:services];
    }];
}

- (FBFuture<NSNull *> *)approve_deeplink:(NSString *)scheme for_application:(NSString *)bundleID
{
  return [self.settingsCommands
  onQueue:self.target.workQueue fmap:^FBFuture *(id<FBSimulatorSettingsCommands> commands) {
    return [commands grantAccess:[NSSet setWithObject:bundleID] toDeeplink:scheme];
  }];
}

- (FBFuture<NSNull *> *)open_url:(NSString *)url
{
  return [self.lifecycleCommands
    onQueue:self.target.workQueue fmap:^FBFuture *(id<FBSimulatorLifecycleCommands> commands) {
      return [commands openURL:[NSURL URLWithString:url]];
    }];
}

- (FBFuture<NSNull *> *)focus
{
  return [self.lifecycleCommands
    onQueue:self.target.workQueue fmap:^FBFuture *(id<FBSimulatorLifecycleCommands> commands) {
      return [commands focus];
    }];
}

- (FBFuture<NSNull *> *)update_contacts:(NSData *)dbTarData
{
  return [[self.temporaryDirectory
    withArchiveExtracted:dbTarData]
    onQueue:self.target.workQueue pop:^(NSURL *tempDirectory) {
      return [self.settingsCommands onQueue:self.target.workQueue fmap:^FBFuture *(id<FBSimulatorSettingsCommands> commands) {
        return [commands updateContacts:tempDirectory.path];
      }];
    }];
}

- (FBFuture<NSSet<id<FBXCTestDescriptor>> *> *)list_test_bundles
{
  return [FBFuture onQueue:self.target.workQueue resolve:^{
    NSError *error;
    NSSet<id<FBXCTestDescriptor>> *testDescriptors = [self.storageManager.xctest listTestDescriptorsWithError:&error];
    if (testDescriptors == nil) {
      return [FBFuture futureWithError:error];
    }
    return [FBFuture futureWithResult:testDescriptors];
  }];
}

static const NSTimeInterval ListTestBundleTimeout = 60.0;

- (FBFuture<NSArray<NSString *> *> *)list_tests_in_bundle:(NSString *)bundleID with_app:(NSString *)appPath
{
  if([appPath isEqualToString:@""]) appPath = nil;
  return [FBFuture onQueue:self.target.workQueue resolve:^ FBFuture<NSArray<NSString *> *> * {
    NSError *error = nil;
    id<FBXCTestDescriptor> testDescriptor = [self.storageManager.xctest testDescriptorWithID:bundleID error:&error];
    if (!testDescriptor) {
      return [FBFuture futureWithError:error];
    }
    return [self.target listTestsForBundleAtPath:testDescriptor.url.path timeout:ListTestBundleTimeout withAppAtPath:appPath];
  }];
}

- (FBFuture<NSNull *> *)uninstall_application:(NSString *)bundleID
{
  return [self.target uninstallApplicationWithBundleID:bundleID];
}

- (FBFuture<NSNull *> *)kill_application:(NSString *)bundleID
{
  return [self.target killApplicationWithBundleID:bundleID];
}

- (FBFuture<id<FBLaunchedProcess>> *)launch_app:(FBApplicationLaunchConfiguration *)configuration
{
  return [self.target launchApplication:[configuration withEnvironment:[self.storageManager interpolateEnvironmentReplacements:configuration.environment]]];
}

- (FBFuture<FBIDBTestOperation *> *)xctest_run:(FBXCTestRunRequest *)request reporter:(id<FBXCTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger
{
  return [request startWithBundleStorageManager:self.storageManager.xctest target:self.target reporter:reporter logger:logger temporaryDirectory:self.temporaryDirectory];
}

- (FBFuture<id<FBDebugServer>> *)debugserver_start:(NSString *)bundleID
{
  return [[self
    debugserver_prepare:bundleID]
    onQueue:self.target.workQueue fmap:^(FBBundleDescriptor *application) {
      return [self.target launchDebugServerForHostApplication:application port:self.ports.debugserverPort];
    }];
}

- (FBFuture<id<FBDebugServer>> *)debugserver_status
{
  return [FBFuture
    onQueue:self.target.workQueue resolve:^{
      id<FBDebugServer> debugServer = self.debugServer;
      if (!debugServer) {
        return [[FBControlCoreError
          describe:@"No debug server running"]
          failFuture];
      }
      return [FBFuture futureWithResult:debugServer];
    }];
}

- (FBFuture<id<FBDebugServer>> *)debugserver_stop
{
  return [[[self
    debugserver_status]
    onQueue:self.target.workQueue fmap:^(id<FBDebugServer> debugServer) {
      return [[self.debugServer.completed cancel] mapReplace:debugServer];
    }]
    onQueue:self.target.workQueue doOnResolved:^(id _) {
      self.debugServer = nil;
    }];
}

- (FBFuture<NSArray<FBCrashLogInfo *> *> *)crash_list:(NSPredicate *)predicate
{
  return [[self.target
    crashes:predicate useCache:NO]
    onQueue:self.target.asyncQueue map:^(NSArray<FBCrashLogInfo *> *crashes) {
      return crashes;
    }];
}

- (FBFuture<FBCrashLog *> *)crash_show:(NSPredicate *)predicate
{
  return [[self.target
    crashes:predicate useCache:YES]
    onQueue:self.target.asyncQueue fmap:^(NSArray<FBCrashLogInfo *> *crashes) {
      if (crashes.count > 1) {
         return [[FBIDBError
          describeFormat:@"More than one crash log matching %@", predicate]
          failFuture];
      }
      if (crashes.count == 0) {
        return [[FBIDBError
          describeFormat:@"No crashes matching %@", predicate]
          failFuture];
      }
      NSError *error = nil;
      FBCrashLog *log = [crashes.firstObject obtainCrashLogWithError:&error];
      if (!log) {
        return [FBFuture futureWithError:error];
      }
      return [FBFuture futureWithResult:log];
    }];
}

- (FBFuture<NSArray<FBCrashLogInfo *> *> *)crash_delete:(NSPredicate *)predicate
{
  return [[self.target
    pruneCrashes:predicate]
    onQueue:self.target.asyncQueue map:^(NSArray<FBCrashLogInfo *> *crashes) {
      return crashes;
    }];
}

- (FBFuture<FBBundleDescriptor *> *)debugserver_prepare:(NSString *)bundleID
{
  return [FBFuture
    onQueue:self.target.workQueue resolve:^ FBFuture<FBBundleDescriptor *> * {
      if (self.debugServer) {
        return [[FBControlCoreError
          describeFormat:@"Debug server is already running"]
          failFuture];
      }
      NSDictionary<NSString *, FBBundleDescriptor *> *persisted = self.storageManager.application.persistedBundles;
      FBBundleDescriptor *bundle = persisted[bundleID];
      if (!bundle) {
        return [[FBIDBError
          describeFormat:@"%@ not persisted application and is therefore not debuggable. Suitable applications: %@", bundleID, [FBCollectionInformation oneLineDescriptionFromArray:persisted.allKeys]]
          failFuture];
      }

      return [FBFuture futureWithResult:bundle];
  }];
}

- (FBFuture<id<FBLogOperation>> *)tail_companion_logs:(id<FBDataConsumer>)consumer
{
  return [self.logger tailToConsumer:consumer];
}

#pragma mark Private Methods

- (FBFuture<id<FBiOSTargetFileCommands>> *)applicationDataContainerCommands:(NSString *)bundleID
{
  id<FBApplicationDataCommands> commands = (id<FBApplicationDataCommands>) self.target;
  if (![commands conformsToProtocol:@protocol(FBApplicationDataCommands)]) {
    return [[FBControlCoreError
      describeFormat:@"Target doesn't conform to FBApplicationDataCommands protocol %@", commands]
      failFuture];
  }
  if (bundleID == nil || bundleID.length == 0) {
    return [FBFuture futureWithResult:[commands fileCommandsForRootFilesystem]];
  }
  return [FBFuture futureWithResult:[commands fileCommandsForContainerApplication:bundleID]];
}


- (FBFuture<id<FBScreenshotCommands>> *)screenshotCommands
{
  id<FBScreenshotCommands> commands = (id<FBScreenshotCommands>) self.target;
  if (![commands conformsToProtocol:@protocol(FBScreenshotCommands)]) {
    return [[FBIDBError
       describeFormat:@"Target doesn't conform to FBScreenshotCommands protocol %@", self.target]
      failFuture];
  }
  return [FBFuture futureWithResult:commands];
}

- (FBFuture<id<FBSimulatorLifecycleCommands>> *)lifecycleCommands
{
  id<FBSimulatorLifecycleCommands> commands = (id<FBSimulatorLifecycleCommands>) self.target;
  if (![commands conformsToProtocol:@protocol(FBSimulatorLifecycleCommands)]) {
    return [[FBIDBError
      describeFormat:@"Target doesn't conform to FBSimulatorLifecycleCommands protocol %@", self.target]
      failFuture];
  }
  return [FBFuture futureWithResult:commands];
}

- (FBFuture<id<FBSimulatorMediaCommands>> *)mediaCommands
{
  id<FBSimulatorMediaCommands> commands = (id<FBSimulatorMediaCommands>) self.target;
  if (![commands conformsToProtocol:@protocol(FBSimulatorMediaCommands)]) {
    return [[FBIDBError
      describeFormat:@"Target doesn't conform to FBSimulatorMediaCommands protocol %@", self.target]
      failFuture];
  }
  return [FBFuture futureWithResult:commands];
}

- (FBFuture<id<FBSimulatorKeychainCommands>> *)keychainCommands
{
  id<FBSimulatorKeychainCommands> commands = (id<FBSimulatorKeychainCommands>) self.target;
  if (![commands conformsToProtocol:@protocol(FBSimulatorKeychainCommands)]) {
    return [[FBIDBError
      describeFormat:@"Target doesn't conform to FBSimulatorKeychainCommands protocol %@", self.target]
      failFuture];
  }
  return [FBFuture futureWithResult:commands];
}

- (FBFuture<id<FBSimulatorSettingsCommands>> *)settingsCommands
{
  id<FBSimulatorSettingsCommands> commands = (id<FBSimulatorSettingsCommands>) self.target;
  if (![commands conformsToProtocol:@protocol(FBSimulatorSettingsCommands)]) {
    return [[FBIDBError
      describeFormat:@"Target doesn't conform to FBSimulatorSettingsCommands protocol %@", self.target]
      failFuture];
  }
  return [FBFuture futureWithResult:commands];
}

- (FBFuture<FBSimulatorConnection *> *)connectToSimulatorConnection
{
  return [[self lifecycleCommands]
    onQueue:self.target.workQueue fmap:^ FBFuture<FBSimulatorConnection *> * (id<FBSimulatorLifecycleCommands> commands) {
      NSError *error = nil;
      if (![FBSimulatorControlFrameworkLoader.xcodeFrameworks loadPrivateFrameworks:self.target.logger error:&error]) {
        return [[FBIDBError
          describeFormat:@"SimulatorKit is required for HID interactions: %@", error]
          failFuture];
      }
      return [commands connect];
    }];
}

- (FBFuture<FBSimulatorBridge *> *)connectToSimulatorBridge
{
  return [[self
    connectToSimulatorConnection]
    onQueue:self.target.workQueue fmap:^(FBSimulatorConnection *connection) {
      return [connection connectToBridge];
    }];
}

- (FBFuture<FBSimulatorHID *> *)connectToHID
{
  return [[self
    connectToSimulatorConnection]
    onQueue:self.target.workQueue fmap:^(FBSimulatorConnection *connection) {
      return [connection connectToHID];
    }];
}

- (FBFuture<FBInstalledArtifact *> *)installExtractedApplication:(FBFutureContext<FBBundleDescriptor *> *)extractedApplication
{
  return [[extractedApplication
    onQueue:self.target.workQueue pend:^(FBBundleDescriptor *appBundle){
      if (!appBundle) {
        return [FBFuture futureWithError:[FBControlCoreError errorForDescription:@"No app bundle could be extracted"]];
      }
      NSError *error = nil;
      if (![self.storageManager.application checkArchitecture:appBundle error:&error]) {
        return [FBFuture futureWithError:error];
      }
      return [[self.target installApplicationWithPath:appBundle.path] mapReplace:appBundle];
    }]
    onQueue:self.target.workQueue pop:^(FBBundleDescriptor *appBundle){
      [self.logger logFormat:@"Persisting application bundle %@", appBundle];
      return [self.storageManager.application saveBundle:appBundle];
    }];
}

- (FBFuture<FBInstalledArtifact *> *)installXctest:(FBFutureContext<NSURL *> *)extractedXctest
{
  return [extractedXctest
    onQueue:self.target.workQueue pop:^(NSURL *extractionDirectory) {
      return [self.storageManager.xctest saveBundleOrTestRunFromBaseDirectory:extractionDirectory];
  }];
}

- (FBFuture<FBInstalledArtifact *> *)installXctestFilePath:(FBFutureContext<NSURL *> *)bundle
{
  return [bundle
    onQueue:self.target.workQueue pop:^(NSURL *xctestURL) {
      return [self.storageManager.xctest saveBundleOrTestRun:xctestURL];
    }];
}

- (FBFuture<FBInstalledArtifact *> *)installFile:(FBFutureContext<NSURL *> *)extractedFileContext intoStorage:(FBFileStorage *)storage
{
  return [extractedFileContext
    onQueue:self.target.workQueue pop:^(NSURL *extractedFile) {
      NSError *error = nil;
      FBInstalledArtifact *artifact = [storage saveFile:extractedFile error:&error];
      if (!artifact) {
        return [FBFuture futureWithError:error];
      }
      return [FBFuture futureWithResult:artifact];
    }];
}

- (FBFuture<FBInstalledArtifact *> *)installBundle:(FBFutureContext<NSURL *> *)extractedDirectoryContext intoStorage:(FBBundleStorage *)storage
{
  return [extractedDirectoryContext
    onQueue:self.target.workQueue pop:^ FBFuture<FBInstalledArtifact *> * (NSURL *extractedDirectory) {
      NSError *error = nil;
      FBBundleDescriptor *bundle = [FBStorageUtils bundleInDirectory:extractedDirectory error:&error];
      if (!bundle) {
        return [FBFuture futureWithError:error];
      }
      return [storage saveBundle:bundle];
    }];
}

@end
