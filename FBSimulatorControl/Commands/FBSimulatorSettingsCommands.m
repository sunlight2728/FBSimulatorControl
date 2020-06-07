/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSimulatorSettingsCommands.h"

#import <CoreSimulator/SimDevice.h>

#import <FBControlCore/FBControlCore.h>

#import "FBSimulator.h"
#import "FBSimulatorError.h"
#import "FBSimulatorBootConfiguration.h"
#import "FBDefaultsModificationStrategy.h"

FBiOSTargetFutureType const FBiOSTargetFutureTypeApproval = @"approve";

@interface FBSimulatorSettingsCommands ()

@property (nonatomic, weak, readonly) FBSimulator *simulator;

@end

@implementation FBSimulatorSettingsCommands

+ (instancetype)commandsWithTarget:(FBSimulator *)target
{
  return [[self alloc] initWithSimulator:target];
}

- (instancetype)initWithSimulator:(FBSimulator *)simulator
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _simulator = simulator;
  return self;
}

- (FBFuture<NSNull *> *)overridingLocalization:(FBLocalizationOverride *)localizationOverride
{
  if (!localizationOverride) {
    return FBFuture.empty;
  }

  return [[FBLocalizationDefaultsModificationStrategy
    strategyWithSimulator:self.simulator]
    overrideLocalization:localizationOverride];
}

- (FBFuture<NSNull *> *)authorizeLocationSettings:(NSArray<NSString *> *)bundleIDs
{
  return [[FBLocationServicesModificationStrategy
    strategyWithSimulator:self.simulator]
    approveLocationServicesForBundleIDs:bundleIDs];
}

- (FBFuture<NSNull *> *)overrideWatchDogTimerForApplications:(NSArray<NSString *> *)bundleIDs withTimeout:(NSTimeInterval)timeout
{
  return [[FBWatchdogOverrideModificationStrategy
    strategyWithSimulator:self.simulator]
    overrideWatchDogTimerForApplications:bundleIDs timeout:timeout];
}

- (FBFuture<NSNull *> *)grantAccess:(NSSet<NSString *> *)bundleIDs toServices:(NSSet<FBSettingsApprovalService> *)services
{
  // We need at least one approval in the array.
  NSParameterAssert(services.count >= 1);

  // Composing different futures due to differences in how these operate.
  NSMutableArray<FBFuture<NSNull *> *> *futures = [NSMutableArray array];
  if ([[NSSet setWithArray:FBSimulatorSettingsCommands.tccDatabaseMapping.allKeys] intersectsSet:services]) {
    [futures addObject:[self modifyTCCDatabaseWithBundleIDs:bundleIDs toServices:services]];
  }
  if ([services containsObject:FBSettingsApprovalServiceLocation]) {
    [futures addObject:[self authorizeLocationSettings:bundleIDs.allObjects]];
  }
  // Don't wrap if there's only one future.
  if (futures.count == 0) {
    return futures.firstObject;
  }
  return [FBFuture futureWithFutures:futures];
}

- (FBFuture<NSNull *> *)grantAccess:(NSSet<NSString *> *)bundleIDs toDeeplink:(NSString *)scheme
{
  if ([scheme length] == 0) {
    return [[FBSimulatorError
             describe:@"Empty scheme provided to url approve"]
            failFuture];
  }

  if ([bundleIDs count] == 0) {
    return [[FBSimulatorError
             describe:@"Empty bundleID set provided to url approve"]
            failFuture];
  }

  NSString *preferencesDirectory = [self.simulator.dataDirectory stringByAppendingPathComponent:@"Library/Preferences"];
  NSString *schemeApprovalPlistPath = [preferencesDirectory stringByAppendingPathComponent:@"com.apple.launchservices.schemeapproval.plist"];

  //Read the existing file if it exists. Otherwise create a new dictionary
  NSMutableDictionary<NSString *, NSString *> *schemeApprovalProperties = [NSMutableDictionary new];
  if ([NSFileManager.defaultManager fileExistsAtPath:schemeApprovalPlistPath]) {
    schemeApprovalProperties = [[NSDictionary dictionaryWithContentsOfFile:schemeApprovalPlistPath] mutableCopy];
    if (schemeApprovalProperties == nil) {
      return [[FBSimulatorError
               describeFormat:@"Failed to read the file at %@", schemeApprovalPlistPath]
              failFuture];
    }
  }

  //Add magic strings to our plist. This is necessary to skip the dialog when using `idb open`
  NSString *urlKey = [NSString stringWithFormat:@"com.apple.CoreSimulator.CoreSimulatorBridge-->%@", scheme];
  for (NSString *bundleID in bundleIDs) {
    schemeApprovalProperties[urlKey] = bundleID;
  }

  //Write our plist back
  NSError *error = nil;
  BOOL success = [NSFileManager.defaultManager
                  createDirectoryAtPath:preferencesDirectory
                  withIntermediateDirectories:YES
                  attributes:nil
                  error:&error];
  if (!success) {
        return [[FBSimulatorError
             describe:@"Failed to create folders for scheme approval plist"]
            failFuture];
  }
  success = [schemeApprovalProperties writeToFile:schemeApprovalPlistPath atomically:YES];
  if (!success) {
    return [[FBSimulatorError
             describe:@"Failed to write scheme approval plist"]
            failFuture];
  }
  return FBFuture.empty;
}

