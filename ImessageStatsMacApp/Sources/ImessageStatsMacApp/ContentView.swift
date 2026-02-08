import SwiftUI
import AppKit
import Charts
import Contacts
import ContactsUI

private enum NumberFormatters {
    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = Locale.current.groupingSeparator
        return formatter
    }()
}

private struct AnimatedCountText: View, Animatable {
    var value: Double
    let formatter: NumberFormatter

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let rounded = Int(value.rounded())
        Text(formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)")
    }
}

private func decimalString(_ value: Int) -> String {
    return NumberFormatters.decimal.string(from: NSNumber(value: value)) ?? "\(value)"
}

private func shortLabel(_ value: String, maxLength: Int = 10) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= maxLength { return trimmed }
    if let first = trimmed.split(separator: " ").first {
        let base = String(first)
        if base.count <= maxLength { return base }
        return String(base.prefix(maxLength - 1)) + "…"
    }
    return String(trimmed.prefix(maxLength - 1)) + "…"
}

private func firstNameOnly(_ label: String) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Them" }
    if let commaIndex = trimmed.firstIndex(of: ",") {
        let firstPart = String(trimmed[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !firstPart.isEmpty { return firstPart }
    }
    let separators = CharacterSet(charactersIn: " &")
    if let range = trimmed.rangeOfCharacter(from: separators) {
        let first = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return first.isEmpty ? trimmed : first
    }
    return trimmed
}

struct ContentView: View {
    @StateObject private var viewModel = ReportViewModel()
    @StateObject private var supabase = SupabaseService()
    @ObservedObject private var updater = UpdaterService.shared
    @State private var chatFilter: ChatFilter = .dm
    @State private var selection: SidebarItem = .overview
    @State private var selectedChatId: Int64?
    @State private var moodDetailsChat: ChatReport?
    @State private var loadingVisible: Bool = false
    @State private var loadingIsActive: Bool = false
    @State private var showBackToTop: Bool = false
    @State private var showContactsPrompt: Bool = false
    @State private var chatSearch: String = ""
    @State private var chatSort: ChatSort = .mostMessages
    @State private var filterRefreshWorkItem: DispatchWorkItem?
    @State private var lastChatListAnchor: Int64?
    @State private var mergedDMsCache: [ChatReport] = []
    @State private var mergedDMsCacheKey: String = ""
    @State private var mergedDMsLoading: Bool = false
    @State private var chatListCache: [ChatReport] = []
    @State private var chatListCacheKey: String = ""
    @State private var chatListLoading: Bool = false
    @State private var chatListWorkItem: DispatchWorkItem?
    @State private var pinnedChatIds: Set<Int64> = []
    @State private var chatPageSize: Int = 20
    @State private var chatPageWorkItems: [DispatchWorkItem] = []
    @State private var authEmail: String = ""
    @State private var authUsername: String = ""
    @State private var authPassword: String = ""
    @State private var authIsSigningUp: Bool = false
    @State private var hasFullDiskAccess: Bool = false
    @State private var hasContactsAccess: Bool = false
    @State private var hasTriggeredPreload: Bool = false
    @State private var showProUpgradeSheet: Bool = false
    @State private var proUpgradeCopied: Bool = false
    private let theme = Theme()

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                detailView
            }
            if !supabase.isSignedIn {
                AuthGateView(
                    email: $authEmail,
                    username: $authUsername,
                    password: $authPassword,
                    isSigningUp: $authIsSigningUp,
                    hasFullDiskAccess: hasFullDiskAccess,
                    hasContactsAccess: hasContactsAccess,
                    theme: theme,
                    status: supabase.syncStatus,
                    onCheckDiskAccess: { checkFullDiskAccess() },
                    onOpenDiskSettings: { promptFullDiskAccess() },
                    onRequestContacts: { requestContactsAccess() },
                    onOpenContactsSettings: { promptContactsAccess() },
                    onSubmit: { submitAuth() }
                )
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            updater.startAutomaticChecks()
            viewModel.onAppear(allowAutoWork: supabase.isSignedIn)
            checkFullDiskAccess()
            checkContactsAccessStatus()
            scheduleChatListRefresh()

            // If the user is already signed in and has already granted Contacts access,
            // onChange handlers won't fire. Kick off a best-effort automatic contacts sync.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if supabase.isSignedIn, hasContactsAccess {
                    supabase.syncContactsIfEnabled()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.checkForUpdatesInBackgroundIfStale()
            // Users often grant permissions in System Settings and switch back.
            // Refresh both access flags automatically so the UI updates without manual "Check".
            checkFullDiskAccess()
            checkContactsAccessStatus()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            // Cloud message sync is incremental (by message ROWID), so this is cheap when nothing changed.
            guard supabase.isSignedIn, hasFullDiskAccess else { return }
            guard let report = viewModel.report, let dbURL = viewModel.dbURL else { return }
            supabase.syncChatMessagesIfNeeded(report: report, dbURL: dbURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: ContactPhotoStore.accessDeniedNotification)) { _ in
            // Avoid unexpected prompts; surface this via the Access UI instead.
            checkContactsAccessStatus()
        }
        .onChange(of: hasFullDiskAccess) { granted in
            if granted {
                maybePreloadData()
            }
        }
        .onChange(of: hasContactsAccess) { granted in
            if granted {
                // Best-effort background sync; avoids re-exporting unless contacts changed.
                supabase.syncContactsIfEnabled()
            }
        }
        .onChange(of: supabase.isSignedIn) { signedIn in
            if signedIn {
                maybePreloadData()
                supabase.syncContactsIfEnabled()
                if viewModel.isWorking {
                    loadingVisible = true
                    loadingIsActive = true
                }
                viewModel.startAutoRefresh()
            } else {
                loadingVisible = false
                loadingIsActive = false
                // Allow report preload again when switching accounts without quitting the app.
                hasTriggeredPreload = false
            }
        }
        .onChange(of: supabase.isAdmin) { isAdmin in
            if !isAdmin, selection == .admin {
                selection = .overview
            }
        }
        .onChange(of: viewModel.sinceEnabled) { _ in scheduleFilterRefresh() }
        .onChange(of: viewModel.untilEnabled) { _ in scheduleFilterRefresh() }
        .onChange(of: viewModel.sinceDate) { _ in scheduleFilterRefresh() }
        .onChange(of: viewModel.untilDate) { _ in scheduleFilterRefresh() }
        .onChange(of: viewModel.thresholdHours) { _ in scheduleFilterRefresh() }
        .onChange(of: viewModel.topCount) { _ in scheduleFilterRefresh() }
        .onChange(of: viewModel.isWorking) { isWorking in
            guard supabase.isSignedIn else {
                loadingVisible = false
                loadingIsActive = false
                return
            }
            if isWorking {
                loadingVisible = true
                loadingIsActive = true
            } else if loadingVisible {
                loadingIsActive = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    loadingVisible = false
                }
            }
        }
        .onChange(of: selection) { newValue in
            if newValue == .chats {
                resetChatPage()
            }
            scheduleChatListRefresh()
        }
        .onChange(of: chatFilter) { _ in
            if selection == .chats {
                resetChatPage()
            }
            scheduleChatListRefresh()
        }
        .onChange(of: chatSearch) { _ in
            if selection == .chats {
                resetChatPage()
            }
            scheduleChatListRefresh()
        }
        .onChange(of: chatSort) { _ in
            if selection == .chats {
                resetChatPage()
            }
            scheduleChatListRefresh()
        }
        .onChange(of: mergedDMsCacheKey) { _ in
            if selection == .chats {
                resetChatPage()
            }
            scheduleChatListRefresh()
        }
        .onChange(of: pinnedChatIds) { _ in
            scheduleChatListRefresh()
        }
        .onChange(of: viewModel.report?.generatedAt ?? "") { _ in
            if let report = viewModel.report {
                refreshMergedDMsIfNeeded(report: report)
                supabase.syncIfNeeded(report: report)
                if let dbURL = viewModel.dbURL {
                    supabase.syncChatMessagesIfNeeded(report: report, dbURL: dbURL)
                }
            }
            scheduleChatListRefresh()
        }
        .onChange(of: supabase.isSignedIn) { signedIn in
            guard signedIn else { return }
            // The report can be generated before the user signs in (or before plan/role loads),
            // so retry sync once we have a session.
            if let report = viewModel.report {
                supabase.syncIfNeeded(report: report)
                if let dbURL = viewModel.dbURL {
                    supabase.syncChatMessagesIfNeeded(report: report, dbURL: dbURL)
                }
            }
        }
        .onChange(of: supabase.plan) { _ in
            // Plan loads async after sign-in; if the first sync attempt happened before eligibility,
            // retry once plan is known.
            if let report = viewModel.report {
                supabase.syncIfNeeded(report: report)
                if let dbURL = viewModel.dbURL {
                    supabase.syncChatMessagesIfNeeded(report: report, dbURL: dbURL)
                }
            }
        }
        .onChange(of: supabase.isAdmin) { _ in
            // Role loads async after sign-in; retry sync when admin flips true.
            if let report = viewModel.report {
                supabase.syncIfNeeded(report: report)
                if let dbURL = viewModel.dbURL {
                    supabase.syncChatMessagesIfNeeded(report: report, dbURL: dbURL)
                }
            }
        }
        .alert("Grant Full Disk Access", isPresented: $viewModel.showAccessPrompt) {
            Button("Open Settings") { viewModel.openPrivacySettings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(viewModel.accessPromptMessage)
        }
        .alert("Allow Contacts Access", isPresented: $showContactsPrompt) {
            Button("Open Settings") { viewModel.openContactsSettings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("To show contact photos, allow access in System Settings → Privacy & Security → Contacts.")
        }
        .alert("Update Available", isPresented: Binding(get: { updater.updatePromptVisible }, set: { visible in
            if !visible { updater.dismissUpdatePrompt() }
        })) {
            Button("Update Now") { updater.checkForUpdates() }
            Button("Later", role: .cancel) { updater.dismissUpdatePrompt() }
        } message: {
            let version = updater.updatePromptVersion ?? "a new version"
            Text("\(version) is available. Install now?")
        }
        .sheet(isPresented: $showProUpgradeSheet) {
            ProUpgradeSheet(
                theme: theme,
                userEmail: supabase.userEmail ?? "",
                didCopy: $proUpgradeCopied,
                onCopy: {
                    supabase.copyToClipboard(supabase.userEmail ?? "")
                    proUpgradeCopied = true
                },
                onOpenMessages: {
                    supabase.openMessagesApp()
                },
                onClose: {
                    showProUpgradeSheet = false
                    proUpgradeCopied = false
                }
            )
        }
    }

    private var visibleSidebarItems: [SidebarItem] {
        // Keep "Access" above "Updates" so users can re-grant permissions after updating.
        // Show "Admin" below "Updates" for admin users only.
        var items: [SidebarItem] = [.overview, .chats, .filters, .reports, .access, .updates]
        if supabase.isAdmin { items.append(.admin) }
        return items
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(visibleSidebarItems) { item in
                SidebarRow(item: item, isSelected: selection == item, theme: theme)
                    .tag(item)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [theme.surfaceDeep, theme.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(minWidth: 220)
    }

    private var detailView: some View {
        ZStack {
            background
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: ScrollOffsetPreferenceKey.self, value: geo.frame(in: .named("scroll")).minY)
                        }
                        .frame(height: 0)
                        VStack(alignment: .leading, spacing: 12) {
                            Color.clear.frame(height: 0).id("top")
                            header
                            if loadingVisible {
                                LoadingIndicator(theme: theme, isActive: loadingIsActive)
                            }
                            sectionContent
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                .animation(.easeInOut(duration: 0.3), value: selection)
                            if !viewModel.statusMessage.isEmpty {
                                Text(viewModel.statusMessage)
                                    .font(.system(size: 12))
                                    .foregroundStyle(viewModel.statusIsError ? .red : theme.textSecondary)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                        .padding(.top, 2)
                        .foregroundStyle(theme.textPrimary)
                    }
                    .coordinateSpace(name: "scroll")
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                        showBackToTop = offset < -240
                    }
                    .onChange(of: selectedChatId) { newValue in
                        if newValue != nil {
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo("top", anchor: .top)
                                }
                            }
                        } else if let anchor = lastChatListAnchor {
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(anchor, anchor: .top)
                                }
                            }
                        }
                    }

                    if showBackToTop {
                        BackToTopButton(theme: theme) {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                        .padding(24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            TopShadowOverlay(theme: theme)
            if let moodChat = moodDetailsChat {
                MoodDetailsSheet(
                    chatLabel: moodChat.label,
                    otherLabel: moodChat.isGroup ? "Others" : firstNameOnly(moodChat.label),
                    moods: moodChat.moodTimeline,
                    summary: moodChat.moodSummary,
                    phraseMoods: moodChat.phraseMoods,
                    theme: theme,
                    onClose: { moodDetailsChat = nil }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(10)
            }
        }
    }

    private var header: some View {
        ZStack {
            HeroHeaderBackground(theme: theme)
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.accent.opacity(0.7), theme.accentAlt.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .shadow(color: theme.shadow.opacity(0.35), radius: 8, x: 0, y: 5)
                    Image(systemName: "message.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("iMessages Stats")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(viewModel.report == nil ? "Local analytics for iMessage" : "Updated \(formattedGeneratedAt(viewModel.report?.generatedAt))")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                HStack(spacing: 12) {
                    Toggle("Auto Refresh", isOn: $viewModel.autoRefreshEnabled)
                        .toggleStyle(PillToggleStyle(theme: theme))
                    if let htmlURL = viewModel.latestHTMLURL {
                        Button("Open Report") { viewModel.openFile(htmlURL) }
                            .buttonStyle(PrimaryButtonStyle(theme: theme))
                    }
                    if supabase.isSignedIn {
                        Button("Sign out") { supabase.signOut() }
                            .buttonStyle(GhostButtonStyle(theme: theme))
                    }
                }
            }
            .padding(16)
        }
        .background(CardSurface(theme: theme, cornerRadius: 20, showShadow: false, elevation: .flat))
    }


    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .overview:
            overviewSection
        case .chats:
            chatsSection
        case .filters:
            filtersSection
        case .reports:
            reportsSection
        case .admin:
            adminSection
        case .access:
            accessSection
        case .updates:
            updatesSection
        }
    }

    private var overviewSection: some View {
        Group {
            if let report = viewModel.report {
                StatGrid(report: report, chatContext: nil, format: format, formatCount: formatCount, theme: theme)
                SectionCard(title: "Overview Charts", subtitle: "Sent vs received and read behavior", theme: theme) {
                    OverviewCharts(report: report, theme: theme, format: format)
                }
                SectionCard(title: "Summary", subtitle: "Key metrics (avg trimmed, left-on-read capped at 7d)", theme: theme) {
                    SummaryTabs(report: report, format: format, formatCount: formatCount, theme: theme)
                }
            } else {
                EmptyStateCard(
                    icon: "lock.shield.fill",
                    title: "Waiting for Access",
                    subtitle: "Grant access to your chat.db and the report will refresh automatically.",
                    theme: theme
                )
            }
        }
    }

    private var adminSection: some View {
        Group {
            if !supabase.isAdmin {
                EmptyStateCard(
                    icon: "lock.fill",
                    title: "Admin Only",
                    subtitle: "This section is only available to admin users.",
                    theme: theme
                )
            } else {
                AdminPanel(theme: theme, supabase: supabase)
            }
        }
    }

    private var chatsSection: some View {
        Group {
            if let report = viewModel.report {
                let mergedDMs = mergedDMsCache
                let hasDMs = report.chats.contains { !$0.isGroup }
                let selectedChat = selectedChatId.flatMap { id in
                    mergedDMs.first(where: { $0.id == id }) ?? report.chats.first(where: { $0.id == id })
                }
                if let selectedChat {
                    GroupDetailView(
                        chat: selectedChat,
                        theme: theme,
                        format: format,
                        formatCount: formatCount,
                        onShowMoodDetails: { moodDetailsChat = $0 }
                    ) {
                        selectedChatId = nil
                    }
                } else {
                    SectionCard(title: "Chats", subtitle: "Search, filter, and sort", theme: theme) {
                        ChatControls(
                            chatFilter: $chatFilter,
                            chatSearch: $chatSearch,
                            chatSort: $chatSort,
                            theme: theme
                        )

                        let chats = chatListCache
                        let isChatLoading = chatListLoading || (chatFilter == .dm && mergedDMsLoading && chats.isEmpty && hasDMs)
                        if isChatLoading {
                            ChatTableHeader(theme: theme)
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading chats…")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.top, 8)
                        } else if chats.isEmpty {
                        EmptyStateInline(
                            icon: "magnifyingglass",
                            title: "No chats match",
                            subtitle: "Try a different filter or search term.",
                            theme: theme
                        )
                        .padding(.top, 8)
                        } else {
                            ChatTableHeader(theme: theme)
                            let pagedChats = Array(chats.prefix(chatPageSize))
                            LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(pagedChats) { chat in
                                        ChatTableRow(
                                            chat: chat,
                                            theme: theme,
                                            format: format,
                                            isSelected: chat.id == selectedChatId,
                                            isPinned: pinnedChatIds.contains(chat.id),
                                            onTogglePin: { togglePin(chat) },
                                            onOpenMessages: openMessagesAction(for: chat),
                                            onCopyName: { copyChatName(chat) }
                                        )
                                            .id(chat.id)
                                            .onTapGesture {
                                                lastChatListAnchor = chat.id
                                                selectedChatId = chat.id
                                            }
                                    }
                            }
                        }
                    }
                }
            } else {
                EmptyStateCard(
                    icon: "bubble.left.and.bubble.right",
                    title: "No Chat Data Yet",
                    subtitle: "Once the report is generated, your chats will appear here.",
                    theme: theme
                )
            }
        }
        .task(id: viewModel.report?.generatedAt ?? "") {
            if let report = viewModel.report {
                refreshMergedDMsIfNeeded(report: report)
            }
        }
    }

    private var filtersSection: some View {
        SectionCard(title: "Filters", subtitle: "Tune the analysis window", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                FilterBlock(title: "Date Range", subtitle: "Choose how far back to analyze", theme: theme) {
                    VStack(alignment: .leading, spacing: 12) {
                        FilterRow(title: "Since", isOn: $viewModel.sinceEnabled, theme: theme) {
                            DateField(date: $viewModel.sinceDate, isEnabled: viewModel.sinceEnabled, theme: theme)
                        }
                        FilterRow(title: "Until", isOn: $viewModel.untilEnabled, theme: theme) {
                            DateField(date: $viewModel.untilDate, isEnabled: viewModel.untilEnabled, theme: theme)
                        }
                        PresetRow(theme: theme) { preset in
                            applyPreset(preset)
                        }
                    }
                }

                FilterBlock(title: "Thresholds", subtitle: "Tune sensitivity", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {
                        LabeledSliderRow(
                            title: "Left-on-read threshold",
                            valueText: "\(Int(viewModel.thresholdHours)) hours",
                            theme: theme
                        ) {
                            CustomSlider(value: $viewModel.thresholdHours, range: 1...168, step: 1, theme: theme)
                        }

                        LabeledSliderRow(
                            title: "Top chats",
                            valueText: decimalString(viewModel.topCount),
                            theme: theme
                        ) {
                            CustomSlider(
                                value: Binding(get: {
                                    Double(viewModel.topCount)
                                }, set: { newValue in
                                    viewModel.topCount = Int(newValue)
                                }),
                                range: 1...300,
                                step: 1,
                                theme: theme
                            )
                        }
                    }
                }
            }
        }
    }

    private var reportsSection: some View {
        SectionCard(title: "Reports", subtitle: "Open generated files", theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                if let report = viewModel.report {
                    HStack(spacing: 12) {
                        MetaTile(title: "Generated", value: formattedGeneratedAt(report.generatedAt), theme: theme)
                        MetaTile(title: "Top chats", value: decimalString(report.filters.top), theme: theme)
                        MetaTile(title: "Threshold", value: "\(Int(report.filters.thresholdHours))h", theme: theme)
                    }
                    MetaTile(title: "Date range", value: filterRangeSummary(report), theme: theme)
                }

                if let htmlURL = viewModel.latestHTMLURL {
                    Button("Open HTML Report") { viewModel.openFile(htmlURL) }
                        .buttonStyle(PrimaryButtonStyle(theme: theme))
                }
                if let outputFolder = viewModel.outputFolderURL {
                    Button("Open Output Folder") { viewModel.openFile(outputFolder) }
                        .buttonStyle(GhostButtonStyle(theme: theme))
                }
            }
        }
    }

    private var updatesSection: some View {
        SectionCard(title: "Updates", subtitle: "Stay on the latest version", theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    MetaTile(title: "Version", value: appVersionString, theme: theme)
                    MetaTile(title: "Last checked", value: updater.lastChecked.map { formattedUpdateCheck($0) } ?? "Never", theme: theme)
                }
                HStack(spacing: 10) {
                    Button("Check for Updates") { updater.checkForUpdates() }
                        .buttonStyle(PrimaryButtonStyle(theme: theme))
                    Text(updater.status)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var accessSection: some View {
        VStack(spacing: 14) {
            if supabase.isSignedIn {
                SectionCard(title: "Account", subtitle: "Role and session state", theme: theme) {
                    VStack(alignment: .leading, spacing: 12) {
                        let trimmedPlanStatus = supabase.planStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedRoleStatus = supabase.roleStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                        let planStatusLower = trimmedPlanStatus.lowercased()
                        let roleStatusLower = trimmedRoleStatus.lowercased()
                        let showPlanStatusError = !trimmedPlanStatus.isEmpty && (
                            planStatusLower.contains("failed") ||
                            planStatusLower.contains("missing") ||
                            planStatusLower.contains("decode") ||
                            planStatusLower.contains("error") ||
                            planStatusLower.contains("rls")
                        )
                        let showRoleStatusError = !trimmedRoleStatus.isEmpty && (
                            roleStatusLower.contains("failed") ||
                            roleStatusLower.contains("missing") ||
                            roleStatusLower.contains("decode") ||
                            roleStatusLower.contains("error") ||
                            roleStatusLower.contains("rls") ||
                            roleStatusLower.contains("no profile")
                        )
                        HStack {
                            Text("Plan")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            Text(supabase.plan.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(supabase.plan == .pro ? theme.accent : theme.textPrimary)
                        }
                        if supabase.plan != .pro {
                            HStack {
                                Button("Get Pro (Monthly)") {
                                    proUpgradeCopied = false
                                    showProUpgradeSheet = true
                                }
                                    .buttonStyle(PrimaryButtonStyle(theme: theme))
                                Spacer()
                            }
                            Text("Pro is activated manually right now. Send your account email to get upgraded.")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if supabase.isAdmin {
                            HStack {
                                Text("Role")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                                Spacer()
                                Text("Admin")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                            }
                            HStack {
                                Button("Refresh account") { supabase.refreshRole() }
                                    .buttonStyle(GhostButtonStyle(theme: theme))
                                Spacer()
                            }
                        }
                        if showPlanStatusError {
                            Text(trimmedPlanStatus)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if showRoleStatusError {
                            Text(trimmedRoleStatus)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            SectionCard(title: "Access", subtitle: "Permissions required for chat stats and contact names", theme: theme) {
                VStack(alignment: .leading, spacing: 14) {
                AccessRow(
                    title: "Full Disk Access",
                    subtitle: "Read chat.db for stats",
                    isGranted: hasFullDiskAccess,
                    primaryAction: { viewModel.openPrivacySettings() },
                    secondaryAction: { checkFullDiskAccess() },
                    theme: theme
                )
                AccessRow(
                    title: "Contacts Access",
                    subtitle: "Show names and photos",
                    isGranted: hasContactsAccess,
                    primaryAction: { viewModel.openContactsSettings() },
                    secondaryAction: { requestContactsAccess() },
                    theme: theme
                )

                if Bundle.main.bundlePath.contains("AppTranslocation") {
                    Text("Tip: You're running from a translocated path (often launching from a DMG). Drag the app to Applications, open it from there, then grant access.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.top, 4)
                } else {
                    Text("Tip: macOS ties permissions to the installed, signed app. If the code signature changes (common with dev/ad-hoc signing), you may need to grant access again after updates.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.top, 4)
                }
                }
            }
        }
    }

private struct ProUpgradeSheet: View {
    let theme: Theme
    let userEmail: String
    @Binding var didCopy: Bool
    let onCopy: () -> Void
    let onOpenMessages: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Get Pro (Monthly)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                Image(systemName: "crown.fill")
                    .foregroundStyle(theme.accent)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.textSecondary)
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            Text("If you want a Pro account, send your user email to request an upgrade.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your user email")
                    .font(.system(size: 12, weight: .semibold))
                Text(userEmail.isEmpty ? "Not available" : userEmail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surfaceElevated.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button(didCopy ? "Copied" : "Copy Email") { onCopy() }
                    .buttonStyle(PrimaryButtonStyle(theme: theme))
                Button("Open Messages") { onOpenMessages() }
                    .buttonStyle(GhostButtonStyle(theme: theme))
                Spacer()
            }

            Text("After your account is upgraded, relaunch the app and go to Access → Account → Refresh account.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)

            Spacer()
        }
        .padding(18)
        .frame(width: 520, height: 420)
        .background(theme.surfaceDeep.opacity(0.95))
    }
}

    private func filteredChats(
        from chats: [ChatReport],
        mergedDMs: [ChatReport],
        chatFilter: ChatFilter,
        chatSearch: String,
        chatSort: ChatSort,
        pinnedChatIds: Set<Int64>
    ) -> [ChatReport] {
        var filtered: [ChatReport]
        switch chatFilter {
        case .dm:
            filtered = mergedDMs
        case .group:
            filtered = chats.filter { $0.isGroup }
        }

        if !chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = chatSearch.lowercased()
            filtered = filtered.filter {
                $0.label.lowercased().contains(needle) ||
                $0.chatIdentifier.lowercased().contains(needle) ||
                ($0.displayName?.lowercased().contains(needle) ?? false) ||
                $0.contactHandles.contains(where: { $0.lowercased().contains(needle) })
            }
        }

        let parser = ISO8601DateFormatter()
        switch chatSort {
        case .mostRecent:
            filtered.sort {
                let left = parser.date(from: $0.lastMessageDate ?? "") ?? .distantPast
                let right = parser.date(from: $1.lastMessageDate ?? "") ?? .distantPast
                return left > right
            }
        case .mostMessages:
            filtered.sort { $0.totals.total > $1.totals.total }
        case .mostLeftOnRead:
            filtered.sort { ($0.leftOnRead.youLeftThem + $0.leftOnRead.theyLeftYou) > ($1.leftOnRead.youLeftThem + $1.leftOnRead.theyLeftYou) }
        case .fastestReply:
            filtered.sort { ($0.responseTimes.youReply.avgMinutes ?? 1e9) < ($1.responseTimes.youReply.avgMinutes ?? 1e9) }
        case .slowestReply:
            filtered.sort { ($0.responseTimes.youReply.avgMinutes ?? 0) > ($1.responseTimes.youReply.avgMinutes ?? 0) }
        }

        if !pinnedChatIds.isEmpty {
            let pinned = filtered.filter { pinnedChatIds.contains($0.id) }
            let unpinned = filtered.filter { !pinnedChatIds.contains($0.id) }
            filtered = pinned + unpinned
        }

        return filtered
    }

    private func scheduleChatListRefresh() {
        chatListWorkItem?.cancel()
        let workItem = DispatchWorkItem { refreshChatList() }
        chatListWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func refreshChatList() {
        guard let report = viewModel.report else {
            chatListCache = []
            chatListLoading = false
            return
        }

        let localFilter = chatFilter
        let localSearch = chatSearch
        let localSort = chatSort
        let localPinned = pinnedChatIds
        let localMerged = mergedDMsCache
        let pinnedKey = localPinned.sorted().map { String($0) }.joined(separator: ",")
        let key = "\(report.generatedAt)|\(localFilter.rawValue)|\(localSearch.lowercased())|\(localSort.rawValue)|\(mergedDMsCacheKey)|\(pinnedKey)"
        guard key != chatListCacheKey else { return }
        chatListCacheKey = key
        chatListLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let filtered = filteredChats(
                from: report.chats,
                mergedDMs: localMerged,
                chatFilter: localFilter,
                chatSearch: localSearch,
                chatSort: localSort,
                pinnedChatIds: localPinned
            )
            DispatchQueue.main.async {
                chatListCache = filtered
                chatListLoading = false
            }
        }
    }

    private func refreshMergedDMsIfNeeded(report: Report) {
        let key = "\(report.generatedAt)|\(report.chats.count)"
        guard key != mergedDMsCacheKey else { return }
        mergedDMsCacheKey = key
        mergedDMsLoading = true
        let chats = report.chats
        DispatchQueue.global(qos: .userInitiated).async {
            let merged = mergeDMChats(from: chats)
            DispatchQueue.main.async {
                mergedDMsCache = merged
                mergedDMsLoading = false
                scheduleChatListRefresh()
            }
        }
    }

    private func resetChatPage() {
        chatPageWorkItems.forEach { $0.cancel() }
        chatPageWorkItems.removeAll()
        chatPageSize = 20

        let steps: [(Double, Int)] = [
            (0.35, 60),
            (0.7, 140),
            (1.1, 300),
            (1.6, 10_000)
        ]
        for (delay, size) in steps {
            let workItem = DispatchWorkItem {
                chatPageSize = max(chatPageSize, size)
            }
            chatPageWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func togglePin(_ chat: ChatReport) {
        if pinnedChatIds.contains(chat.id) {
            pinnedChatIds.remove(chat.id)
        } else {
            pinnedChatIds.insert(chat.id)
        }
    }

    private func openMessagesAction(for chat: ChatReport) -> (() -> Void)? {
        guard !chat.isGroup else { return nil }
        let handle = chat.contactHandles.first(where: { !$0.isEmpty }) ?? chat.chatIdentifier
        guard !handle.isEmpty else { return nil }
        return {
            let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? handle
            if let url = URL(string: "imessage://\(encoded)") {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: "sms:\(encoded)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func copyChatName(_ chat: ChatReport) {
        let name = chat.label
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
    }

    private func mergeDMChats(from chats: [ChatReport]) -> [ChatReport] {
        let dmChats = chats.filter { !$0.isGroup }
        guard !dmChats.isEmpty else { return [] }
        let grouped = Dictionary(grouping: dmChats, by: { mergeKey(for: $0) })
        return grouped
            .map { mergeDMGroup($0.value, key: $0.key) }
    }

    private func mergeDMGroup(_ chats: [ChatReport], key: String) -> ChatReport {
        let parser = ISO8601DateFormatter()
        let sortedByRecent = chats.sorted {
            let left = parser.date(from: $0.lastMessageDate ?? "") ?? .distantPast
            let right = parser.date(from: $1.lastMessageDate ?? "") ?? .distantPast
            return left > right
        }
        let primary = sortedByRecent.first ?? chats[0]

        let totals = chats.reduce(Totals(sent: 0, received: 0, total: 0)) { partial, chat in
            Totals(
                sent: partial.sent + chat.totals.sent,
                received: partial.received + chat.totals.received,
                total: partial.total + chat.totals.total
            )
        }

        let leftOnRead = LeftOnRead(
            youLeftThem: chats.reduce(0) { $0 + $1.leftOnRead.youLeftThem },
            theyLeftYou: chats.reduce(0) { $0 + $1.leftOnRead.theyLeftYou }
        )

        let responseTimes = ResponseTimes(
            youReply: mergeResponseStats(chats.map { $0.responseTimes.youReply }),
            theyReply: mergeResponseStats(chats.map { $0.responseTimes.theyReply })
        )

        let lastMessageDate = chats
            .compactMap { $0.lastMessageDate }
            .compactMap { parser.date(from: $0) }
            .max()
            .map { parser.string(from: $0) } ?? primary.lastMessageDate

        let earliest = chats
            .compactMap { chat -> (Date, ChatReport)? in
                guard let dateString = chat.firstMessageDate,
                      let date = parser.date(from: dateString) else { return nil }
                return (date, chat)
            }
            .sorted { $0.0 < $1.0 }
            .first

        let firstMessageDate = earliest.map { parser.string(from: $0.0) } ?? primary.firstMessageDate
        let firstMessageText = earliest?.1.firstMessageText ?? primary.firstMessageText
        let firstMessageFromMe = earliest?.1.firstMessageFromMe ?? primary.firstMessageFromMe
        let firstConversation = earliest?.1.firstConversation ?? primary.firstConversation

        let energyScore = mergeEnergyScore(chats: chats, totalMessages: totals.total, fallback: primary.energyScore)

        let streaks = StreakStats(
            currentDays: primary.streaks.currentDays,
            longestDays: chats.map { $0.streaks.longestDays }.max() ?? primary.streaks.longestDays,
            longestSilenceDays: chats.map { $0.streaks.longestSilenceDays }.max() ?? primary.streaks.longestSilenceDays
        )

        let initiators = InitiatorStats(
            youStarted: chats.reduce(0) { $0 + $1.initiators.youStarted },
            themStarted: chats.reduce(0) { $0 + $1.initiators.themStarted }
        )

        let peak = mergePeak(chats: chats)
        let reengagement = mergeReengagement(chats: chats)

        let timeOfDay = mergeTimeOfDay(chats: chats)
        let weekdayActivity = mergeWeekdayActivity(chats: chats)

        let recentBalance = mergeRecentBalance(chats: chats, total: totals.total)

        let attachments = AttachmentStats(
            you: chats.reduce(0) { $0 + $1.attachments.you },
            them: chats.reduce(0) { $0 + $1.attachments.them },
            total: chats.reduce(0) { $0 + $1.attachments.total }
        )

        let replyBuckets = mergeReplyBuckets(chats: chats)
        let moodSummary = MoodSummary(
            friendly: chats.reduce(0) { $0 + $1.moodSummary.friendly },
            romantic: chats.reduce(0) { $0 + $1.moodSummary.romantic },
            professional: chats.reduce(0) { $0 + $1.moodSummary.professional },
            neutral: chats.reduce(0) { $0 + $1.moodSummary.neutral }
        )

        let moodTimeline = mergeMoodTimeline(chats: chats)
        let greetings = GreetingStats(
            youMorning: chats.reduce(0) { $0 + $1.greetings.youMorning },
            themMorning: chats.reduce(0) { $0 + $1.greetings.themMorning },
            youNight: chats.reduce(0) { $0 + $1.greetings.youNight },
            themNight: chats.reduce(0) { $0 + $1.greetings.themNight }
        )

        let contactHandles = Array(Set(chats.flatMap { $0.contactHandles })).sorted()
        let participants = mergeParticipants(chats: chats)
        let participantReplySpeeds = mergeParticipantReplySpeeds(chats: chats)

        let topWords = mergeWordStats(chats.flatMap { $0.topWords }, limit: 10)
        let topWordsYou = mergeWordStats(chats.flatMap { $0.topWordsYou }, limit: 10)
        let topWordsThem = mergeWordStats(chats.flatMap { $0.topWordsThem }, limit: 10)

        let topEmojis = mergeEmojiStats(chats.flatMap { $0.topEmojis }, limit: 10)
        let topEmojisYou = mergeEmojiStats(chats.flatMap { $0.topEmojisYou }, limit: 10)
        let topEmojisThem = mergeEmojiStats(chats.flatMap { $0.topEmojisThem }, limit: 10)

        let reactions = mergeReactionStats(chats.flatMap { $0.reactions }, limit: 12)
        let topPhrases = mergePhraseStats(chats.flatMap { $0.topPhrases }, limit: 10)
        let phraseMoods = mergePhraseMoodStats(chats.flatMap { $0.phraseMoods })

        let label = preferredLabel(from: chats, fallback: primary.label)
        let mergedId = mergedChatId(for: key)
        let contactKey = key.hasPrefix("chat-") ? nil : key

        return ChatReport(
            id: mergedId,
            chatIdentifier: primary.chatIdentifier,
            displayName: primary.displayName,
            label: label,
            contactHandles: contactHandles,
            contactKey: contactKey,
            groupPhotoPath: nil,
            totals: totals,
            leftOnRead: leftOnRead,
            responseTimes: responseTimes,
            lastMessageDate: lastMessageDate,
            firstMessageText: firstMessageText,
            firstMessageDate: firstMessageDate,
            firstMessageFromMe: firstMessageFromMe,
            energyScore: energyScore,
            streaks: streaks,
            initiators: initiators,
            peak: peak,
            reengagement: reengagement,
            timeOfDay: timeOfDay,
            recentBalance: recentBalance,
            attachments: attachments,
            topEmojis: topEmojis,
            topEmojisYou: topEmojisYou,
            topEmojisThem: topEmojisThem,
            reactions: reactions,
            replyBuckets: replyBuckets,
            moodSummary: moodSummary,
            moodTimeline: moodTimeline,
            greetings: greetings,
            firstConversation: firstConversation,
            participantReplySpeeds: participantReplySpeeds,
            weekdayActivity: weekdayActivity,
            topPhrases: topPhrases,
            phraseMoods: phraseMoods,
            participantCount: 2,
            isGroup: false,
            participants: participants,
            topWords: topWords,
            topWordsYou: topWordsYou,
            topWordsThem: topWordsThem
        )
    }

    private func preferredLabel(from chats: [ChatReport], fallback: String) -> String {
        for chat in chats {
            let label = chat.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, !looksLikeHandle(label), label.lowercased() != "unknown" {
                return label
            }
        }
        return fallback
    }

    private func mergeKey(for chat: ChatReport) -> String {
        if let contactKey = chat.contactKey, !contactKey.isEmpty {
            return contactKey
        }
        let normalizedHandles = chat.contactHandles
            .map { normalizeHandle($0) }
            .filter { !$0.isEmpty }
        if !normalizedHandles.isEmpty {
            return "handles:\(normalizedHandles.sorted().joined(separator: "|"))"
        }
        let label = chat.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, !looksLikeHandle(label), label.lowercased() != "unknown" {
            return "label:\(label.lowercased())"
        }
        return "chat-\(chat.id)"
    }

    private func normalizeHandle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("@") { return trimmed }
        let digits = trimmed.filter { $0.isNumber }
        return digits.isEmpty ? trimmed : digits
    }

    private func looksLikeHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("@") { return true }
        let digits = trimmed.filter { $0.isNumber }
        let letters = trimmed.filter { $0.isLetter }
        return !digits.isEmpty && letters.isEmpty
    }

    private func mergedChatId(for key: String) -> Int64 {
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        var signed = Int64(bitPattern: hash)
        if signed == 0 { signed = 1 }
        if signed == Int64.min { signed = Int64.max }
        return signed > 0 ? -signed : signed
    }

    private func mergeResponseStats(_ stats: [ResponseStats]) -> ResponseStats {
        let totalCount = stats.reduce(0) { $0 + $1.count }
        func weighted(_ key: KeyPath<ResponseStats, Double?>) -> Double? {
            var sum = 0.0
            var count = 0
            for stat in stats {
                guard let value = stat[keyPath: key], stat.count > 0 else { continue }
                sum += value * Double(stat.count)
                count += stat.count
            }
            return count > 0 ? sum / Double(count) : nil
        }
        return ResponseStats(
            count: totalCount,
            avgMinutes: weighted(\.avgMinutes),
            medianMinutes: weighted(\.medianMinutes),
            p90Minutes: weighted(\.p90Minutes)
        )
    }

    private func mergeEnergyScore(chats: [ChatReport], totalMessages: Int, fallback: Int) -> Int {
        guard totalMessages > 0 else { return fallback }
        let weighted = chats.reduce(0.0) { partial, chat in
            partial + Double(chat.energyScore) * Double(chat.totals.total)
        }
        return Int((weighted / Double(totalMessages)).rounded())
    }

    private func mergePeak(chats: [ChatReport]) -> ConversationPeak {
        let best = chats.max { $0.peak.total < $1.peak.total }
        let maxChain = chats.map { $0.peak.longestBackAndForth }.max() ?? 0
        return ConversationPeak(
            date: best?.peak.date ?? chats.first?.peak.date,
            total: best?.peak.total ?? 0,
            longestBackAndForth: maxChain
        )
    }

    private func mergeReengagement(chats: [ChatReport]) -> ReengagementStats {
        let youCount = chats.reduce(0) { $0 + $1.reengagement.youCount }
        let themCount = chats.reduce(0) { $0 + $1.reengagement.themCount }
        func weightedAvg(_ key: KeyPath<ReengagementStats, Double?>, countKey: KeyPath<ReengagementStats, Int>) -> Double? {
            var sum = 0.0
            var count = 0
            for chat in chats {
                let c = chat.reengagement[keyPath: countKey]
                guard let value = chat.reengagement[keyPath: key], c > 0 else { continue }
                sum += value * Double(c)
                count += c
            }
            return count > 0 ? sum / Double(count) : nil
        }
        return ReengagementStats(
            youAvgGapHours: weightedAvg(\.youAvgGapHours, countKey: \.youCount),
            themAvgGapHours: weightedAvg(\.themAvgGapHours, countKey: \.themCount),
            youCount: youCount,
            themCount: themCount
        )
    }

    private func mergeTimeOfDay(chats: [ChatReport]) -> [TimeOfDayBin] {
        var bins: [Int: (you: Int, them: Int)] = [:]
        for chat in chats {
            for bin in chat.timeOfDay {
                let existing = bins[bin.hour] ?? (0, 0)
                bins[bin.hour] = (existing.you + bin.you, existing.them + bin.them)
            }
        }
        return (0..<24).map { hour in
            let entry = bins[hour] ?? (0, 0)
            return TimeOfDayBin(id: hour, hour: hour, total: entry.you + entry.them, you: entry.you, them: entry.them)
        }
    }

    private func mergeWeekdayActivity(chats: [ChatReport]) -> [WeekdayBin] {
        var bins: [Int: (you: Int, them: Int)] = [:]
        for chat in chats {
            for bin in chat.weekdayActivity {
                let existing = bins[bin.weekday] ?? (0, 0)
                bins[bin.weekday] = (existing.you + bin.you, existing.them + bin.them)
            }
        }
        return bins.keys.sorted().map { weekday in
            let entry = bins[weekday] ?? (0, 0)
            return WeekdayBin(id: weekday, weekday: weekday, total: entry.you + entry.them, you: entry.you, them: entry.them)
        }
    }

    private func mergeRecentBalance(chats: [ChatReport], total: Int) -> RecentBalance {
        let last30 = chats.reduce(0) { $0 + $1.recentBalance.last30 }
        let last90 = chats.reduce(0) { $0 + $1.recentBalance.last90 }
        let totalCount = max(total, 1)
        return RecentBalance(
            last30: last30,
            last90: last90,
            total: total,
            last30Pct: (Double(last30) / Double(totalCount)) * 100.0,
            last90Pct: (Double(last90) / Double(totalCount)) * 100.0
        )
    }

    private func mergeReplyBuckets(chats: [ChatReport]) -> ReplySpeedBuckets {
        func sumBuckets(_ buckets: [ReplyBucketStats]) -> ReplyBucketStats {
            ReplyBucketStats(
                under5m: buckets.reduce(0) { $0 + $1.under5m },
                under1h: buckets.reduce(0) { $0 + $1.under1h },
                under6h: buckets.reduce(0) { $0 + $1.under6h },
                under24h: buckets.reduce(0) { $0 + $1.under24h },
                under7d: buckets.reduce(0) { $0 + $1.under7d },
                over7d: buckets.reduce(0) { $0 + $1.over7d }
            )
        }
        let youBuckets = sumBuckets(chats.map { $0.replyBuckets.you })
        let themBuckets = sumBuckets(chats.map { $0.replyBuckets.them })
        return ReplySpeedBuckets(you: youBuckets, them: themBuckets)
    }

    private func mergeMoodTimeline(chats: [ChatReport]) -> [MoodDaily] {
        var map: [String: (friendly: Int, romantic: Int, professional: Int, neutral: Int)] = [:]
        for chat in chats {
            for entry in chat.moodTimeline {
                let existing = map[entry.date] ?? (0, 0, 0, 0)
                map[entry.date] = (
                    existing.friendly + entry.friendly,
                    existing.romantic + entry.romantic,
                    existing.professional + entry.professional,
                    existing.neutral + entry.neutral
                )
            }
        }
        return map.keys.sorted().map { date in
            let entry = map[date] ?? (0, 0, 0, 0)
            return MoodDaily(
                id: date,
                date: date,
                friendly: entry.friendly,
                romantic: entry.romantic,
                professional: entry.professional,
                neutral: entry.neutral
            )
        }
    }

    private func mergeParticipants(chats: [ChatReport]) -> [ParticipantStat] {
        var counts: [String: Int] = [:]
        for chat in chats {
            for participant in chat.participants {
                counts[participant.label, default: 0] += participant.count
            }
        }
        return counts
            .map { ParticipantStat(id: $0.key, label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private func mergeParticipantReplySpeeds(chats: [ChatReport]) -> [ParticipantReplyStat] {
        var sums: [String: (sum: Double, count: Int)] = [:]
        for chat in chats {
            for stat in chat.participantReplySpeeds {
                guard let avg = stat.avgMinutes else { continue }
                var entry = sums[stat.label] ?? (0, 0)
                entry.sum += avg
                entry.count += 1
                sums[stat.label] = entry
            }
        }
        return sums.map {
            ParticipantReplyStat(
                id: $0.key,
                label: $0.key,
                avgMinutes: $0.value.count > 0 ? $0.value.sum / Double($0.value.count) : nil
            )
        }
    }

    private func mergeWordStats(_ stats: [WordStat], limit: Int) -> [WordStat] {
        var counts: [String: Int] = [:]
        for stat in stats {
            counts[stat.word, default: 0] += stat.count
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { WordStat(id: $0.key, word: $0.key, count: $0.value) }
    }

    private func mergeEmojiStats(_ stats: [EmojiStat], limit: Int) -> [EmojiStat] {
        var counts: [String: Int] = [:]
        for stat in stats {
            counts[stat.emoji, default: 0] += stat.count
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { EmojiStat(id: $0.key, emoji: $0.key, count: $0.value) }
    }

    private func mergeReactionStats(_ stats: [ReactionStat], limit: Int) -> [ReactionStat] {
        var counts: [String: Int] = [:]
        for stat in stats {
            counts[stat.reaction, default: 0] += stat.count
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ReactionStat(id: $0.key, reaction: $0.key, count: $0.value) }
    }

    private func mergePhraseStats(_ stats: [PhraseStat], limit: Int) -> [PhraseStat] {
        var counts: [String: Int] = [:]
        for stat in stats {
            counts[stat.phrase, default: 0] += stat.count
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { PhraseStat(id: $0.key, phrase: $0.key, count: $0.value) }
    }

    private func mergePhraseMoodStats(_ stats: [PhraseMoodStat]) -> [PhraseMoodStat] {
        var counts: [String: (phrase: String, mood: String, you: Int, them: Int)] = [:]
        for stat in stats {
            let key = "\(stat.mood)|\(stat.phrase)"
            let entry = counts[key] ?? (stat.phrase, stat.mood, 0, 0)
            counts[key] = (entry.phrase, entry.mood, entry.you + stat.youCount, entry.them + stat.themCount)
        }
        return counts.map {
            PhraseMoodStat(
                id: "\($0.value.mood.lowercased())-\($0.value.phrase)",
                phrase: $0.value.phrase,
                mood: $0.value.mood,
                youCount: $0.value.you,
                themCount: $0.value.them
            )
        }
        .sorted { ($0.youCount + $0.themCount) > ($1.youCount + $1.themCount) }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [theme.backgroundTop, theme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [theme.accent.opacity(0.18), Color.clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 260
            )
            RadialGradient(
                colors: [theme.accentAlt.opacity(0.14), Color.clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 280
            )
            RadialGradient(
                colors: [theme.accentWarm.opacity(0.10), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
    }

    private func format(_ value: Double?) -> String {
        return humanizeMinutes(value)
    }

    private func formatCount(_ value: Int) -> String {
        return decimalString(value)
    }

    private func formattedGeneratedAt(_ value: String?) -> String {
        guard let value else { return "—" }
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: value) {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return value
    }

    private func filterRangeSummary(_ report: Report) -> String {
        let since = formattedShortDate(report.filters.since)
        let until = formattedShortDate(report.filters.until)
        if since == nil && until == nil {
            return "All time"
        }
        if let since, let until {
            return "\(since) → \(until)"
        }
        if let since {
            return "\(since) → Now"
        }
        if let until {
            return "Until \(until)"
        }
        return "All time"
    }

    private func formattedShortDate(_ value: String?) -> String? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: value) {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
        return value
    }

    private func applyPreset(_ preset: PresetRange) {
        if let days = preset.days {
            let sinceDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            viewModel.sinceEnabled = true
            viewModel.untilEnabled = false
            viewModel.sinceDate = sinceDate
        } else {
            viewModel.sinceEnabled = false
            viewModel.untilEnabled = false
        }
        scheduleFilterRefresh()
    }

    private func scheduleFilterRefresh() {
        filterRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak viewModel] in
            guard let viewModel else { return }
            if !viewModel.isWorking {
                viewModel.generateReport()
            }
        }
        filterRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func humanizeMinutes(_ value: Double?) -> String {
        guard let minutes = value else { return "—" }
        if minutes < 60 {
            let rounded = Int(minutes.rounded())
            return "\(rounded) min"
        }
        let hours = minutes / 60
        if hours < 24 {
            let rounded = hours.rounded()
            if abs(hours - rounded) < 0.05 {
                let h = Int(rounded)
                return "\(h) \(h == 1 ? "hr" : "hrs")"
            }
            return String(format: "%.1f hrs", hours)
        }
        let days = hours / 24
        let rounded = days.rounded()
        if abs(days - rounded) < 0.05 {
            let d = Int(rounded)
            return "\(d) \(d == 1 ? "day" : "days")"
        }
        return String(format: "%.1f days", days)
    }

    private func submitAuth() {
        let email = authEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !authPassword.isEmpty else { return }
        guard hasFullDiskAccess, hasContactsAccess else {
            supabase.setStatus("Grant access before signing in")
            return
        }
        if authIsSigningUp {
            supabase.signUpWithEmail(email: email, password: authPassword, username: authUsername.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            supabase.signInWithEmail(email: email, password: authPassword)
        }
    }

    private func checkFullDiskAccess() {
        let fallback = URL(fileURLWithPath: ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath)
        let url = viewModel.dbURL ?? fallback
        guard FileManager.default.fileExists(atPath: url.path) else {
            hasFullDiskAccess = false
            return
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
            hasFullDiskAccess = true
        } catch {
            hasFullDiskAccess = false
        }
    }

    private func requestContactsAccess() {
        ContactPhotoStore.shared.requestAccess { granted in
            hasContactsAccess = granted
            if granted {
                supabase.notifyContactsAccessGranted()
            }
        }
    }

    private func checkContactsAccessStatus() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        hasContactsAccess = status == .authorized
    }

    private func promptFullDiskAccess() {
        viewModel.accessPromptMessage = "This app needs Full Disk Access to read iMessage data. Click Open Settings and allow access for this app."
        viewModel.showAccessPrompt = true
    }

    private func promptContactsAccess() {
        showContactsPrompt = true
    }

    private func maybePreloadData() {
        guard hasFullDiskAccess else { return }
        guard !viewModel.isWorking else { return }
        // If the user deleted the report outputs, treat that as a cache miss and regenerate.
        let outputFolder = viewModel.outputFolderURL
        let fallbackHTML = outputFolder?.appendingPathComponent("report.html")
        let htmlURL = viewModel.latestHTMLURL ?? fallbackHTML
        let htmlMissing = htmlURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        if hasTriggeredPreload && !htmlMissing && viewModel.report != nil { return }
        hasTriggeredPreload = true
        viewModel.generateReport()
        if supabase.isSignedIn {
            viewModel.startAutoRefresh()
        }
    }

    private var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func formattedUpdateCheck(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case chats
    case filters
    case reports
    case admin
    case access
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .chats: return "Chats"
        case .filters: return "Filters"
        case .reports: return "Reports"
        case .admin: return "Admin"
        case .access: return "Access"
        case .updates: return "Updates"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.bar.xaxis"
        case .chats: return "bubble.left.and.bubble.right"
        case .filters: return "slider.horizontal.3"
        case .reports: return "doc.text.magnifyingglass"
        case .admin: return "person.2.badge.gearshape"
        case .access: return "lock.shield"
        case .updates: return "arrow.down.circle"
        }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                (isSelected ? theme.accent : theme.surfaceElevated).opacity(0.35),
                                theme.surfaceDeep.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
            }
            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? theme.surfaceElevated.opacity(0.9) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? theme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

enum ChatFilter: String, CaseIterable, Identifiable {
    case dm
    case group

    var id: String { rawValue }
}

enum ChatSort: String, CaseIterable, Identifiable {
    case mostRecent
    case mostMessages
    case mostLeftOnRead
    case fastestReply
    case slowestReply

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostRecent: return "Most Recent"
        case .mostMessages: return "Most Messages"
        case .mostLeftOnRead: return "Most Left on Read"
        case .fastestReply: return "Fastest Reply"
        case .slowestReply: return "Slowest Reply"
        }
    }
}

private enum PresetRange: String, CaseIterable, Identifiable {
    case last7
    case last30
    case last90
    case last365
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last7: return "7d"
        case .last30: return "30d"
        case .last90: return "90d"
        case .last365: return "1y"
        case .all: return "All"
        }
    }

    var days: Int? {
        switch self {
        case .last7: return 7
        case .last30: return 30
        case .last90: return 90
        case .last365: return 365
        case .all: return nil
        }
    }
}

private struct Theme {
    let backgroundTop = Color(red: 0.04, green: 0.05, blue: 0.08)
    let backgroundBottom = Color(red: 0.09, green: 0.10, blue: 0.14)
    let surfaceDeep = Color(red: 0.10, green: 0.11, blue: 0.15)
    let surface = Color(red: 0.12, green: 0.13, blue: 0.18)
    let surfaceElevated = Color(red: 0.16, green: 0.17, blue: 0.23)
    let border = Color.white.opacity(0.08)
    let borderStrong = Color.white.opacity(0.14)
    let textPrimary = Color(red: 0.94, green: 0.95, blue: 0.99)
    let textSecondary = Color(red: 0.70, green: 0.74, blue: 0.82)
    let accent = Color(red: 0.38, green: 0.66, blue: 1.0)
    let accentAlt = Color(red: 0.46, green: 0.90, blue: 0.78)
    let accentWarm = Color(red: 1.0, green: 0.74, blue: 0.48)
    let shadow = Color.black.opacity(0.4)
}

private enum TypeScale {
    static let title = Font.system(size: 15, weight: .semibold)
    static let subtitle = Font.system(size: 12)
    static let label = Font.system(size: 11, weight: .semibold)
    static let value = Font.system(size: 20, weight: .bold)
    static let micro = Font.system(size: 10, weight: .semibold)
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum CardElevation {
    case flat
    case raised
    case floating
}

private struct TopShadowOverlay: View {
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Color.black.opacity(0.45), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct BackToTopButton: View {
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                Text("Top")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(PrimaryButtonStyle(theme: theme))
        .shadow(color: theme.shadow.opacity(0.6), radius: 10, x: 0, y: 6)
    }
}

private struct HeroHeaderBackground: View {
    let theme: Theme

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 0.35) + 1) / 2
            let start = UnitPoint(x: 0.15 + (0.55 * phase), y: 0.0)
            let end = UnitPoint(x: 0.85 - (0.55 * phase), y: 1.0)

            LinearGradient(
                colors: [
                    theme.surfaceDeep.opacity(0.8),
                    theme.surfaceElevated.opacity(0.9),
                    theme.surfaceDeep.opacity(0.8)
                ],
                startPoint: start,
                endPoint: end
            )
            .overlay(
                RadialGradient(
                    colors: [theme.accent.opacity(0.16), Color.clear],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 240
                )
            )
            .overlay(
                RadialGradient(
                    colors: [theme.accentAlt.opacity(0.12), Color.clear],
                    center: .bottomTrailing,
                    startRadius: 10,
                    endRadius: 260
                )
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .allowsHitTesting(false)
    }
}

private struct CardSurface: View {
    let theme: Theme
    let cornerRadius: CGFloat
    let isSelected: Bool
    let showShadow: Bool
    let elevation: CardElevation

    init(
        theme: Theme,
        cornerRadius: CGFloat = 16,
        isSelected: Bool = false,
        showShadow: Bool = true,
        elevation: CardElevation = .raised
    ) {
        self.theme = theme
        self.cornerRadius = cornerRadius
        self.isSelected = isSelected
        self.showShadow = showShadow
        self.elevation = elevation
    }

    var body: some View {
        let gradientColors: [Color] = {
            switch elevation {
            case .flat:
                return [theme.surfaceDeep, theme.surfaceDeep]
            case .raised:
                return [theme.surfaceElevated, theme.surface]
            case .floating:
                return [theme.surfaceElevated, theme.surfaceDeep]
            }
        }()
        let shadowRadius: CGFloat = {
            switch elevation {
            case .flat: return 0
            case .raised: return 10
            case .floating: return 18
            }
        }()

        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isSelected ? theme.accent.opacity(0.65) : theme.border, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: showShadow ? theme.shadow : .clear, radius: showShadow ? shadowRadius : 0, x: 0, y: showShadow ? (shadowRadius * 0.6) : 0)
    }
}

private struct MoodLegend: View {
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            LegendChip(label: "Friendly", color: theme.accentAlt, theme: theme)
            LegendChip(label: "Romantic", color: Color.pink.opacity(0.85), theme: theme)
            LegendChip(label: "Professional", color: Color.blue.opacity(0.8), theme: theme)
            LegendChip(label: "Neutral", color: Color.gray.opacity(0.7), theme: theme)
        }
    }
}

private struct LegendChip: View {
    let label: String
    let color: Color
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [theme.surfaceElevated, theme.surfaceDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Capsule()
                        .stroke(theme.border, lineWidth: 1)
                )
        )
    }
}

private struct EmptyStateCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.surfaceElevated, theme.surfaceDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .background(CardSurface(theme: theme, cornerRadius: 18, elevation: .raised))
    }
}

private struct EmptyStateInline: View {
    let icon: String
    let title: String
    let subtitle: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
        }
        .padding(10)
        .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false, elevation: .flat))
    }
}

private struct StickySectionHeader: View {
    let title: String
    let subtitle: String
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceDeep.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )
        )
        .padding(.horizontal, 4)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let theme: Theme
    let showHeader: Bool
    let content: Content

    init(title: String, subtitle: String, theme: Theme, showHeader: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.theme = theme
        self.showHeader = showHeader
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showHeader {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TypeScale.title)
                    Text(subtitle)
                        .font(TypeScale.subtitle)
                        .foregroundStyle(theme.textSecondary)
                }
                Divider()
                    .overlay(theme.border.opacity(0.6))
            }
            content
        }
        .padding(16)
        .background(CardSurface(theme: theme, cornerRadius: 18, elevation: .floating))
    }
}

