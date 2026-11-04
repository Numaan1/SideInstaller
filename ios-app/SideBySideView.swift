import SwiftUI
import SideInstallerFFI

// MARK: - Steps

/// Steps of a Side by Side install, in run order.
///
/// Fewer than the Install tab's `Step`: the tunnel goes directly over Wi-Fi (no
/// VPN), and no pairing file is written afterwards since SideInstaller pairs
/// itself.
enum SideBySideStep: Int, CaseIterable, Identifiable {
    case connect, signIn, download, sign, install

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .connect:  return L("Pair with their iPhone")
        case .signIn:   return L("Sign in to their Apple ID")
        case .download: return L("Download SideInstaller")
        case .sign:     return L("Sign the app")
        case .install:  return L("Install on their iPhone")
        }
    }

    /// The download row when an app chosen here installs instead of
    /// SideInstaller's release; every other row says the same either way.
    func title(installingOwnIPA: Bool) -> String {
        if self == .download && installingOwnIPA {
            return L("Take the .ipa you chose")
        }
        return title
    }
}

/// What a Side by Side run puts on their iPhone.
enum SideBySideApp: Hashable {
    /// SideInstaller's own latest release: what makes their iPhone able to pair
    /// itself and renew from then on, so the default.
    case release
    /// An IPA picked on this page, installed instead.
    case chosen
}

// MARK: - Manager

/// Installs an app onto *another* iPhone on the same Wi-Fi network — by default
/// SideInstaller itself, or whichever IPA was chosen on the page.
///
/// Same flow as the Install tab, but over the LAN:
///
/// 1. **Pair.** With an IP address typed in, a record saved by an earlier run
///    goes first. Otherwise run the lockdown `Pair` handshake directly against
///    `<their IP>:62078`: their iPhone shows a Trust prompt and returns a
///    lockdown pair record, which CoreDeviceProxy (`tunnel_create_usb`) uses to
///    open the tunnel. iOS 27's lockdownd won't pair over Wi-Fi — it resets the
///    connection at the first request, before any Trust prompt — so when
///    lockdownd answers but won't pair, their iPhone pairs from its own
///    Settings instead (Remote Pairing): this iPhone advertises a pairing host,
///    they pick it under Developer Mode and type the code shown here, and the
///    RPPairing file that produces opens the tunnel
///    (`tunnel_create_rppairing`). With no address typed in, the run goes
///    straight to Remote Pairing, and their iPhone is reached at the address
///    it connected from.
/// 2. **Sign in, sign, install** as in the one-click flow, using the credentials
///    entered on this page and the target's UDID.
///
/// Credentials are kept in memory only, never saved to `AccountStore` or the
/// keychain. Pair records with their iPhone are forgotten once the app is on
/// it, or on Clear.
final class SideBySideManager: ObservableObject {

    /// Unsigned IPA from SideInstaller's latest GitHub release.
    static let releaseIPA = URL(string:
        "https://github.com/FrizzleM/SideInstaller/releases/latest/download/SideInstaller.ipa")!

    /// What the release asset is called, and what the download is saved as.
    static let ipaFileName = "SideInstaller.ipa"

    /// Where an IPA chosen for their iPhone is staged. Kept apart from the
    /// Install tab's Custom .ipa so neither run overwrites the other's file.
    static let chosenIPAStaging = IPALibrary.peerDir

    // MARK: Inputs

    /// The other iPhone's address on this Wi-Fi network. Optional: pairing from
    /// their Settings reports it, and fills it in so a retry finds the record.
    @Published var targetIP = ""
    /// The Apple ID the app is signed with. Never persisted — see the note above.
    @Published var appleID = ""
    @Published var password = ""
    /// SideInstaller's release, or the IPA chosen below.
    @Published var app: SideBySideApp = .release
    /// A link to an `.ipa`, staged as the pick by the link field's download
    /// button. Emptied once the file is in.
    @Published var chosenIPALink = ""

    // MARK: State

    @Published private(set) var stepStates: [SideBySideStep: StepState] = Dictionary(
        uniqueKeysWithValues: SideBySideStep.allCases.map { ($0, .pending) })
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false
    /// The far device's name and iOS version, once the link is open.
    @Published private(set) var targetSummary: String?
    /// How much of the download has arrived (0…1), while that step is running.
    @Published private(set) var downloadProgress: Double = 0
    /// Home-screen name of what landed on their iPhone.
    @Published private(set) var installedAppName: String?
    /// The IPA chosen to install instead of the release, once it's staged.
    @Published private(set) var chosenIPAName: String?
    /// Its size in bytes, shown under the name.
    @Published private(set) var chosenIPASize: Int = 0
    /// True while a picked file is copied in, or a linked one downloads.
    @Published private(set) var isFetchingIPA = false
    /// How much of a linked download has arrived (0…1); nil for a file copy,
    /// which reports no fraction.
    @Published private(set) var chosenIPAProgress: Double?
    /// True while their iPhone has to pair from its own Settings, which it
    /// never prompts for by itself.
    @Published private(set) var pairingInSettings = false
    /// The code to type into their iPhone, once it has asked for one.
    @Published private(set) var pairingPIN: String?
    @Published var lastError: String?
    /// True from a finished run until its popup is closed.
    @Published private(set) var showsSuccess = false
    /// True while a pair record with someone else's iPhone is saved here.
    @Published private(set) var remembersTheirIPhone = PrivateStore.hasPeerPairings

    private var task: Task<Void, Never>?

    /// This tool's own link, so a run here never disturbs the Install tab's
    /// connection to the loopback tunnel (or the other way round).
    private let connection = DeviceConnection()
    private let deviceQueue = DispatchQueue(label: "sideinstaller.sidebyside.device")
    private let signQueue = DispatchQueue(label: "sideinstaller.sidebyside.sign")

    private var signSession: OpaquePointer?          // SignSession*
    /// The Apple ID `signSession` belongs to, so editing the field signs out.
    private var signedInAs: String?
    /// Where the pair record for the current target lives: a lockdown record,
    /// or an RPPairing file from Remote Pairing.
    private var pairRecordPath: String?
    /// The downloaded IPA, kept between runs so a retry after a signing failure
    /// doesn't fetch it again. Its staging directory is ours to delete.
    private var downloadedIPA: URL?
    /// The IPA chosen for their iPhone, staged under `Self.chosenIPAStaging` so
    /// it survives a retry, and a relaunch of the app.
    private var chosenIPA: URL?
    private var signedAppPath: String?
    private var targetUDID: String?
    private var targetName: String?
    /// True once the Local Network prompt has been raised, so it asks once.
    private var askedLocalNetwork = false

    private var engine: Engine { Engine.shared }

    init() {
        reloadChosenIPA()
    }

    deinit {
        if let signSession { si_sign_session_free(signSession) }
        connection.disconnect()
        discardDownload()
    }

    // MARK: - Derived

    /// True when there is enough on the page to start a run. The address is
    /// optional; see `targetIP`. A chosen IPA has to be on disk, not just asked
    /// for.
    var canRun: Bool {
        !Self.tidy(appleID).isEmpty && !password.isEmpty && (app == .release || chosenIPA != nil)
    }