- (FBFuture<NSNull *> *)updateContacts:(NSString *)databaseDirectory
{
  // Get and confirm the destination directory exists.
  NSString *destinationDirectory = [self.simulator.dataDirectory stringByAppendingPathComponent:@"Library/AddressBook"];
  if (![NSFileManager.defaultManager fileExistsAtPath:destinationDirectory]) {
    return [[FBSimulatorError
      describeFormat:@"Expected Address Book path to exist at %@ but it was not there", destinationDirectory]
      failFuture];
  }

  // Obtain the relevant file paths
  NSError *error = nil;
  NSArray<NSString *> *sourceFilePaths = [FBSimulatorSettingsCommands contactsDatabaseFilePathsFromContainingDirectory:databaseDirectory error:&error];
  if (!sourceFilePaths) {
    return [FBFuture futureWithError:error];
  }


  // Perform the copies
  for (NSString *sourceFilePath in sourceFilePaths) {
    NSString *destinationFilePath = [destinationDirectory stringByAppendingPathComponent:sourceFilePath.lastPathComponent];
    if ([NSFileManager.defaultManager fileExistsAtPath:destinationFilePath] && ! [NSFileManager.defaultManager removeItemAtPath:destinationFilePath error:&error]) {
      return [FBFuture futureWithError:error];
    }
    if (![NSFileManager.defaultManager copyItemAtPath:sourceFilePath toPath:destinationFilePath error:&error]) {
      return [FBFuture futureWithError:error];
    }
  }

  return FBFuture.empty;
}

- (FBFuture<NSNull *> *)setupKeyboard
{
  return [[FBKeyboardSettingsModificationStrategy
    strategyWithSimulator:self.simulator]
    setupKeyboard];
}

#pragma mark Private

- (FBFuture<NSNull *> *)modifyTCCDatabaseWithBundleIDs:(NSSet<NSString *> *)bundleIDs toServices:(NSSet<FBSettingsApprovalService> *)services
{
  NSString *databasePath = [self.simulator.dataDirectory stringByAppendingPathComponent:@"Library/TCC/TCC.db"];
  if (!databasePath) {
    return [[FBSimulatorError
      describeFormat:@"Expected file to exist at path %@ but it was not there", databasePath]
      failFuture];
  }

  id<FBControlCoreLogger> logger = [self.simulator.logger withName:@"sqlite_auth"];
  dispatch_queue_t queue = self.simulator.asyncQueue;

  return [[[FBSimulatorSettingsCommands
    buildRowsForDatabase:databasePath bundleIDs:bundleIDs services:services queue:queue logger:logger]
    onQueue:self.simulator.workQueue fmap:^(NSString *rows) {
      return [FBSimulatorSettingsCommands
        runSqliteCommandOnDatabase:databasePath
        arguments:@[[NSString stringWithFormat:@"INSERT or REPLACE INTO access VALUES %@", rows]]
        queue:queue
        logger:logger];
    }]
    mapReplace:NSNull.null];
}

#pragma mark Private

+ (NSDictionary<FBSettingsApprovalService, NSString *> *)tccDatabaseMapping
{
  static dispatch_once_t onceToken;
  static NSDictionary<FBSettingsApprovalService, NSString *> *mapping;
  dispatch_once(&onceToken, ^{
    mapping = @{
      FBSettingsApprovalServiceContacts: @"kTCCServiceAddressBook",
      FBSettingsApprovalServicePhotos: @"kTCCServicePhotos",
      FBSettingsApprovalServiceCamera: @"kTCCServiceCamera",
      FBSettingsApprovalServiceMicrophone: @"kTCCServiceMicrophone",
    };
  });
  return mapping;
}

+ (NSSet<NSString *> *)permissibleAddressBookDBFilenames
{
  static dispatch_once_t onceToken;
  static NSSet<NSString *> *filenames;
  dispatch_once(&onceToken, ^{
    filenames = [NSSet setWithArray:@[
      @"AddressBook.sqlitedb",
      @"AddressBook.sqlitedb-shm",
      @"AddressBook.sqlitedb-wal",
      @"AddressBookImages.sqlitedb",
      @"AddressBookImages.sqlitedb-shm",
      @"AddressBookImages.sqlitedb-wal",
    ]];
  });
  return filenames;
}

+ (NSSet<FBSettingsApprovalService> *)filteredTCCApprovals:(NSSet<FBSettingsApprovalService> *)approvals
{
  NSMutableSet<FBSettingsApprovalService> *filtered = [NSMutableSet setWithSet:approvals];
  [filtered intersectSet:[NSSet setWithArray:self.tccDatabaseMapping.allKeys]];
  return [filtered copy];
}

