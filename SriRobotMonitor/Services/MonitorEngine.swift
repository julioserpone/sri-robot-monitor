import AppKit
import Foundation
import Observation
import UserNotifications

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case runs
    case files
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Panel"
        case .runs: "Ejecuciones"
        case .files: "Archivos"
        case .logs: "Registros"
        case .settings: "Configuración"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: "Estado del robot en tiempo real"
        case .runs: "Historial reconstruido desde CloudWatch"
        case .files: "Contenido del bucket configurado"
        case .logs: "Flujo de CloudWatch Logs"
        case .settings: "Credenciales, conexión y datos"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .runs: "clock.arrow.circlepath"
        case .files: "folder.fill"
        case .logs: "text.alignleft"
        case .settings: "gearshape.fill"
        }
    }
}

/// Coordina AWS, CloudWatch y el estado que consume la interfaz.
@MainActor
@Observable
final class MonitorEngine {
    var configuration = RobotConfiguration.default
    var credentials: AWSCredentials?
    /// Secretos del robot que viajan en el evento de invocación.
    var environment = RobotEnvironment()
    /// Artefactos (TXT y JSON) encontrados en S3 para cada ejecución.
    var artifacts: [String: [S3Object]] = [:]
    var artifactErrors: [String: String] = [:]
    /// Árbol del bucket para el explorador de archivos.
    var bucketTree: [BucketNode] = []
    var bucketLoading = false
    var bucketError: String?
    var bucketLoadedAt: Date?
    var callerIdentity: CallerIdentity?
    var functionInfo: LambdaFunctionInfo?
    var runs: [RobotRun] = []
    var logs: [LogEntry] = []
    var status: RobotStatus = .unknown
    var lastSync: Date?
    var lastValidationAt: Date?
    var connectionError: String?
    var invocationError: String?
    var keychainError: String?
    var lastInvocationRequestID: String?
    var pendingInvocationStartedAt: Date?
    var isBootstrapped = false
    var needsOnboarding = true
    var isRefreshing = false
    var isValidating = false
    var isInvoking = false
    var notificationsAuthorized = false
    var logGroupMissing = false
    var dataDirectoryPath = ""
    var selectedSection: AppSection = .dashboard
    /// Live Tail: `true` cuando CloudWatch mantiene abierta la transmisión.
    var isLiveTailing = false
    var liveTailError: String?
    /// Resultado del último relanzamiento hecho desde la app.
    var lastInvocationResult: RobotInvocationResult?
    var lastInvocationFinishedAt: Date?
    /// Variables de entorno que la función de Lambda tiene declaradas.
    var functionEnvironmentKeys: Set<String> = []
    /// RequestId que la vista de registros debe resaltar al abrirse. Se limpia
    /// en cuanto la vista lo consume.
    var pendingLogHighlight: String?

    private let persistence: AppPersistence
    /// Sesión HTTP de los clientes de AWS. Inyectable para poder probar los
    /// clientes sin red (basta con una `URLProtocol` de prueba).
    @ObservationIgnored let session: URLSession
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var liveTailTask: Task<Void, Never>?
    /// `true` mientras la supervisión está activa y debe haber un Live Tail.
    /// Evita que la tarea vieja, al cancelarse, marque el flujo como inactivo.
    @ObservationIgnored private var isLiveTailingRequested = false
    @ObservationIgnored private var lastNotifiedConnectionError: String?
    /// Reloj del último paquete recibido por Live Tail (cualquier línea).
    @ObservationIgnored private var lastLivePacketAt: Date?
    private var lastFetchedAt: Date?
    private var notifiedRunIDs: Set<String> = []
    private var didSeedNotifications = false
    private var lastPersistedRuns: [RobotRun] = []
    private var lastPersistedLogCount = -1

    init(persistence: AppPersistence = AppPersistence(), session: URLSession = .shared) {
        self.persistence = persistence
        self.session = session
        dataDirectoryPath = persistence.directory.path(percentEncoded: false)
    }

    deinit {
        // `deinit` es nonisolated y no puede leer propiedades aisladas al
        // actor principal. Las tareas guardan una referencia débil al motor,
        // así que la cancelación real la hace `stopMonitoring()`.
    }

    var latestRun: RobotRun? {
        runs.first
    }

    var completedRuns: [RobotRun] {
        runs.filter(\.finished)
    }