    /// This iPhone's Wi-Fi address, shown as an example of what theirs looks like.
    var ownWiFiAddress: String? {
        NetworkStatus.interfaces().first { $0.name == "en0" }?.ipv4
    }

    /// Fraction across all five steps, for the progress bar. The download and
    /// install steps also fill their own share as they go.
    var overallProgress: Double {
        let total = Double(SideBySideStep.allCases.count)
        let done = Double(SideBySideStep.allCases.filter { stepStates[$0] == .done }.count)
        var partial = 0.0
        if stepStates[.download] == .active { partial = downloadProgress }
        if stepStates[.install] == .active { partial = engine.installProgress }
        return min(1, (done + partial) / total)
    }

    // MARK: - Popups

    /// One of this page's popups; they stack in this order. Each carries what
    /// it shows, so it keeps its content while it closes.
    enum Popup: Hashable {
        /// The code their iPhone asks for while it pairs.
        case pairingCode(String)
        /// How to pair from their iPhone's Settings.
        case pairInSettings
        case error(String)
        /// The app is on their iPhone, named.
        case success(String)
    }

    /// True while the run waits for their iPhone to pair from its Settings,
    /// whose steps and code it can't go on without.
    var isWaitingOnUser: Bool {
        isRunning && (pairingInSettings || pairingPIN != nil)
    }

    /// The popups up now, top to bottom.
    var popups: [Popup] {
        var shown: [Popup] = []
        if let pairingPIN { shown.append(.pairingCode(pairingPIN)) }
        if pairingInSettings { shown.append(.pairInSettings) }
        if let lastError { shown.append(.error(lastError)) }
        if showsSuccess { shown.append(.success(installedAppName ?? "SideInstaller")) }
        return shown
    }

    /// True for a popup the run is waiting on: closing it stops the run.
    func blocks(_ popup: Popup) -> Bool {
        switch popup {
        case .pairingCode, .pairInSettings: return isWaitingOnUser
        case .error, .success:              return false
        }
    }

    /// Closes one popup. The run can't go on without the pairing steps or the
    /// code, so closing either stops it, and both go.
    @MainActor
    func closePopup(_ popup: Popup) {
        if blocks(popup) {
            cancel()
            // Gone now, not once the cancelled wait has unwound.
            pairingInSettings = false
            pairingPIN = nil
            return
        }
        switch popup {
        case .error:          lastError = nil
        case .success:        showsSuccess = false
        // The steps hang under the code and close with it.
        case .pairingCode:    pairingPIN = nil; pairingInSettings = false
        case .pairInSettings: pairingInSettings = false
        }
    }

    // MARK: - The run

    @MainActor
    func run() {
        guard !isRunning else { return }
        let typed = Self.tidy(targetIP)
        let ip = typed.isEmpty ? nil : typed
        let id = Self.tidy(appleID)
        let pw = password

        if let ip {
            guard Self.isIPv4(ip) else {
                lastError = ErrorHelp.explained(L("“%@” isn't an IPv4 address. It should look like 192.168.1.42.", ip))
                return
            }
            // Pointed at this iPhone, the whole run would talk to itself.
            guard !NetworkStatus.isOwnAddress(ip) else {
                lastError = ErrorHelp.explained(L("%@ is an address this iPhone already holds. Side by Side installs onto someone else's iPhone — use theirs. To install on this one, use the Install tab.", ip))
                return
            }
        }
        guard !id.isEmpty, !pw.isEmpty else {
            lastError = ErrorHelp.explained(L("Enter the Apple ID to sign with, and its password."))
            return
        }
        engine.refreshNetworkStatus()
        guard engine.wifiConnected else {
            lastError = ErrorHelp.explained(L("Wi-Fi is off. Both iPhones have to be on the same Wi-Fi network for this to work."))
            return
        }

        // A different Apple ID than the session was opened with invalidates it.
        if let signedInAs, signedInAs.caseInsensitiveCompare(id) != .orderedSame {
            signOut()
        }

        reset()
        isRunning = true
        engine.log("=== Side by Side: installing onto \(ip ?? "the iPhone that pairs from its Settings") ===")

        task = Task { @MainActor in
            do {
                await ensureLocalNetwork()
                let address = try await connectToTarget(typedIP: ip)
                try await signIn(id: id, pw: pw)
                try await download()
                try await signApp()
                try await install(ip: address)
                finishSuccess()
            } catch is CancellationError {
                engine.log("Side by Side: cancelled.")
                failActiveStep(to: .pending)
            } catch {
                let message = short(error)
                lastError = message
                engine.log("⛔️ Side by Side stopped: \(message)")
                failActiveStep(to: .failed)
            }
            remembersTheirIPhone = PrivateStore.hasPeerPairings
            isRunning = false
        }
    }

    /// Cancels the run at the next step boundary. Blocking FFI calls (e.g.
    /// waiting on the Trust prompt) can't be interrupted, so it takes effect once
    /// the current call returns. Waiting for them to pair from Settings stops
    /// straight away.
    @MainActor
    func cancel() {
        task?.cancel()
    }

    /// Frees the Apple ID session so the next run signs in again. Called when
    /// the Apple ID changes and by Clear, so another person's session isn't kept.
    ///
    /// Not main-actor isolated: the work runs on `signQueue`, and the session
    /// pointer isn't `Sendable`.
    func signOut() {
        signedInAs = nil
        // Freed on `signQueue`, which owns `signSession`. It's serial, so this
        // can't race the next sign-in.
        signQueue.async { [weak self] in
            guard let self, let session = self.signSession else { return }
            si_sign_session_free(session)
            self.signSession = nil
        }
    }

    /// Closes the link to their iPhone and deletes every pair record saved with
    /// someone else's, so this iPhone can't reach theirs again without pairing
    /// anew. Their address goes too: it was kept to find those records.
    @MainActor
    private func forgetTheirIPhone() {
        disconnectTheirIPhone()
        PrivateStore.forgetPeerPairings()
        pairRecordPath = nil
        targetIP = ""
        remembersTheirIPhone = false
    }

    /// Closes the link to their iPhone on `deviceQueue`, which owns the
    /// connection.
    ///
    /// Not main-actor isolated, like `signOut`: the queued closure holds
    /// `self`, which isn't `Sendable`, and only reads `connection`, a `let`.
    private func disconnectTheirIPhone() {
        deviceQueue.async { [weak self] in self?.connection.disconnect() }
    }

    /// Clear the page back to how it opened, credentials and pairings included.
    @MainActor
    func clear() {
        guard !isRunning else { return }
        signOut()
        forgetTheirIPhone()
        discardDownload()
        signedAppPath = nil
        targetUDID = nil
        targetName = nil
        targetSummary = nil
        installedAppName = nil
        appleID = ""
        password = ""
        reset()
    }

    @MainActor
    private func reset() {
        for step in SideBySideStep.allCases { stepStates[step] = .pending }
        downloadProgress = 0
        lastError = nil
        finished = false
        showsSuccess = false
        pairingInSettings = false
        pairingPIN = nil
    }

    @MainActor
    private func setStep(_ step: SideBySideStep, _ state: StepState) {
        stepStates[step] = state
    }