private struct StatGrid: View {
    let report: Report
    let chatContext: ChatReport?
    let format: (Double?) -> String
    let formatCount: (Int) -> String
    let theme: Theme

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            if let chat = chatContext, chat.isGroup {
                let metrics = groupMetrics(for: chat)
                MetricCard(title: "Your share", value: metrics.share, numericValue: nil, icon: "person.fill", tint: theme.accent, theme: theme)
                MetricCard(title: "Avg share", value: metrics.avgShare, numericValue: nil, icon: "person.2.fill", tint: theme.accentAlt, theme: theme)
                MetricCard(title: "Rank", value: metrics.rank, numericValue: nil, icon: "list.number", tint: theme.accent, theme: theme)
                MetricCard(title: "Vs avg", value: metrics.vsAvg, numericValue: nil, icon: "speedometer", tint: theme.accentAlt, theme: theme)
                MetricCard(title: "You Left", value: formatCount(report.summary.leftOnRead.youLeftThem), numericValue: Double(report.summary.leftOnRead.youLeftThem), icon: "eye.slash", tint: theme.accentAlt, theme: theme)
                MetricCard(title: "They Left", value: formatCount(report.summary.leftOnRead.theyLeftYou), numericValue: Double(report.summary.leftOnRead.theyLeftYou), icon: "eye", tint: theme.accent, theme: theme)
            } else {
                MetricCard(title: "Sent", value: formatCount(report.summary.totals.sent), numericValue: Double(report.summary.totals.sent), icon: "paperplane.fill", tint: theme.accent, theme: theme)
                MetricCard(title: "Received", value: formatCount(report.summary.totals.received), numericValue: Double(report.summary.totals.received), icon: "tray.full.fill", tint: theme.accentAlt, theme: theme)
                MetricCard(title: "Total", value: formatCount(report.summary.totals.total), numericValue: Double(report.summary.totals.total), icon: "sum", tint: theme.accent, theme: theme)
                MetricCard(title: "You Left", value: formatCount(report.summary.leftOnRead.youLeftThem), numericValue: Double(report.summary.leftOnRead.youLeftThem), icon: "eye.slash", tint: theme.accentAlt, theme: theme)
                MetricCard(title: "They Left", value: formatCount(report.summary.leftOnRead.theyLeftYou), numericValue: Double(report.summary.leftOnRead.theyLeftYou), icon: "eye", tint: theme.accent, theme: theme)
                MetricCard(title: "Avg Reply", value: format(report.summary.responseTimes.youReply.avgMinutes), numericValue: nil, icon: "clock.fill", tint: theme.accentAlt, theme: theme)
            }
        }
    }

    private func groupMetrics(for chat: ChatReport) -> (share: String, avgShare: String, rank: String, vsAvg: String) {
        let total = max(chat.totals.total, 0)
        let participantCount = max(chat.participantCount, chat.participants.count, 1)
        let shareValue = total > 0 ? Double(chat.totals.sent) / Double(total) : nil
        let avgShareValue = participantCount > 0 ? 1.0 / Double(participantCount) : nil
        let avgCount = participantCount > 0 ? Double(total) / Double(participantCount) : nil
        let vsAvgValue = (avgCount ?? 0) > 0 ? Double(chat.totals.sent) / (avgCount ?? 1) : nil

        let rankInfo = participantRank(for: chat, totalParticipants: participantCount)
        let rankText = rankInfo.rank > 0 ? "\(rankInfo.rank) / \(rankInfo.total) · Top \(rankInfo.percentile)%" : "—"

        return (
            share: percentString(shareValue),
            avgShare: percentString(avgShareValue),
            rank: rankText,
            vsAvg: ratioString(vsAvgValue)
        )
    }

    private func participantRank(for chat: ChatReport, totalParticipants: Int) -> (rank: Int, total: Int, percentile: Int) {
        var counts = chat.participants
        if !counts.contains(where: { $0.label == "You" }) {
            counts.append(ParticipantStat(id: "you", label: "You", count: chat.totals.sent))
        }
        let sorted = counts.sorted { $0.count > $1.count }
        let total = max(totalParticipants, sorted.count)
        guard let index = sorted.firstIndex(where: { $0.label == "You" }) else {
            return (rank: 0, total: total, percentile: 0)
        }
        let rank = index + 1
        let percentile: Int
        if total <= 1 {
            percentile = 100
        } else {
            let value = (1.0 - Double(rank - 1) / Double(max(total - 1, 1))) * 100.0
            percentile = Int(value.rounded())
        }
        return (rank: rank, total: total, percentile: percentile)
    }

    private func percentString(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func ratioString(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1fx", value)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let numericValue: Double?
    let icon: String
    let tint: Color
    let theme: Theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.35), tint.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(TypeScale.label)
                    .foregroundStyle(theme.textSecondary)
                if let numericValue {
                    AnimatedCountText(value: numericValue, formatter: NumberFormatters.decimal)
                        .font(TypeScale.value)
                        .animation(.easeOut(duration: 0.6), value: numericValue)
                } else {
                    Text(value)
                        .font(TypeScale.value)
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(theme: theme, cornerRadius: 16, elevation: .raised))
    }
}