    var isLive: Bool {
        pollTask != nil && !pollTask!.isCancelled
    }

    /// Texto corto del medio de supervisión, para la barra lateral.
    var monitoringModeText: String {
        guard isLive else { return "Supervisión pausada" }
        if isLiveTailing { return "Live Tail de CloudWatch" }
        if liveTailError != nil { return "Sondeo cada \(configuration.pollIntervalSeconds) s" }
        return "Conectando con CloudWatch…"
    }

    /// El LED se pinta rojo también cuando la propia supervisión falla, no
    /// solo cuando falla una ejecución: si no se puede leer CloudWatch, la app
    /// no puede afirmar que el robot esté operativo.
    var effectiveStatus: RobotStatus {
        if needsOnboarding { return .unknown }
        if connectionError != nil || keychainError != nil { return .error }
        if liveTailError != nil, status == .unknown { return .warning }
        return status
    }

    var statusMessage: String {
        if let keychainError {
            return keychainError
        }
        if let connectionError {
            return connectionError
        }
        if needsOnboarding {
            return "Configura tus credenciales de AWS para empezar."
        }
        guard let latestRun else {
            return "Todavía no hay ejecuciones registradas."
        }
        switch latestRun.status {
        case .running:
            return "El robot está trabajando. Los registros se actualizan solos."
        case .healthy:
            return "La última ejecución terminó sin errores ni advertencias."
        case .warning:
            return "La última ejecución terminó con advertencias."
        case .error:
            return latestRun.failureMessages.first ?? "La última ejecución terminó con errores."
        case .unknown:
            return liveTailError ?? "No hay información suficiente para determinar el estado."
        }
    }

    // MARK: - Ciclo de vida

    func bootstrap() async {
        guard !isBootstrapped else { return }
        configuration = await persistence.loadConfiguration()
        dataDirectoryPath = persistence.directory.path(percentEncoded: false)

        do {
            credentials = try await persistence.loadCredentials()
            environment = try await persistence.loadEnvironment()
        } catch {
            keychainError = error.localizedDescription
        }

        runs = await persistence.loadRuns()
        logs = await persistence.loadLogs()
        notifiedRunIDs = Set(await persistence.loadNotifiedRunIDs())
        didSeedNotifications = !notifiedRunIDs.isEmpty || !runs.isEmpty

        if runs.isEmpty, !logs.isEmpty {
            runs = LogAnalyzer.analyze(logs)
        }
        status = runs.first?.status ?? .unknown
        lastPersistedRuns = runs
        lastPersistedLogCount = logs.count

        notificationsAuthorized = await notificationPermissionGranted()
        needsOnboarding = !(credentials?.isComplete ?? false)
        isBootstrapped = true

        if !needsOnboarding {
            startMonitoring()
        }
    }

    func startMonitoring() {
        guard credentials?.isComplete == true, !needsOnboarding else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Live Tail mantiene el flujo abierto; el sondeo es solo el
                // respaldo cuando AWS no permite transmitir.
                let interval = self.isLiveTailing
                    ? 30.0
                    : (self.isInvoking ? 2.0 : Double(max(2, self.configuration.pollIntervalSeconds)))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        startLiveTail()
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        liveTailTask?.cancel()
        liveTailTask = nil
        isLiveTailingRequested = false
        isLiveTailing = false
        liveTailError = nil
    }

    // MARK: - Live Tail

