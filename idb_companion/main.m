/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>
#import <FBSimulatorControl/FBSimulatorControl.h>
#import <FBDeviceControl/FBDeviceControl.h>

#import "FBIDBCompanionServer.h"
#import "FBIDBConfiguration.h"
#import "FBIDBError.h"
#import "FBIDBLogger.h"
#import "FBIDBPortsConfiguration.h"
#import "FBiOSTargetProvider.h"
#import "FBiOSTargetStateChangeNotifier.h"
#import "FBStorageUtils.h"
#import "FBTemporaryDirectory.h"

const char *kUsageHelpMessage = "\
Usage: \n \
  Modes of operation, only one of these may be specified:\n\
    --udid UDID                Launches a companion server for the specified UDID.\n\
    --boot UDID                Boots the simulator with the specified UDID.\n\
    --shutdown UDID            Shuts down the simulator with the specified UDID.\n\
    --erase UDID               Erases the simulator with the specified UDID.\n\
    --delete UDID|all          Deletes the simulator with the specified UDID, or 'all' to delete all simulators in the set.\n\
    --create VALUE             Creates a simulator using the VALUE argument like \"iPhone X,iOS 12.4\"\n\
    --clone UDID               Clones a simulator by a given UDID\n\
    --clone-destination-set    A path to the destination device set in a clone operation, --device-set-path specifies the source simulator.\n\
    --notify PATH|stdout       Launches a companion notifier which will stream availability updates to the specified path, or stdout.\n\
    --list 1                   Lists all available devices/simulators in the current context.\n\
    --help                     Show this help message and exit.\n\
\n\
  Options:\n\
    --grpc-port PORT           Port to start the grpc companion server on (default: 10882).\n\
    --debug-port PORT          Port to connect debugger on (default: 10881).\n\
    --log-file-path PATH       Path to write a log file to e.g ./output.log (default: logs to stdErr).\n\
    --device-set-path PATH     Path to a custom Simulator device set.\n\
    --only simulator|device    If provided will query only against simulators or devices\n\
    --headless VALUE           If VALUE is a true value, the Simulator boot's lifecycle will be tied to the lifecycle of this invocation.\n\
    --terminate-offline VALUE  Terminate if the target goes offline, otherwise the companion will stay alive.\n";

static BOOL shouldPrintUsage(void)
{
  return [NSProcessInfo.processInfo.arguments containsObject:@"--help"];
}