    @MainActor
    private func failActiveStep(to state: StepState) {
        for step in SideBySideStep.allCases
        where stepStates[step] == .active || stepStates[step] == .waiting {
            stepStates[step] = state
        }
    }

    @MainActor
    private func finishSuccess() {
        finished = true
        showsSuccess = true
        let name = installedAppName ?? "SideInstaller"
        engine.log("✅ Side by Side done — \(name) is on their iPhone. One trust step left, on their side.")
        // It pairs itself from there, so this iPhone has no more use for theirs.
        forgetTheirIPhone()
        engine.log("Side by Side: forgot the pairing with their iPhone.")
    }

    // MARK: - Step 0: Local Network permission

    /// Triggers the Local Network prompt before the first connect. iOS silently
    /// blocks local-network connections until it's granted.
    @MainActor
    private func ensureLocalNetwork() async {
        guard !askedLocalNetwork else { return }
        askedLocalNetwork = true
        engine.log("Checking Local Network permission — reaching their iPhone needs it…")
        let localNetwork = LocalNetworkAuthorization()
        if await localNetwork.request(timeout: 8) {
            engine.log("Local Network OK.")
        } else {
            engine.log("⚠️ Local Network didn't confirm. If nothing connects, turn it on in Settings › SideInstaller › Local Network.")
        }
    }

    // MARK: - Step 1: pair with the target and open the link

    /// Opens the link to their iPhone, and returns the address it's reached at:
    /// the one typed in, or the one it paired from.
    @MainActor
    private func connectToTarget(typedIP: String?) async throws -> String {
        try Task.checkCancellation()
        setStep(.connect, .waiting)
        // With no address there's no saved record to find and no lockdownd to
        // ask, so their iPhone pairs from its Settings.
        var outcome = ConnectOutcome.needsRemotePairing
        if let typedIP {
            outcome = try await onDeviceQueue { try self.performConnect(ip: typedIP) }
        }
        let target: ConnectedTarget
        switch outcome {
        case let .connected(connected):
            target = connected
        case .needsRemotePairing:
            target = try await connectByRemotePairing(typedIP: typedIP)
        }
        targetSummary = target.summary
        targetUDID = target.udid
        targetName = target.name
        // Filled in so a retry finds the record saved for it.
        targetIP = target.address
        remembersTheirIPhone = true
        setStep(.connect, .done)
        return target.address
    }

    private struct ConnectedTarget {
        let summary: String
        let udid: String?
        let name: String?
        let address: String
    }

    /// How far connecting got without their iPhone's Settings.
    private enum ConnectOutcome {
        case connected(ConnectedTarget)
        /// lockdownd answered but won't pair over Wi-Fi, so their iPhone has to
        /// pair from its own Settings.
        case needsRemotePairing
    }

    /// Opens the link with a record saved by an earlier run, or by pairing over
    /// lockdown. Runs on `deviceQueue`.
    private func performConnect(ip: String) throws -> ConnectOutcome {
        // Records saved by an earlier run first: pairing needs them at their
        // iPhone, and uses one of its pairing slots.
        if try connectWithSavedRecord(PrivateStore.peerRemotePairing(host: ip), ip: ip) {
            return .connected(try describeTarget(ip: ip))
        }
        let record = PrivateStore.peerPairRecord(host: ip)
        if try connectWithSavedRecord(record, ip: ip) {
            return .connected(try describeTarget(ip: ip))
        }

        engine.log("Asking \(ip) to pair — their iPhone has to be unlocked, and they have to tap Trust …")
        let data: Data
        do {
            data = try connection.lockdownPairRecordDirect(
                hosts: [ip],
                hostID: CompositePairingFile.hostID,
                systemBUID: CompositePairingFile.systemBUID,
                hostName: "SideInstaller")
        } catch let error as DeviceConnection.LockdownPairError {
            if error.userDeclined {
                throw EngineError.message(L("They tapped “Don't Trust” on their iPhone. Start again, and have them tap Trust."))
            }
            // No answer at all is the address or the network, which pairing
            // another way can't get past. A refusal comes from their iPhone:
            // it's there, and lockdownd just isn't listening on Wi-Fi.
            if error.stage == .connect, !DeviceConnection.wasRefused(error.underlying) {
                throw EngineError.message(Self.unreachableAdvice(ip: ip))
            }
            engine.log("lockdownd on \(ip) won't pair over Wi-Fi (\(error)) — iOS 27 only pairs over a network from its own Settings. Switching to Remote Pairing.")
            return .needsRemotePairing
        }
        try data.write(to: record, options: .atomic)
        engine.log("Paired with \(ip) (\(data.count)-byte record). Opening the tunnel over CoreDeviceProxy …")
        try connection.connect(deviceIP: ip, pairingFilePath: record.path, allowLockdownMinting: false)
        pairRecordPath = record.path
        return .connected(try describeTarget(ip: ip))
    }

    /// Opens the link with `record`, saved by an earlier run. False when there
    /// is none, or it didn't open a link and pairing again might.
    private func connectWithSavedRecord(_ record: URL, ip: String) throws -> Bool {
        guard fileSize(record.path) > 0 else { return false }
        engine.log("Trying the pair record already saved for \(ip) (\(record.lastPathComponent)) …")
        do {
            try connection.connect(deviceIP: ip, pairingFilePath: record.path, allowLockdownMinting: false)
        } catch let error as DeviceConnection.TunnelError where !error.repairingCouldHelp {
            // The link never reached their iPhone, so pairing again won't either.
            throw EngineError.message(Self.tunnelAdvice(error, ip: ip))
        } catch {
            engine.log("That record didn't open a link (\(error)). Pairing again…")
            return false
        }
        pairRecordPath = record.path
        return true
    }

    /// Has their iPhone pair from its own Settings — the way iOS 27 pairs over
    /// a network — then opens the link with the RPPairing file that produces,
    /// at the address their iPhone connected from. That's where it is, even if
    /// a different address was typed in.
    @MainActor
    private func connectByRemotePairing(typedIP: String?) async throws -> ConnectedTarget {
        let pairingFile: URL
        if let typedIP {
            pairingFile = PrivateStore.peerRemotePairing(host: typedIP)
        } else {
            pairingFile = PrivateStore.unaddressedPeerRemotePairing
            // A leftover would lend this pairing its keys.
            try? FileManager.default.removeItem(at: pairingFile)
        }
        let paired = try await pairFromSettings(record: pairingFile)
        let ip = paired.address
        // Their own Settings lists this iPhone's host too.
        guard !NetworkStatus.isOwnAddress(ip) else {
            try? FileManager.default.removeItem(atPath: paired.path)
            throw EngineError.message(L("The iPhone that paired was this one. Pair from their iPhone's Settings instead. To install on this iPhone, use the Install tab."))
        }
        if let typedIP, typedIP != ip {
            engine.log("Their iPhone paired from \(ip), not \(typedIP) — reaching it there.")
        }
        // Filed under the address it's reached at, where a retry looks for it.
        let recordPath = Self.move(paired.path, to: PrivateStore.peerRemotePairing(host: ip).path)
        setStep(.connect, .active)
        engine.log("Paired with their \(paired.deviceModel) at \(ip). Opening the tunnel over Remote Pairing …")
        return try await onDeviceQueue {
            do {
                try self.connection.connect(deviceIP: ip, pairingFilePath: recordPath,
                                            allowLockdownMinting: false)
            } catch let error as DeviceConnection.TunnelError {
                throw EngineError.message(Self.tunnelAdvice(error, ip: ip))
            }
            self.pairRecordPath = recordPath
            return try self.describeTarget(ip: ip)
        }
    }

