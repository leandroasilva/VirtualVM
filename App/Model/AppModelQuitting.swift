import VMCore

extension AppModel {
    // MARK: Quitting

    /// Quits for the command-line tool, a moment from now so that the tool gets its answer first. Call it
    /// only when no machine is running.
    ///
    /// From here on nothing starts, and further requests from the tool are turned down. That is what
    /// makes it safe to quit without the dialog that asks what to do with running machines: none can
    /// have come up between the check and the quit.
    func quitUnattended() {
        isQuittingUnattended = true
        library.allowsStarting = false
        unattendedQuitTimer = AppDelegate.terminate(after: 0.2)
    }

    /// Goes back to normal after a quit for the command-line tool was called off.
    func cancelUnattendedQuit() {
        isQuittingUnattended = false
        isClosingDown = false
        library.allowsStarting = true
        unattendedQuitTimer?.invalidate()
        unattendedQuitTimer = nil
    }
}