static void WriteJSONToStdOut(id json)
{
  NSData *jsonOutput = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
  NSMutableData *readyOutput = [NSMutableData dataWithData:jsonOutput];
  [readyOutput appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
  write(STDOUT_FILENO, readyOutput.bytes, readyOutput.length);
  fflush(stdout);
}

static void WriteTargetToStdOut(id<FBiOSTarget> target)
{
  WriteJSONToStdOut([[FBiOSTargetStateUpdate alloc] initWithTarget:target].jsonSerializableRepresentation);
}

static FBFuture<FBSimulatorSet *> *SimulatorSetWithPath(NSString *deviceSetPath, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  // Give a more meaningful message if we can't load the frameworks.
  NSError *error = nil;
  if(![FBSimulatorControlFrameworkLoader.essentialFrameworks loadPrivateFrameworks:logger error:&error]) {
    return [FBFuture futureWithError:error];
  }
  FBSimulatorControlConfiguration *configuration = [FBSimulatorControlConfiguration configurationWithDeviceSetPath:deviceSetPath options:0 logger:logger reporter:reporter];
  FBSimulatorControl *control = [FBSimulatorControl withConfiguration:configuration error:&error];
  if (!control) {
    return [FBFuture futureWithError:error];
  }
  return [FBFuture futureWithResult:control.set];
}

static FBFuture<FBSimulatorSet *> *SimulatorSet(NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  NSString *deviceSetPath = [userDefaults stringForKey:@"-device-set-path"];
  return SimulatorSetWithPath(deviceSetPath, logger, reporter);
}

static FBFuture<FBDeviceSet *> *DeviceSet(id<FBControlCoreLogger> logger)
{
  // Give a more meaningful message if we can't load the frameworks.
  NSError *error = nil;
  if(![FBDeviceControlFrameworkLoader.new loadPrivateFrameworks:logger error:&error]) {
    return [FBFuture futureWithError:error];
  }
  FBDeviceSet *deviceSet = [FBDeviceSet defaultSetWithLogger:logger error:&error delegate:nil];
  if (!deviceSet) {
    return [FBFuture futureWithError:error];
  }
  return [FBFuture futureWithResult:deviceSet];
}

static FBFuture<NSArray<id<FBiOSTargetSet>> *> *DefaultTargetSets(NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  NSString *only = [userDefaults stringForKey:@"-only"];
  if (only) {
    if ([only.lowercaseString containsString:@"simulator"]) {
      [logger log:@"'--only' set for Simulators"];
      return [FBFuture futureWithFutures:@[SimulatorSet(userDefaults, logger, reporter)]];
    }
    if ([only.lowercaseString containsString:@"device"]) {
      [logger log:@"'--only' set for Devices"];
      return [FBFuture futureWithFutures:@[DeviceSet(logger)]];
    }
    return [[FBIDBError
      describeFormat:@"%@ is not a valid argument for '--only'", only]
      failFuture];
  }
  [logger log:@"Providing targets across Simulator and Device sets."];
  return [FBFuture futureWithFutures:@[
    SimulatorSet(userDefaults, logger, reporter),
    DeviceSet(logger),
  ]];
}

static FBFuture<id<FBiOSTarget>> *TargetForUDID(NSString *udid, NSUserDefaults *userDefaults, BOOL warmUp, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  if ([udid isEqualToString:@"mac"]) {
    udid = [FBMacDevice resolveDeviceUDID];
  }
  return [DefaultTargetSets(userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^(NSArray<id<FBiOSTargetSet>> *targetSets) {
      return [FBiOSTargetProvider targetWithUDID:udid targetSets:targetSets warmUp:warmUp logger:logger];
    }];
}

static FBFuture<FBSimulator *> *SimulatorFuture(NSString *udid, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  return [[SimulatorSet(userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^(FBSimulatorSet *simulatorSet) {
      return [FBiOSTargetProvider targetWithUDID:udid targetSets:@[simulatorSet] warmUp:NO logger:logger];
    }]
    onQueue:dispatch_get_main_queue() fmap:^(id<FBiOSTarget> target) {
      id<FBSimulatorLifecycleCommands> commands = (id<FBSimulatorLifecycleCommands>) target;
      if (![commands conformsToProtocol:@protocol(FBSimulatorLifecycleCommands)]) {
        return [[FBIDBError
          describeFormat:@"%@ does not support Simulator Lifecycle commands", commands]
          failFuture];
      }
      return [FBFuture futureWithResult:commands];
    }];
}

static FBFuture<NSNull *> *TargetOfflineFuture(id<FBiOSTarget> target, id<FBControlCoreLogger> logger)
{
  return [[FBFuture
    onQueue:target.workQueue resolveWhen:^ BOOL {
      if (target.state != FBiOSTargetStateBooted) {
        [logger.error logFormat:@"Target with udid %@ is no longer booted, it is in state %@", target.udid, FBiOSTargetStateStringFromState(target.state)];
        return YES;
      }
      return NO;
    }]
    mapReplace:NSNull.null];
}

static FBFuture<FBFuture<NSNull *> *> *BootFuture(NSString *udid, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  BOOL headless = [userDefaults boolForKey:@"-headless"];
  return [[SimulatorFuture(udid, userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^(FBSimulator *simulator) {
      // Boot the simulator with the options provided.
      FBSimulatorBootConfiguration *config = FBSimulatorBootConfiguration.defaultConfiguration;
      if (headless) {
        [logger logFormat:@"Booting %@ headlessly", udid];
        config = [config withOptions:(config.options | FBSimulatorBootOptionsEnableDirectLaunch)];
      } else {
        [logger logFormat:@"Booting %@ normally", udid];
      }
      return [[simulator bootWithConfiguration:config] mapReplace:simulator];
    }]
    onQueue:dispatch_get_main_queue() map:^ FBFuture<NSNull *> * (FBSimulator *simulator) {
      // Write the boot success to stdout
      WriteTargetToStdOut(simulator);
      // In a headless boot:
      // - We need to keep this process running until it's otherwise shutdown. When the sim is shutdown this process will die.
      // - If this process is manually killed then the simulator will die
      // For a regular boot the sim will outlive this process.
      if (!headless) {
        return FBFuture.empty;
      }
      // Whilst we can rely on this process being killed shutting the simulator, this is asynchronous.
      // This means that we should attempt to handle cancellation gracefully.
      // In this case we should attempt to shutdown in response to cancellation.
      // This means if this future is cancelled and waited-for before the process exits we will return it in a "Shutdown" state.
      return [TargetOfflineFuture(simulator, logger)
        onQueue:dispatch_get_main_queue() respondToCancellation:^{
          return [simulator shutdown];
        }];
    }];
}

static FBFuture<NSNull *> *ShutdownFuture(NSString *udid, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  return [SimulatorFuture(udid, userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^(FBSimulator *simulator) {
      return [simulator shutdown];
    }];
}

static FBFuture<NSNull *> *EraseFuture(NSString *udid, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  return [SimulatorFuture(udid, userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^(FBSimulator *simulator) {
      return [simulator erase];
    }];
}

static FBFuture<NSNull *> *DeleteFuture(NSString *udidOrAll, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  return [[SimulatorSet(userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^ FBFuture * (FBSimulatorSet *set) {
      if ([udidOrAll.lowercaseString isEqualToString:@"all"]) {
        return [set deleteAll];
      }
      NSArray<FBSimulator *> *simulators = [set query:[FBiOSTargetQuery udid:udidOrAll]];
      if (simulators.count != 1) {
        return [[FBIDBError
          describeFormat:@"Could not find a simulator with udid %@ got %@", udidOrAll, [FBCollectionInformation oneLineDescriptionFromArray:simulators]]
          failFuture];
      }
      return [set deleteSimulator:simulators.firstObject];
    }]
    mapReplace:NSNull.null];
}

static FBFuture<NSNull *> *ListFuture(NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  return [DefaultTargetSets(userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() map:^ NSNull * (NSArray<id<FBiOSTargetSet>> *targetSets) {
      for (id<FBiOSTargetSet> targetSet in targetSets) {
        for (id<FBiOSTarget> target in targetSet.allTargets) {
          WriteTargetToStdOut(target);
        }
      }
      return NSNull.null;
    }];
}

static FBFuture<NSNull *> *CreateFuture(NSString *create, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  return [[SimulatorSet(userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^ FBFuture<FBSimulator *> * (FBSimulatorSet *set) {
      NSArray<NSString *> *parameters = [create componentsSeparatedByString:@","];
      FBSimulatorConfiguration *config = [FBSimulatorConfiguration defaultConfiguration];
      if (parameters.count > 0) {
        config = [config withDeviceModel:parameters[0]];
      }
      if (parameters.count > 1) {
        config = [config withOSNamed:parameters[1]];
      }
      return [set createSimulatorWithConfiguration:config];
    }]
    onQueue:dispatch_get_main_queue() map:^(FBSimulator *simulator) {
      WriteTargetToStdOut(simulator);
      return NSNull.null;
    }];
}

static FBFuture<NSNull *> *CloneFuture(NSString *udid, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  NSString *destinationSet = [userDefaults stringForKey:@"-clone-destination-set"];
  return [[[FBFuture
    futureWithFutures:@[
      SimulatorFuture(udid, userDefaults, logger, reporter),
      SimulatorSetWithPath(destinationSet, logger, reporter),
    ]]
    onQueue:dispatch_get_main_queue() fmap:^ FBFuture<FBSimulator *> * (NSArray<id> *tuple) {
      FBSimulator *base = tuple[0];
      FBSimulatorSet *destination = tuple[1];
      return [base.set cloneSimulator:base toDeviceSet:destination];
    }]
    onQueue:dispatch_get_main_queue() map:^(FBSimulator *cloned) {
      WriteTargetToStdOut(cloned);
      return NSNull.null;
    }];
}

static FBFuture<FBFuture<NSNull *> *> *CompanionServerFuture(NSString *udid, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  BOOL terminateOffline = [userDefaults boolForKey:@"-terminate-offline"];
  return [TargetForUDID(udid, userDefaults, YES, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^(id<FBiOSTarget> target) {
      [reporter addMetadata:@{@"udid": udid}];
      [reporter report:[FBEventReporterSubject subjectForEvent:FBEventNameLaunched]];
      // Start up the companion
      FBIDBPortsConfiguration *ports = [FBIDBPortsConfiguration portsWithArguments:userDefaults];
      FBTemporaryDirectory *temporaryDirectory = [FBTemporaryDirectory temporaryDirectoryWithLogger:logger];
      NSError *error = nil;
      FBIDBCompanionServer *server = [FBIDBCompanionServer companionForTarget:target temporaryDirectory:temporaryDirectory ports:ports eventReporter:reporter logger:logger error:&error];
      if (!server) {
        return [FBFuture futureWithError:error];
      }
      return [[server
        start]
        onQueue:target.workQueue map:^ FBFuture * (NSNumber *port) {
          WriteJSONToStdOut(@{@"grpc_port": port});
          FBFuture<NSNull *> *completed = server.completed;
          if (terminateOffline) {
            [logger.info logFormat:@"Companion will terminate when target goes offline"];
            completed = [FBFuture race:@[completed, TargetOfflineFuture(target, logger)]];
          } else {
            [logger.info logFormat:@"Companion will stay alive if target goes offline"];
          }
          return [completed
            onQueue:target.workQueue chain:^(FBFuture *future) {
              [temporaryDirectory cleanOnExit];
              return future;
            }];
        }];
    }];
}

static FBFuture<FBFuture<NSNull *> *> *NotiferFuture(NSString *notify, NSUserDefaults *userDefaults, id<FBControlCoreLogger> logger, id<FBEventReporter> reporter)
{
  return [[[DefaultTargetSets(userDefaults, logger, reporter)
    onQueue:dispatch_get_main_queue() fmap:^(NSArray<id<FBiOSTargetSet>> *targetSets) {
      if ([notify isEqualToString:@"stdout"]) {
        return [FBiOSTargetStateChangeNotifier notifierToStdOutWithTargetSets:targetSets logger:logger];
      }
      return [FBiOSTargetStateChangeNotifier notifierToFilePath:notify withTargetSets:targetSets logger:logger];
    }]
    onQueue:dispatch_get_main_queue() fmap:^(FBiOSTargetStateChangeNotifier *notifier) {
      [logger logFormat:@"Starting Notifier %@", notifier];
      return [[notifier startNotifier] mapReplace:notifier];
    }]
    onQueue:dispatch_get_main_queue() map:^(FBiOSTargetStateChangeNotifier *notifier) {
      [logger logFormat:@"Started Notifier %@", notifier];
      return [notifier.notifierDone
        onQueue:dispatch_get_main_queue() respondToCancellation:^{
          [logger logFormat:@"Stopping Notifier %@", notifier];
          return FBFuture.empty;
        }];
    }];
}

static FBFuture<FBFuture<NSNull *> *> *GetCompanionCompletedFuture(int argc, const char *argv[], NSUserDefaults *userDefaults, FBIDBLogger *logger) {
  NSString *udid = [userDefaults stringForKey:@"-udid"];
  NSString *notify = [userDefaults stringForKey:@"-notify"];
  NSString *boot = [userDefaults stringForKey:@"-boot"];
  NSString *create = [userDefaults stringForKey:@"-create"];
  NSString *shutdown = [userDefaults stringForKey:@"-shutdown"];
  NSString *erase = [userDefaults stringForKey:@"-erase"];
  NSString *delete = [userDefaults stringForKey:@"-delete"];
  NSString *list = [userDefaults stringForKey:@"-list"];
  NSString *clone = [userDefaults stringForKey:@"-clone"];

  id<FBEventReporter> reporter = FBIDBConfiguration.eventReporter;
  if (udid) {
    return CompanionServerFuture(udid, userDefaults, logger, reporter);
  } else if (list) {
    [logger.info log:@"Listing"];
    return [FBFuture futureWithResult:ListFuture(userDefaults, logger, reporter)];
  } else if (notify) {
    [logger.info logFormat:@"Notifying %@", notify];
    return NotiferFuture(notify, userDefaults, logger, reporter);
  } else if (boot) {
    [logger logFormat:@"Booting %@", boot];
    return BootFuture(boot, userDefaults, logger, reporter);
  } else if(shutdown) {
    [logger.info logFormat:@"Shutting down %@", shutdown];
    return [FBFuture futureWithResult:ShutdownFuture(shutdown, userDefaults, logger, reporter)];
  } else if (erase) {
    [logger.info logFormat:@"Erasing %@", erase];
    return [FBFuture futureWithResult:EraseFuture(erase, userDefaults, logger, reporter)];
  } else if (delete) {
    [logger.info logFormat:@"Deleting %@", delete];
    return [FBFuture futureWithResult:DeleteFuture(delete, userDefaults, logger, reporter)];
  } else if (create) {
    [logger.info logFormat:@"Creating %@", create];
    return [FBFuture futureWithResult:CreateFuture(create, userDefaults, logger, reporter)];
  } else if (clone) {
    [logger.info logFormat:@"Cloning %@", clone];
    return [FBFuture futureWithResult:CloneFuture(clone, userDefaults, logger, reporter)];
  }
  return [[[FBIDBError
    describeFormat:@"You must specify at least one 'Mode of operation'\n\n%s", kUsageHelpMessage]
    noLogging]
    failFuture];
}

static FBFuture<NSNumber *> *signalHandlerFuture(int signalCode, NSString *exitMessage, id<FBControlCoreLogger> logger)
{
  dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
  FBMutableFuture<NSNumber *> *future = FBMutableFuture.future;
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signalCode, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(source, ^{
    [logger.error log:exitMessage];
    [future resolveWithResult:@(signalCode)];
  });
  dispatch_resume(source);
  struct sigaction action = {{0}};
  action.sa_handler = SIG_IGN;
  sigaction(signalCode, &action, NULL);
  return [future
    onQueue:queue notifyOfCompletion:^(FBFuture *_) {
      dispatch_cancel(source);
    }];
}

static NSString *EnvDescription()
{
  NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
  NSMutableDictionary<NSString *, NSString *> *modified = NSMutableDictionary.dictionary;
  for (NSString *key in env) {
    if ([key containsString:@"TERMCAP"]) {
      continue;
    }
    modified[key] = env[key];
  }
  return [FBCollectionInformation oneLineDescriptionFromDictionary:modified];
}

int main(int argc, const char *argv[]) {
  if (shouldPrintUsage()) {
    fprintf(stderr, "%s", kUsageHelpMessage);
    return 1;
  }

  @autoreleasepool
  {
    NSUserDefaults *userDefaults = NSUserDefaults.standardUserDefaults;
    FBIDBLogger *logger = [FBIDBLogger loggerWithUserDefaults:userDefaults];
    [logger.info logFormat:@"IDB Companion Built at %s %s", __DATE__, __TIME__];
    [logger.info logFormat:@"Invoked with args=%@ env=%@", [FBCollectionInformation oneLineDescriptionFromArray:NSProcessInfo.processInfo.arguments], EnvDescription()];
    NSError *error = nil;

    // Check that xcode-select returns a valid path
    [FBXcodeDirectory.xcodeSelectFromCommandLine.xcodePath await:&error];
    if (error) {
      [logger.error log:error.localizedDescription];
      return 1;
    }

    FBFuture<NSNumber *> *signalled = [FBFuture race:@[
      signalHandlerFuture(SIGINT, @"Signalled: SIGINT", logger),
      signalHandlerFuture(SIGTERM, @"Signalled: SIGTERM", logger),
    ]];
    FBFuture<NSNull *> *companionCompleted = [GetCompanionCompletedFuture(argc, argv, userDefaults, logger) await:&error];
    if (!companionCompleted) {
      [logger.error log:error.localizedDescription];
      return 1;
    }

    FBFuture<NSNull *> *completed = [FBFuture race:@[
      companionCompleted,
      signalled,
    ]];
    if (completed.error) {
      [logger.error log:completed.error.localizedDescription];
      return 1;
    }
    id result = [completed await:&error];
    if (!result) {
      [logger.error log:error.localizedDescription];
      return 1;
    }
    if (companionCompleted.state == FBFutureStateCancelled) {
      [logger logFormat:@"Responding to termination of idb with signo %@", result];
      FBFuture<NSNull *> *cancellation = [companionCompleted cancel];
      result = [cancellation await:&error];
      if (!result) {
        [logger.error log:error.localizedDescription];
        return 1;
      }
    }
  }
  return 0;
}
