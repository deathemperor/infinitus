import ExpoModulesCore

/// `InfinitusLoopbackCatch`: the phone answers the sign-in redirect itself.
///
/// `listen(port)` binds this phone's loopback on the port the CLI's `redirect_uri`
/// names and resolves once it is up — open the sign-in page only after that, or the
/// browser reaches a port nothing is on. `awaitRedirect()` resolves with the URL the
/// browser asked for, verbatim, or with null when `stop()` (a dismissed sheet) came
/// first. `stop()` gives the port back.
///
/// Every function runs on the main queue and the module's own state is touched
/// nowhere else; the listener hops its callbacks there.
public final class InfinitusLoopbackCatchModule: Module {
  private var listener: InfinitusLoopbackListener?
  private var caught: String?
  private var waiting: Promise?

  public func definition() -> ModuleDefinition {
    Name("InfinitusLoopbackCatch")

    AsyncFunction("listen") { (port: Int, promise: Promise) in
      guard let port = UInt16(exactly: port) else {
        promise.reject("ERR_LOOPBACK_PORT", "\(port) is not a port number.")
        return
      }
      self.release()
      let listener = InfinitusLoopbackListener(port: port) { [weak self] url in
        self?.deliver(url)
      }
      self.listener = listener
      listener.start { error in
        guard let error else {
          promise.resolve(nil)
          return
        }
        self.release()
        promise.reject("ERR_LOOPBACK_LISTEN", error.localizedDescription)
      }
    }.runOnQueue(.main)

    AsyncFunction("awaitRedirect") { (promise: Promise) in
      if let url = self.caught {
        self.caught = nil
        promise.resolve(url)
        return
      }
      // Only one waiter: a second call means the first flow was abandoned.
      self.waiting?.resolve(nil)
      self.waiting = nil
      guard self.listener != nil else {
        promise.resolve(nil)
        return
      }
      self.waiting = promise
    }.runOnQueue(.main)

    AsyncFunction("stop") { self.release() }.runOnQueue(.main)

    OnDestroy { self.release() }
  }

  /// The catch: hand it to whoever is waiting, or park it for the next `awaitRedirect`.
  /// The port is given back either way — one redirect is the whole job.
  private func deliver(_ url: String) {
    listener?.cancel()
    listener = nil
    if let promise = waiting {
      waiting = nil
      promise.resolve(url)
    } else {
      caught = url
    }
  }

  private func release() {
    listener?.cancel()
    listener = nil
    caught = nil
    let promise = waiting
    waiting = nil
    promise?.resolve(nil)
  }
}