private struct OverviewCharts: View {
    let report: Report
    let theme: Theme
    let format: (Double?) -> String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            MiniChartCard(title: "Sent vs Received", theme: theme) {
                Chart {
                    BarMark(x: .value("Type", "Sent"), y: .value("Count", report.summary.totals.sent))
                        .foregroundStyle(theme.accent)
                    BarMark(x: .value("Type", "Received"), y: .value("Count", report.summary.totals.received))
                        .foregroundStyle(theme.accentAlt)
                }
                .frame(height: 160)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                        AxisValueLabel().foregroundStyle(theme.textSecondary).font(.system(size: 10))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                        AxisValueLabel().foregroundStyle(theme.textSecondary).font(.system(size: 10))
                    }
                }
                .chartPlotStyle { plot in
                    plot.background(theme.surfaceDeep.opacity(0.45)).cornerRadius(8)
                }
            }

            MiniChartCard(title: "Left on Read", theme: theme) {
                Chart {
                    BarMark(x: .value("Type", "You left"), y: .value("Count", report.summary.leftOnRead.youLeftThem))
                        .foregroundStyle(theme.accent)
                    BarMark(x: .value("Type", "They left"), y: .value("Count", report.summary.leftOnRead.theyLeftYou))
                        .foregroundStyle(theme.accentAlt)
                }
                .frame(height: 160)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                        AxisValueLabel().foregroundStyle(theme.textSecondary).font(.system(size: 10))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                        AxisValueLabel().foregroundStyle(theme.textSecondary).font(.system(size: 10))
                    }
                }
                .chartPlotStyle { plot in
                    plot.background(theme.surfaceDeep.opacity(0.45)).cornerRadius(8)
                }
            }

            MiniChartCard(title: "Avg Reply Time", theme: theme) {
                Chart {
                    BarMark(x: .value("Person", "You"), y: .value("Minutes", report.summary.responseTimes.youReply.avgMinutes ?? 0))
                        .foregroundStyle(theme.accent)
                    BarMark(x: .value("Person", "Them"), y: .value("Minutes", report.summary.responseTimes.theyReply.avgMinutes ?? 0))
                        .foregroundStyle(theme.accentAlt)
                }
                .frame(height: 160)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                        AxisValueLabel().foregroundStyle(theme.textSecondary).font(.system(size: 10))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                        AxisValueLabel().foregroundStyle(theme.textSecondary).font(.system(size: 10))
                    }
                }
                .chartPlotStyle { plot in
                    plot.background(theme.surfaceDeep.opacity(0.45)).cornerRadius(8)
                }
            }
        }
    }
}