    /// Advertises this iPhone as a pairing host and waits until their iPhone
    /// has paired with it from Settings, showing the code it asks for. The
    /// instructions stay up until then; Cancel stops the wait.
    @MainActor
    private func pairFromSettings(record: URL) async throws -> PairingController.PairedDevice {
        try Task.checkCancellation()
        pairingInSettings = true
        defer {
            pairingInSettings = false
            pairingPIN = nil
        }
        engine.log("Waiting for them to pair: on their iPhone, Settings › Privacy & Security › Developer Mode › “Pair with \(PairingController.peerHostName)”, then the code shown here.")
        do {
            return try await withTaskCancellationHandler {
                try await PairingController.shared.pairPeer(outPath: record.path) { [weak self] pin in
                    self?.pairingPIN = pin
                }
            } onCancel: {
                Task { @MainActor in PairingController.shared.cancelPeer() }
            }
        } catch PairingController.PairingError.busy {
            throw EngineError.message(L("SideInstaller is already waiting for an iPhone to pair with it — from the Install tab, the Pairing page, or an earlier attempt here. Finish that pairing, or close and reopen SideInstaller, then try again."))
        } catch let PairingController.PairingError.failed(message) {
            throw EngineError.message(L("Pairing with their iPhone didn't finish: %@", message))
        }
    }

    /// Their iPhone's name, iOS version and UDID, read over the open link.
    private func describeTarget(ip: String) throws -> ConnectedTarget {
        engine.log("Tunnel + RSD handshake established with \(ip).")
        engine.log(try connection.rsdSummary())

        var values: [String: String] = [:]
        let info = try connection.deviceInfo()
        if info.isEmpty {
            engine.log("Device info: (lockdownd returned no values)")
        } else {
            engine.log("Device info:")
            for (key, value) in info { values[key] = value; engine.log("  \(key) = \(value)") }
        }
        let name = values["DeviceName"] ?? L("device")
        let summary = values["ProductVersion"].map { "\(name) · iOS \($0)" } ?? name
        return ConnectedTarget(summary: summary,
                               udid: values["UniqueDeviceID"],
                               name: values["DeviceName"],
                               address: ip)
    }

    /// What to say when the Remote Pairing tunnel to their iPhone didn't come
    /// up. The error's own advice is about the Install tab's loopback VPN,
    /// which Side by Side doesn't use.
    private static func tunnelAdvice(_ error: DeviceConnection.TunnelError, ip: String) -> String {
        switch error.kind {
        case TunnelFailureRsdUnreachable where DeviceConnection.wasRefused(error.underlying):
            return L("Their iPhone at %@ refused the connection. It only accepts one while Developer Mode is on, and iOS asks to confirm Developer Mode again after every restart: on their iPhone, turn it on under Settings › Privacy & Security › Developer Mode, then try again.", ip)
        case TunnelFailureRsdUnreachable:
            return unreachableAdvice(ip: ip)
        default:
            return L("The link to their iPhone didn't come up: %@", error.underlying.description)
        }
    }

    private static func unreachableAdvice(ip: String) -> String {
        L("Couldn't reach their iPhone at %@. Check the address (Settings › Wi-Fi › ⓘ on their iPhone), that both iPhones are on the same Wi-Fi network, and that Local Network is on for SideInstaller in this iPhone's Settings. Guest and public networks often keep devices from reaching each other.", ip)
    }

    // MARK: - Step 2: Apple ID sign-in

    @MainActor
    private func signIn(id: String, pw: String) async throws {
        if signSession != nil, signedInAs?.caseInsensitiveCompare(id) == .orderedSame {
            engine.log("Already signed in as \(LogRedactor.maskAppleID(id)) — skipping.")
            setStep(.signIn, .done)
            return
        }
        setStep(.signIn, .active)

        // Anisette servers go down often, so with Auto on try each one before
        // giving up. A server picked in Settings is the only one tried.
        let servers = anisetteCandidates()
        let dir = PrivateStore.isideload.path
        engine.twoFactorWasCancelled = false
        var failures = AnisetteServer.SignInFailures()
        var appleRefusals = AnisetteServer.AppleRefusals(servers: engine.anisetteServers)
        var appleUnreachable = 0

        for (index, anisette) in servers.enumerated() {
            try Task.checkCancellation()
            if appleRefusals.rulesOut(anisette) {
                engine.log("Side by Side: skipping anisette \(index + 1)/\(servers.count): Apple has refused the device sign-in reports through it.")
                failures.skip()
                continue
            }
            do {
                let summary = try await onSignQueue {
                    try self.performSignIn(id: id, pw: pw, anisette: anisette, dir: dir)
                }
                engine.anisetteSignedIn(anisette)
                signedInAs = id
                engine.log("Side by Side: signed in (\(summary)).")
                setStep(.signIn, .done)
                return
            } catch let error as EngineError {
                let failure = error.errorDescription ?? "sign-in failed"
                // A cancelled 2FA prompt isn't the server's fault.
                if engine.twoFactorWasCancelled {
                    throw EngineError.message(L("Two-factor verification was cancelled."))
                }
                // A locked account fails everywhere, and retrying keeps it locked.
                if Engine.isAccountLocked(failure) {
                    engine.log("Apple has locked this Apple Account: \(failure)")
                    throw EngineError.accountLocked
                }
                if Engine.isEmailUnverifiedError(failure) {
                    engine.log("Apple wants this Apple Account's email address verified first: \(failure)")
                    throw EngineError.emailUnverified
                }
                // Bad credentials fail everywhere, and retrying risks a lockout.
                if Engine.isCredentialError(failure) {
                    engine.log("Apple ID credentials rejected: \(failure)")
                    throw EngineError.message(Engine.credentialErrorMessage)
                }
                // Not logged in through an Android-ADI server (-80046).
                if Engine.isAndroidADISkip(failure) {
                    engine.log("Side by Side: skipping anisette \(index + 1)/\(servers.count): Apple refuses the sign-in token for anisette from its Android library (-80046).")
                    appleRefusals.recordTokenRefusal(anisette)
                    failures.skip()
                    if failures.tried == 0, appleRefusals.rulesOutAll(servers[(index + 1)...]) {
                        throw EngineError.message(engine.androidADIRefusalMessage(server: anisette))
                    }
                    continue
                }
                engine.log("Side by Side: anisette \(index + 1)/\(servers.count) failed: \(failure)")
                failures.failed(anisette, error: failure)
                engine.anisetteFailed(anisette, error: failure)
                if Engine.isAppleRateLimit(failure) {
                    engine.log("Side by Side: Apple is rate-limiting sign-in (HTTP 429) — stopping.")
                    throw EngineError.message(Engine.appleRateLimitMessage)
                }
                // Apple refuses a reported device through every server alike;
                // see `AnisetteServer.AppleRefusals`.
                if Engine.isAppleOutdatedMacRefusal(failure) {
                    appleRefusals.recordOutdated(anisette)
                }
                if Engine.isAppleTokenRefusal(failure) {
                    appleRefusals.recordTokenRefusal(anisette)
                    if appleRefusals.rulesOutAll(servers[(index + 1)...]) {
                        engine.log("Side by Side: Apple refused the sign-in token (-80046) — stopping.")
                        throw EngineError.message(engine.appleTokenRefusalMessage(through: anisette))
                    }
                }
                if Engine.isAppleServiceRefusal(failure) {
                    appleRefusals.record(anisette)
                    if appleRefusals.endsSignIn(remaining: servers[(index + 1)...]) {
                        engine.log("Side by Side: Apple's sign-in server refused \(appleRefusals.count) attempts with HTTP 503 — stopping.")
                        throw EngineError.message(Engine.appleServiceRefusalMessage)
                    }
                }
                // Every anisette server starts with the same request to Apple, so
                // when that can't even be sent, more of them won't help.
                if Engine.isAppleUnreachable(failure) {
                    appleUnreachable += 1
                    if let message = await engine.appleUnreachableStop(
                        failures: appleUnreachable, logPrefix: "Side by Side: ") {
                        throw EngineError.message(message)
                    }
                } else {
                    appleUnreachable = 0
                }
            }
        }
        throw EngineError.message(engine.anisetteSignInFailure(failures))
    }

