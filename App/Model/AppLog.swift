import os

/// Where the app writes down what went wrong without the user being asked to do anything: work that is
/// retried, or that the machine goes on doing without.
nonisolated(unsafe) let appLog = Logger(subsystem: "com.virtualvm.app", category: "app")