private struct MiniChartCard<Content: View>: View {
    let title: String
    let theme: Theme
    let content: Content

    init(title: String, theme: Theme, @ViewBuilder content: () -> Content) {
        self.title = title
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(theme.textSecondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false, elevation: .flat))
    }
}

private struct ValueTile: View {
    let title: String
    let value: String
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false, elevation: .flat))
    }
}

private struct MetaTile: View {
    let title: String
    let value: String
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false, elevation: .flat))
    }
}

private struct ParticipantChart: View {
    let chat: ChatReport
    let theme: Theme

    var body: some View {
        if chat.participants.isEmpty {
            EmptyStateInline(
                icon: "person.2.fill",
                title: "No participants",
                subtitle: "No participant stats available yet.",
                theme: theme
            )
        } else {
            Chart {
                ForEach(chat.participants.prefix(10)) { person in
                    BarMark(
                        x: .value("Person", shortLabel(firstNameOnly(person.label))),
                        y: .value("Count", person.count)
                    )
                    .foregroundStyle(person.label == "You" ? theme.accent : theme.accentAlt)
                    .cornerRadius(3)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .rotationEffect(.degrees(-25))
                                .frame(width: 60, alignment: .trailing)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                    AxisValueLabel().font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                }
            }
            .chartPlotStyle { plot in
                plot.background(theme.surfaceDeep.opacity(0.45)).cornerRadius(8)
            }
            .frame(height: 220)
        }
    }
}

private struct ChatControls: View {
    @Binding var chatFilter: ChatFilter
    @Binding var chatSearch: String
    @Binding var chatSort: ChatSort
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    TextField("Search chats", text: $chatSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))

                HStack(spacing: 8) {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Picker("", selection: $chatSort) {
                        ForEach(ChatSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: 190)
                .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))
            }

            Picker("Filter", selection: $chatFilter) {
                Text("DMs").tag(ChatFilter.dm)
                Text("Groups").tag(ChatFilter.group)
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    QuickFilterChip(title: "Recent", isActive: chatSort == .mostRecent, theme: theme) {
                        chatSort = .mostRecent
                    }
                    QuickFilterChip(title: "Most messages", isActive: chatSort == .mostMessages, theme: theme) {
                        chatSort = .mostMessages
                    }
                    QuickFilterChip(title: "Left on read", isActive: chatSort == .mostLeftOnRead, theme: theme) {
                        chatSort = .mostLeftOnRead
                    }
                    QuickFilterChip(title: "Fast reply", isActive: chatSort == .fastestReply, theme: theme) {
                        chatSort = .fastestReply
                    }
                    QuickFilterChip(title: "Slow reply", isActive: chatSort == .slowestReply, theme: theme) {
                        chatSort = .slowestReply
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct ChatTableHeader: View {
    let theme: Theme
    private let statWidth: CGFloat = 74

    var body: some View {
        HStack(spacing: 12) {
            Text("Chat")
                .font(TypeScale.label)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            HStack(spacing: 12) {
                headerCell("Sent")
                headerCell("Recv")
                headerCell("Left You")
                headerCell("Left Them")
                headerCell("Avg Reply")
            }
        }
        .padding(.horizontal, 8)
    }

    private func headerCell(_ title: String) -> some View {
        Text(title)
            .font(TypeScale.micro)
            .foregroundStyle(theme.textSecondary)
            .frame(width: statWidth, alignment: .trailing)
    }
}

private struct ChatTableRow: View {
    let chat: ChatReport
    let theme: Theme
    let format: (Double?) -> String
    let isSelected: Bool
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onOpenMessages: (() -> Void)?
    let onCopyName: () -> Void
    private let statWidth: CGFloat = 74
    @State private var isHovering: Bool = false
    @State private var resolvedLabel: String?

    var body: some View {
        let highlight = isSelected || isHovering
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ContactAvatarView(
                    isGroup: chat.isGroup,
                    handles: chat.contactHandles,
                    label: displayLabel,
                    groupPhotoPath: chat.groupPhotoPath,
                    theme: theme
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                statCell(decimalString(chat.totals.sent))
                statCell(decimalString(chat.totals.received))
                statCell(decimalString(chat.leftOnRead.youLeftThem))
                statCell(decimalString(chat.leftOnRead.theyLeftYou))
                statCell(format(chat.responseTimes.youReply.avgMinutes))
            }
        }
        .padding(12)
        .background(
            ZStack(alignment: .leading) {
                CardSurface(theme: theme, cornerRadius: 16, isSelected: highlight, showShadow: false)
                if highlight {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.accent, theme.accentAlt],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 4, height: 36)
                        .padding(.leading, 6)
                }
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
        }
        .task(id: nameKey) {
            resolveLabelIfNeeded()
        }
        .overlay(alignment: .trailing) {
            if isHovering {
                HStack(spacing: 6) {
                    RowActionButton(icon: isPinned ? "pin.slash" : "pin", theme: theme, action: onTogglePin)
                    if let onOpenMessages {
                        RowActionButton(icon: "message", theme: theme, action: onOpenMessages)
                    }
                    RowActionButton(icon: "doc.on.doc", theme: theme, action: onCopyName)
                }
                .padding(.trailing, 12)
                .transition(.opacity)
            }
        }
    }

    private var displayLabel: String {
        resolvedLabel ?? chat.label
    }

    private var nameKey: String {
        ([chat.id.description] + chat.contactHandles + [chat.label]).joined(separator: "|")
    }

    private func resolveLabelIfNeeded() {
        guard !chat.isGroup else {
            resolvedLabel = nil
            return
        }
        ContactPhotoStore.shared.fetchDisplayName(
            handles: chat.contactHandles,
            fallbackName: chat.displayName ?? chat.label
        ) { name in
            guard let name, !name.isEmpty, name != chat.label else {
                resolvedLabel = nil
                return
            }
            resolvedLabel = name
        }
    }

    private var subtitle: String {
        let base = chat.isGroup ? "Group · \(chat.participantCount) participants" : "Direct message"
        if let last = formattedLastMessage(chat.lastMessageDate) {
            return "\(base) · Last \(last)"
        }
        return base
    }

    private func formattedLastMessage(_ value: String?) -> String? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: value) {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
        return value
    }

    private func statCell(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: statWidth, alignment: .trailing)
    }
}

private struct RowActionButton: View {
    let icon: String
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surfaceElevated.opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.border.opacity(0.8), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct QuickFilterChip: View {
    let title: String
    let isActive: Bool
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isActive ? theme.surfaceElevated : theme.surfaceDeep.opacity(0.7))
                        .overlay(
                            Capsule()
                                .stroke(isActive ? theme.accent.opacity(0.6) : theme.border.opacity(0.7), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct AuthGateView: View {
    @Binding var email: String
    @Binding var username: String
    @Binding var password: String
    @Binding var isSigningUp: Bool
    let hasFullDiskAccess: Bool
    let hasContactsAccess: Bool
    let theme: Theme
    let status: String
    let onCheckDiskAccess: () -> Void
    let onOpenDiskSettings: () -> Void
    let onRequestContacts: () -> Void
    let onOpenContactsSettings: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.backgroundTop, theme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.accent.opacity(0.9), theme.accentAlt.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 54, height: 54)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iMessages Stats")
                            .font(.system(size: 28, weight: .bold))
                        Text("Secure local analytics")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    StatusPill(
                        title: hasFullDiskAccess && hasContactsAccess ? "Access ready" : "Access required",
                        isActive: hasFullDiskAccess && hasContactsAccess,
                        theme: theme
                    )
                }
                .frame(maxWidth: 900)

                HStack(alignment: .top, spacing: 18) {
                    AuthAccessCard(
                        hasFullDiskAccess: hasFullDiskAccess,
                        hasContactsAccess: hasContactsAccess,
                        theme: theme,
                        onOpenDiskSettings: onOpenDiskSettings,
                        onCheckDiskAccess: onCheckDiskAccess,
                        onOpenContactsSettings: onOpenContactsSettings,
                        onRequestContacts: onRequestContacts
                    )

                    AuthFormCard(
                        email: $email,
                        username: $username,
                        password: $password,
                        isSigningUp: $isSigningUp,
                        canSubmit: hasFullDiskAccess && hasContactsAccess,
                        status: status,
                        theme: theme,
                        onSubmit: onSubmit
                    )
                }
                .frame(maxWidth: 900)
            }
            .padding(36)
        }
    }
}

private struct AuthAccessCard: View {
    let hasFullDiskAccess: Bool
    let hasContactsAccess: Bool
    let theme: Theme
    let onOpenDiskSettings: () -> Void
    let onCheckDiskAccess: () -> Void
    let onOpenContactsSettings: () -> Void
    let onRequestContacts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 1 · Permissions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            AccessRow(
                title: "Full Disk Access",
                subtitle: "Read chat.db for stats",
                isGranted: hasFullDiskAccess,
                primaryAction: onOpenDiskSettings,
                secondaryAction: onCheckDiskAccess,
                theme: theme
            )
            AccessRow(
                title: "Contacts Access",
                subtitle: "Show names and photos",
                isGranted: hasContactsAccess,
                primaryAction: onOpenContactsSettings,
                secondaryAction: onRequestContacts,
                theme: theme
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(CardSurface(theme: theme, cornerRadius: 20, elevation: .raised))
    }
}

private struct AuthFormCard: View {
    @Binding var email: String
    @Binding var username: String
    @Binding var password: String
    @Binding var isSigningUp: Bool
    let canSubmit: Bool
    let status: String
    let theme: Theme
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 2 · Account")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Email")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                TextField("name@email.com", text: $email)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(CardSurface(theme: theme, cornerRadius: 12, showShadow: false))
            }

            if isSigningUp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Username")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    TextField("Your name", text: $username)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(CardSurface(theme: theme, cornerRadius: 12, showShadow: false))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Password")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(CardSurface(theme: theme, cornerRadius: 12, showShadow: false))
            }

            Toggle("Create a new account", isOn: $isSigningUp)
                .toggleStyle(PillToggleStyle(theme: theme))

            Button(isSigningUp ? "Create account" : "Sign in", action: onSubmit)
                .buttonStyle(PrimaryButtonStyle(theme: theme))
                .disabled(!canSubmit || email.isEmpty || password.isEmpty || (isSigningUp && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(CardSurface(theme: theme, cornerRadius: 20, elevation: .raised))
    }
}

private struct AccessRow: View {
    let title: String
    let subtitle: String
    let isGranted: Bool
    let primaryAction: () -> Void
    let secondaryAction: () -> Void
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isGranted ? theme.accent : theme.accentWarm)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                StatusPill(title: isGranted ? "Granted" : "Required", isActive: isGranted, theme: theme)
            }
            HStack(spacing: 8) {
                Button("Open Settings", action: primaryAction)
                    .buttonStyle(GhostButtonStyle(theme: theme))
                Button("Check", action: secondaryAction)
                    .buttonStyle(GhostButtonStyle(theme: theme))
            }
        }
        .padding(12)
        .background(CardSurface(theme: theme, cornerRadius: 16, showShadow: false))
    }
}

private struct StatusPill: View {
    let title: String
    let isActive: Bool
    let theme: Theme

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isActive ? theme.accent : theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive ? theme.accent.opacity(0.15) : theme.surfaceDeep.opacity(0.8))
                    .overlay(
                        Capsule()
                            .stroke(isActive ? theme.accent.opacity(0.6) : theme.border.opacity(0.7), lineWidth: 1)
                    )
            )
    }
}

private struct ContactAvatarView: View {
    let isGroup: Bool
    let handles: [String]
    let label: String
    let groupPhotoPath: String?
    let size: CGFloat
    let theme: Theme
    @State private var images: [NSImage] = []
    @State private var groupImage: NSImage?
    @State private var didResolveImages: Bool = false
    @State private var didResolveGroup: Bool = false
    @State private var isLoading: Bool = true

    init(isGroup: Bool, handles: [String], label: String, groupPhotoPath: String?, theme: Theme, size: CGFloat = 36) {
        self.isGroup = isGroup
        self.handles = handles
        self.label = label
        self.groupPhotoPath = groupPhotoPath
        self.size = size
        self.theme = theme
    }

    private var key: String {
        (handles + [label, groupPhotoPath ?? ""]).joined(separator: "|")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            (isGroup ? theme.accentAlt : theme.accent).opacity(0.35),
                            (isGroup ? theme.accentAlt : theme.accent).opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
            )
            .frame(width: size, height: size)
            if isLoading {
                Image(systemName: isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: max(12, size * 0.38), weight: .semibold))
                    .foregroundStyle(isGroup ? theme.accentAlt : theme.accent)
            } else if isGroup, let groupImage {
                AvatarImage(image: groupImage)
                    .frame(width: size - 2, height: size - 2)
            } else if images.isEmpty {
                Image(systemName: isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: max(12, size * 0.38), weight: .semibold))
                    .foregroundStyle(isGroup ? theme.accentAlt : theme.accent)
            } else if isGroup {
                GroupAvatarGrid(images: images, size: size - 2)
            } else {
                AvatarImage(image: images[0])
                    .frame(width: size - 2, height: size - 2)
            }
        }
        .task(id: key) {
            isLoading = true
            images = []
            groupImage = nil
            didResolveImages = false
            didResolveGroup = !isGroup || groupPhotoPath?.isEmpty != false

            if isGroup, let groupPhotoPath, !groupPhotoPath.isEmpty {
                GroupPhotoStore.shared.fetchImage(path: groupPhotoPath) { image in
                    groupImage = image
                    didResolveGroup = true
                    updateLoadingState()
                }
            }
            ContactPhotoStore.shared.fetchImages(
                handles: handles,
                maxCount: isGroup ? 4 : 1,
                fallbackName: label
            ) { result in
                images = result
                didResolveImages = true
                updateLoadingState()
            }
        }
    }

    private func updateLoadingState() {
        if isGroup, groupImage != nil {
            isLoading = false
            return
        }
        isLoading = !(didResolveImages && didResolveGroup)
    }
}

private struct GroupAvatarGrid: View {
    let images: [NSImage]
    let size: CGFloat

    var body: some View {
        let items = Array(images.prefix(4))
        let spacing: CGFloat = 2
        let cellSize: CGFloat = max((size - spacing) / 2, 12)

        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                avatarCell(items.indices.contains(0) ? items[0] : nil, size: cellSize)
                avatarCell(items.indices.contains(1) ? items[1] : nil, size: cellSize)
            }
            HStack(spacing: spacing) {
                avatarCell(items.indices.contains(2) ? items[2] : nil, size: cellSize)
                avatarCell(items.indices.contains(3) ? items[3] : nil, size: cellSize)
            }
        }
    }

    private func avatarCell(_ image: NSImage?, size: CGFloat) -> some View {
        ZStack {
            if let image {
                AvatarImage(image: image)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct AvatarImage: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct PresetRow: View {
    let theme: Theme
    let onSelect: (PresetRange) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick presets")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: 8) {
                ForEach(PresetRange.allCases) { preset in
                    PresetChip(title: preset.title, theme: theme) {
                        onSelect(preset)
                    }
                }
            }
        }
    }
}

private struct PresetChip: View {
    let title: String
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(theme.surfaceElevated)
                        .overlay(
                            Capsule()
                                .stroke(theme.border, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct FilterRow<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    let theme: Theme
    let content: Content

    init(title: String, isOn: Binding<Bool>, theme: Theme, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isOn = isOn
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(PillToggleStyle(theme: theme))
            Spacer()
            content
        }
    }
}

private struct LabeledSliderRow<Content: View>: View {
    let title: String
    let valueText: String
    let theme: Theme
    let content: Content

    init(title: String, valueText: String, theme: Theme, @ViewBuilder content: () -> Content) {
        self.title = title
        self.valueText = valueText
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(valueText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            content
                .tint(theme.accent)
        }
    }
}

private struct FilterBlock<Content: View>: View {
    let title: String
    let subtitle: String
    let theme: Theme
    let content: Content

    init(title: String, subtitle: String, theme: Theme, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            content
        }
        .padding(12)
        .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))
    }
}

private struct DateField: View {
    @Binding var date: Date
    let isEnabled: Bool
    let theme: Theme

    var body: some View {
        DatePicker("", selection: $date, displayedComponents: .date)
            .datePickerStyle(.compact)
            .labelsHidden()
            .disabled(!isEnabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(CardSurface(theme: theme, cornerRadius: 12, showShadow: false))
            .opacity(isEnabled ? 1.0 : 0.5)
    }
}

private struct PillToggleStyle: ToggleStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 8) {
                configuration.label
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isOn ? theme.accent : Color.white.opacity(0.12))
                    .frame(width: 44, height: 24)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 18, height: 18)
                            .offset(x: configuration.isOn ? 10 : -10)
                            .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CustomSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let theme: Theme

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let percent = min(max(normalized, 0), 1)
            let fillWidth = max(10, width * percent)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 10)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.accent, theme.accentAlt],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: 10)
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.2), lineWidth: 1)
                    )
                    .offset(x: fillWidth - 9)
                    .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let clampedX = min(max(0, gesture.location.x), width)
                        let raw = range.lowerBound + (Double(clampedX) / Double(width)) * (range.upperBound - range.lowerBound)
                        let stepped = range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step
                        let clampedValue = min(max(range.lowerBound, stepped), range.upperBound)
                        value = clampedValue
                    }
            )
        }
        .frame(height: 20)
    }
}

private struct SummaryTabs: View {
    let report: Report
    let format: (Double?) -> String
    let formatCount: (Int) -> String
    let theme: Theme
    @State private var selection: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selection) {
                Text("Sent").tag(0)
                Text("Received").tag(1)
                Text("Total").tag(2)
                Text("You Left").tag(3)
                Text("They Left").tag(4)
                Text("Avg Reply").tag(5)
            }
            .pickerStyle(.segmented)

        SummaryPane(
            title: selectionTitle,
            value: selectionValue,
            numericValue: selectionNumericValue,
            subtitle: selectionSubtitle,
            theme: theme
        )
    }
    }

    private var selectionTitle: String {
        switch selection {
        case 0: return "Sent"
        case 1: return "Received"
        case 2: return "Total"
        case 3: return "You Left Them"
        case 4: return "They Left You"
        default: return "Your Avg Reply (trimmed)"
        }
    }

    private var selectionValue: String {
        switch selection {
        case 0: return formatCount(report.summary.totals.sent)
        case 1: return formatCount(report.summary.totals.received)
        case 2: return formatCount(report.summary.totals.total)
        case 3: return formatCount(report.summary.leftOnRead.youLeftThem)
        case 4: return formatCount(report.summary.leftOnRead.theyLeftYou)
        default: return format(report.summary.responseTimes.youReply.avgMinutes)
        }
    }

    private var selectionNumericValue: Double? {
        switch selection {
        case 0: return Double(report.summary.totals.sent)
        case 1: return Double(report.summary.totals.received)
        case 2: return Double(report.summary.totals.total)
        case 3: return Double(report.summary.leftOnRead.youLeftThem)
        case 4: return Double(report.summary.leftOnRead.theyLeftYou)
        default: return nil
        }
    }

    private var selectionSubtitle: String {
        switch selection {
        case 0: return "Messages you sent"
        case 1: return "Messages you received"
        case 2: return "All messages"
        case 3: return "They read, you didn't reply"
        case 4: return "You read, they didn't reply"
        default: return "Average reply time (trimmed)"
        }
    }
}

private struct SummaryPane: View {
    let title: String
    let value: String
    let numericValue: Double?
    let subtitle: String
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            if let numericValue {
                AnimatedCountText(value: numericValue, formatter: NumberFormatters.decimal)
                    .font(.system(size: 36, weight: .bold))
                    .animation(.easeOut(duration: 0.6), value: numericValue)
            } else {
                Text(value)
                    .font(.system(size: 36, weight: .bold))
            }
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))
    }
}