    /// One sign-in attempt against a specific anisette server. Uses the machine
    /// name `SideInstaller`, so an existing certificate is recognized as reusable.
    private func performSignIn(id: String, pw: String, anisette: String, dir: String) throws -> String {
        defer { engine.endTwoFactor() }
        engine.log("Apple ID sign-in for \(LogRedactor.maskAppleID(id)) via anisette \(Engine.oneLine(anisette)) …")
        var session: OpaquePointer?
        var summary: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        // 0 = don't save the session: it's someone else's Apple ID.
        let rc = si_apple_signin(id, pw, anisette, "SideInstaller", dir, 0,
                                 sideBySideTwoFactorCallback, nil,
                                 &session, &summary, &error)
        if rc == 0 {
            if let old = signSession { si_sign_session_free(old) }
            signSession = session
            let text = summary.map { String(cString: $0) } ?? ""
            summary.map { si_string_free($0) }
            return text
        } else {
            let message = error.map { String(cString: $0) } ?? "rc=\(rc)"
            error.map { si_string_free($0) }
            throw EngineError.message(message)
        }
    }

    // MARK: - The IPA to install

    /// Re-read the staged IPA from disk, so a pick survives a relaunch.
    private func reloadChosenIPA() {
        guard let entry = IPALibrary.imported(in: Self.chosenIPAStaging),
              IPALibrary.looksLikeIPA(entry.url) else { return }
        chosenIPA = entry.url
        chosenIPAName = entry.url.lastPathComponent
        chosenIPASize = entry.size
    }

    /// Stage a `.ipa` picked from Files as the app to install, replacing the
    /// previous pick.
    @MainActor
    func chooseIPA(from url: URL) async {
        guard !isFetchingIPA else { return }
        isFetchingIPA = true
        chosenIPAProgress = nil
        // Delete the picker's temporary copy once the import is done.
        defer { isFetchingIPA = false; Engine.discardInboxCopy(url) }
        do {
            let dest = try await Engine.copyImport(from: url, into: Self.chosenIPAStaging)
            showChosenIPA(dest)
            engine.log("Side by Side: will install \(dest.lastPathComponent) on their iPhone.")
        } catch IPALibrary.ImportError.notAnIPA {
            // Validation runs on a staged copy, so the previous pick survives.
            reloadChosenIPA()
            lastError = ErrorHelp.explained(L("%@ isn't an IPA. Pick the .ipa file itself — if it looks right, the download may have saved an error page instead, or stopped partway.",
                                              url.lastPathComponent))
            engine.log("⛔️ Side by Side import: \(lastError ?? "")")
        } catch is CancellationError {
            reloadChosenIPA()
            engine.log("Side by Side import cancelled.")
        } catch {
            reloadChosenIPA()
            lastError = L("Couldn't import %@: %@", url.lastPathComponent, error.localizedDescription)
            engine.log("⛔️ Side by Side import: \(lastError ?? "")")
        }
    }

    /// Download the `.ipa` in `chosenIPALink` and stage it as the app to
    /// install. True once it's in.
    @MainActor
    @discardableResult
    func chooseIPAFromLink() async -> Bool {
        guard !isFetchingIPA else { return false }
        guard let link = Engine.downloadLink(chosenIPALink) else {
            lastError = ErrorHelp.explained(L("That isn't a link SideInstaller can download. Paste the whole https:// address the .ipa downloads from."))
            engine.log("⛔️ Side by Side import: \(lastError ?? "")")
            return false
        }
        isFetchingIPA = true
        chosenIPAProgress = 0
        defer { isFetchingIPA = false; chosenIPAProgress = nil }
        do {
            let downloaded = try await SideStoreDownloader.fetchDirect(
                link, named: Engine.importFileName(for: link)) { fraction in
                    Task { @MainActor in self.chosenIPAProgress = fraction }
                }
            // The download lives in its own staging directory; remove all of it.
            defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
            let dest = try await Engine.copyImport(from: downloaded, into: Self.chosenIPAStaging)
            showChosenIPA(dest)
            chosenIPALink = ""
            engine.log("Side by Side: will install \(dest.lastPathComponent) on their iPhone.")
            return true
        } catch IPALibrary.ImportError.notAnIPA {
            lastError = ErrorHelp.explained(L("That link didn't return an IPA. It has to download the file itself — a page that only links to the .ipa, or one that asks you to sign in first, arrives here as a web page."))
            engine.log("⛔️ Side by Side import: \(lastError ?? "")")
        } catch is CancellationError {
            reloadChosenIPA()
            engine.log("Side by Side import cancelled.")
        } catch {
            lastError = L("Couldn't download that link: %@", short(error))
            engine.log("⛔️ Side by Side import: \(lastError ?? "")")
        }
        return false
    }

    /// Stop installing the chosen IPA and delete the file it staged. The Install
    /// tab's Custom .ipa is a different file, and stays.
    @MainActor
    func forgetChosenIPA() {
        guard !isRunning, let file = chosenIPA else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        chosenIPA = nil
        chosenIPAName = nil
        chosenIPASize = 0
        app = .release
        engine.log("Side by Side: forgot \(file.lastPathComponent).")
    }

    /// Show a freshly staged IPA as the pick, with its size.
    @MainActor
    private func showChosenIPA(_ url: URL) {
        chosenIPA = url
        chosenIPAName = url.lastPathComponent
        chosenIPASize = fileSize(url.path)
    }

    // MARK: - Step 3: fetch the release build