    /// Abre `StartLiveTail` de CloudWatch Logs. A diferencia del sondeo, AWS
    /// empuja cada línea en cuanto Lambda la escribe, así que la app ve el
    /// `START`, la traza del robot y el `REPORT` sin esperar turno.
    ///
    /// Si la cuenta, la región o los permisos no admiten Live Tail, la app
    /// sigue funcionando con `FilterLogEvents` y deja constancia del motivo.
    private func startLiveTail() {
        liveTailTask?.cancel()
        liveTailTask = nil
        isLiveTailing = false
        liveTailError = nil

        guard let credentials, credentials.isComplete, !needsOnboarding else { return }
        let remote = configuration
        let account = callerIdentity?.account
        let session = self.session
        isLiveTailingRequested = true
        liveTailTask = Task { [weak self] in
            var retryDelay: Duration = .seconds(3)
            while !Task.isCancelled {
                do {
                    let client = CloudWatchLogsClient(
                        credentials: credentials,
                        region: remote.region,
                        session: session
                    )
                    let stream = try await client.startLiveTail(
                        logGroupName: remote.logGroupName,
                        account: account
                    )
                    await self?.markLiveTail(active: true, error: nil)
                    retryDelay = .seconds(3)
                    for try await event in stream {
                        if Task.isCancelled { break }
                        await self?.ingestLive(event)
                    }
                    // AWS cierra la sesión a las 3 h o por inactividad: se
                    // reabre sin mostrar error, el sondeo cubre el hueco.
                    try? await Task.sleep(for: .milliseconds(500))
                } catch is CancellationError {
                    break
                } catch {
                    let message = (error as? AWSAPIError)?.friendlyMessage ?? error.localizedDescription
                    if Self.isUnsupportedLiveTail(error) {
                        await self?.markLiveTail(active: false, error: message)
                        Self.logLiveTailFallback(message)
                        return
                    }
                    await self?.markLiveTail(active: false, error: message)
                    try? await Task.sleep(for: retryDelay)
                    retryDelay = min(retryDelay * 2, .seconds(60))
                }
            }
            await self?.markLiveTail(active: false, error: nil)
        }
    }
    /// Errores que no se arreglan reintentando: la cuenta, la región o el
    /// usuario IAM no pueden usar Live Tail. Se deja de intentar y se sigue
    /// con el sondeo.
    nonisolated static func isUnsupportedLiveTail(_ error: any Error) -> Bool {
        LiveTailPolicy.isPermanent(error)
    }

    nonisolated private static func logLiveTailFallback(_ message: String) {
        NSLog("[SriRobotMonitor] Live Tail no disponible: %@", message)
    }

    private func markLiveTail(active: Bool, error: String?) {
        guard isLiveTailingRequested else { return }
        if isLiveTailing != active { isLiveTailing = active }
        if liveTailError != error { liveTailError = error }
    }

    /// Una sola línea recibida por el flujo en vivo. No se espera al sondeo:
    /// se fusiona, se recalcula el estado y se persiste con un pequeño retardo.
    private func ingestLive(_ event: CloudWatchLogEvent) async {
        guard !logs.contains(where: { $0.id == event.eventId }) else { return }
        let now = Date()
        merge(events: [event], now: now)
        lastSync = now
        if event.message.hasPrefix("START RequestId:") {
            pendingInvocationStartedAt = now
        }
        lastLivePacketAt = now
        updateStatus()
        await evaluateNotifications()
        persistIfNeeded()
    }

    // MARK: - Lectura de AWS