+ (FBFuture<NSString *> *)buildRowsForDatabase:(NSString *)databasePath bundleIDs:(NSSet<NSString *> *)bundleIDs services:(NSSet<FBSettingsApprovalService> *)services queue:(dispatch_queue_t)queue logger:(id<FBControlCoreLogger>)logger
{
  NSParameterAssert(bundleIDs.count >= 1);
  NSParameterAssert(services.count >= 1);

  return [[self
    runSqliteCommandOnDatabase:databasePath arguments:@[@".schema access"] queue:queue logger:logger]
    onQueue:queue map:^(NSString *result) {
      if ([result containsString:@"last_modified"]) {
        return [FBSimulatorSettingsCommands postiOS12ApprovalRowsForBundleIDs:bundleIDs services:services];
      } else {
        return [FBSimulatorSettingsCommands preiOS12ApprovalRowsForBundleIDs:bundleIDs services:services];
      }
    }];
}

+ (NSString *)preiOS12ApprovalRowsForBundleIDs:(NSSet<NSString *> *)bundleIDs services:(NSSet<FBSettingsApprovalService> *)services
{
  NSMutableArray<NSString *> *tuples = [NSMutableArray array];
  for (NSString *bundleID in bundleIDs) {
    for (FBSettingsApprovalService service in [self filteredTCCApprovals:services]) {
      NSString *serviceName = self.tccDatabaseMapping[service];
      [tuples addObject:[NSString stringWithFormat:@"('%@', '%@', 0, 1, 0, 0, 0)", serviceName, bundleID]];
    }
  }
  return [tuples componentsJoinedByString:@", "];
}

+ (NSString *)postiOS12ApprovalRowsForBundleIDs:(NSSet<NSString *> *)bundleIDs services:(NSSet<FBSettingsApprovalService> *)services
{
  NSUInteger timestamp = (NSUInteger) NSDate.date.timeIntervalSince1970;
  NSMutableArray<NSString *> *tuples = [NSMutableArray array];
  for (NSString *bundleID in bundleIDs) {
    for (FBSettingsApprovalService service in [self filteredTCCApprovals:services]) {
      NSString *serviceName = self.tccDatabaseMapping[service];
      [tuples addObject:[NSString stringWithFormat:@"('%@', '%@', 0, 1, 1, NULL, NULL, NULL, 'UNUSED', NULL, NULL, %lu)", serviceName, bundleID, timestamp]];
    }
  }
  return [tuples componentsJoinedByString:@", "];
}

+ (FBFuture<NSString *> *)runSqliteCommandOnDatabase:(NSString *)databasePath arguments:(NSArray<NSString *> *)arguments queue:(dispatch_queue_t)queue logger:(id<FBControlCoreLogger>)logger
{
  return [[[[[FBTaskBuilder
    withLaunchPath:@"/usr/bin/sqlite3" arguments:[@[databasePath] arrayByAddingObjectsFromArray:arguments]]
    withStdOutInMemoryAsString]
    withStdErrInMemoryAsString]
    runUntilCompletion]
    onQueue:queue fmap:^(FBTask<NSNull *, NSString *, NSString *> *task) {
      if ([task.stdErr hasPrefix:@"Error"]) {
        return [[[FBSimulatorError
          describeFormat:@"Failed to execute sqlite command: %@", task.stdErr]
          logger:logger]
          failFuture];
      }
      return [FBFuture futureWithResult:task.stdOut];
    }];
}

+ (NSArray<NSString *> *)contactsDatabaseFilePathsFromContainingDirectory:(NSString *)databaseDirectory error:(NSError **)error
{
  NSMutableArray<NSString *> *filePaths = [NSMutableArray array];
  NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:databaseDirectory];
  NSSet<NSString *> *permissibleDatabaseFilepaths = FBSimulatorSettingsCommands.permissibleAddressBookDBFilenames;

  for (NSString *path in enumerator) {
    if (![permissibleDatabaseFilepaths containsObject:path.lastPathComponent]) {
      continue;
    }
    NSString *fullPath = [databaseDirectory stringByAppendingPathComponent:path];
    [filePaths addObject:fullPath];
  }

  // Fail if nothing is provided
  if (!filePaths.count) {
    return [[FBSimulatorError
      describe:@"Could not update Address Book DBs when no databases are provided"]
      fail:error];
  }

  return [filePaths copy];
}

@end

@implementation FBSettingsApproval (FBiOSTargetFuture)

+ (FBiOSTargetFutureType)futureType
{
  return FBiOSTargetFutureTypeApproval;
}

- (FBFuture<id<FBiOSTargetContinuation>> *)runWithTarget:(id<FBiOSTarget>)target consumer:(id<FBDataConsumer>)consumer reporter:(id<FBEventReporter>)reporter
{
  id<FBSimulatorSettingsCommands> commands = (id<FBSimulatorSettingsCommands>) target;
  if (![target conformsToProtocol:@protocol(FBSimulatorSettingsCommands)]) {
    return [[FBControlCoreError
      describeFormat:@"%@ does not conform to FBSimulatorSettingsCommands", target]
      failFuture];
  }
  return [[commands
    grantAccess:[NSSet setWithArray:self.bundleIDs] toServices:[NSSet setWithArray:self.services]]
    mapReplace:FBiOSTargetContinuationDone(self.class.futureType)];
}

@end