    @MainActor
    private func download() async throws {
        try Task.checkCancellation()
        guard app == .release else { return try useChosenIPA() }
        if let existing = downloadedIPA, FileManager.default.fileExists(atPath: existing.path) {
            engine.log("SideInstaller IPA already downloaded — skipping.")
            setStep(.download, .done)
            return
        }
        setStep(.download, .active)
        downloadProgress = 0
        engine.log("Fetching the latest SideInstaller release from \(Self.releaseIPA.absoluteString) …")
        do {
            let file = try await SideStoreDownloader.fetchDirect(
                Self.releaseIPA, named: Self.ipaFileName) { fraction in
                    Task { @MainActor in self.downloadProgress = fraction }
                }
            // Validate now, so an error page or truncated download doesn't fail
            // later during signing.
            guard IPALibrary.looksLikeIPA(file) else {
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                throw EngineError.message(L("The release download wasn't an IPA. GitHub may be returning an error page — try again in a minute."))
            }
            downloadedIPA = file
            downloadProgress = 1
            engine.log("SideInstaller IPA ready at \(file.path) (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize(file.path)), countStyle: .file))).")
            setStep(.download, .done)
        } catch let error as SideStoreDownloader.DownloadError {
            throw EngineError.message(L("Couldn't download the latest SideInstaller release: %@", error.description))
        }
    }

    /// Take the IPA chosen on the page as the download step's result. It's
    /// already on this iPhone, so nothing is fetched.
    @MainActor
    private func useChosenIPA() throws {
        setStep(.download, .active)
        guard let ipa = chosenIPA, IPALibrary.looksLikeIPA(ipa) else {
            throw EngineError.message(L("Choose the .ipa to install first, or pick SideInstaller's release instead."))
        }
        downloadProgress = 1
        engine.log("Installing \(ipa.lastPathComponent) on their iPhone — it's already here, so nothing downloads.")
        setStep(.download, .done)
    }

    /// Delete the downloaded IPA and the staging directory it lives in.
    private func discardDownload() {
        guard let file = downloadedIPA else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        downloadedIPA = nil
    }

    // MARK: - Step 4: sign for their device

    @MainActor
    private func signApp() async throws {
        try Task.checkCancellation()
        guard let session = signSession else { throw EngineError.message(L("Not signed in.")) }
        let ipa: URL
        switch app {
        case .release:
            guard let file = downloadedIPA else { throw EngineError.message(L("No SideInstaller IPA downloaded.")) }
            ipa = file
        case .chosen:
            guard let file = chosenIPA else { throw EngineError.message(L("No .ipa chosen to install.")) }
            ipa = file
        }
        // Their UDID is registered with the team before the profile is asked
        // for, or Apple refuses it with error 8220.
        let udid = targetUDID ?? ""
        let name = targetName ?? ""
        if udid.isEmpty {
            engine.log("⚠️ No UDID captured from their iPhone — signing may fail with error 8220.")
        }
        // SideInstaller wants neither more memory nor a bundled pairing file. An
        // app chosen here is signed the way the Install tab signs it: Increased
        // Memory Limit where Apple allows it, required for Madeira, which renews
        // its own profile and so gets no app group.
        let forMadeira = app == .chosen && Self.isMadeira(ipa)
        let memoryLimit: Int32 = app == .release ? 0 : (forMadeira ? 1 : 2)
        let appGroup: Int32 = forMadeira ? 0 : 1
        setStep(.sign, .active)
        let path = try await onSignQueue {
            try self.performSign(session: session, ipa: ipa.path, udid: udid, deviceName: name,
                                 memoryLimit: memoryLimit, appGroup: appGroup)
        }
        signedAppPath = path
        installedAppName = Self.displayName(ofBundleAt: path) ?? ipa.deletingPathExtension().lastPathComponent
        setStep(.sign, .done)
    }

    /// True when the IPA at `url` is Madeira, told by its bundle id.
    private static func isMadeira(_ url: URL) -> Bool {
        IPALibrary.appInfo(at: url).map { MadeiraPairingHandoff.isMadeira(bundleID: $0.bundleID) } ?? false
    }

    private func performSign(session: OpaquePointer, ipa: String,
                             udid: String, deviceName: String,
                             memoryLimit: Int32, appGroup: Int32) throws -> String {
        engine.log("Signing \(ipa) for \(udid.isEmpty ? "their iPhone" : udid) …")
        var signed: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        // No pairing file is bundled for Remote AltServer: it would be this
        // iPhone's own record, not one for their device.
        let rc = si_sign_ipa(session, ipa, udid, deviceName, nil, memoryLimit, appGroup,
                             &signed, &error)
        if rc == 0 {
            let path = signed.map { String(cString: $0) } ?? ""
            signed.map { si_string_free($0) }
            engine.log("Signed bundle at \(path)")
            return path
        } else {
            let message = error.map { String(cString: $0) } ?? "rc=\(rc)"
            error.map { si_string_free($0) }
            engine.log("Sign FAILED: \(message)")
            // Same errors as the Install tab, worded for another person's
            // account and iPhone.
            if Engine.isCertExistsError(message) {
                throw EngineError.message(L("Apple won't issue a signing certificate for this Apple ID: it reports that one already exists (error 7460). One has to be revoked first — with the Certificates tool if this is the Apple ID saved in Settings › Account, and at developer.apple.com signed in as it otherwise."))
            }
            if Engine.isDeviceRegistrationError(message) {
                throw EngineError.message(L("Apple wouldn't register their iPhone with this Apple ID's developer team, so it won't issue a provisioning profile. %@", message))
            }
            throw EngineError.message(L("Signing failed: %@", message))
        }
    }

    /// Home-screen name read from the signed `.app` (display name, else bundle
    /// name).
    private static func displayName(ofBundleAt path: String) -> String? {
        let plist = (path as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil),
              let dict = parsed as? [String: Any]
        else { return nil }
        let name = (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String)
        return (name?.isEmpty == false) ? name : nil
    }

    // MARK: - Step 5: install over AFC + installation_proxy

    @MainActor
    private func install(ip: String) async throws {
        try Task.checkCancellation()
        guard let bundle = signedAppPath else { throw EngineError.message(L("No signed bundle to install.")) }
        guard let record = pairRecordPath else { throw EngineError.message(L("No pair record for their iPhone.")) }
        setStep(.install, .active)
        engine.installProgress = 0
        try await onDeviceQueue {
            // iOS drops the idle tunnel during sign-in and signing, and
            // `isConnected` doesn't detect it, so reconnect first.
            self.engine.log("Refreshing the link to \(ip) before installing …")
            do {
                try self.connection.connect(deviceIP: ip, pairingFilePath: record,
                                            allowLockdownMinting: false)
            } catch let error as DeviceConnection.TunnelError {
                throw EngineError.message(Self.tunnelAdvice(error, ip: ip))
            }
            guard self.connection.isConnected else {
                throw EngineError.message(L("The link to their iPhone dropped — start again."))
            }
            self.engine.log("Installing the signed bundle via AFC + installation_proxy …")
            try self.connection.installSignedApp(bundlePath: bundle)
            self.engine.log("Install request completed.")
        }
        engine.installProgress = 1
        setStep(.install, .done)
    }

    // MARK: - Helpers

    /// Anisette addresses to try, in the engine's order.
    private func anisetteCandidates() -> [String] {
        engine.anisetteCandidates()
    }

