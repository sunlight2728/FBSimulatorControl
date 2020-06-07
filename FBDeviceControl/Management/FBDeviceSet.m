/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBDeviceSet.h"
#import "FBDeviceSet+Private.h"

#import <FBControlCore/FBControlCore.h>
#import <FBControlCore/FBiOSTargetSet.h>
#import <FBControlCore/FBiOSTarget.h>

#import <XCTestBootstrap/XCTestBootstrap.h>

#import <objc/runtime.h>

#import "FBDeviceControlFrameworkLoader.h"
#import "FBDevice.h"
#import "FBDevice+Private.h"
#import "FBAMDevice.h"
#import "FBAMDevice+Private.h"
#import "FBDeviceInflationStrategy.h"

@implementation FBDeviceSet

@synthesize allDevices = _allDevices;
@synthesize delegate = _delegate;

#pragma mark Initializers

+ (void)initialize
{
  [FBDeviceControlFrameworkLoader.new loadPrivateFrameworksOrAbort];
}

+ (nullable instancetype)defaultSetWithLogger:(nullable id<FBControlCoreLogger>)logger error:(NSError **)error delegate:(nullable id<FBiOSTargetSetDelegate>)delegate
{
  static dispatch_once_t onceToken;
  static FBDeviceSet *deviceSet = nil;
  dispatch_once(&onceToken, ^{
    deviceSet = [[FBDeviceSet alloc] initWithLogger:logger delegate:delegate];
  });
  return deviceSet;
}

+ (nullable instancetype)defaultSetWithLogger:(nullable id<FBControlCoreLogger>)logger error:(NSError **)error
{
  return [FBDeviceSet defaultSetWithLogger:logger error:error delegate:nil];
}

- (instancetype)initWithLogger:(id<FBControlCoreLogger>)logger delegate:(id<FBiOSTargetSetDelegate>)delegate
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _delegate = delegate;
  _logger = logger;
  _allDevices = @[];
  [self recalculateAllDevices];
  [self subscribeToDeviceNotifications];

  return self;
}

- (void)dealloc
{
  [self unsubscribeFromDeviceNotifications];
}

#pragma mark Querying

- (NSArray<FBDevice *> *)query:(FBiOSTargetQuery *)query
{
  if ([query excludesAll:FBiOSTargetTypeDevice]) {
    return @[];
  }
  return (NSArray<FBDevice *> *)[query filter:_allDevices];
}

- (nullable FBDevice *)deviceWithUDID:(NSString *)udid
{
  FBiOSTargetQuery *query = [FBiOSTargetQuery udids:@[udid]];
  return [[self query:query] firstObject];
}

#pragma mark Predicates

+ (NSPredicate *)predicateDeviceWithUDID:(NSString *)udid
{
  return [NSPredicate predicateWithBlock:^ BOOL (FBDevice *device, id _) {
    return [device.udid isEqualToString:udid];
  }];
}

#pragma mark FBiOSTargetSet Implementation

- (NSArray<id<FBiOSTarget>> *)allTargets
{
  return self.allDevices;
}

#pragma mark Private

- (FBDeviceInflationStrategy *)inflationStrategy
{
  return [FBDeviceInflationStrategy strategyForSet:self];
}

- (void)subscribeToDeviceNotifications
{
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(deviceAttachedNotification:) name:FBAMDeviceNotificationNameDeviceAttached object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(deviceDetachedNotification:) name:FBAMDeviceNotificationNameDeviceDetached object:nil];
}

- (void)unsubscribeFromDeviceNotifications
{
  [NSNotificationCenter.defaultCenter removeObserver:self name:FBAMDeviceNotificationNameDeviceAttached object:nil];
  [NSNotificationCenter.defaultCenter removeObserver:self name:FBAMDeviceNotificationNameDeviceDetached object:nil];
}

- (void)deviceAttachedNotification:(NSNotification *)notification
{
  [self recalculateAllDevices];
  FBDevice *device = [self deviceWithUDID:notification.object];
  [_delegate targetDidUpdate:[[FBiOSTargetStateUpdate alloc] initWithTarget:device]];
}

- (void)deviceDetachedNotification:(NSNotification *)notification
{
  FBDevice *device = [self deviceWithUDID:notification.object];
  [self recalculateAllDevices];
  [_delegate targetDidUpdate:[[FBiOSTargetStateUpdate alloc] initWithTarget:device]];
}

- (void)recalculateAllDevices
{
  _allDevices = [[self.inflationStrategy
    inflateFromDevices:FBAMDevice.allDevices existingDevices:_allDevices]
    sortedArrayUsingSelector:@selector(compare:)];
}

@end