private struct GroupDetailView: View {
    let chat: ChatReport
    let theme: Theme
    let format: (Double?) -> String
    let formatCount: (Int) -> String
    let onShowMoodDetails: (ChatReport) -> Void
    let onBack: () -> Void
    @State private var moodWindow: MoodWindow = .last30
    @State private var showContactDetails: Bool = false
    @State private var contactLoading: Bool = false
    @State private var selectedContact: CNContact?
    @State private var resolvedLabel: String?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
            HStack {
                Button(action: onBack) {
                    Label("Back to Chats", systemImage: "chevron.left")
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
                Spacer()
                if !chat.isGroup {
                    Button("Contact") { openContactDetails() }
                        .buttonStyle(GhostButtonStyle(theme: theme))
                }
                Text(chat.isGroup ? "Group" : "DM")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }

            ChatHeroHeader(
                chat: chat,
                displayLabel: displayLabel,
                theme: theme,
                format: format,
                formatCount: formatCount
            )

            Section(header: StickySectionHeader(title: displayLabel, subtitle: chat.isGroup ? "\(chat.participantCount) participants" : "Direct message", theme: theme)) {
                SectionCard(title: displayLabel, subtitle: chat.isGroup ? "\(chat.participantCount) participants" : "Direct message", theme: theme, showHeader: false) {
                    StatGrid(report: reportForChat(chat), chatContext: chat, format: format, formatCount: formatCount, theme: theme)
                }
            }

            Section(header: StickySectionHeader(title: "Scorecard", subtitle: "At-a-glance metrics", theme: theme)) {
                SectionCard(title: "Scorecard", subtitle: "At-a-glance metrics", theme: theme, showHeader: false) {
                    HStack(spacing: 16) {
                        ValueTile(title: "Energy", value: "\(chat.energyScore)/100", theme: theme)
                        ValueTile(title: "Current streak", value: "\(chat.streaks.currentDays) days", theme: theme)
                        ValueTile(title: "Longest streak", value: "\(chat.streaks.longestDays) days", theme: theme)
                        ValueTile(title: "Dominant mood", value: dominantMoodLabel, theme: theme)
                    }
                }
            }

            Section(header: StickySectionHeader(title: "Conversation Highlights", subtitle: "Initiators, peaks, and re-engagement", theme: theme)) {
                SectionCard(title: "Conversation Highlights", subtitle: "Initiators, peaks, and re-engagement", theme: theme, showHeader: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 16) {
                            ValueTile(title: "You initiated", value: decimalString(chat.initiators.youStarted), theme: theme)
                            ValueTile(title: "They initiated", value: decimalString(chat.initiators.themStarted), theme: theme)
                            ValueTile(title: "Longest chain", value: decimalString(chat.peak.longestBackAndForth), theme: theme)
                            ValueTile(title: "Peak day", value: peakDayLabel, theme: theme)
                        }

                        HStack(spacing: 16) {
                            ValueTile(title: "You re-engage", value: formatHours(chat.reengagement.youAvgGapHours), theme: theme)
                            ValueTile(title: "They re-engage", value: formatHours(chat.reengagement.themAvgGapHours), theme: theme)
                            ValueTile(title: "Re-engage count", value: decimalString(chat.reengagement.youCount + chat.reengagement.themCount), theme: theme)
                        }
                    }
                }
            }

            Section(header: StickySectionHeader(title: "Mood Timeline", subtitle: "Recent mood snapshot", theme: theme)) {
                SectionCard(title: "Mood Timeline", subtitle: "Recent mood snapshot", theme: theme, showHeader: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Picker("", selection: $moodWindow) {
                                ForEach(MoodWindow.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            Spacer()
                            Button("Full timeline") {
                                onShowMoodDetails(chat)
                            }
                            .buttonStyle(GhostButtonStyle(theme: theme))
                        }
                        MoodTimelineChart(moods: chat.moodTimeline, theme: theme, windowDays: moodWindow.days, limitPoints: 32, showLegend: true)
                            .frame(height: 200)
                            .onTapGesture {
                                onShowMoodDetails(chat)
                            }
                    }
                }
            }

            Section(header: StickySectionHeader(title: "Reply Speed", subtitle: "How fast replies happen", theme: theme)) {
                SectionCard(title: "Reply Speed", subtitle: "How fast replies happen", theme: theme, showHeader: false) {
                    ReplySpeedSection(
                        isGroup: chat.isGroup,
                        buckets: chat.replyBuckets,
                        participantSpeeds: chat.participantReplySpeeds,
                        otherLabel: firstNameOnly(displayLabel),
                        format: format,
                        theme: theme
                    )
                }
            }

            Section(header: StickySectionHeader(title: "Time of Day", subtitle: "When this chat is most active", theme: theme)) {
                SectionCard(title: "Time of Day", subtitle: "When this chat is most active", theme: theme, showHeader: false) {
                    TimeOfDayChart(bins: chat.timeOfDay, theme: theme)
                        .frame(height: 200)
                }
            }

            Section(header: StickySectionHeader(title: "Weekday Heatmap", subtitle: "Most active days", theme: theme)) {
                SectionCard(title: "Weekday Heatmap", subtitle: "Most active days", theme: theme, showHeader: false) {
                    WeekdayHeatmapView(bins: chat.weekdayActivity, theme: theme)
                }
            }

            Section(header: StickySectionHeader(title: "Top Words", subtitle: "Most common words in this chat", theme: theme)) {
                SectionCard(title: "Top Words", subtitle: "Most common words in this chat", theme: theme, showHeader: false) {
                    TopWordsView(
                        allWords: chat.topWords,
                        yourWords: chat.topWordsYou,
                        theirWords: chat.topWordsThem,
                        theme: theme
                    )
                }
            }

            Section(header: StickySectionHeader(title: "Top Phrases", subtitle: "Most common 2-word phrases", theme: theme)) {
                SectionCard(title: "Top Phrases", subtitle: "Most common 2-word phrases", theme: theme, showHeader: false) {
                    PhraseListView(phrases: chat.topPhrases, theme: theme)
                }
            }

            Section(header: StickySectionHeader(title: "Top Emojis", subtitle: "Most used emojis in this chat", theme: theme)) {
                SectionCard(title: "Top Emojis", subtitle: "Most used emojis in this chat", theme: theme, showHeader: false) {
                    TopEmojisView(
                        allEmojis: chat.topEmojis,
                        yourEmojis: chat.topEmojisYou,
                        theirEmojis: chat.topEmojisThem,
                        theme: theme
                    )
                }
            }

            Section(header: StickySectionHeader(title: "Reactions", subtitle: "Common reaction types", theme: theme)) {
                SectionCard(title: "Reactions", subtitle: "Common reaction types", theme: theme, showHeader: false) {
                    ReactionsView(reactions: chat.reactions, theme: theme)
                }
            }

            Section(header: StickySectionHeader(title: "Greetings", subtitle: "Good morning & night counts", theme: theme)) {
                SectionCard(title: "Greetings", subtitle: "Good morning & night counts", theme: theme, showHeader: false) {
                    HStack(spacing: 16) {
                        ValueTile(title: "Your mornings", value: decimalString(chat.greetings.youMorning), theme: theme)
                        ValueTile(title: "Their mornings", value: decimalString(chat.greetings.themMorning), theme: theme)
                        ValueTile(title: "Your nights", value: decimalString(chat.greetings.youNight), theme: theme)
                        ValueTile(title: "Their nights", value: decimalString(chat.greetings.themNight), theme: theme)
                    }
                }
            }

            Section(header: StickySectionHeader(title: "Recent Balance", subtitle: "How much of this chat is recent", theme: theme)) {
                SectionCard(title: "Recent Balance", subtitle: "How much of this chat is recent", theme: theme, showHeader: false) {
                    HStack(spacing: 16) {
                        ValueTile(title: "Last 30 days", value: balanceLabel(count: chat.recentBalance.last30, pct: chat.recentBalance.last30Pct), theme: theme)
                        ValueTile(title: "Last 90 days", value: balanceLabel(count: chat.recentBalance.last90, pct: chat.recentBalance.last90Pct), theme: theme)
                        ValueTile(title: "Total", value: decimalString(chat.recentBalance.total), theme: theme)
                    }
                }
            }

            Section(header: StickySectionHeader(title: "Attachments", subtitle: "Photos, videos, and files", theme: theme)) {
                SectionCard(title: "Attachments", subtitle: "Photos, videos, and files", theme: theme, showHeader: false) {
                    HStack(spacing: 16) {
                        ValueTile(title: "You sent", value: decimalString(chat.attachments.you), theme: theme)
                        ValueTile(title: "They sent", value: decimalString(chat.attachments.them), theme: theme)
                        ValueTile(title: "Total", value: decimalString(chat.attachments.total), theme: theme)
                    }
                }
            }

            Section(header: StickySectionHeader(title: "Participants", subtitle: "Messages per person", theme: theme)) {
                SectionCard(title: "Participants", subtitle: "Messages per person", theme: theme, showHeader: false) {
                    ParticipantChart(chat: chat, theme: theme)
                }
            }

            Section(header: StickySectionHeader(title: "First Conversation", subtitle: "Opening messages in this chat", theme: theme)) {
                SectionCard(title: "First Conversation", subtitle: "Opening messages in this chat", theme: theme, showHeader: false) {
                    FirstConversationView(
                        lines: chat.firstConversation,
                        header: firstConversationHeader,
                        theme: theme
                    )
                }
            }

            Section(header: StickySectionHeader(title: "Reply Time", subtitle: "Trimmed average", theme: theme)) {
                SectionCard(title: "Reply Time", subtitle: "Trimmed average", theme: theme, showHeader: false) {
                    HStack(spacing: 16) {
                        ValueTile(title: "You", value: format(chat.responseTimes.youReply.avgMinutes), theme: theme)
                        ValueTile(title: "Them", value: format(chat.responseTimes.theyReply.avgMinutes), theme: theme)
                    }
                }
            }
        }
        .sheet(isPresented: $showContactDetails) {
            ContactDetailSheet(
                chatLabel: displayLabel,
                contact: selectedContact,
                isLoading: contactLoading,
                theme: theme
            )
        }
        .task(id: labelKey) {
            resolveLabelIfNeeded()
        }
    }

    private func reportForChat(_ chat: ChatReport) -> Report {
        let summary = Summary(
            totals: chat.totals,
            leftOnRead: chat.leftOnRead,
            responseTimes: chat.responseTimes
        )
        return Report(
            summary: summary,
            chats: [],
            daily: [],
            generatedAt: "",
            filters: ReportFilters(since: nil, until: nil, thresholdHours: 0, top: 0, dateScale: "")
        )
    }

    private var dominantMoodLabel: String {
        let summary = chat.moodSummary
        let pairs: [(String, Int)] = [
            ("Friendly", summary.friendly),
            ("Romantic", summary.romantic),
            ("Professional", summary.professional),
            ("Neutral", summary.neutral)
        ]
        return pairs.max(by: { $0.1 < $1.1 })?.0 ?? "Neutral"
    }

    private var peakDayLabel: String {
        if let date = formattedShortDate(chat.peak.date) {
            return "\(date) · \(decimalString(chat.peak.total))"
        }
        return decimalString(chat.peak.total)
    }

    private func formatHours(_ hours: Double?) -> String {
        guard let hours else { return "—" }
        return format(hours * 60.0)
    }

    private func balanceLabel(count: Int, pct: Double) -> String {
        let pctValue = String(format: "%.0f%%", pct)
        return "\(decimalString(count)) · \(pctValue)"
    }

    private var firstConversationHeader: String {
        if let date = formattedShortDate(chat.firstMessageDate) {
            return "Started \(date)"
        }
        return "Opening exchange"
    }

    private var displayLabel: String {
        resolvedLabel ?? chat.label
    }

    private var labelKey: String {
        ([chat.id.description] + chat.contactHandles + [chat.label]).joined(separator: "|")
    }

    private func formattedShortDate(_ value: String?) -> String? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: value) {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
        return value
    }

    private func openContactDetails() {
        showContactDetails = true
        contactLoading = true
        selectedContact = nil
        let fallbackName = chat.displayName ?? displayLabel
        ContactPhotoStore.shared.fetchContact(
            handles: chat.contactHandles,
            fallbackName: fallbackName
        ) { contact in
            contactLoading = false
            selectedContact = contact
        }
    }

    private func resolveLabelIfNeeded() {
        guard !chat.isGroup else {
            resolvedLabel = nil
            return
        }
        ContactPhotoStore.shared.fetchDisplayName(
            handles: chat.contactHandles,
            fallbackName: chat.displayName ?? chat.label
        ) { name in
            guard let name, !name.isEmpty, name != chat.label else {
                resolvedLabel = nil
                return
            }
            resolvedLabel = name
        }
    }
}

private struct ChatHeroHeader: View {
    let chat: ChatReport
    let displayLabel: String
    let theme: Theme
    let format: (Double?) -> String
    let formatCount: (Int) -> String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ContactAvatarView(
                isGroup: chat.isGroup,
                handles: chat.contactHandles,
                label: displayLabel,
                groupPhotoPath: chat.groupPhotoPath,
                theme: theme,
                size: 56
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(displayLabel)
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                HStack(spacing: 8) {
                    MiniMetric(title: "Sent", value: formatCount(chat.totals.sent), theme: theme)
                    MiniMetric(title: "Recv", value: formatCount(chat.totals.received), theme: theme)
                    MiniMetric(title: "Left", value: formatCount(chat.leftOnRead.youLeftThem + chat.leftOnRead.theyLeftYou), theme: theme)
                    MiniMetric(title: "Avg", value: format(chat.responseTimes.youReply.avgMinutes), theme: theme)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(CardSurface(theme: theme, cornerRadius: 18, elevation: .flat))
    }

    private var subtitle: String {
        if let last = formattedLastMessage(chat.lastMessageDate) {
            return chat.isGroup ? "Group · Last \(last)" : "Direct message · Last \(last)"
        }
        return chat.isGroup ? "Group chat" : "Direct message"
    }

    private func formattedLastMessage(_ value: String?) -> String? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: value) {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
        return value
    }
}

private struct MiniMetric: View {
    let title: String
    let value: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.surfaceElevated)
                .overlay(
                    Capsule()
                        .stroke(theme.border.opacity(0.8), lineWidth: 1)
                )
        )
    }
}

private struct TopWordsView: View {
    let allWords: [WordStat]
    let yourWords: [WordStat]
    let theirWords: [WordStat]
    let theme: Theme
    @State private var selection: Int = 0

    private var currentWords: [WordStat] {
        switch selection {
        case 1: return yourWords
        case 2: return theirWords
        default: return allWords
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selection) {
                Text("Combined").tag(0)
                Text("You").tag(1)
                Text("Others").tag(2)
            }
            .pickerStyle(.segmented)

            if currentWords.isEmpty {
                EmptyStateInline(
                    icon: "text.bubble",
                    title: "No words yet",
                    subtitle: "This chat doesn’t have enough text to analyze.",
                    theme: theme
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(currentWords) { word in
                        WordChip(word: word.word, count: word.count, theme: theme)
                    }
                }
            }
        }
    }
}

private struct TopEmojisView: View {
    let allEmojis: [EmojiStat]
    let yourEmojis: [EmojiStat]
    let theirEmojis: [EmojiStat]
    let theme: Theme
    @State private var selection: Int = 0

    private var currentEmojis: [EmojiStat] {
        switch selection {
        case 1: return yourEmojis
        case 2: return theirEmojis
        default: return allEmojis
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selection) {
                Text("Combined").tag(0)
                Text("You").tag(1)
                Text("Others").tag(2)
            }
            .pickerStyle(.segmented)

            if currentEmojis.isEmpty {
                EmptyStateInline(
                    icon: "face.smiling",
                    title: "No emojis yet",
                    subtitle: "This chat doesn’t have emoji usage to show.",
                    theme: theme
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(currentEmojis) { emoji in
                        EmojiChip(emoji: emoji.emoji, count: emoji.count, theme: theme)
                    }
                }
            }
        }
    }
}

private struct EmojiChip: View {
    let emoji: String
    let count: Int
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 16))
            Text(decimalString(count))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.surfaceElevated)
                .overlay(
                    Capsule()
                        .stroke(theme.border, lineWidth: 1)
                )
        )
    }
}

private struct ReactionsView: View {
    let reactions: [ReactionStat]
    let theme: Theme

    var body: some View {
        if reactions.isEmpty {
            Text("No reactions detected.")
                .foregroundStyle(theme.textSecondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(reactions) { reaction in
                    ReactionChip(reaction: reaction.reaction, count: reaction.count, theme: theme)
                }
            }
        }
    }
}

private struct ReactionChip: View {
    let reaction: String
    let count: Int
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Text(reaction)
                .font(.system(size: 12, weight: .semibold))
            Text(decimalString(count))
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.surfaceElevated)
                .overlay(
                    Capsule()
                        .stroke(theme.border, lineWidth: 1)
                )
        )
    }
}

private struct FirstConversationView: View {
    let lines: [ConversationLine]
    let header: String
    let theme: Theme

    var body: some View {
        if lines.isEmpty {
            Text("No text messages found for this chat.")
                .foregroundStyle(theme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(header)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                ForEach(lines) { line in
                    ConversationBubble(line: line, theme: theme)
                }
            }
        }
    }
}

private struct ConversationBubble: View {
    let line: ConversationLine
    let theme: Theme

    var body: some View {
        let isMe = line.sender == "You"
        HStack(alignment: .top, spacing: 10) {
            Text(line.sender)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 80, alignment: .leading)
            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isMe ? theme.accent.opacity(0.18) : theme.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(theme.border, lineWidth: 1)
                        )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LoadingBar: View {
    let theme: Theme
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.accent.opacity(0.7), theme.accentAlt],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * max(min(progress, 1), 0))
            }
        }
        .frame(height: 8)
    }
}

private struct LoadingIndicator: View {
    let theme: Theme
    let isActive: Bool
    @State private var progress: Double = 0.02
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 12) {
            LoadingBar(theme: theme, progress: progress)
                .frame(height: 8)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
        .onAppear {
            if isActive {
                startTimer()
            }
        }
        .onChange(of: isActive) { active in
            if active {
                progress = 0.02
                startTimer()
            } else {
                timer?.invalidate()
                timer = nil
                withAnimation(.easeOut(duration: 0.6)) {
                    progress = 1.0
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { _ in
            let target = 0.985
            guard progress < target else { return }
            let step: Double
            if progress < 0.5 {
                step = 0.02
            } else if progress < 0.75 {
                step = 0.01
            } else if progress < 0.9 {
                step = 0.005
            } else if progress < 0.96 {
                step = 0.0025
            } else {
                step = 0.0012
            }
            let jitter = Double.random(in: 0.0...0.0006)
            progress = min(target, progress + step + jitter)
        }
    }
}

private struct TimeOfDayChart: View {
    let bins: [TimeOfDayBin]
    let theme: Theme

    var body: some View {
        if bins.allSatisfy({ $0.total == 0 }) {
            Text("No activity data yet.")
                .foregroundStyle(theme.textSecondary)
        } else {
            Chart {
                ForEach(bins) { bin in
                    BarMark(
                        x: .value("Hour", bin.hour),
                        y: .value("Messages", bin.total)
                    )
                    .foregroundStyle(theme.accent)
                    .cornerRadius(3)
                }
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text("\(hour)h")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                    AxisValueLabel().font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                }
            }
            .chartPlotStyle { plot in
                plot.background(theme.surfaceDeep.opacity(0.45)).cornerRadius(8)
            }
        }
    }
}

private struct ReplyBucketsView: View {
    let buckets: ReplySpeedBuckets
    let otherLabel: String
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BucketChart(title: "You", stats: buckets.you, theme: theme)
            BucketChart(title: otherLabel, stats: buckets.them, theme: theme)
        }
    }
}

private enum MoodWindow: String, CaseIterable, Identifiable {
    case last30
    case last90
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last30: return "30d"
        case .last90: return "90d"
        case .all: return "All"
        }
    }

    var days: Int? {
        switch self {
        case .last30: return 30
        case .last90: return 90
        case .all: return nil
        }
    }
}

private struct ReplySpeedSection: View {
    let isGroup: Bool
    let buckets: ReplySpeedBuckets
    let participantSpeeds: [ParticipantReplyStat]
    let otherLabel: String
    let format: (Double?) -> String
    let theme: Theme

    var body: some View {
        if isGroup {
            if participantSpeeds.isEmpty {
                EmptyStateInline(
                    icon: "clock.badge.exclamationmark",
                    title: "No reply speeds yet",
                    subtitle: "Not enough messages to calculate speeds.",
                    theme: theme
                )
            } else {
                ParticipantReplyChart(participants: participantSpeeds, format: format, theme: theme)
                    .frame(height: 220)
            }
        } else {
            ReplyBucketsView(buckets: buckets, otherLabel: otherLabel, theme: theme)
        }
    }
}

private struct ParticipantReplyChart: View {
    let participants: [ParticipantReplyStat]
    let format: (Double?) -> String
    let theme: Theme

    var body: some View {
        let sorted = participants.prefix(10)
        Chart {
            ForEach(sorted) { person in
                BarMark(
                    x: .value("Person", shortLabel(firstNameOnly(person.label))),
                    y: .value("Minutes", person.avgMinutes ?? 0)
                )
                .foregroundStyle(theme.accent)
                .cornerRadius(3)
            }
        }
        .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .rotationEffect(.degrees(-25))
                                .frame(width: 60, alignment: .trailing)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                AxisValueLabel().font(.system(size: 10)).foregroundStyle(theme.textSecondary)
            }
        }
        .chartPlotStyle { plot in
            plot.background(theme.surfaceDeep.opacity(0.45)).cornerRadius(8)
        }
    }
}

private struct BucketChart: View {
    let title: String
    let stats: ReplyBucketStats
    let theme: Theme

    private var items: [(String, Int)] {
        [
            ("<=5m", stats.under5m),
            ("<=1h", stats.under1h),
            ("<=6h", stats.under6h),
            ("<=24h", stats.under24h),
            ("<=7d", stats.under7d),
            (">7d", stats.over7d)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Chart {
                ForEach(items, id: \.0) { item in
                    BarMark(
                        x: .value("Bucket", item.0),
                        y: .value("Count", item.1)
                    )
                    .foregroundStyle(theme.accent)
                    .cornerRadius(3)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                    AxisValueLabel().font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                    AxisValueLabel().font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                }
            }
            .chartPlotStyle { plot in
                plot.background(theme.surfaceDeep.opacity(0.45)).cornerRadius(8)
            }
            .frame(height: 140)
        }
    }
}

private struct MoodTimelineChart: View {
    let moods: [MoodDaily]
    let theme: Theme
    let windowDays: Int?
    let limitPoints: Int?
    let showLegend: Bool

    private var sortedMoods: [(Date, MoodDaily)] {
        let parser = ISO8601DateFormatter()
        return moods.compactMap { entry in
            if let date = parser.date(from: entry.date) {
                return (date, entry)
            }
            return nil
        }
        .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        if moods.isEmpty {
            Text("No mood data yet.")
                .foregroundStyle(theme.textSecondary)
        } else {
            let filtered: [(Date, MoodDaily)] = {
                guard let windowDays, let last = sortedMoods.last?.0 else { return sortedMoods }
                if let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: last) {
                    return sortedMoods.filter { $0.0 >= cutoff }
                }
                return sortedMoods
            }()

            let sampled: [(Date, MoodDaily)] = {
                guard let limitPoints, filtered.count > limitPoints else { return filtered }
                let stride = max(1, filtered.count / limitPoints)
                return filtered.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
            }()

            let points: [(date: Date, mood: String, value: Int)] = sampled.flatMap { (date, entry) in
                [
                    (date, "Friendly", entry.friendly),
                    (date, "Romantic", entry.romantic),
                    (date, "Professional", entry.professional),
                    (date, "Neutral", entry.neutral)
                ]
            }
            VStack(alignment: .leading, spacing: 8) {
                if showLegend {
                    MoodLegend(theme: theme)
                }
                Chart {
                    ForEach(points.indices, id: \.self) { idx in
                        let point = points[idx]
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Count", point.value)
                        )
                        .foregroundStyle(by: .value("Mood", point.mood))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Count", point.value)
                        )
                        .foregroundStyle(by: .value("Mood", point.mood))
                    }
                }
                .chartForegroundStyleScale([
                    "Friendly": theme.accentAlt,
                    "Romantic": Color.pink.opacity(0.8),
                    "Professional": Color.blue.opacity(0.7),
                    "Neutral": Color.gray.opacity(0.6)
                ])
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(sampled.count / 4, 1))) { _ in
                        AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                        AxisValueLabel().font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(theme.border.opacity(0.6))
                        AxisValueLabel().font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                    }
                }
                .chartPlotStyle { plot in
                    plot.background(theme.surfaceDeep.opacity(0.45)).cornerRadius(8)
                }
            }
        }
    }
}