    func refresh(forceValidation: Bool = false) async {
        guard !isRefreshing, !needsOnboarding, let credentials, credentials.isComplete else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let sts = STSClient(credentials: credentials, region: configuration.region, session: session)
            let lambda = LambdaClient(credentials: credentials, region: configuration.region, session: session)
            let cloudWatch = CloudWatchLogsClient(credentials: credentials, region: configuration.region, session: session)

            let needsValidation = forceValidation
                || callerIdentity == nil
                || functionInfo == nil
                || lastValidationAt.map { Date().timeIntervalSince($0) > 300 } == true

            if needsValidation {
                async let identityTask = sts.getCallerIdentity()
                async let functionTask = lambda.configuration(functionName: configuration.functionName)
                let (identity, function) = try await (identityTask, functionTask)
                callerIdentity = identity
                functionInfo = function
                lastValidationAt = Date()
            }

            let now = Date()
            let lookback = now.addingTimeInterval(-Double(configuration.historyDays) * 86_400)
            let start = lastFetchedAt.map { max($0.addingTimeInterval(-120), lookback) } ?? lookback
            let events = try await fetchLogEvents(
                client: cloudWatch,
                startTime: start,
                logGroupName: configuration.logGroupName
            )

            merge(events: events, now: now)
            if liveTailError == nil || isLiveTailing {
                connectionError = nil
            }
            logGroupMissing = false
            lastSync = Date()
            lastFetchedAt = now.addingTimeInterval(-30)
            updateStatus()
            await evaluateNotifications()
            persistIfNeeded()
        } catch let error as AWSAPIError {
            // "no hay streams todavía" no es un fallo de conexión: el robot aún
            // no ha ejecutado desde que existe el log group.
            if error.code == "ResourceNotFoundException", error.message.contains("log stream") {
                logGroupMissing = true
                connectionError = nil
            } else {
                connectionError = error.friendlyMessage
            }
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// Borra el historial de la conexión actual tras regenerar las claves de
    /// AWS. Se conserva lo que haya en la nube; solo se evita mezclar runs y
    /// logs de un usuario IAM anterior.
    func invalidateScope() async {
        stopMonitoring()
        runs = []
        logs = []
        status = .unknown
        lastFetchedAt = nil
        lastPersistedRuns = []
        lastPersistedLogCount = -1
        callerIdentity = nil
        functionInfo = nil
        lastValidationAt = nil
        lastInvocationResult = nil
        try? await persistence.clearHistory()
        startMonitoring()
    }

    private func fetchLogEvents(
        client: CloudWatchLogsClient,
        startTime: Date,
        logGroupName: String
    ) async throws -> [CloudWatchLogEvent] {
        var events: [CloudWatchLogEvent] = []
        var token: String?
        var page = 0
        repeat {
            let result = try await client.filterLogEvents(
                logGroupName: logGroupName,
                startTime: startTime,
                nextToken: token
            )
            events.append(contentsOf: result.events)
            token = result.nextToken
            page += 1
        } while token != nil && page < 6

        return events
    }

    private func merge(events: [CloudWatchLogEvent], now: Date) {
        guard !events.isEmpty else { return }
        var known = Set(logs.map(\.id))
        var appended: [LogEntry] = []
        appended.reserveCapacity(events.count)

        for event in events where known.insert(event.eventId).inserted {
            appended.append(CloudWatchLogParser.parse(event: event))
        }
        guard !appended.isEmpty else { return }

        logs.append(contentsOf: appended)
        logs.sort {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
        if logs.count > 3_000 {
            logs = Array(logs.suffix(3_000))
        }

        let previous = runs
        runs = LogAnalyzer.analyze(logs, now: now)

        if let pending = pendingInvocationStartedAt,
           runs.contains(where: { $0.startedAt >= pending.addingTimeInterval(-15) }) {
            pendingInvocationStartedAt = nil
        }
        _ = previous
    }

    private func updateStatus() {
        if pendingInvocationStartedAt != nil {
            status = .running
            return
        }
        if let latestRun = runs.first {
            status = latestRun.status
        } else {
            status = .unknown
        }
    }

    private func persistIfNeeded() {
        let runsToSave = runs
        let logsToSave = logs
        let runsChanged = runsToSave != lastPersistedRuns
        let logsChanged = logsToSave.count != lastPersistedLogCount

        if runsChanged {
            lastPersistedRuns = runsToSave
            Task { try? await persistence.saveRuns(runsToSave) }
        }
        if logsChanged {
            lastPersistedLogCount = logsToSave.count
            Task { try? await persistence.saveLogs(logsToSave) }
        }
    }

    // MARK: - Notificaciones

    private func evaluateNotifications() async {
        let completed = runs.filter { $0.finished && !$0.isDerived }

        if !didSeedNotifications {
            notifiedRunIDs.formUnion(completed.map(\.id))
            didSeedNotifications = true
            persistNotified()
            return
        }

        var newNotifications: [(RobotRun, RobotStatus)] = []
        for run in completed where !notifiedRunIDs.contains(run.id) {
            notifiedRunIDs.insert(run.id)
            if run.status == .error || (run.status == .warning && configuration.notifyWarnings) {
                newNotifications.append((run, run.status))
            }
        }

        guard !newNotifications.isEmpty || connectionErrorChangedSinceLastNotification else {
            return
        }
        persistNotified()
        guard configuration.notificationsEnabled else { return }

        if connectionErrorChangedSinceLastNotification, let connectionError {
            lastNotifiedConnectionError = connectionError
            await NotificationService.send(
                title: "SRI Robot · supervisión interrumpida",
                body: connectionError,
                runID: "conexion-\(Date().timeIntervalSince1970)"
            )
        }

        for (run, runStatus) in newNotifications {
            let title = runStatus == .error ? "SRI Robot · error de ejecución" : "SRI Robot · advertencia"
            var body = run.periodText
            if run.failures > 0 {
                body += " · \(run.failures) fallo(s)"
            } else if let first = run.failureMessages.first {
                body += " · \(first)"
            } else if run.warningCount > 0 {
                body += " · \(run.warningCount) advertencia(s)"
            }
            await NotificationService.send(title: title, body: body, runID: run.id)
        }
    }

    /// Solo avisa cuando el error de supervisión es nuevo o cambió, para no
    /// repetir el mismo banner cada dos segundos mientras AWS no responde.
    private var connectionErrorChangedSinceLastNotification: Bool {
        guard let connectionError else { return false }
        return connectionError != lastNotifiedConnectionError
    }

    private func persistNotified() {
        let ids = Array(notifiedRunIDs)
        Task { try? await persistence.saveNotifiedRunIDs(ids) }
    }

    private func notificationPermissionGranted() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    // MARK: - Configuración

    func validate(draft: AWSSetupDraft) async throws -> AWSValidation {
        guard draft.hasCredentials else {
            throw SetupError.missingCredentials
        }
        let config = draft.configuration
        guard config.isUsable else {
            throw SetupError.missingConfiguration
        }

        isValidating = true
        defer { isValidating = false }

        let sts = STSClient(credentials: draft.credentials, region: config.region, session: session)
        let lambda = LambdaClient(credentials: draft.credentials, region: config.region, session: session)

        async let identityTask = sts.getCallerIdentity()
        async let functionTask = lambda.configuration(functionName: config.functionName)
        let (identity, function) = try await (identityTask, functionTask)
        return AWSValidation(identity: identity, function: function, validatedAt: Date())
    }

    func validateCredentials(draft: AWSSetupDraft) async throws -> CallerIdentity {
        guard draft.hasCredentials else {
            throw SetupError.missingCredentials
        }
        let config = draft.configuration
        guard !config.region.isEmpty else {
            throw SetupError.missingConfiguration
        }

        isValidating = true
        defer { isValidating = false }

        return try await STSClient(credentials: draft.credentials, region: config.region, session: session).getCallerIdentity()
    }

    func validateFunction(draft: AWSSetupDraft) async throws -> LambdaFunctionInfo {
        guard draft.hasCredentials else {
            throw SetupError.missingCredentials
        }
        let config = draft.configuration
        guard config.isUsable else {
            throw SetupError.missingConfiguration
        }

        isValidating = true
        defer { isValidating = false }

        return try await LambdaClient(credentials: draft.credentials, region: config.region, session: session)
            .configuration(functionName: config.functionName)
    }

    func saveInitialSetup(
        draft: AWSSetupDraft,
        validation: AWSValidation,
        notificationsEnabled: Bool
    ) async throws {
        var config = draft.configuration
        config.notificationsEnabled = notificationsEnabled
        config.notifyWarnings = true
        config.pollIntervalSeconds = RobotConfiguration.default.pollIntervalSeconds
        config.historyDays = RobotConfiguration.default.historyDays

        try await persistence.saveSecrets(draft.credentials, environment: draft.environment)
        try await persistence.saveConfiguration(config)

        credentials = draft.credentials
        environment = draft.environment
        configuration = config
        callerIdentity = validation.identity
        functionInfo = validation.function
        lastValidationAt = validation.validatedAt
        needsOnboarding = false
        keychainError = nil
        connectionError = nil

        await refresh(forceValidation: true)
        startMonitoring()
    }

    func saveRevalidatedConnection(draft: AWSSetupDraft, validation: AWSValidation) async throws {
        let old = configuration
        var config = old
        config.region = draft.configuration.region
        config.functionName = draft.configuration.functionName
        config.logGroupName = draft.configuration.logGroupName
        config.bucketName = draft.bucketName
        config.environmentName = draft.environmentName
        config.environment = draft.environment
        config = RobotConfiguration.normalized(config)

        let scopeChanged = old.region != config.region
            || old.functionName != config.functionName
            || old.logGroupName != config.logGroupName

        try await persistence.saveSecrets(draft.credentials, environment: draft.environment)
        try await persistence.saveConfiguration(config)

        credentials = draft.credentials
        environment = draft.environment
        configuration = config
        callerIdentity = validation.identity
        functionInfo = validation.function
        lastValidationAt = validation.validatedAt
        needsOnboarding = false
        keychainError = nil
        connectionError = nil

        if scopeChanged {
            runs = []
            logs = []
            lastFetchedAt = nil
            status = .unknown
            lastPersistedRuns = []
            lastPersistedLogCount = -1
            lastNotifiedConnectionError = nil
            try? await persistence.clearHistory()
        }

        await refresh(forceValidation: true)
        startMonitoring()
    }

    /// Guarda los secretos del robot sin tocar AWS. Se usan desde Ajustes
    /// cuando solo cambia la clave del portal o del anti-captcha.
    func saveEnvironment(_ newValue: RobotEnvironment) async throws {
        guard let credentials else { throw SetupError.missingCredentials }
        let normalized = RobotEnvironment.normalized(newValue)
        try await persistence.saveSecrets(credentials, environment: normalized)
        environment = normalized
        var config = configuration
        config.environment = normalized
        configuration = config
        try await persistence.saveConfiguration(config)
    }

    func savePreferences(_ newValue: RobotConfiguration) async throws {
        let normalized = RobotConfiguration.normalized(newValue)
        let old = configuration
        let scopeChanged = old.region != normalized.region
            || old.functionName != normalized.functionName
            || old.logGroupName != normalized.logGroupName

        try await persistence.saveConfiguration(normalized)
        configuration = normalized
        connectionError = nil

        if scopeChanged {
            callerIdentity = nil
            functionInfo = nil
            lastValidationAt = nil
            lastFetchedAt = nil
            runs = []
            logs = []
            status = .unknown
            lastPersistedRuns = []
            lastPersistedLogCount = -1
            try? await persistence.clearHistory()
        }

        if normalized.notificationsEnabled, !notificationsAuthorized {
            notificationsAuthorized = await NotificationService.requestAuthorization()
        }
        await refresh(forceValidation: true)
    }

    func requestNotificationPermission() async {
        notificationsAuthorized = await NotificationService.requestAuthorization()
    }

    // MARK: - Ejecución remota

    /// Relanza el robot con el perfil caliente.
    ///
    /// - `waitForResult == false`: modo `event`, la app recibe el RequestId y
    ///   el flujo en vivo muestra el progreso.
    /// - `waitForResult == true`: modo `tail` (`RequestResponse`). La app
    ///   espera al `REPORT` y muestra el resumen con fallos, descargas y claves.
    func invoke(
        periods: [Periodo],
        types: [String],
        force: Bool,
        waitForResult: Bool = false
    ) async throws {
        guard let credentials, credentials.isComplete else {
            throw SetupError.missingCredentials
        }
        guard !periods.isEmpty else {
            throw SetupError.missingPeriod
        }

        isInvoking = true
        invocationError = nil
        lastInvocationResult = nil
        defer { isInvoking = false }

        let region = configuration.region
        let functionName = configuration.functionName
        let secrets = environment
        let variables = secrets.variables()
        let payload = RobotInvocationPayload(
            periodos: periods.map(\.key),
            tipos: types.isEmpty ? nil : types,
            forzar: force ? true : nil,
            environment: waitForResult && !variables.isEmpty ? variables : nil
        )
        let lambda = LambdaClient(credentials: credentials, region: region, session: session)

        do {
            if waitForResult {
                let started = Date()
                let result = try await lambda.invokeSync(functionName: functionName, payload: payload)
                let seconds = Date().timeIntervalSince(started)
                lastInvocationResult = result
                lastInvocationFinishedAt = Date()
                appendLocalInvocationLog(
                    requestID: lastInvocationRequestID ?? "—",
                    periods: periods,
                    types: types,
                    suffix: result.succeeded
                        ? "resumen recibido en \(Int(seconds)) s"
                        : "resumen con errores"
                )
                await refresh()
                if !result.succeeded {
                    let message = result.error ?? result.fallos?.first ?? result.detalle
                    throw InvocationFailure.summaryFailed(message ?? "La ejecución terminó con fallos.")
                }
            } else {
                let requestID = try await lambda.invoke(functionName: functionName, payload: payload)
                lastInvocationRequestID = requestID
                pendingInvocationStartedAt = Date()
                status = .running
                appendLocalInvocationLog(requestID: requestID, periods: periods, types: types)
                lastFetchedAt = Date().addingTimeInterval(-10)
                await refresh()
            }
        } catch let error as InvocationFailure {
            invocationError = error.localizedDescription
            throw error
        } catch {
            invocationError = error.localizedDescription
            throw error
        }
    }

    /// Comprueba qué variables declara la función y cuáles llegan desde la app,
    /// para avisar en Ajustes de lo que falta sin exponer valores.
    func loadFunctionEnvironmentKeys() async {
        guard let credentials, credentials.isComplete else { return }
        let lambda = LambdaClient(credentials: credentials, region: configuration.region, session: session)
        functionEnvironmentKeys = (try? await lambda.environmentKeys(functionName: configuration.functionName)) ?? []
    }

    func validateEnvironment(draft: AWSSetupDraft) async throws -> [String] {
        guard draft.hasCredentials else { throw SetupError.missingCredentials }
        let config = draft.configuration
        guard config.isUsable else { throw SetupError.missingConfiguration }
        let lambda = LambdaClient(credentials: draft.credentials, region: config.region, session: session)
        let keys = try await lambda.environmentKeys(functionName: config.functionName)
        functionEnvironmentKeys = keys
        return Array(keys).sorted()
    }

    private func appendLocalInvocationLog(
        requestID: String,
        periods: [Periodo],
        types: [String],
        suffix: String? = nil
    ) {
        let detailParts = [
            "RequestId: \(requestID)",
            types.isEmpty ? "tipos de la función" : "tipos: \(types.joined(separator: ", "))"
        ]
        let entry = LogEntry(
            id: "local-\(UUID().uuidString)",
            timestamp: Date(),
            level: .system,
            message: ["Invocación enviada · \(periods.map(\.key).joined(separator: ", "))", suffix]
                .compactMap { $0 }
                .joined(separator: " · "),
            detail: detailParts.joined(separator: " · "),
            requestID: requestID == "—" ? nil : requestID
        )
        logs.append(entry)
    }

    // MARK: - Explorador de archivos

    /// Carga el listado del bucket completo (hasta el tope de S3 por llamada)
    /// y lo convierte en un árbol de carpetas.
    func loadBucketTree(force: Bool = false) async {
        guard let credentials, credentials.isComplete else { return }
        guard !configuration.bucketName.isEmpty else {
            bucketError = "Indica el bucket de S3 en Ajustes para explorar los archivos."
            bucketTree = []
            return
        }
        if bucketLoading { return }
        if !force, let bucketLoadedAt, Date().timeIntervalSince(bucketLoadedAt) < 120 { return }

        bucketLoading = true
        bucketError = nil
        defer { bucketLoading = false }

        let client = S3Client(
            credentials: credentials,
            region: configuration.region,
            session: session
        )
        do {
            var objects: [S3Object] = []
            var token: String?
            var pages = 0
            repeat {
                let page = try await client.listObjects(
                    bucket: configuration.bucketName,
                    prefix: "",
                    continuationToken: token
                )
                objects.append(contentsOf: page.objects)
                token = page.nextToken
                pages += 1
            } while token != nil && pages < 10

            bucketTree = BucketNode.build(from: objects)
            bucketLoadedAt = Date()
        } catch let error as AWSAPIError {
            bucketError = error.friendlyMessage
        } catch {
            bucketError = error.localizedDescription
        }
    }

    // MARK: - Descarga de artefactos

    /// Busca en S3 el TXT y el JSON que el robot generó para una ejecución.
    ///
    /// Se hace a petición (al abrir el detalle o pulsar Descargar) y no en
    /// cada sondeo: listar S3 cuesta una llamada por carpeta y período, y no
    /// hace falta hasta que alguien quiere el archivo.
    func loadArtifacts(for run: RobotRun) async {
        guard let credentials, credentials.isComplete else { return }
        guard !run.periods.isEmpty else {
            artifactErrors[run.id] = "La ejecución no registró períodos en los logs."
            return
        }
        guard !configuration.bucketName.isEmpty else {
            artifactErrors[run.id] = "Indica el bucket de S3 en Ajustes para descargar los archivos."
            return
        }
        if artifacts[run.id] != nil { return }

        artifactErrors[run.id] = nil
        let client = S3Client(
            credentials: credentials,
            region: configuration.region,
            session: session
        )
        do {
            let found = try await client.findArtifacts(
                bucket: configuration.bucketName,
                environment: run.environment ?? configuration.environmentName,
                periods: run.periods,
                ruc: run.ruc
            )
            artifacts[run.id] = found
            if found.isEmpty {
                artifactErrors[run.id] = "No hay archivos de esa ejecución en s3://\(configuration.bucketName)."
            }
        } catch let error as AWSAPIError {
            artifactErrors[run.id] = error.friendlyMessage
        } catch {
            artifactErrors[run.id] = error.localizedDescription
        }
    }

    /// Descarga un objeto y lo escribe donde la persona elija.
    ///
    /// Devuelve `false` si se canceló el diálogo de guardar.
    func download(_ object: S3Object) async throws -> Bool {
        guard let credentials, credentials.isComplete else {
            throw SetupError.missingCredentials
        }
        let client = S3Client(
            credentials: credentials,
            region: configuration.region,
            session: session
        )
        let data = try await client.getObject(object)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = object.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Guardar \(object.kind.title)"
        // `runModal()` dentro de una `Task` bloquea el hilo principal y deja la
        // app sin responder (el panel aparece pero los clics no hacen nada).
        // La API asíncrona lo presenta sin bloquear.
        guard await panel.begin() == .OK, let url = panel.url else { return false }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DownloadError.writeFailed(url: url, underlying: error.localizedDescription)
        }
        return true
    }

    // MARK: - Datos locales

    func clearHistory() async {
        runs = []
        logs = []
        status = .unknown
        lastFetchedAt = nil
        lastPersistedRuns = []
        lastPersistedLogCount = -1
        notifiedRunIDs = []
        didSeedNotifications = false
        try? await persistence.clearHistory()
    }

    func resetApplication() async throws {
        stopMonitoring()
        try await persistence.resetAll()
        credentials = nil
        environment = RobotEnvironment()
        callerIdentity = nil
        functionInfo = nil
        runs = []
        logs = []
        status = .unknown
        lastInvocationResult = nil
        needsOnboarding = true
        configuration = .default
    }

    var agentLogs: [LogEntry] {
        logs
    }
}

enum SetupError: LocalizedError {
    case missingCredentials
    case missingConfiguration
    case missingPeriod

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Escribe el Access Key ID y el Secret Access Key de AWS."
        case .missingConfiguration:
            "Completa la región y el nombre de la función de Lambda."
        case .missingPeriod:
            "Selecciona al menos un período para ejecutar el robot."
        }
    }
}

