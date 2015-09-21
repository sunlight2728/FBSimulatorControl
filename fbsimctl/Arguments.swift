/**
* Copyright (c) 2015-present, Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD-style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*/

import Foundation

/**
  Defines a Format for displaying Simulator Information
  */
public enum SimulatorFormat {
  case UDID

  public static func format(simulator: FBSimulator)(format: SimulatorFormat) -> String {
    switch (format) {
      case SimulatorFormat.UDID: return simulator.udid
    }
  }

  public static func formatAll(format: [SimulatorFormat])(simulator: FBSimulator) -> String {
    return format
      .map(SimulatorFormat.format(simulator))
      .joinWithSeparator(" ")
  }

  public static func formatSimulators(format: [SimulatorFormat], simulators: [FBSimulator]) -> String {
    return simulators
      .map(SimulatorFormat.formatAll(format))
      .joinWithSeparator("\n")
  }

  public var asArguments: String {
    switch (self) {
    case .UDID: return "--format--udid"
    }
  }
}

/**
  Defines the pieces of a Query for Simulators
  */
public enum SimulatorQuery {
  case UDID(String)
  case Booted
  case Managed

  public func get(pool: FBSimulatorPool) -> NSPredicate {
    switch (self) {
      case .UDID(let udid):
        return FBSimulatorPredicates.onlyUDID(udid)
      case .Booted:
        return FBSimulatorPredicates.withState(.Booted)
      case .Managed:
        return FBSimulatorPredicates.managed()
    }
  }

  public static func perform(pool: FBSimulatorPool, query: [SimulatorQuery]) -> [FBSimulator] {
    return pool.allSimulators.filteredOrderedSetUsingPredicate(
      NSCompoundPredicate(andPredicateWithSubpredicates: query.map { $0.get(pool) } )
    ).array as! [FBSimulator]
  }

  public static func parse(args: ArraySlice<String>) -> ([String], SimulatorQuery)? {
    if (
    if (args.first! == "--booted") {
      return
    }
  }
}

/**
  The Base of all fbsimctl commands
  */
public enum Command {
  case List([SimulatorQuery], [SimulatorFormat])
  case Help

  public static func parseArguments(args: ArraySlice<String>) -> Command {
    if (args.isEmpty) {
      return .Help
    }

    return   ?: .Help
  }

  private static func parseArguments(args: [String]) -> Command {

  }

  public func run() -> Void {
    let application = try! FBSimulatorApplication(error: ())
    let config = FBSimulatorControlConfiguration(simulatorApplication: application, namePrefix: "E2E", bucket: 0, options: .DeleteOnFree)
    let control = FBSimulatorControl(configuration: config)

    switch (self) {
      case .Help:
        printHelp()
      case .List(let query, let format):
        let simulators = SimulatorQuery.perform(control.simulatorPool, query: query)
        print(SimulatorFormat.formatSimulators(format, simulators: simulators))
    }
  }

  private func printHelp() -> Void {
    let help = [Command.Help, Command.List([], [])]
      .map(Command.commandHelp)
      .joinWithSeparator("\n")
    print(help)
  }

  private static func commandHelp(command: Command) -> String {
    switch (command) {
      case .Help: return "Prints Help"
      case .List: return "Lists Simulators"
    }
  }

  private static func asString(command: Command) -> String {
    switch (command) {
      case .Help: return "help"
      case .List(_, _): return "list"
    }
  }
}