private struct MoodDetailsSheet: View {
    let chatLabel: String
    let otherLabel: String
    let moods: [MoodDaily]
    let summary: MoodSummary
    let phraseMoods: [PhraseMoodStat]
    let theme: Theme
    let onClose: () -> Void
    @State private var selectedMood: MoodFilter = .friendly

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.backgroundTop, theme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(chatLabel) · Mood Timeline")
                                .font(.system(size: 22, weight: .semibold))
                            Text("Full history overview")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Button("Done") { onClose() }
                            .buttonStyle(PrimaryButtonStyle(theme: theme))
                    }

                    HStack(spacing: 12) {
                        MetaTile(title: "Friendly", value: decimalString(summary.friendly), theme: theme)
                        MetaTile(title: "Romantic", value: decimalString(summary.romantic), theme: theme)
                        MetaTile(title: "Professional", value: decimalString(summary.professional), theme: theme)
                        MetaTile(title: "Neutral", value: decimalString(summary.neutral), theme: theme)
                    }

                    SectionCard(title: "Full Timeline", subtitle: "All mood signals", theme: theme) {
                        MoodTimelineChart(moods: moods, theme: theme, windowDays: nil, limitPoints: 90, showLegend: true)
                            .frame(height: 280)
                    }

                    SectionCard(title: "Phrases By Mood", subtitle: "Who said what", theme: theme) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("", selection: $selectedMood) {
                                ForEach(MoodFilter.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)

                            PhraseMoodListView(
                                phrases: phraseMoods,
                                selectedMood: selectedMood.title,
                                otherLabel: otherLabel,
                                theme: theme
                            )
                        }
                    }
                }
                .padding(28)
            }
        }
    }
}

private struct ContactDetailSheet: View {
    let chatLabel: String
    let contact: CNContact?
    let isLoading: Bool
    let theme: Theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.backgroundTop, theme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(chatLabel) · Contact")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Contact card from your address book")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle(theme: theme))
                }

                if isLoading {
                    SectionCard(title: "Loading", subtitle: "Fetching contact details", theme: theme) {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading contact…")
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else if let contact {
                    SectionCard(title: "Contact", subtitle: "Details", theme: theme) {
                        ContactViewController(contact: contact)
                            .frame(minHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                } else {
                    SectionCard(title: "Contact", subtitle: "Not found", theme: theme) {
                        EmptyStateInline(
                            icon: "person.crop.circle.badge.questionmark",
                            title: "Contact not found",
                            subtitle: "This chat doesn’t match a saved contact. Save the number or email to Contacts to view details.",
                            theme: theme
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 640)
    }
}

private struct ContactViewController: NSViewControllerRepresentable {
    let contact: CNContact

    func makeNSViewController(context: Context) -> CNContactViewController {
        let controller = CNContactViewController()
        controller.contact = contact
        return controller
    }

    func updateNSViewController(_ nsViewController: CNContactViewController, context: Context) {
        nsViewController.contact = contact
    }
}

private enum MoodFilter: String, CaseIterable, Identifiable {
    case friendly
    case romantic
    case professional
    case neutral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friendly: return "Friendly"
        case .romantic: return "Romantic"
        case .professional: return "Professional"
        case .neutral: return "Neutral"
        }
    }
}

private struct PhraseMoodListView: View {
    let phrases: [PhraseMoodStat]
    let selectedMood: String
    let otherLabel: String
    let theme: Theme

    var body: some View {
        let filtered = phrases
            .filter { $0.mood == selectedMood }
            .sorted { ($0.youCount + $0.themCount) > ($1.youCount + $1.themCount) }
            .prefix(12)

        if filtered.isEmpty {
            Text("No phrases found for this mood.")
                .foregroundStyle(theme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(filtered)) { item in
                    HStack {
                        Text(item.phrase)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        HStack(spacing: 10) {
                            PhraseCountChip(label: "You", count: item.youCount, theme: theme)
                            PhraseCountChip(label: otherLabel, count: item.themCount, theme: theme)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.surfaceElevated)
                    )
                }
            }
        }
    }
}

private struct PhraseCountChip: View {
    let label: String
    let count: Int
    let theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text(decimalString(count))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [theme.surfaceElevated, theme.surfaceDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Capsule()
                        .stroke(theme.border, lineWidth: 1)
                )
        )
    }
}

private struct WordChip: View {
    let word: String
    let count: Int
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Text(word)
                .font(.system(size: 12, weight: .semibold))
            Text(decimalString(count))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [theme.surfaceElevated, theme.surfaceDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Capsule()
                        .stroke(theme.border, lineWidth: 1)
                )
        )
    }
}

private struct WeekdayHeatmapView: View {
    let bins: [WeekdayBin]
    let theme: Theme

    private let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let maxValue = bins.map { $0.total }.max() ?? 0
        HStack(spacing: 10) {
            ForEach(bins.sorted { $0.weekday < $1.weekday }) { bin in
                VStack(spacing: 6) {
                    Text(labels[bin.weekday])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color(for: bin.total, max: maxValue))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Text(decimalString(bin.total))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                        )
                }
            }
        }
    }

    private func color(for value: Int, max maxValue: Int) -> Color {
        guard maxValue > 0 else { return theme.surfaceElevated }
        let ratio = min(max(Double(value) / Double(maxValue), 0), 1)
        return theme.accent.opacity(0.25 + ratio * 0.65)
    }
}

private struct PhraseListView: View {
    let phrases: [PhraseStat]
    let theme: Theme

    var body: some View {
        if phrases.isEmpty {
            Text("No common phrases yet.")
                .foregroundStyle(theme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(phrases) { phrase in
                    HStack {
                        Text(phrase.phrase)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(decimalString(phrase.count))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.surfaceElevated)
                    )
                }
            }
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.accent, theme.accentAlt],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .foregroundStyle(Color.black.opacity(0.85))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .shadow(color: theme.shadow.opacity(0.6), radius: 8, x: 0, y: 4)
    }
}

private struct GhostButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.surfaceElevated, theme.surfaceDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
            )
            .foregroundStyle(theme.textPrimary)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

// MARK: - Admin Panel

private enum AdminTab: String, CaseIterable, Identifiable {
    case dashboard
    case users
    case reports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .users: return "Users"
        case .reports: return "Reports"
        }
    }
}

private struct AdminUser: Identifiable {
    let id: String
    let email: String?
    let username: String?
    var isAdmin: Bool
    let createdAt: String?
}

private struct UserContactHandle: Identifiable, Hashable {
    let id: String
    let handle: String
    let handleType: String
    let handleNormalized: String
    let handleHash: String
}

private struct MergedUserContact: Identifiable {
    let id: String
    let ownerUserId: String
    let primaryName: String
    let allNames: [String]
    let handles: [UserContactHandle]
    let createdAt: String?
    let rawCount: Int

    var handleCount: Int { handles.count }
    var primaryHandle: UserContactHandle? { handles.first }
}

private struct AdminReport: Identifiable {
    let id: String
    let userId: String?
    let generatedAt: String?
    let createdAt: String?
    let totalMessages: Int?
    let payloadPretty: String
}

private final class AdminPanelViewModel: ObservableObject {
    @Published var users: [AdminUser] = []
    @Published var reports: [AdminReport] = []
    @Published var selectedUser: AdminUser?
    @Published var contactsRaw: [UserContactPoint] = []
    @Published var isLoadingContacts: Bool = false
    @Published var contactsError: String = ""
    @Published var selectedUserPlan: AccountPlan = .free
    @Published var isLoadingPlan: Bool = false
    @Published var planError: String = ""
    @Published var status: String = ""
    @Published var errorMessage: String = ""
    @Published var isLoadingUsers: Bool = false
    @Published var isLoadingReports: Bool = false
    @Published var lastRefresh: Date?

    var isLoadingAny: Bool { isLoadingUsers || isLoadingReports || isLoadingContacts }

    func refresh(supabase: SupabaseService) {
        errorMessage = ""
        status = "Refreshing…"
        lastRefresh = Date()
        loadUsers(supabase: supabase)
        loadReports(supabase: supabase)
        if let selectedUser {
            loadContacts(supabase: supabase, ownerUserId: selectedUser.id)
            loadEntitlements(supabase: supabase, userId: selectedUser.id)
        }
    }