/// La ejecución se completó, pero el robot reportó fallos en su resumen.
enum InvocationFailure: LocalizedError {
    case summaryFailed(String)

    var errorDescription: String? {
        switch self {
        case let .summaryFailed(message): "La ejecución terminó con fallos: \(message)"
        }
    }
}

/// Fallos al guardar un archivo descargado.
enum DownloadError: LocalizedError {
    case writeFailed(url: URL, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .writeFailed(url, underlying):
            "Se descargó el archivo, pero no se pudo escribir en \(url.path(percentEncoded: false)): \(underlying)"
        }
    }
}

/// Decide si un fallo de Live Tail se puede reintentar.
///
/// Reintentar un `AccessDeniedException` cada 60 s durante horas solo llena la
/// consola de AWS y gasta cuota: si el problema es de configuración, la app
/// deja de intentarlo y sigue con el sondeo, que sí funciona.
enum LiveTailPolicy {
    private static let permanentCodes: Set<String> = [
        "UnknownOperationException",
        "AccessDeniedException",
        "UnrecognizedClientException",
        "InvalidSignatureException",
        "ResourceNotFoundException",
        "InvalidParameterException",
        "UnsupportedOperationException",
        "ExpiredToken",
        "ExpiredTokenException"
    ]

    /// Errores transitorios conocidos: vale la pena reintentar con espera.
    private static let transientCodes: Set<String> = [
        "ThrottlingException",
        "TooManyRequestsException",
        "ServiceUnavailableException",
        "RequestTimeout",
        "RequestTimeoutException",
        "LimitExceededException"
    ]

    static func isPermanent(_ error: any Error) -> Bool {
        guard let error = error as? AWSAPIError else {
            // Red caída o DNS: transitorio, se reintenta.
            return false
        }
        if transientCodes.contains(error.code) { return false }
        if permanentCodes.contains(error.code) { return true }
        if error.statusCode == 429 || error.statusCode >= 500 { return false }
        return error.statusCode == 400 || error.statusCode == 403
    }

    /// Espera entre intentos: 3, 6, 12, 24, 48 y luego 60 s fijos, para no
    /// martillear AWS cuando la cuenta simplemente está limitada.
    static func retryDelay(after attempt: Int) -> Duration {
        guard attempt > 0 else { return .seconds(3) }
        let raw = 3 * (1 << min(attempt, 5))
        return .seconds(min(raw, 60))
    }
}