    private static func tidy(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for a dotted-quad IPv4 address. Checked early for a clear error.
    private static func isIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { UInt8($0) != nil }
    }

    /// Moves the file at `path` to `destination`, replacing anything there, and
    /// returns where it is: still at `path` if it couldn't be moved.
    private static func move(_ path: String, to destination: String) -> String {
        guard path != destination else { return path }
        let fm = FileManager.default
        try? fm.removeItem(atPath: destination)
        return (try? fm.moveItem(atPath: path, toPath: destination)) != nil ? destination : path
    }

    private func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
    }

    private func short(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Bridge a blocking device call to async, serialized on this tool's queue.
    private func onDeviceQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            deviceQueue.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// The same, on the signing queue: isideload's session isn't thread-safe.
    private func onSignQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            signQueue.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}

// MARK: - C 2FA callback

/// Bridges a 2FA request during a Side by Side sign-in to the engine's shared
/// prompt, which `RootView` presents over whichever tab is showing.
private let sideBySideTwoFactorCallback: SITwoFactorCb = { _, request, outBuf, bufLen in
    Engine.shared.answerTwoFactor(request: request, outBuf: outBuf, len: Int(bufLen))
}

// MARK: - View

/// Installs an app onto somebody else's iPhone across the Wi-Fi network —
/// SideInstaller's own release, or an IPA chosen on this page.
/// Pushed from Tools, whose `NavigationStack` this relies on.
struct SideBySideView: View {
    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    /// Read for the install step's progress, which installd reports globally.
    @EnvironmentObject private var engine: Engine
    /// Observed so the "use my saved Apple ID" button follows the saved account.
    @EnvironmentObject private var accounts: AccountStore
    @ObservedObject var manager: SideBySideManager