    func loadUsers(supabase: SupabaseService) {
        isLoadingUsers = true
        supabase.postgrest(
            table: "profiles",
            query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "200")
            ]
        ) { [weak self] result in
            guard let self else { return }
            self.isLoadingUsers = false
            switch result {
            case .success(let (data, _)):
                let parsed = self.parseUsers(data: data)
                self.users = parsed
                self.status = self.isLoadingAny ? "Loading…" : "Loaded \(decimalString(parsed.count)) users"
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.status = self.isLoadingAny ? "Loading…" : "Failed to load users"
            }
        }
    }

    func loadReports(supabase: SupabaseService) {
        isLoadingReports = true
        supabase.postgrest(
            table: "message_reports",
            query: [
                URLQueryItem(name: "select", value: "*"),
                // message_reports is updated in-place (PATCH) to avoid storage growth, so
                // use generated_at for "latest" ordering instead of created_at.
                URLQueryItem(name: "order", value: "generated_at.desc"),
                URLQueryItem(name: "limit", value: "50")
            ]
        ) { [weak self] result in
            guard let self else { return }
            self.isLoadingReports = false
            switch result {
            case .success(let (data, _)):
                let parsed = self.parseReports(data: data)
                self.reports = parsed
                self.status = self.isLoadingAny ? "Loading…" : "Loaded \(decimalString(parsed.count)) reports"
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.status = self.isLoadingAny ? "Loading…" : "Failed to load reports"
            }
        }
    }

    func loadContacts(supabase: SupabaseService, ownerUserId: String) {
        isLoadingContacts = true
        contactsRaw = []
        contactsError = ""
        supabase.postgrest(
            table: "user_contacts",
            query: [
                URLQueryItem(name: "owner_user_id", value: "eq.\(ownerUserId)"),
                URLQueryItem(name: "select", value: "id,owner_user_id,contact_name,handle,handle_type,handle_normalized,handle_hash,created_at"),
                URLQueryItem(name: "order", value: "contact_name.asc"),
                URLQueryItem(name: "limit", value: "2000")
            ]
        ) { [weak self] result in
            guard let self else { return }
            self.isLoadingContacts = false
            switch result {
            case .success(let (data, _)):
                // user_contacts is snake_case already; using convertFromSnakeCase here can
                // break explicit CodingKeys like "contact_name" by double-transforming keys.
                let decoder = JSONDecoder()
                do {
                    let parsed = try decoder.decode([UserContactPoint].self, from: data)
                    self.contactsRaw = parsed
                    self.status = self.isLoadingAny ? "Loading…" : "Loaded \(decimalString(parsed.count)) contacts"
                } catch {
                    self.contactsError = "Contacts decode failed: \(error.localizedDescription)"
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        self.status = self.isLoadingAny ? "Loading…" : "Loaded 0 contacts (raw \(decimalString(json.count)))"
                    } else {
                        self.status = self.isLoadingAny ? "Loading…" : "Loaded 0 contacts"
                    }
                }
            case .failure(let error):
                let text = error.localizedDescription
                self.contactsError = text
                self.status = self.isLoadingAny ? "Loading…" : "Failed to load contacts"
            }
        }
    }

    func loadEntitlements(supabase: SupabaseService, userId: String) {
        isLoadingPlan = true
        planError = ""
        selectedUserPlan = .free
        supabase.postgrest(
            table: "user_entitlements",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "select", value: "user_id,plan,updated_at")
            ]
        ) { [weak self] result in
            guard let self else { return }
            self.isLoadingPlan = false
            switch result {
            case .success((let data, _)):
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    self.planError = "Plan decode failed"
                    return
                }
                guard let row = root.first else {
                    self.selectedUserPlan = .free
                    return
                }
                let raw = (row["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "free"
                self.selectedUserPlan = AccountPlan(rawValue: raw) ?? .free
            case .failure(let error):
                self.planError = error.localizedDescription
            }
        }
    }

    func setPlan(supabase: SupabaseService, userId: String, to newPlan: AccountPlan) {
        // Upsert so it works even if the entitlements row doesn't exist yet.
        let body = (try? JSONSerialization.data(withJSONObject: [["user_id": userId, "plan": newPlan.rawValue]])) ?? Data()
        supabase.postgrest(
            table: "user_entitlements",
            query: [],
            method: "POST",
            body: body,
            prefer: "resolution=merge-duplicates,return=representation"
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.selectedUserPlan = newPlan
                self.status = "Updated plan"
            case .failure(let error):
                self.planError = error.localizedDescription
                self.status = "Failed to update plan"
            }
        }
    }

    func setAdmin(supabase: SupabaseService, userId: String, to newValue: Bool) {
        guard let idx = users.firstIndex(where: { $0.id == userId }) else { return }
        let oldValue = users[idx].isAdmin
        users[idx].isAdmin = newValue

        let body = (try? JSONSerialization.data(withJSONObject: ["is_admin": newValue])) ?? Data()
        supabase.postgrest(
            table: "profiles",
            query: [URLQueryItem(name: "id", value: "eq.\(userId)")],
            method: "PATCH",
            body: body,
            prefer: "return=representation"
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.status = "Updated admin flag"
            case .failure(let error):
                if let revertIdx = self.users.firstIndex(where: { $0.id == userId }) {
                    self.users[revertIdx].isAdmin = oldValue
                }
                self.errorMessage = error.localizedDescription
                self.status = "Failed to update admin flag"
            }
        }
    }

    private func parseUsers(data: Data) -> [AdminUser] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let email = row["email"] as? String
            let username = row["username"] as? String
            let createdAt = row["created_at"] as? String
            let rawAdmin = row["is_admin"] ?? row["isAdmin"] ?? row["admin"]
            let isAdmin: Bool
            if let b = rawAdmin as? Bool { isAdmin = b }
            else if let n = rawAdmin as? NSNumber { isAdmin = n.boolValue }
            else { isAdmin = false }
            return AdminUser(id: id, email: email, username: username, isAdmin: isAdmin, createdAt: createdAt)
        }
    }

    private func parseReports(data: Data) -> [AdminReport] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json.compactMap { row in
            let id: String
            if let n = row["id"] as? NSNumber {
                id = n.stringValue
            } else if let s = row["id"] as? String {
                id = s
            } else {
                id = UUID().uuidString
            }

            let userId = row["user_id"] as? String
            let generatedAt = row["generated_at"] as? String
            let createdAt = row["created_at"] as? String
            let payload = row["payload"]
            let totalMessages = extractTotalMessages(from: payload)
            let payloadPretty = prettyJSONString(payload) ?? "{}"
            return AdminReport(
                id: id,
                userId: userId,
                generatedAt: generatedAt,
                createdAt: createdAt,
                totalMessages: totalMessages,
                payloadPretty: payloadPretty
            )
        }
    }

    private func extractTotalMessages(from payload: Any?) -> Int? {
        guard let payload else { return nil }
        guard let dict = payload as? [String: Any] else { return nil }
        guard let summary = dict["summary"] as? [String: Any] else { return nil }
        guard let totals = summary["totals"] as? [String: Any] else { return nil }
        let value = totals["total"] ?? totals["messages"] ?? totals["count"]
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    private func prettyJSONString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        let options: JSONSerialization.WritingOptions
        if #available(macOS 11.0, *) {
            options = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            options = [.prettyPrinted]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct AdminPanel: View {
    let theme: Theme
    @ObservedObject var supabase: SupabaseService
    @StateObject private var viewModel = AdminPanelViewModel()
    @State private var tab: AdminTab = .dashboard
    @State private var userSearch: String = ""
    @State private var reportDetail: AdminReport?
    @State private var contactsSheetUser: AdminUser?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCard(title: "Admin", subtitle: "Manage users and reports", theme: theme) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        MetaTile(title: "Users loaded", value: decimalString(viewModel.users.count), theme: theme)
                        MetaTile(title: "Reports loaded", value: decimalString(viewModel.reports.count), theme: theme)
                        MetaTile(title: "Last refresh", value: formattedRefresh(viewModel.lastRefresh), theme: theme)
                    }

                    HStack(spacing: 10) {
                        Picker("", selection: $tab) {
                            ForEach(AdminTab.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 460)

                        Spacer()

                        Button("Refresh") { viewModel.refresh(supabase: supabase) }
                            .buttonStyle(PrimaryButtonStyle(theme: theme))
                    }

                    if viewModel.isLoadingAny {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("Loading…")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                    } else if !viewModel.status.isEmpty {
                        Text(viewModel.status)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }

                    if !viewModel.errorMessage.isEmpty {
                        Text(viewModel.errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
            }

            switch tab {
            case .dashboard:
                adminDashboard
            case .users:
                adminUsers
            case .reports:
                adminReports
            }
        }
        .onAppear {
            if viewModel.users.isEmpty && viewModel.reports.isEmpty {
                viewModel.refresh(supabase: supabase)
            }
        }
        .sheet(item: $reportDetail) { report in
            AdminReportDetailSheet(report: report, userLabel: reportUserLabel(report.userId), theme: theme, supabase: supabase)
        }
        .sheet(item: $contactsSheetUser) { user in
            AdminContactsSheet(
                theme: theme,
                userEmail: user.email ?? "User",
                ownerUserId: user.id,
                rawContacts: viewModel.contactsRaw
            )
        }
    }

    private func formattedRefresh(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func reportUserLabel(_ userId: String?) -> String {
        guard let userId else { return "Unknown user" }
        if let user = viewModel.users.first(where: { $0.id == userId }) {
            let email = (user.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let username = (user.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty && !username.isEmpty {
                return "\(email) (\(username))"
            }
            if !email.isEmpty { return email }
            if !username.isEmpty { return username }
        }
        return shortLabel(userId, maxLength: 28)
    }

    private var adminDashboard: some View {
        SectionCard(title: "Admin Dashboard", subtitle: "Quick info", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    MetaTile(title: "Signed in", value: supabase.userEmail ?? "Yes", theme: theme)
                    MetaTile(title: "Profile", value: supabase.profileUsername ?? "—", theme: theme)
                    MetaTile(title: "Role", value: supabase.isAdmin ? "Admin" : "User", theme: theme)
                }

                Text("Notes: counts are based on the currently loaded lists (top 200 users, top 50 reports).")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var adminUsers: some View {
        SectionCard(title: "Users", subtitle: "Profiles and uploaded contacts", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        TextField("Search users", text: $userSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))

                    Spacer()

                    Button("Reload Users") { viewModel.loadUsers(supabase: supabase) }
                        .buttonStyle(GhostButtonStyle(theme: theme))
                }

                let filtered = filteredUsers(viewModel.users, search: userSearch)
                if filtered.isEmpty {
                    EmptyStateInline(
                        icon: "person.crop.circle",
                        title: "No users",
                        subtitle: "No profiles match your search.",
                        theme: theme
                    )
                    .padding(.top, 8)
                } else {
                HStack(alignment: .top, spacing: 12) {
                    // User list
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(filtered) { user in
                                Button {
                                    viewModel.selectedUser = user
                                    viewModel.loadContacts(supabase: supabase, ownerUserId: user.id)
                                    viewModel.loadEntitlements(supabase: supabase, userId: user.id)
                                } label: {
                                    AdminUserRow(
                                        user: user,
                                        theme: theme,
                                        onToggleAdmin: { newValue in
                                            viewModel.setAdmin(supabase: supabase, userId: user.id, to: newValue)
                                        }
                                    )
                                }
                                .buttonStyle(.plain)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill((viewModel.selectedUser?.id == user.id) ? theme.surfaceElevated.opacity(0.8) : Color.clear)
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxWidth: 420)

                    // Contacts for selected user
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(viewModel.selectedUser?.email ?? "Select a user")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            if let selected = viewModel.selectedUser {
                                Button("Reload Contacts") {
                                    viewModel.loadContacts(supabase: supabase, ownerUserId: selected.id)
                                    viewModel.loadEntitlements(supabase: supabase, userId: selected.id)
                                }
                                .buttonStyle(GhostButtonStyle(theme: theme))
                            }
                        }
                        if let selected = viewModel.selectedUser, (selected.username?.isEmpty == false) {
                            Text(selected.username ?? "")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }

                        if viewModel.selectedUser != nil {
                            let merged = mergeUserContacts(viewModel.contactsRaw)
                            HStack(spacing: 12) {
                                MetaTile(title: "Unique", value: decimalString(merged.count), theme: theme)
                                MetaTile(title: "Raw", value: decimalString(viewModel.contactsRaw.count), theme: theme)
                                Spacer()
                                if supabase.isAdmin, let selected = viewModel.selectedUser {
                                    Picker("", selection: Binding(
                                        get: { viewModel.selectedUserPlan },
                                        set: { newPlan in
                                            viewModel.setPlan(supabase: supabase, userId: selected.id, to: newPlan)
                                        }
                                    )) {
                                        ForEach(AccountPlan.allCases) { plan in
                                            Text(plan.title).tag(plan)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: 220)
                                }
                                Button("View Contacts") {
                                    guard let selected = viewModel.selectedUser else { return }
                                    contactsSheetUser = selected
                                }
                                    .buttonStyle(PrimaryButtonStyle(theme: theme))
                            }
                        }

                        if viewModel.isLoadingContacts {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text("Loading contacts…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .padding(.top, 4)
                        } else if viewModel.isLoadingPlan {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text("Loading plan…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .padding(.top, 4)
                        } else if !viewModel.planError.isEmpty {
                            Text("Plan error: \(viewModel.planError)")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        } else if !viewModel.contactsError.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Contacts load failed")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(viewModel.contactsError)
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if viewModel.contactsError.contains("PGRST205") || viewModel.contactsError.lowercased().contains("could not find the table") {
                                    Text("This usually means the backend table `public.user_contacts` is missing or the API schema cache is stale. Create the table, reload the schema cache, then retry.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 4)
                        } else if viewModel.selectedUser != nil && viewModel.contactsRaw.isEmpty {
                            Text("No contacts uploaded for this user yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.top, 4)
                            Text("Contacts upload happens automatically after they sign in and grant Contacts access. Ask them to open the app once and leave it running for ~30 seconds.")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                            Text("If you can see rows in the backend but this list is empty, it usually means access policies block admin reads or the selected user's id doesn't match the stored `owner_user_id`.")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
                }
            }
        }
    }

    private func filteredContacts(_ contacts: [UserContactPoint], search: String) -> [UserContactPoint] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return contacts }
        return contacts.filter {
            $0.contactName.lowercased().contains(needle) ||
            $0.handle.lowercased().contains(needle) ||
            $0.handleNormalized.lowercased().contains(needle)
        }
    }

    private var adminReports: some View {
        SectionCard(title: "Reports", subtitle: "Latest reports", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button("Reload Reports") { viewModel.loadReports(supabase: supabase) }
                        .buttonStyle(GhostButtonStyle(theme: theme))
                    Spacer()
                    Text("Showing up to 50")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }

                if viewModel.reports.isEmpty {
                    EmptyStateInline(
                        icon: "doc.text.magnifyingglass",
                        title: "No reports found",
                        subtitle: "New reports will show up here.",
                        theme: theme
                    )
                    .padding(.top, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.reports) { report in
                            AdminReportRow(report: report, userLabel: reportUserLabel(report.userId), theme: theme) {
                                reportDetail = report
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func filteredUsers(_ users: [AdminUser], search: String) -> [AdminUser] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return users }
        return users.filter { user in
            user.id.lowercased().contains(needle) ||
            (user.username?.lowercased().contains(needle) ?? false) ||
            (user.email?.lowercased().contains(needle) ?? false)
        }
    }
}

private struct AdminUserRow: View {
    let user: AdminUser
    let theme: Theme
    let onToggleAdmin: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surfaceDeep.opacity(0.65))
                    .frame(width: 34, height: 34)
                Image(systemName: user.isAdmin ? "star.fill" : "person.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(user.isAdmin ? theme.accent : theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(user.username?.isEmpty == false ? user.username! : (user.email ?? "User"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(user.email ?? shortLabel(user.id, maxLength: 26))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Toggle("Admin", isOn: Binding(
                get: { user.isAdmin },
                set: { newValue in onToggleAdmin(newValue) }
            ))
            .toggleStyle(SwitchToggleStyle(tint: theme.accent))
            .labelsHidden()

            Text(user.isAdmin ? "Admin" : "User")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(user.isAdmin ? theme.accent : theme.textSecondary)
        }
        .padding(12)
        .background(CardSurface(theme: theme, cornerRadius: 16, showShadow: false))
    }
}

private struct AdminContactDetailSheet: View {
    let contact: UserContactPoint
    let theme: Theme

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.surfaceDeep, theme.surfaceDeep.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.contactName.isEmpty ? "Contact" : contact.contactName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(2)
                        Text("\(contact.handleType): \(contact.handle)")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button("Done") { dismiss() }
                        .buttonStyle(GhostButtonStyle(theme: theme))
                }

                VStack(alignment: .leading, spacing: 10) {
                    MetaTile(title: "Owner user id", value: contact.ownerUserId, theme: theme)
                    MetaTile(title: "Handle normalized", value: contact.handleNormalized, theme: theme)
                    MetaTile(title: "Handle hash", value: contact.handleHash, theme: theme)
                    if let created = contact.createdAt, !created.isEmpty {
                        MetaTile(title: "Created at", value: created, theme: theme)
                    }
                }

                Spacer()
            }
            .padding(18)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

private func mergeUserContacts(_ contacts: [UserContactPoint]) -> [MergedUserContact] {
    if contacts.isEmpty { return [] }

    // We store one row per handle in Supabase. When Contacts.app has a unified (merged) contact with
    // multiple handles, those rows usually share the same contact_name. Merge by contact_name first,
    // then fall back to per-handle merging for unnamed contacts.
    func normalizedNameKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let lowered = trimmed.lowercased()
        if lowered == "unknown" { return "" }
        // Collapse internal whitespace.
        let parts = lowered.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    func handleKey(_ c: UserContactPoint) -> String {
        let key = c.handleHash.isEmpty ? c.handleNormalized.lowercased() : c.handleHash.lowercased()
        return key.isEmpty ? c.handle.lowercased() : key
    }

    func bestName(_ points: [UserContactPoint]) -> (primary: String, all: [String]) {
        let names = points
            .map { $0.contactName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = Array(Set(names)).sorted()
        if let longest = unique.sorted(by: { $0.count > $1.count }).first {
            return (longest, unique)
        }
        return ("", [])
    }

    var byName: [String: [UserContactPoint]] = [:]
    var unnamed: [UserContactPoint] = []
    byName.reserveCapacity(min(contacts.count, 1024))
    unnamed.reserveCapacity(min(contacts.count, 1024))

    for c in contacts {
        let nameKey = normalizedNameKey(c.contactName)
        if nameKey.isEmpty {
            unnamed.append(c)
        } else {
            byName[nameKey, default: []].append(c)
        }
    }

    // Unnamed contacts: merge by handle hash/normalized.
    var byHandle: [String: [UserContactPoint]] = [:]
    byHandle.reserveCapacity(min(unnamed.count, 2048))
    for c in unnamed {
        byHandle[handleKey(c), default: []].append(c)
    }

    func handlesFrom(_ points: [UserContactPoint]) -> [UserContactHandle] {
        var seen: Set<String> = []
        var handles: [UserContactHandle] = []
        handles.reserveCapacity(min(points.count, 8))
        for p in points {
            let k = handleKey(p)
            if seen.contains(k) { continue }
            seen.insert(k)
            handles.append(
                UserContactHandle(
                    id: k,
                    handle: p.handle,
                    handleType: p.handleType,
                    handleNormalized: p.handleNormalized,
                    handleHash: p.handleHash
                )
            )
        }
        func typeRank(_ t: String) -> Int {
            let lowered = t.lowercased()
            if lowered.contains("phone") { return 0 }
            if lowered.contains("email") { return 1 }
            return 2
        }
        handles.sort {
            let lr = typeRank($0.handleType)
            let rr = typeRank($1.handleType)
            if lr != rr { return lr < rr }
            return $0.handle.localizedCaseInsensitiveCompare($1.handle) == .orderedAscending
        }
        return handles
    }

    var merged: [MergedUserContact] = []
    merged.reserveCapacity(byName.count + byHandle.count)

    for (nameKey, points) in byName {
        guard let any = points.first else { continue }
        let name = bestName(points)
        let created = points.compactMap(\.createdAt).sorted().first
        merged.append(
            MergedUserContact(
                id: "name:\(nameKey)",
                ownerUserId: any.ownerUserId,
                primaryName: name.primary,
                allNames: name.all,
                handles: handlesFrom(points),
                createdAt: created,
                rawCount: points.count
            )
        )
    }

    for (_, points) in byHandle {
        guard let any = points.first else { continue }
        let name = bestName(points)
        let created = points.compactMap(\.createdAt).sorted().first
        merged.append(
            MergedUserContact(
                id: "handle:\(handleKey(any))",
                ownerUserId: any.ownerUserId,
                primaryName: name.primary,
                allNames: name.all,
                handles: handlesFrom(points),
                createdAt: created,
                rawCount: points.count
            )
        )
    }

    merged.sort {
        let left = $0.primaryName.isEmpty ? ($0.primaryHandle?.handle ?? "") : $0.primaryName
        let right = $1.primaryName.isEmpty ? ($1.primaryHandle?.handle ?? "") : $1.primaryName
        return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
    }
    return merged
}

private struct AdminContactsSheet: View {
    let theme: Theme
    let userEmail: String
    let ownerUserId: String
    let rawContacts: [UserContactPoint]

    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var selected: MergedUserContact?
    @State private var sort: AdminContactsSort = .name

    private var merged: [MergedUserContact] { mergeUserContacts(rawContacts) }

    private var visible: [MergedUserContact] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [MergedUserContact]
        if needle.isEmpty {
            filtered = merged
        } else {
            filtered = merged.filter { c in
                if c.primaryName.lowercased().contains(needle) { return true }
                if c.allNames.joined(separator: " ").lowercased().contains(needle) { return true }
                if c.handles.contains(where: { h in
                    h.handle.lowercased().contains(needle) ||
                    h.handleNormalized.lowercased().contains(needle) ||
                    h.handleHash.lowercased().contains(needle)
                }) { return true }
                return false
            }
        }

        switch sort {
        case .name:
            return filtered.sorted {
                let left = $0.primaryName.isEmpty ? ($0.primaryHandle?.handle ?? "") : $0.primaryName
                let right = $1.primaryName.isEmpty ? ($1.primaryHandle?.handle ?? "") : $1.primaryName
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        case .mostHandles:
            return filtered.sorted { a, b in
                if a.handleCount != b.handleCount { return a.handleCount > b.handleCount }
                let left = a.primaryName.isEmpty ? (a.primaryHandle?.handle ?? "") : a.primaryName
                let right = b.primaryName.isEmpty ? (b.primaryHandle?.handle ?? "") : b.primaryName
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        case .mostRaw:
            return filtered.sorted { a, b in
                if a.rawCount != b.rawCount { return a.rawCount > b.rawCount }
                let left = a.primaryName.isEmpty ? (a.primaryHandle?.handle ?? "") : a.primaryName
                let right = b.primaryName.isEmpty ? (b.primaryHandle?.handle ?? "") : b.primaryName
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.surfaceDeep, theme.surfaceDeep.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Contacts")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                        Text(userEmail)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(GhostButtonStyle(theme: theme))
                }

                HStack(spacing: 12) {
                    MetaTile(title: "User", value: userEmail, theme: theme)
                    MetaTile(title: "People", value: decimalString(merged.count), theme: theme)
                    MetaTile(title: "Handles", value: decimalString(rawContacts.count), theme: theme)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    TextField("Search contacts", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))

                HStack(spacing: 8) {
                    Text("Sort")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Picker("", selection: $sort) {
                        ForEach(AdminContactsSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    Spacer()
                }

                if merged.isEmpty {
                    EmptyStateInline(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "No contacts",
                        subtitle: "No contacts found for this user yet (or RLS is blocking admin read).",
                        theme: theme
                    )
                    .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(visible) { c in
                                Button {
                                    selected = c
                                } label: {
                                    HStack(spacing: 10) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(theme.surfaceDeep.opacity(0.65))
                                                .frame(width: 36, height: 36)
                                            let iconName: String = {
                                                if c.handleCount > 1 { return "person.crop.circle.fill" }
                                                guard let primary = c.primaryHandle else { return "person.crop.circle.fill" }
                                                return primary.handleType.lowercased().contains("email") ? "envelope.fill" : "phone.fill"
                                            }()
                                            Image(systemName: iconName)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(theme.textSecondary)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            let title = c.primaryName.isEmpty ? (c.primaryHandle?.handle ?? "Contact") : c.primaryName
                                            Text(title)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(theme.textPrimary)
                                                .lineLimit(1)
                                            let subtitle: String = {
                                                guard let primary = c.primaryHandle else { return "No handle" }
                                                if c.handleCount <= 1 { return "\(primary.handleType): \(primary.handle)" }
                                                return "\(primary.handleType): \(primary.handle)  +\(decimalString(max(c.handleCount - 1, 0)))"
                                            }()
                                            Text(subtitle)
                                                .font(.system(size: 11))
                                                .foregroundStyle(theme.textSecondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        if c.handleCount > 1 || c.rawCount > 1 {
                                            let badge = c.handleCount > 1 ? "\(decimalString(c.handleCount))" : "\(decimalString(c.rawCount))"
                                            Text(badge)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(theme.textPrimary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .fill(theme.surfaceDeep.opacity(0.65))
                                                )
                                        }

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(theme.textSecondary.opacity(0.8))
                                    }
                                    .padding(10)
                                    .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(18)
        }
        .frame(minWidth: 760, minHeight: 620)
        .sheet(item: $selected) { contact in
            AdminMergedContactDetailSheet(contact: contact, theme: theme)
        }
    }
}

private struct AdminMergedContactDetailSheet: View {
    let contact: MergedUserContact
    let theme: Theme

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.surfaceDeep, theme.surfaceDeep.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.primaryName.isEmpty ? "Contact" : contact.primaryName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(2)
                        Text("\(decimalString(contact.handleCount)) handle\(contact.handleCount == 1 ? "" : "s")")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button("Done") { dismiss() }
                        .buttonStyle(GhostButtonStyle(theme: theme))
                }

                HStack(spacing: 12) {
                    MetaTile(title: "Merged rows", value: decimalString(contact.rawCount), theme: theme)
                    if let created = contact.createdAt, !created.isEmpty {
                        MetaTile(title: "Created", value: shortLabel(created, maxLength: 22), theme: theme)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                }

                SectionCard(title: "Handles", subtitle: "Phone numbers and emails for this contact", theme: theme) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(contact.handles) { h in
                            HStack(spacing: 10) {
                                Image(systemName: h.handleType.lowercased().contains("email") ? "envelope.fill" : "phone.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.handle)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Text(h.handleType)
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !contact.allNames.isEmpty {
                    SectionCard(title: "Names", subtitle: "Names seen across merged rows", theme: theme) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(contact.allNames.prefix(20), id: \.self) { name in
                                Text(name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                            }
                            if contact.allNames.count > 20 {
                                Text("…and \(decimalString(contact.allNames.count - 20)) more")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(18)
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

private enum AdminContactsSort: String, CaseIterable, Identifiable {
    case name
    case mostHandles
    case mostRaw

    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .mostHandles: return "Most handles"
        case .mostRaw: return "Most rows"
        }
    }
}

private struct AdminReportRow: View {
    let report: AdminReport
    let userLabel: String
    let theme: Theme
    let onView: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surfaceDeep.opacity(0.65))
                    .frame(width: 34, height: 34)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(userLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text("Generated: \(shortLabel(report.generatedAt ?? "—", maxLength: 42))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            if let total = report.totalMessages {
                Text(decimalString(total))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.surfaceDeep.opacity(0.65))
                    )
            }

            Button("View") { onView() }
                .buttonStyle(GhostButtonStyle(theme: theme))
        }
        .padding(12)
        .background(CardSurface(theme: theme, cornerRadius: 16, showShadow: false))
    }
}

private enum AdminReportDetailTab: String, CaseIterable, Identifiable {
    case overview
    case chats
    case rawJSON

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .chats: return "Chats"
        case .rawJSON: return "Raw JSON"
        }
    }
}

private enum AdminReportChatSort: String, CaseIterable, Identifiable {
    case mostMessages
    case mostRecent
    case mostLeftOnRead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostMessages: return "Most messages"
        case .mostRecent: return "Most recent"
        case .mostLeftOnRead: return "Most left on read"
        }
    }
}

private struct AdminSyncPayload: Decodable {
    let summary: Summary
    let filters: ReportFilters
    let topChats: [AdminSyncChat]

    enum CodingKeys: String, CodingKey {
        case summary
        case filters
        case topChats = "top_chats"
    }
}

private struct AdminSyncChat: Decodable, Identifiable {
    let id: Int64
    let label: String
    let isGroup: Bool
    let totals: Totals
    let leftOnRead: LeftOnRead
    let responseTimes: ResponseTimes
    let lastMessageDate: String?
    let participantCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case isGroup = "is_group"
        case totals
        case leftOnRead = "left_on_read"
        case responseTimes = "response_times"
        case lastMessageDate = "last_message_date"
        case participantCount = "participant_count"
    }
}

private struct AdminReportDetailSheet: View {
    let report: AdminReport
    let userLabel: String
    let theme: Theme
    @ObservedObject var supabase: SupabaseService

    @Environment(\.dismiss) private var dismiss
    @State private var tab: AdminReportDetailTab = .overview
    @State private var chatSearch: String = ""
    @State private var chatSort: AdminReportChatSort = .mostMessages
    @State private var messagesChat: AdminSyncChat?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(userLabel)
                        .font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 8) {
                        if let userId = report.userId {
                            Text("User \(shortLabel(userId, maxLength: 38))")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        } else {
                            Text("No user_id")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        if let generatedAt = report.generatedAt {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                            Text("Generated \(shortLabel(generatedAt, maxLength: 42))")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Close")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
                .keyboardShortcut(.cancelAction)
            }

            Picker("", selection: $tab) {
                ForEach(AdminReportDetailTab.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let payload = decodePayload(report.payloadPretty)
                    switch tab {
                    case .overview:
                        if let payload {
                            overview(payload)
                        } else {
                            EmptyStateInline(
                                icon: "exclamationmark.triangle.fill",
                                title: "Couldn't parse report",
                                subtitle: "Showing raw JSON instead.",
                                theme: theme
                            )
                            rawJSON(report.payloadPretty)
                        }
                    case .chats:
                        if let payload {
                            chats(payload)
                        } else {
                            EmptyStateInline(
                                icon: "exclamationmark.triangle.fill",
                                title: "Couldn't parse report",
                                subtitle: "Showing raw JSON instead.",
                                theme: theme
                            )
                            rawJSON(report.payloadPretty)
                        }
                    case .rawJSON:
                        rawJSON(report.payloadPretty)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
        .background(
            LinearGradient(
                colors: [theme.surfaceDeep, theme.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .sheet(item: $messagesChat) { chat in
            if let ownerUserId = report.userId, !ownerUserId.isEmpty {
                AdminChatMessagesSheet(
                    theme: theme,
                    supabase: supabase,
                    ownerUserId: ownerUserId,
                    chat: chat
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Missing user id")
                        .font(.system(size: 16, weight: .semibold))
                    Text("This report row didn't include a user_id, so messages can't be queried.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Button("Close") { messagesChat = nil }
                        .buttonStyle(PrimaryButtonStyle(theme: theme))
                    Spacer()
                }
                .padding(16)
                .frame(minWidth: 520, minHeight: 240)
                .background(theme.surfaceDeep)
            }
        }
    }

    private func decodePayload(_ prettyJSON: String) -> AdminSyncPayload? {
        guard let data = prettyJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(AdminSyncPayload.self, from: data)
    }

    @ViewBuilder
    private func overview(_ payload: AdminSyncPayload) -> some View {
        SectionCard(title: "Summary", subtitle: "Totals and left on read", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    MetaTile(title: "Total", value: decimalString(payload.summary.totals.total), theme: theme)
                    MetaTile(title: "Sent", value: decimalString(payload.summary.totals.sent), theme: theme)
                    MetaTile(title: "Received", value: decimalString(payload.summary.totals.received), theme: theme)
                }
                HStack(spacing: 12) {
                    MetaTile(title: "You left them", value: decimalString(payload.summary.leftOnRead.youLeftThem), theme: theme)
                    MetaTile(title: "They left you", value: decimalString(payload.summary.leftOnRead.theyLeftYou), theme: theme)
                    MetaTile(title: "Top chats", value: decimalString(payload.topChats.count), theme: theme)
                }
            }
        }

        SectionCard(title: "Reply Times", subtitle: "Average/median/p90", theme: theme) {
            let you = payload.summary.responseTimes.youReply
            let them = payload.summary.responseTimes.theyReply

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("You → Them")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(decimalString(you.count)) pairs")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    HStack(spacing: 12) {
                        MetaTile(title: "Avg", value: humanizeMinutes(you.avgMinutes), theme: theme)
                        MetaTile(title: "Median", value: humanizeMinutes(you.medianMinutes), theme: theme)
                        MetaTile(title: "p90", value: humanizeMinutes(you.p90Minutes), theme: theme)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Them → You")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(decimalString(them.count)) pairs")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    HStack(spacing: 12) {
                        MetaTile(title: "Avg", value: humanizeMinutes(them.avgMinutes), theme: theme)
                        MetaTile(title: "Median", value: humanizeMinutes(them.medianMinutes), theme: theme)
                        MetaTile(title: "p90", value: humanizeMinutes(them.p90Minutes), theme: theme)
                    }
                }
            }
        }

        SectionCard(title: "Filters", subtitle: "How this report was generated", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    MetaTile(title: "Since", value: formattedShortDate(payload.filters.since) ?? "—", theme: theme)
                    MetaTile(title: "Until", value: formattedShortDate(payload.filters.until) ?? "—", theme: theme)
                    MetaTile(title: "Top", value: decimalString(payload.filters.top), theme: theme)
                }
                HStack(spacing: 12) {
                    MetaTile(title: "Read threshold", value: humanizeHours(payload.filters.thresholdHours), theme: theme)
                    MetaTile(title: "Date scale", value: payload.filters.dateScale, theme: theme)
                    MetaTile(title: "User", value: userLabel, theme: theme)
                }
            }
        }

        SectionCard(title: "Chats", subtitle: "Top chats in this report", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                if payload.topChats.isEmpty {
                    Text("No chats in this payload.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    HStack(spacing: 10) {
                        Text("Showing \(decimalString(min(payload.topChats.count, 10))) of \(decimalString(payload.topChats.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Button("View all") { tab = .chats }
                            .buttonStyle(GhostButtonStyle(theme: theme))
                    }

                    ForEach(payload.topChats.prefix(10)) { chat in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(theme.surfaceDeep.opacity(0.65))
                                    .frame(width: 34, height: 34)
                                Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.label.isEmpty ? "Chat \(chat.id)" : chat.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Text(chatSubtitle(chat))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(decimalString(chat.totals.total))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(theme.surfaceDeep.opacity(0.65))
                                )
                        }
                        .padding(12)
                        .background(CardSurface(theme: theme, cornerRadius: 16, showShadow: false))
                    }
                    if payload.topChats.count > 10 {
                        Text("Open the Chats tab to see all \(decimalString(payload.topChats.count)) chats in this payload.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func chats(_ payload: AdminSyncPayload) -> some View {
        SectionCard(title: "Chats", subtitle: "\(decimalString(payload.topChats.count)) chats", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        TextField("Search chats", text: $chatSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))

                    Spacer()

                    Picker("", selection: $chatSort) {
                        ForEach(AdminReportChatSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }

                let filtered = filteredChats(payload.topChats, search: chatSearch)
                let sorted = sortedChats(filtered, sort: chatSort)

                if sorted.isEmpty {
                    EmptyStateInline(
                        icon: "message.fill",
                        title: "No chats found",
                        subtitle: "Try a different search.",
                        theme: theme
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(sorted) { chat in
                            chatRow(chat)
                        }
                    }
                }

                if payload.topChats.count >= 100 {
                    Text("Note: this payload currently includes up to 100 chats per user.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func filteredChats(_ chats: [AdminSyncChat], search: String) -> [AdminSyncChat] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return chats }
        return chats.filter { chat in
            chat.label.lowercased().contains(needle) ||
            "\(chat.id)".contains(needle)
        }
    }

    private func sortedChats(_ chats: [AdminSyncChat], sort: AdminReportChatSort) -> [AdminSyncChat] {
        switch sort {
        case .mostMessages:
            return chats.sorted { $0.totals.total > $1.totals.total }
        case .mostLeftOnRead:
            return chats.sorted { leftOnReadTotal($0) > leftOnReadTotal($1) }
        case .mostRecent:
            return chats.sorted { (parseISODate($0.lastMessageDate) ?? .distantPast) > (parseISODate($1.lastMessageDate) ?? .distantPast) }
        }
    }

    private func leftOnReadTotal(_ chat: AdminSyncChat) -> Int {
        chat.leftOnRead.youLeftThem + chat.leftOnRead.theyLeftYou
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        return parser.date(from: value)
    }

    private func chatRow(_ chat: AdminSyncChat) -> some View {
        let left = leftOnReadTotal(chat)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surfaceDeep.opacity(0.65))
                    .frame(width: 34, height: 34)
                Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.label.isEmpty ? "Chat \(chat.id)" : chat.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(chatSubtitle(chat))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Messages") {
                guard let owner = report.userId, !owner.isEmpty else { return }
                messagesChat = chat
            }
            .buttonStyle(GhostButtonStyle(theme: theme))
            .disabled(report.userId == nil)

            if left > 0 {
                Text(decimalString(left))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.surfaceDeep.opacity(0.65))
                    )
            }

            Text(decimalString(chat.totals.total))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.surfaceDeep.opacity(0.65))
                )
        }
        .padding(12)
        .background(CardSurface(theme: theme, cornerRadius: 16, showShadow: false))
    }

    private func rawJSON(_ prettyJSON: String) -> some View {
        Text(prettyJSON)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))
}

private struct AdminChatMessageRow: Decodable, Identifiable {
    let messageId: Int64
    let chatId: Int64
    let messageDate: String?
    let isFromMe: Bool
    let senderHandle: String?
    let text: String?

    var id: Int64 { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case chatId = "chat_id"
        case messageDate = "message_date"
        case isFromMe = "is_from_me"
        case senderHandle = "sender_handle"
        case text
    }
}

private struct AdminContactNameRow: Decodable {
    let handleNormalized: String
    let contactName: String

    enum CodingKeys: String, CodingKey {
        case handleNormalized = "handle_normalized"
        case contactName = "contact_name"
    }
}

private enum AdminMessagesFilter: String, CaseIterable, Identifiable {
    case all
    case you
    case them

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .you: return "You"
        case .them: return "Them"
        }
    }
}

private struct AdminChatMessagesSheet: View {
    let theme: Theme
    @ObservedObject var supabase: SupabaseService
    let ownerUserId: String
    let chat: AdminSyncChat

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading: Bool = false
    @State private var error: String = ""
    @State private var messages: [AdminChatMessageRow] = []
    @State private var totalMessageCount: Int?
    @State private var search: String = ""
    @State private var filter: AdminMessagesFilter = .all
    // Cursor for paging older messages (keyset pagination by date, then id).
    // We intentionally page by `message_date` rather than `message_id` because SQLite ROWID
    // can be out of chronological order after migrations / iCloud backfills.
    @State private var nextBeforeDate: String?
    @State private var nextBeforeId: Int64?
    @State private var isLoadingMore: Bool = false
    @State private var senderNamesByNormalized: [String: String] = [:]
    @State private var isResolvingSenders: Bool = false
    @State private var scrollTarget: AnyHashable?
    @State private var scrollTargetAnchor: UnitPoint = .bottom
    @State private var scrollRequestToken: Int = 0
    @State private var shouldScrollToLatest: Bool = false
    @State private var didInitialScrollToBottom: Bool = false

    private let initialPageSize: Int = 80
    private let pageSize: Int = 250
    private let bottomAnchorId: String = "bottom-anchor"
    private static let messageDateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()
    private static let messageDateParserNoFraction: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    private static let queryTimestampFormatter: DateFormatter = {
        // PostgREST query params often treat '+' as a space during decoding, which breaks
        // RFC3339 offsets like "+00:00". Force a UTC timestamp string with a literal 'Z'.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.label.isEmpty ? "Chat \(chat.id)" : chat.label)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(messagesCountSubtitle())
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Close")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    TextField("Search message text", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CardSurface(theme: theme, cornerRadius: 14, showShadow: false))

                Picker("", selection: $filter) {
                    ForEach(AdminMessagesFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Spacer()

                Button("Reload") { loadMessages(reset: true) }
                    .buttonStyle(GhostButtonStyle(theme: theme))
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading messages…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            } else if !error.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Could not load messages")
                        .font(.system(size: 12, weight: .semibold))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if error.contains("PGRST205") || error.lowercased().contains("could not find the table") {
                        Text("This usually means the backend table `public.chat_messages` is missing or the API schema cache is stale. Create the table, reload the schema cache, then retry.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                let filtered = filteredMessages(messages, search: search, filter: filter)
                if filtered.isEmpty {
                    EmptyStateInline(
                        icon: "bubble.left.and.bubble.right",
                        title: "No messages",
                        subtitle: "This chat has no messages yet. Ask the user to open the app and leave it running briefly, or wait for the next refresh.",
                        theme: theme
                    )
                    .padding(.top, 6)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if nextBeforeId != nil {
                                    // Auto-load older pages when the user scrolls to the top.
                                    // Gate on `didInitialScrollToBottom` to avoid accidentally
                                    // loading history if the initial scroll hasn't settled yet.
                                    HStack(spacing: 8) {
                                        Spacer()
                                        if isLoadingMore {
                                            ProgressView().scaleEffect(0.75)
                                            Text("Loading earlier…")
                                                .font(.system(size: 11))
                                                .foregroundStyle(theme.textSecondary)
                                        } else {
                                            // Keep the view extremely small so it doesn't shift layout.
                                            Color.clear.frame(width: 1, height: 1)
                                        }
                                        Spacer()
                                    }
                                    .frame(height: isLoadingMore ? 28 : 2)
                                    .contentShape(Rectangle())
                                    .onAppear {
                                        guard didInitialScrollToBottom else { return }
                                        if !isLoadingMore {
                                            loadMore()
                                        }
                                    }
                                }

                                if isResolvingSenders, chat.isGroup {
                                    HStack(spacing: 8) {
                                        ProgressView().scaleEffect(0.7)
                                        Text("Resolving names…")
                                            .font(.system(size: 11))
                                            .foregroundStyle(theme.textSecondary)
                                        Spacer()
                                    }
                                }

                                ForEach(Array(filtered.enumerated()), id: \.element.messageId) { idx, msg in
                                    if let separatorDate = daySeparatorDate(current: msg, previous: idx > 0 ? filtered[idx - 1] : nil) {
                                        daySeparator(separatorDate)
                                    }

                                    messageBubble(
                                        msg,
                                        showSenderName: chat.isGroup,
                                        senderName: senderName(for: msg),
                                        timeText: formattedTime(msg.messageDate)
                                    )
                                    .id(msg.messageId)
                                }

                                // Stable bottom anchor for reliable "scroll to latest".
                                Color.clear
                                    .frame(height: 1)
                                    .id(bottomAnchorId)
                                    .onAppear {
                                        guard shouldScrollToLatest else { return }
                                        shouldScrollToLatest = false
                                        DispatchQueue.main.async {
                                            withAnimation(.easeOut(duration: 0.22)) {
                                                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                                            }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                                didInitialScrollToBottom = true
                                            }
                                        }
                                    }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                        }
                        .onChange(of: scrollRequestToken) { _ in
                            guard let target = scrollTarget else { return }
                            let anchor = scrollTargetAnchor
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.22)) {
                                    proxy.scrollTo(target, anchor: anchor)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 600)
        .background(
            LinearGradient(
                colors: [theme.surfaceDeep, theme.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            loadMessages(reset: true)
        }
    }

    private func filteredMessages(_ messages: [AdminChatMessageRow], search: String, filter: AdminMessagesFilter) -> [AdminChatMessageRow] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return messages.filter { msg in
            if filter == .you, !msg.isFromMe { return false }
            if filter == .them, msg.isFromMe { return false }
            if needle.isEmpty { return true }
            return (msg.text ?? "").lowercased().contains(needle)
        }
    }

    private func loadMore() {
        guard nextBeforeId != nil else { return }
        loadMessages(reset: false)
    }

    private func requestScroll(to target: AnyHashable, anchor: UnitPoint) {
        scrollTarget = target
        scrollTargetAnchor = anchor
        scrollRequestToken += 1
    }

    private func loadMessages(reset: Bool) {
        let preserveTopId: Int64? = reset ? nil : messages.first?.messageId

        if reset {
            messages = []
            nextBeforeDate = nil
            nextBeforeId = nil
            totalMessageCount = nil
            isLoading = true
            error = ""
            didInitialScrollToBottom = false
        } else {
            isLoadingMore = true
        }

        let limit = reset ? initialPageSize : pageSize
        var query: [URLQueryItem] = [
            URLQueryItem(name: "owner_user_id", value: "eq.\(ownerUserId)"),
            URLQueryItem(name: "chat_id", value: "eq.\(chat.id)"),
            URLQueryItem(name: "select", value: "message_id,chat_id,message_date,is_from_me,sender_handle,text"),
            // Sort by time first. ROWID is a useful cursor but not a reliable chronology signal.
            URLQueryItem(name: "order", value: "message_date.desc.nullslast,message_id.desc"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if let beforeId = nextBeforeId {
            if let beforeDate = queryTimestamp(nextBeforeDate), !beforeDate.isEmpty {
                // (message_date, message_id) < (beforeDate, beforeId)
                // This keeps paging stable even when many messages share the same timestamp.
                let orValue = "(\n" +
                "message_date.lt.\(beforeDate),\n" +
                "and(message_date.eq.\(beforeDate),message_id.lt.\(beforeId))\n" +
                ")"
                query.append(URLQueryItem(name: "or", value: orValue.replacingOccurrences(of: "\n", with: "")))
            } else {
                // Fallback if date is missing.
                query.append(URLQueryItem(name: "message_id", value: "lt.\(beforeId)"))
            }
        }

        let prefer = reset ? "count=estimated" : nil
        supabase.postgrest(table: "chat_messages", query: query, prefer: prefer) { [weak supabase] result in
            _ = supabase // keep capture stable for debugging; UI uses self.supabase
            switch result {
            case .success((let data, let http)):
                let decoder = JSONDecoder()
                do {
                    // We request newest-first, but don't fully trust server-side ordering. Sort locally
                    // using message_date (then message_id) so the chat reads like iMessages.
                    let rows = try decoder.decode([AdminChatMessageRow].self, from: data)
                    let rowsDesc = rows.sorted { lhs, rhs in
                        let ld = self.parseMessageDate(lhs.messageDate)
                        let rd = self.parseMessageDate(rhs.messageDate)
                        switch (ld, rd) {
                        case let (l?, r?):
                            if l != r { return l > r }
                        case (nil, nil):
                            break
                        case (nil, _?):
                            // nil dates are treated as oldest (last in desc).
                            return false
                        case (_?, nil):
                            return true
                        }
                        return lhs.messageId > rhs.messageId
                    }
                    let rowsAsc = Array(rowsDesc.reversed())

                    if reset {
                        self.messages = rowsAsc
                        // Show the latest message by default.
                        if let total = parseTotalCount(from: http) {
                            self.totalMessageCount = total
                        }
                        self.shouldScrollToLatest = true
                        self.requestScroll(to: AnyHashable(self.bottomAnchorId), anchor: .bottom)
                    } else {
                        self.messages = rowsAsc + self.messages
                        if let preserveTopId {
                            // Keep the previously-visible top message anchored after we prepend older content.
                            self.requestScroll(to: AnyHashable(preserveTopId), anchor: .top)
                        }
                    }

                    // Pagination cursor: keep the oldest id we have (for lt.<id> paging).
                    if rowsDesc.count >= limit, let oldest = self.messages.first {
                        self.nextBeforeDate = oldest.messageDate
                        self.nextBeforeId = oldest.messageId
                    } else {
                        self.nextBeforeDate = nil
                        self.nextBeforeId = nil
                    }
                    self.error = ""

                    // Best-effort: resolve sender names for group chats so the UI is readable.
                    if self.chat.isGroup {
                        self.resolveSenderNames(from: rowsDesc)
                    }
                } catch {
                    self.error = "Decode failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                self.error = error.localizedDescription
            }

            self.isLoading = false
            self.isLoadingMore = false
        }
    }

    private func messageBubble(
        _ msg: AdminChatMessageRow,
        showSenderName: Bool,
        senderName: String?,
        timeText: String?
    ) -> some View {
        let isMe = msg.isFromMe
        let bubbleText = (msg.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = bubbleText.isEmpty ? "—" : bubbleText

        return HStack(alignment: .bottom, spacing: 10) {
            if isMe { Spacer(minLength: 60) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if showSenderName, !isMe {
                    Text((senderName ?? msg.senderHandle ?? "Unknown").trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(isMe ? Color.black.opacity(0.86) : theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                isMe
                                ? LinearGradient(colors: [theme.accent, theme.accentAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [theme.surfaceElevated, theme.surfaceDeep.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(isMe ? Color.white.opacity(0.15) : theme.border, lineWidth: 1)
                            )
                    )
                    .frame(maxWidth: 520, alignment: isMe ? .trailing : .leading)

                if let timeText, !timeText.isEmpty {
                    Text(timeText)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .padding(isMe ? .trailing : .leading, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)

            if !isMe { Spacer(minLength: 60) }
        }
        .padding(.vertical, 1)
    }

    private func parseMessageDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = Self.messageDateParser.date(from: value) { return date }
        return Self.messageDateParserNoFraction.date(from: value)
    }

    private func queryTimestamp(_ isoString: String?) -> String? {
        guard let date = parseMessageDate(isoString) else { return nil }
        return Self.queryTimestampFormatter.string(from: date)
    }

    private func daySeparatorDate(current: AdminChatMessageRow, previous: AdminChatMessageRow?) -> Date? {
        guard let currentDate = parseMessageDate(current.messageDate) else { return nil }
        guard let previous else { return currentDate }
        guard let prevDate = parseMessageDate(previous.messageDate) else { return currentDate }
        if Calendar.current.isDate(currentDate, inSameDayAs: prevDate) { return nil }
        return currentDate
    }

    private func daySeparator(_ date: Date) -> some View {
        let label = dayLabel(for: date)
        return HStack {
            Spacer()
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(theme.surfaceElevated.opacity(0.92))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(theme.border, lineWidth: 1)
                        )
                )
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func dayLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return Self.dayFormatter.string(from: date)
    }

    private func formattedTime(_ isoString: String?) -> String? {
        guard let date = parseMessageDate(isoString) else { return nil }
        return Self.timeFormatter.string(from: date)
    }

    private func parseTotalCount(from response: HTTPURLResponse) -> Int? {
        let header = (response.allHeaderFields["Content-Range"] as? String)
            ?? (response.allHeaderFields["content-range"] as? String)
        guard let header, !header.isEmpty else { return nil }
        let parts = header.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let totalPart = parts[1]
        guard totalPart != "*" else { return nil }
        return Int(totalPart)
    }

    private func formatCount(_ value: Int) -> String {
        Self.countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func messagesCountSubtitle() -> String {
        let loaded = messages.count
        if let total = totalMessageCount, total > 0 {
            return "Loaded \(formatCount(loaded)) of \(formatCount(total)) messages"
        }
        if loaded > 0 {
            return "Loaded \(formatCount(loaded)) messages"
        }
        return "Messages"
    }

    private func senderName(for msg: AdminChatMessageRow) -> String? {
        guard !msg.isFromMe, let handle = msg.senderHandle else { return nil }
        for candidate in normalizedHandleCandidates(handle) {
            if let name = senderNamesByNormalized[candidate], !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func resolveSenderNames(from rowsDesc: [AdminChatMessageRow]) {
        // Only relevant for group chats; DM label already identifies the other person.
        guard chat.isGroup else { return }
        guard !isResolvingSenders else { return }

        var wanted: Set<String> = []
        wanted.reserveCapacity(64)
        for row in rowsDesc where !row.isFromMe {
            guard let handle = row.senderHandle else { continue }
            for candidate in normalizedHandleCandidates(handle) {
                if senderNamesByNormalized[candidate] == nil {
                    wanted.insert(candidate)
                }
            }
        }
        guard !wanted.isEmpty else { return }

        let all = Array(wanted).sorted()
        let chunks = stride(from: 0, to: all.count, by: 140).map { start in
            Array(all[start..<min(start + 140, all.count)])
        }

        isResolvingSenders = true

        func inList(_ values: [String]) -> String {
            let quoted = values.map { value -> String in
                let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }.joined(separator: ",")
            return "in.(\(quoted))"
        }

        func fetchChunk(_ idx: Int) {
            if idx >= chunks.count {
                isResolvingSenders = false
                return
            }

            let chunk = chunks[idx]
            supabase.postgrest(
                table: "user_contacts",
                query: [
                    URLQueryItem(name: "owner_user_id", value: "eq.\(ownerUserId)"),
                    URLQueryItem(name: "handle_normalized", value: inList(chunk)),
                    URLQueryItem(name: "select", value: "handle_normalized,contact_name"),
                    URLQueryItem(name: "limit", value: "2000")
                ]
            ) { result in
                switch result {
                case .success((let data, _)):
                    let decoder = JSONDecoder()
                    if let rows = try? decoder.decode([AdminContactNameRow].self, from: data) {
                        for row in rows {
                            let key = row.handleNormalized.trimmingCharacters(in: .whitespacesAndNewlines)
                            let name = row.contactName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if key.isEmpty || name.isEmpty { continue }
                            // Keep the longest name if duplicates exist.
                            if let existing = self.senderNamesByNormalized[key], existing.count >= name.count { continue }
                            self.senderNamesByNormalized[key] = name
                        }
                    }
                case .failure:
                    break
                }
                fetchChunk(idx + 1)
            }
        }

        fetchChunk(0)
    }

    private func normalizedHandleCandidates(_ handle: String) -> [String] {
        var trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("imessage;") {
            trimmed = String(trimmed.dropFirst("iMessage;".count))
        } else if lower.hasPrefix("sms;") {
            trimmed = String(trimmed.dropFirst("SMS;".count))
        } else if lower.hasPrefix("mailto:") {
            trimmed = String(trimmed.dropFirst("mailto:".count))
        } else if lower.hasPrefix("tel:") {
            trimmed = String(trimmed.dropFirst("tel:".count))
        } else if lower.hasPrefix("p:") || lower.hasPrefix("e:") {
            trimmed = String(trimmed.dropFirst(2))
        }
        let cleaned = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return [] }
        if cleaned.contains("@") {
            return [cleaned.lowercased()]
        }

        let digits = cleaned.filter { $0.isNumber }
        if digits.isEmpty { return [cleaned] }

        var variants: Set<String> = []
        variants.insert(digits)
        variants.insert("+\(digits)")
        if digits.count > 10 {
            let suffix = String(digits.suffix(10))
            variants.insert(suffix)
            variants.insert("+\(suffix)")
        }
        return Array(variants)
    }
}

    private func formattedShortDate(_ value: String?) -> String? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func chatSubtitle(_ chat: AdminSyncChat) -> String {
        var parts: [String] = []
        if chat.isGroup {
            parts.append("\(decimalString(chat.participantCount)) people")
        } else {
            parts.append("Direct message")
        }
        if let last = formattedShortDate(chat.lastMessageDate) {
            parts.append("Last \(last)")
        }
        let left = chat.leftOnRead.youLeftThem + chat.leftOnRead.theyLeftYou
        if left > 0 {
            parts.append("\(decimalString(left)) left on read")
        }
        return parts.joined(separator: " • ")
    }

    private func humanizeMinutes(_ value: Double?) -> String {
        guard let minutes = value else { return "—" }
        if minutes < 60 {
            let rounded = Int(minutes.rounded())
            return "\(rounded) min"
        }
        let hours = minutes / 60
        if hours < 24 {
            let rounded = hours.rounded()
            if abs(hours - rounded) < 0.05 {
                let h = Int(rounded)
                return "\(h) \(h == 1 ? "hr" : "hrs")"
            }
            return String(format: "%.1f hrs", hours)
        }
        let days = hours / 24
        let rounded = days.rounded()
        if abs(days - rounded) < 0.05 {
            let d = Int(rounded)
            return "\(d) \(d == 1 ? "day" : "days")"
        }
        return String(format: "%.1f days", days)
    }

    private func humanizeHours(_ value: Double) -> String {
        if value < 24 {
            let rounded = value.rounded()
            if abs(value - rounded) < 0.05 {
                let h = Int(rounded)
                return "\(h) \(h == 1 ? "hr" : "hrs")"
            }
            return String(format: "%.1f hrs", value)
        }
        let days = value / 24
        let rounded = days.rounded()
        if abs(days - rounded) < 0.05 {
            let d = Int(rounded)
            return "\(d) \(d == 1 ? "day" : "days")"
        }
        return String(format: "%.1f days", days)
    }
}