    @State private var showSettings = false
    @State private var showIPAImporter = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case address, email, password, ipaLink }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header.cascadeItem(0)
                targetCard.cascadeItem(1)
                appCard.cascadeItem(2)
                accountCard.cascadeItem(3)
                stepsCard.cascadeItem(4)
                actionButton.cascadeItem(5)
                // The pairing steps and code, errors and success show as
                // `SideBySidePopup`, which `RootView` lays over the app.
            }
            .padding(20)
            .pageColumn()
            .animation(.smooth(duration: 0.35), value: manager.targetSummary)
            .animation(.smooth(duration: 0.3), value: manager.isRunning)
            .animation(.smooth(duration: 0.4, extraBounce: 0.12), value: manager.finished)
        }
        .background(AppBackground())
        .toolbar { settingsToolbarItem(isPresented: $showSettings) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showIPAImporter) {
            FileImporterRepresentableView(allowedContentTypes: [.ipa]) { urls in
                guard let url = urls.first else { return }   // empty means cancelled
                Task { await manager.chooseIPA(from: url) }
            }
            .ignoresSafeArea()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Header

    private var header: some View {
        BrandHeader(icon: "iphone.gen3.radiowaves.left.and.right",
                    image: "SideBySideLogo",
                    title: L("Side by Side"),
                    beta: true,
                    subtitle: L("Set up someone else's iPhone"),
                    animateIcon: manager.isRunning) {
            if let summary = manager.targetSummary {
                StatusPill(text: summary, systemImage: "iphone", color: .green)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
            } else {
                StatusPill(text: L("Same Wi-Fi network"), systemImage: "wifi", color: .secondary, glass: true)
            }
        }
    }

    // MARK: Their iPhone

    private var targetCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(L("Their iPhone"), systemImage: "iphone")
                // Their iPhone needs iOS 27+ so the installed SideInstaller can
                // pair itself. This can't be checked before the run.
                warningNote(manager.app == .release
                            ? L("Their iPhone needs iOS %@ — SideInstaller pairs itself once it's installed, and nothing older can.",
                                Engine.minimumOSText)
                            : L("An app you choose here is signed for their iPhone but can't pair itself afterwards — install SideInstaller on it first if it has nothing on it yet."))
                TextField(L("IP address (optional)"), text: $manager.targetIP)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // Not `.decimalPad`: its separator is a comma in many regions.
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .address)
                    .disabled(manager.isRunning)
                    .fieldBackground()
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// That their IP is optional, how to find it, and this iPhone's address as
    /// an example.
    private var hint: String {
        let optional = L("Optional: leave it empty, and it fills in when their iPhone pairs.")
        let route = L("On their iPhone: Settings › Wi-Fi › ⓘ next to the network, then “IP Address”.")
        guard let own = manager.ownWiFiAddress else { return optional + " " + route }
        return optional + " " + route + " " + L("This iPhone is %@, so theirs will look similar.", own)
    }

    /// An orange one-line caution, as the cards carry them.
    private func warningNote(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    // MARK: What installs

    /// The choice between SideInstaller's own release and an IPA picked here.
    /// Both take the same pairing, sign-in, signing and install steps; only the
    /// file and how it's signed differ.
    private var appCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(L("What installs"), systemImage: "square.stack.3d.up.fill")
                Picker(L("App"), selection: $manager.app) {
                    Text("SideInstaller").tag(SideBySideApp.release)
                    Text(L("My own .ipa")).tag(SideBySideApp.chosen)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(manager.isRunning)

                if manager.app == .release {
                    Text(L("The latest release, fetched from GitHub at install time."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ipaPickerButton
                    ipaLinkField
                    chosenIPACaption
                }
            }
            .animation(.smooth(duration: 0.3), value: manager.app)
        }
    }

    /// Opens Files and stages the picked IPA as the app to install.
    private var ipaPickerButton: some View {
        Button {
            focus = nil
            showIPAImporter = true
        } label: {
            HStack(spacing: 8) {
                if manager.isFetchingIPA {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: manager.chosenIPAName == nil
                          ? "square.and.arrow.down" : "checkmark.circle.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(manager.chosenIPAName == nil ? Color.secondary : Theme.accent2)
                }
                Text(chosenIPALabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer()
                if manager.chosenIPAName != nil, !manager.isFetchingIPA {
                    Text(L("Replace"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent2)
                }
            }
            .fieldBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain, sound: .tap)
        .disabled(manager.isRunning || manager.isFetchingIPA)
    }

    /// The button's caption: what a fetch is doing, or which IPA is loaded.
    private var chosenIPALabel: String {
        guard manager.isFetchingIPA else { return manager.chosenIPAName ?? L("Import .ipa") }
        // A file copy reports no fraction; a link download does.
        guard let fraction = manager.chosenIPAProgress else { return L("Importing…") }
        return L("Downloading… %d%%", Int(fraction * 100))
    }

    /// A direct link to an IPA, staged into the same slot as a picked file.
    private var ipaLinkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(L("Paste a download link"), text: $manager.chosenIPALink)
                .textFieldStyle(.plain)
                .focused($focus, equals: .ipaLink)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .lineLimit(1)
                .disabled(manager.isRunning || manager.isFetchingIPA)
                .onSubmit(fetchChosenIPA)
            if !manager.chosenIPALink.isEmpty {
                Button { manager.chosenIPALink = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain, sound: .tick)
            }
            Button(action: fetchChosenIPA) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(linkIsUsable ? Theme.accent2 : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain, sound: .tap)
            .disabled(!linkIsUsable)
        }
        .fieldBackground()
        .animation(.smooth(duration: 0.25), value: manager.chosenIPAProgress == nil)
    }

    /// True once the field holds something worth trying to download.
    private var linkIsUsable: Bool {
        !manager.isRunning && !manager.isFetchingIPA && Engine.downloadLink(manager.chosenIPALink) != nil
    }

    private func fetchChosenIPA() {
        focus = nil
        Task { await manager.chooseIPAFromLink() }
    }

    /// The loaded IPA's size, and a way back to the release build.
    @ViewBuilder
    private var chosenIPACaption: some View {
        if let name = manager.chosenIPAName {
            HStack(spacing: 8) {
                Text(L("%@ · %@", name,
                       ByteCountFormatter.string(fromByteCount: Int64(manager.chosenIPASize),
                                                 countStyle: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(L("Remove")) { manager.forgetChosenIPA() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain, sound: .tap)
                    .foregroundStyle(.red)
                    .disabled(manager.isRunning)
            }
        } else if !manager.isFetchingIPA {
            Text(L("Nothing chosen yet — import an .ipa, or paste a link to one."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The Apple ID

    private var accountCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(L("Apple ID to sign with"), systemImage: "person.crop.circle")
                TextField(L("Email"), text: $manager.appleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    // No `.username`/`.password` content types on this card:
                    // these are someone else's credentials, so don't offer to
                    // save them to the keychain.
                    .textFieldStyle(.plain)
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
                    .disabled(manager.isRunning)
                    .fieldBackground()
                SecureField(L("Password"), text: $manager.password)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .focused($focus, equals: .password)
                    .disabled(manager.isRunning)
                    .fieldBackground()
                Text(L("Tip: Use the iPhone/iPad owner's Apple account credentials"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if accounts.active != nil, !manager.isRunning {
                    Button(L("Use my saved Apple ID instead")) {
                        manager.appleID = accounts.activeAppleID
                        manager.password = accounts.activePassword
                        focus = nil
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain, sound: .tap)
                    .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    // MARK: Steps

    private var stepsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(L("Steps"), systemImage: "list.bullet")
                ForEach(SideBySideStep.allCases) { step in
                    SideBySideStepRow(title: step.title(installingOwnIPA: manager.app == .chosen),
                                      state: manager.stepStates[step] ?? .pending,
                                      detail: detail(for: step))
                }
                if manager.isRunning || manager.finished {
                    ProgressView(value: manager.overallProgress)
                        .tint(Theme.accent)
                }
            }
        }
    }

    /// The extra line a step carries while it is the one in flight.
    private func detail(for step: SideBySideStep) -> String? {
        let state = manager.stepStates[step] ?? .pending
        guard state == .active || state == .waiting else { return nil }
        switch step {
        case .connect:
            if manager.pairingPIN != nil { return L("Waiting for them to enter the code…") }
            if manager.pairingInSettings { return L("Waiting for them to pair in Settings…") }
            // `.active` is the tunnel opening once they've paired.
            return state == .waiting ? L("Waiting for them to tap Trust…") : nil
        case .download:
            return L("%d%% downloaded", Int(manager.downloadProgress * 100))
        case .install:
            return L("%d%% uploaded", Int(engine.installProgress * 100))
        default:
            return nil
        }
    }

    // MARK: Action

    @ViewBuilder
    private var actionButton: some View {
        if manager.isRunning {
            Button(role: .cancel) {
                manager.cancel()
            } label: {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(L("Cancel"))
                }
            }
            .buttonStyle(PrimaryButtonStyle(gradient: Theme.gradient(.red), glow: .red))
        } else {
            VStack(spacing: 12) {
                Button {
                    focus = nil
                    manager.run()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "iphone.and.arrow.forward")
                        Text(manager.finished ? L("Install again") : L("Start the install"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!manager.canRun)
                .opacity(manager.canRun ? 1 : 0.35)
                .animation(.snappy(duration: 0.25), value: manager.canRun)

                if manager.finished || !manager.appleID.isEmpty || manager.remembersTheirIPhone {
                    Button(L("Clear their details")) { manager.clear() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain, sound: .tap)
                    if manager.remembersTheirIPhone {
                        Text(L("This iPhone is still paired with theirs. Clearing forgets it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.brand)
        }
    }
}

// MARK: - Popup

/// One of Side by Side's popups, which `RootView` stacks over the whole app:
/// how to pair their iPhone from its Settings and the code it asks for, or how
/// the run ended. See `SideBySideManager.Popup`.
struct SideBySidePopup: View {
    @ObservedObject var manager: SideBySideManager
    let popup: SideBySideManager.Popup

    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        switch popup {
        case .pairingCode(let pin):
            PairingCodePopup(pin: pin, caption: L("Type this into the prompt on their iPhone."),
                             onClose: close)
        case .pairInSettings:
            pairInSettingsPopup
        case .error(let message):
            PopupCard(title: L("Something went wrong"),
                      systemImage: "exclamationmark.triangle.fill",
                      tint: .red,
                      onClose: close) {
                ErrorMessage(message: message)
            }
        case .success(let appName):
            PopupCard(title: L("Last step: they trust %@", appName),
                      systemImage: "checkmark.seal.fill",
                      tint: .green,
                      onClose: close) {
                NumberedSteps(steps: [
                    L("On their iPhone: Settings › General › VPN & Device Management."),
                    L("Tap the Apple ID under “Developer App”, then tap Trust."),
                    L("Open it from their Home Screen — they're set up."),
                ])
            }
        }
    }

    private func close() { manager.closePopup(popup) }

    /// The pairing steps' title, which also titles the group they share with
    /// the code.
    static var pairInSettingsTitle: String { L("Pair their iPhone in Settings") }

    /// What to do on their iPhone while it has to pair from Settings. Nothing
    /// appears on it by itself, so without this the run just looks stuck.
    private var pairInSettingsPopup: some View {
        PopupCard(title: Self.pairInSettingsTitle,
                  systemImage: "gearshape",
                  tint: Theme.accent,
                  onClose: close) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Their iPhone won't ask by itself — pairing starts from its Settings."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NumberedSteps(steps: [
                    L("On their iPhone, open Settings › Privacy & Security › Developer Mode."),
                    L("Tap “Pair with %@”.", PairingController.peerHostName),
                    L("Enter their iPhone’s passcode if it asks for it."),
                    L("Type the code that appears here into the prompt on their iPhone."),
                ])
            }
        }
    }
}

// MARK: - Step row

/// One row of the Side by Side checklist: a status node, the title, and the
/// line the step adds while it is the one in flight.
private struct SideBySideStepRow: View {
    let title: String
    let state: StepState
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            node
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(state == .pending ? .regular : .medium))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.smooth(duration: 0.3), value: state)
    }

    @ViewBuilder
    private var node: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.red)
        case .active:
            ProgressView().controlSize(.small)
        case .waiting:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
        case .pending:
            Circle()
                .strokeBorder(Color(.tertiaryLabel), lineWidth: 1.5)
                .frame(width: 18, height: 18)
        }
    }
}
