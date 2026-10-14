//
//  AppData.swift
//  LBox
//
//  Created by Alexey Olendor on 12/3/25.
//

import Foundation
import Combine
import SwiftUI

actor Semaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { self.count = count }
    func wait() async { if count > 0 { count -= 1 } else { await withCheckedContinuation { waiters.append($0) } } }
    func signal() { if !waiters.isEmpty { waiters.removeFirst().resume() } else { count += 1 } }
}

actor RepoPersistenceWriter {
    private var latestRevision = 0
    
    func save(_ repos: [SavedRepo], to url: URL, revision: Int) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        
        do {
            let data = try JSONEncoder().encode(repos)
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save repos to file: \(error)")
        }
    }
}

@MainActor
class AppStoreViewModel: ObservableObject {
    @Published var savedRepos: [SavedRepo] = []
    @Published var displayApps: [AppItem] = []
    @Published var allAppsByVariant: [String: [AppItem]] = [:]
    
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var selectedRepoID: String? = nil
    
    // Updates
    @Published var availableUpdates: [String: String] = [:] // BundleID -> Latest Version
    
    // Sort Options
    @Published var appSortOrder: AppSortOption = .name {
        didSet {
            // Trigger async refresh when sort changes
            Task { await refreshDisplayApps() }
        }
    }
    @Published var repoSortOrder: RepoSortOption = .standard {
        didSet {
            UserDefaults.standard.set(repoSortOrder.rawValue, forKey: "kRepoSortOrder")
            sortRepos()
        }
    }
    
    // NEW: Strict Grouping Setting to separate apps by source/details
    @Published var strictGrouping: Bool = true {
        didSet {
            UserDefaults.standard.set(strictGrouping, forKey: "kStrictGrouping")
            Task { await refreshDisplayApps() }
        }
    }
    
    // Track fetch progress
    @Published var fetchProgress: Int = 0
    @Published var fetchTotal: Int = 0
    
    @Published var filteredApps: [AppItem] = []
    private var cancellables = Set<AnyCancellable>()
    
    @Published var isAutoUnzipEnabled: Bool = false { didSet { UserDefaults.standard.set(isAutoUnzipEnabled, forKey: "kAutoUnzipEnabled") } }
    private let kSavedReposKey = "kSavedReposKey"
    private let persistenceWriter = RepoPersistenceWriter()
    private var persistenceRevision = 0
    private var displayGeneration = 0
    @Published private(set) var catalogRevision = 0
    
    // MARK: - Persistence Path
    private var reposFileURL: URL {
        // Use Application Support so it isn't visible in user's Documents/Downloads
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("repos.json")
    }
    
    init() {
        self.isAutoUnzipEnabled = UserDefaults.standard.bool(forKey: "kAutoUnzipEnabled")
        if let storedSort = UserDefaults.standard.string(forKey: "kRepoSortOrder"),
           let option = RepoSortOption(rawValue: storedSort) {
            self.repoSortOrder = option
        }
        
        // Initialize Strict Grouping (Default to true)
        if UserDefaults.standard.object(forKey: "kStrictGrouping") != nil {
            self.strictGrouping = UserDefaults.standard.bool(forKey: "kStrictGrouping")
        } else {
            self.strictGrouping = true
        }
        
        loadRepos()
        setupSearchSubscription()
    }
    
    private func setupSearchSubscription() {
        Publishers.CombineLatest3(
            $searchText.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main),
            $displayApps,
            $selectedRepoID
        )
        .receive(on: DispatchQueue.global(qos: .userInitiated))
        .map { (text, apps, repoID) -> [AppItem] in
            let appsFromRepo = (repoID == nil) ? apps : apps.filter { $0.sourceRepoName == repoID }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return appsFromRepo
            } else {
                return appsFromRepo.filter {
                    $0.name.localizedCaseInsensitiveContains(text) ||
                    $0.bundleIdentifier.localizedCaseInsensitiveContains(text)
                }
            }
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$filteredApps)
    }
    
    // MARK: - Update Logic
    
    func checkForUpdates(installedApps: [LocalApp]) {
        Task {
            // Flatten all enabled apps from repos
            let allStoreApps = getEnabledLeafRepos().flatMap { $0.cachedApps ?? [] }
            
            // Group store apps by Bundle ID and find latest version
            var latestStoreVersions: [String: String] = [:] // BundleID : Version
            
            for app in allStoreApps {
                let bid = app.bundleIdentifier
                if bid.isEmpty || bid == "unknown" { continue }
                
                if let currentBest = latestStoreVersions[bid] {
                    if compareVersions(app.version, currentBest) == .orderedDescending {
                        latestStoreVersions[bid] = app.version
                    }
                } else {
                    latestStoreVersions[bid] = app.version
                }
            }
            
            // Compare with installed apps
            var newUpdates: [String: String] = [:]
            for installed in installedApps {
                guard let currentVer = installed.version else { continue }
                if let latestVer = latestStoreVersions[installed.bundleID] {
                    if compareVersions(latestVer, currentVer) == .orderedDescending {
                        newUpdates[installed.bundleID] = latestVer
                    }
                }
            }
            
            let finalUpdates = newUpdates
            await MainActor.run {
                self.availableUpdates = finalUpdates
            }
        }
    }
    
    func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        return v1.compare(v2, options: .numeric)
    }
    
    // MARK: - Repo Management
    
    func loadRepos() {
        let fileManager = FileManager.default
        
        // 0. Migration from Documents (Visible to User) -> Application Support (Hidden)
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("repos.json")
            
        if fileManager.fileExists(atPath: documentsURL.path) {
            do {
                print("Migrating repos.json to Application Support...")
                let destFolder = reposFileURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
                
                // If destination exists for some reason, remove it
                if fileManager.fileExists(atPath: reposFileURL.path) {
                    try fileManager.removeItem(at: reposFileURL)
                }
                
                try fileManager.moveItem(at: documentsURL, to: reposFileURL)
            } catch {
                print("Migration failed: \(error)")
            }
        }
        
        // 1. Try loading from File (Application Support)
        if let data = try? Data(contentsOf: reposFileURL),
           let decoded = try? JSONDecoder().decode([SavedRepo].self, from: data) {
            savedRepos = decoded
            sortRepos()
            return
        }
        
        // 2. Migration: Try loading from UserDefaults (Legacy)
        if let data = UserDefaults.standard.data(forKey: kSavedReposKey),
           let decoded = try? JSONDecoder().decode([SavedRepo].self, from: data) {
            print("Migrating repos from UserDefaults to File...")
            savedRepos = decoded
            sortRepos()
            // Save to new file location
            saveRepos()
            // Clean up old storage
            UserDefaults.standard.removeObject(forKey: kSavedReposKey)
            return
        }
        
        // 3. Fallback
        resetReposToDefault()
    }
    
    func getEnabledLeafRepos() -> [SavedRepo] {
        func flatten(_ nodes: [SavedRepo]) -> [SavedRepo] {
            var result: [SavedRepo] = []
            for node in nodes {
                if !node.isEnabled { continue }
                if let children = node.children { result.append(contentsOf: flatten(children)) }
                else { result.append(node) }
            }
            return result
        }
        let leaves = flatten(savedRepos)
        if repoSortOrder == .name {
            return leaves.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return leaves
    }
    
    func repoExists(_ id: String) -> Bool {
        func check(_ nodes: [SavedRepo]) -> Bool {
            for node in nodes {
                if node.id == id { return true }
                if let children = node.children { if check(children) { return true } }
            }
            return false
        }
        return check(savedRepos)
    }
    
    func getRepo(_ id: String) -> SavedRepo? {
        func find(_ nodes: [SavedRepo]) -> SavedRepo? {
            for node in nodes {
                if node.id == id { return node }
                if let children = node.children { if let found = find(children) { return found } }
            }
            return nil
        }
        return find(savedRepos)
    }
    
    func getRepos(in parentID: String?) -> [SavedRepo] {
        if let parentID = parentID {
            let kids = getRepo(parentID)?.children ?? []
            return sortNodes(kids)
        } else {
            return sortNodes(savedRepos)
        }
    }
    
    private func sortNodes(_ nodes: [SavedRepo]) -> [SavedRepo] {
        var sorted = nodes
        if repoSortOrder == .name {
            sorted.sort { (lhs, rhs) -> Bool in
                if lhs.isFolder && !rhs.isFolder { return true }
                if !lhs.isFolder && rhs.isFolder { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        return sorted
    }
    
    func updateNode(_ node: SavedRepo) {
        func update(_ nodes: inout [SavedRepo]) {
            for i in 0..<nodes.count {
                if nodes[i].id == node.id { nodes[i] = node; return }
                if nodes[i].isFolder { update(&nodes[i].children!) }
            }
        }
        update(&savedRepos)
    }
    
    func updateRepoStatus(id: String, status: RepoFetchStatus) {
        func update(_ nodes: inout [SavedRepo]) -> Bool {
            for i in 0..<nodes.count {
                if nodes[i].id == id { nodes[i].fetchStatus = status; return true }
                if nodes[i].isFolder { if update(&nodes[i].children!) { return true } }
            }
            return false
        }
        _ = update(&savedRepos)
    }
    
    func setRepoEnabled(id: String, enabled: Bool) {
        func update(_ nodes: inout [SavedRepo]) {
            for i in 0..<nodes.count {
                if nodes[i].id == id { nodes[i].isEnabled = enabled; return }
                if nodes[i].isFolder { update(&nodes[i].children!) }
            }
        }
        update(&savedRepos); saveRepos()
        if enabled { Task { await fetchRepo(id: id); await refreshDisplayApps() } }
        else { Task { await refreshDisplayApps() } }
    }
    
    func addRepo(url: URL, parentID: String? = nil) {
        let id = url.absoluteString
        if repoExists(id) { return }
        let newRepo = SavedRepo(url: url)
        if let pid = parentID {
            func insert(_ nodes: inout [SavedRepo]) -> Bool {
                for i in 0..<nodes.count {
                    if nodes[i].id == pid {
                       if nodes[i].repoListURL != nil { return false } // Cannot add repo manually to remote folder
                       if nodes[i].children == nil { nodes[i].children = [] }
                       nodes[i].children?.append(newRepo)
                       return true
                    }
                    if nodes[i].isFolder { if insert(&nodes[i].children!) { return true } }
                }
                return false
            }
            _ = insert(&savedRepos)
        } else { savedRepos.append(newRepo) }
        saveRepos()
        Task { await fetchRepo(id: id); await refreshDisplayApps() }
    }
    
    func addFolder(name: String, parentID: String?, repoListURL: URL? = nil) {
        let folder = SavedRepo(folderName: name, repoListURL: repoListURL)
        if let pid = parentID {
            func insert(_ nodes: inout [SavedRepo]) -> Bool {
                for i in 0..<nodes.count {
                    if nodes[i].id == pid {
                        // Cannot add folder manually to a remote folder
                       if nodes[i].repoListURL != nil { return false }
                       
                       if nodes[i].children == nil { nodes[i].children = [] }
                       nodes[i].children?.append(folder)
                       return true
                    }
                    if nodes[i].isFolder { if insert(&nodes[i].children!) { return true } }
                }
                return false
            }
            _ = insert(&savedRepos)
        } else { savedRepos.append(folder) }
        saveRepos()
        
        // If it's a remote folder, fetch immediately AND fetch its apps
        if let _ = repoListURL {
            Task { await fetchRemoteFolderList(folderID: folder.id, fetchApps: true) }
        }
    }
    
    func renameRepo(id: String, newName: String) {
        func update(_ nodes: inout [SavedRepo]) {
            for i in 0..<nodes.count {
                if nodes[i].id == id { nodes[i].name = newName; return }
                if nodes[i].isFolder { update(&nodes[i].children!) }
            }
        }
        update(&savedRepos); saveRepos()
    }
    
    func deleteRepo(id: String) {
        func remove(_ nodes: inout [SavedRepo]) {
            nodes.removeAll(where: { $0.id == id })
            for i in 0..<nodes.count {
                if nodes[i].isFolder { remove(&nodes[i].children!) }
            }
        }
        remove(&savedRepos); saveRepos()
        Task { await refreshDisplayApps() }
    }
    
    func moveRepo(id: String, toParentId: String?) {
        if let target = toParentId, isDescendant(childId: target, parentId: id) { return }
        var itemToMove: SavedRepo?
        func remove(_ nodes: inout [SavedRepo]) -> Bool {
            for i in 0..<nodes.count {
                if nodes[i].id == id { itemToMove = nodes.remove(at: i); return true }
                if nodes[i].isFolder { if remove(&nodes[i].children!) { return true } }
            }
            return false
        }
        guard remove(&savedRepos), let item = itemToMove else { return }
        if let targetId = toParentId {
            func insert(_ nodes: inout [SavedRepo]) -> Bool {
                for i in 0..<nodes.count {
                    if nodes[i].id == targetId {
                        if nodes[i].repoListURL != nil { return false } // Block move to remote folder
                        if nodes[i].children == nil { nodes[i].children = [] }
                        nodes[i].children?.append(item)
                        return true
                    }
                    if nodes[i].isFolder { if insert(&nodes[i].children!) { return true } }
                }
                return false
            }
            if !insert(&savedRepos) { savedRepos.append(item) }
        } else { savedRepos.append(item) }
        saveRepos()
    }
    
    private func isDescendant(childId: String, parentId: String) -> Bool {
        if childId == parentId { return true }
        var parentNode: SavedRepo?
        func find(_ nodes: [SavedRepo]) {
            for node in nodes {
                if node.id == parentId { parentNode = node; return }
                if let children = node.children { find(children) }
            }
        }
        find(savedRepos)
        if let p = parentNode {
            func has(_ nodes: [SavedRepo]) -> Bool {
                for node in nodes {
                    if node.id == childId { return true }
                    if let children = node.children { if has(children) { return true } }
                }
                return false
            }
            return p.children?.contains(where: { has([$0]) }) ?? false
        }
        return false
    }
    
    func getFolderTargets(excludingId: String) -> [SavedRepo] {
        func collect(_ nodes: [SavedRepo]) -> [SavedRepo] {
            var res: [SavedRepo] = []
            for node in nodes {
                if node.id == excludingId { continue } // Can't move into itself
                if node.isFolder {
                    // Can't move into remote folder
                    if node.repoListURL == nil {
                        res.append(node)
                        if let children = node.children { res.append(contentsOf: collect(children)) }
                    }
                }
            }
            return res
        }
        return collect(savedRepos)
    }

    func sortRepos() {
        func sort(_ nodes: inout [SavedRepo]) {
            nodes.sort { (lhs, rhs) -> Bool in
                if lhs.isFolder && !rhs.isFolder { return true }
                if !lhs.isFolder && rhs.isFolder { return false }
                
                // If sort order is name, we sort purely by name
                if repoSortOrder == .name {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                
                // Default: allow manual ordering / insertion order (stable)
                return false
            }
            for i in 0..<nodes.count { if nodes[i].isFolder { sort(&nodes[i].children!) } }
        }
        sort(&savedRepos)
    }
    
    func saveRepos() {
        sortRepos()
        persistenceRevision += 1
        
        let revision = persistenceRevision
        let snapshot = savedRepos
        let destination = reposFileURL
        
        // Serialize persistence away from the main actor so large repo caches do not stall scrolling.
        // Revisions prevent an older snapshot from overwriting a newer one if tasks are scheduled out of order.
        Task(priority: .utility) {
            await persistenceWriter.save(snapshot, to: destination, revision: revision)
        }
    }
    
    func exportReposJSON(onlyEnabled: Bool = false) -> String? {
        let exportable = savedRepos.map { ExportableRepo($0, onlyEnabled: onlyEnabled) }
        guard let data = try? JSONEncoder().encode(exportable) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    func exportSingleRepoJSON(_ repo: SavedRepo, onlyEnabled: Bool = false) -> String? {
        let exportable = ExportableRepo(repo, onlyEnabled: onlyEnabled)
        guard let data = try? JSONEncoder().encode(exportable) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    func exportReposURLList(onlyEnabled: Bool = false) -> String {
        return savedRepos.map { $0.allURLs(onlyEnabled: onlyEnabled) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    
    func importReposJSON(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        if let exported = try? JSONDecoder().decode([ExportableRepo].self, from: data) {
            let imported = exported.map { $0.toSavedRepo() }
            if savedRepos.isEmpty { savedRepos = imported } else { savedRepos.append(contentsOf: imported) }
        } else if let single = try? JSONDecoder().decode(ExportableRepo.self, from: data) {
            savedRepos.append(single.toSavedRepo())
        } else if let full = try? JSONDecoder().decode([SavedRepo].self, from: data) {
            if savedRepos.isEmpty { savedRepos = full } else { savedRepos.append(contentsOf: full) }
        }
        saveRepos()
        Task { await fetchAllRepos() }
    }
    
    func resetReposToDefault() {
        // Set default repos to a remote folder list
        if let url = URL(string: "https://lolendor.github.io/LBox/default_repos.csv") {
            let folder = SavedRepo(folderName: "Recommended", repoListURL: url)
            savedRepos = [folder]
            saveRepos()
            Task { await fetchAllRepos() }
        }
    }
    
    func fetchRemoteFolderList(folderID: String, fetchApps: Bool = false) async {
        guard let folder = getRepo(folderID), let listURL = folder.repoListURL else { return }
        updateRepoStatus(id: folderID, status: .loading)
        
        do {
            var request = URLRequest(url: listURL)
            request.cachePolicy = .useProtocolCachePolicy
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            try DownloadFileIdentity.validate(response)
            guard let string = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            let lines = string.components(separatedBy: .newlines)
            
            var newChildren: [SavedRepo] = []
            let existingKids = folder.children ?? []
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                     let fixed = (!trimmed.lowercased().hasPrefix("http") ? "https://" + trimmed : trimmed)
                     if let u = URL(string: fixed) {
                        // Attempt to preserve state (cache, names, enabled) if it existed before
                        if let existing = existingKids.first(where: { $0.url?.absoluteString == u.absoluteString }) {
                             newChildren.append(existing)
                        } else {
                            newChildren.append(SavedRepo(url: u))
                        }
                     }
                }
            }
            
            // Inline update
            func updateChildren(id: String, children: [SavedRepo]) {
                func scan(_ nodes: inout [SavedRepo]) {
                    for i in 0..<nodes.count {
                        if nodes[i].id == id {
                            nodes[i].children = children
                            nodes[i].fetchStatus = .success
                            return
                        }
                        if nodes[i].isFolder { scan(&nodes[i].children!) }
                    }
                }
                scan(&savedRepos)
            }
            
            // Update the structure only
            if !newChildren.isEmpty {
                 await MainActor.run {
                     updateChildren(id: folderID, children: newChildren)
                 }
            }
            
            // If explicitly asked (e.g. addFolder), fetch the apps for these children now.
            // fetchAllRepos passes false to avoid double-fetching.
            if fetchApps {
                let childrenToFetch = newChildren.filter { $0.url != nil && $0.isEnabled }
                await withTaskGroup(of: Void.self) { group in
                    for child in childrenToFetch {
                        group.addTask {
                            await self.fetchRepo(id: child.id, saveAfter: false)
                        }
                    }
                }
                saveRepos()
                await refreshDisplayApps()
            }
            
        } catch {
            print("Remote folder fetch error: \(error)")
            await MainActor.run {
                updateRepoStatus(id: folderID, status: .error(error.localizedDescription))
            }
        }
    }
    
    func fetchRepo(id: String, saveAfter: Bool = true) async {
        guard let repo = getRepo(id), let url = repo.url else { return }
        updateRepoStatus(id: id, status: .loading)
        
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .useProtocolCachePolicy
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            try DownloadFileIdentity.validate(response)
            
            // Offload decoding to background thread
            let (decoded, apps) = try await Task.detached {
                let decoded = try JSONDecoder().decode(RepoResponse.self, from: data)
                let apps = decoded.apps.map { var app = $0; app.sourceRepoName = decoded.name; return app }
                return (decoded, apps)
            }.value
            
            guard var updatedRepo = getRepo(id) else { return }
            updatedRepo.name = decoded.name
            if let bestIcon = decoded.bestIconURL { updatedRepo.iconURL = bestIcon }
            updatedRepo.appCount = decoded.apps.count
            updatedRepo.fetchStatus = .success
            updatedRepo.cachedApps = apps
            updateNode(updatedRepo)
        } catch {
            print("Failed to fetch \(url): \(error)")
            // Keep the source enabled and retain its cached apps after transient network failures.
            guard var failed = getRepo(id) else { return }
            failed.fetchStatus = .error(error.localizedDescription)
            updateNode(failed)
        }
        
        // Conditionally save
        if saveAfter {
            saveRepos()
        }
    }
    
    func fetchAllRepos() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        
        // 1. Update Remote Folders first
        func findRemoteFolders(_ nodes: [SavedRepo]) -> [SavedRepo] {
            var res: [SavedRepo] = []
            for node in nodes {
                if node.repoListURL != nil { res.append(node) }
                if let children = node.children { res.append(contentsOf: findRemoteFolders(children)) }
            }
            return res
        }
        let remoteFolders = findRemoteFolders(savedRepos)
        if !remoteFolders.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for folder in remoteFolders {
                    group.addTask { await self.fetchRemoteFolderList(folderID: folder.id, fetchApps: false) }
                }
            }
        }
        
        // 2. Update Leaf Repos
        let leafRepos = getEnabledLeafRepos()
        
        fetchTotal = leafRepos.count
        fetchProgress = 0
        
        for repo in leafRepos { updateRepoStatus(id: repo.id, status: .waiting) }
        // A modern iPhone can comfortably refresh several small JSON feeds in parallel.
        // Keep an upper bound so large source lists do not overwhelm slower hosts.
        let concurrentFetches = min(6, max(3, ProcessInfo.processInfo.activeProcessorCount))
        let semaphore = Semaphore(concurrentFetches)
        await withTaskGroup(of: Void.self) { group in
            for repo in leafRepos {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    await self.fetchRepo(id: repo.id, saveAfter: false)
                    await MainActor.run { self.fetchProgress += 1 }
                }
            }
        }
        
        // Save once at the end
        saveRepos()
        
        await refreshDisplayApps()
        isLoading = false
    }
    
    // Helper for consistent key generation across processes
    nonisolated static func generateGroupingKey(for app: AppItem, strict: Bool) -> String {
        if strict {
            // Combine bundleID (or url) + name + repo + description to enforce strict separation
            let bid = (app.bundleIdentifier != "unknown" && !app.bundleIdentifier.isEmpty) ? app.bundleIdentifier : app.downloadURL
            let name = app.name
            let repo = app.sourceRepoName ?? ""
            let desc = app.localizedDescription ?? ""
            return "\(bid)|#|\(name)|#|\(repo)|#|\(desc)"
        } else {
            // Default grouping: Only Bundle Identifier matters
            if app.bundleIdentifier != "unknown" && !app.bundleIdentifier.isEmpty {
                return app.bundleIdentifier
            }
            return app.downloadURL
        }
    }
    
    func refreshDisplayApps() async {
        let enabled = getEnabledLeafRepos()
        var allApps: [AppItem] = []
        for repo in enabled { if let cache = repo.cachedApps { allApps.append(contentsOf: cache) } }
        await processApps(allApps)
    }
    
    private func processApps(_ apps: [AppItem]) async {
        displayGeneration += 1
        let generation = displayGeneration
        let sortOrder = self.appSortOrder
        let isStrict = self.strictGrouping // Capture for detached task
        
        // Offload heavy sorting/filtering to background
        let (grouped, displayList) = await Task.detached(priority: .userInitiated) {
            // Group using the helper
            let grouped = Dictionary(grouping: apps) { app in
                AppStoreViewModel.generateGroupingKey(for: app, strict: isStrict)
            }
            
            var representatives: [AppItem] = []
            for (_, versions) in grouped {
                // Latest version based on version string comparison (or date)
                if let latest = versions.sorted(by: {
                    // Try numeric comparison first, fallback to date
                    let v1 = $0.version
                    let v2 = $1.version
                    if v1 != v2 {
                        return v1.compare(v2, options: .numeric) == .orderedDescending
                    }
                    return ($0.versionDate ?? "") > ($1.versionDate ?? "")
                }).first {
                    representatives.append(latest)
                }
            }
            
            let sorted = representatives.sorted { lhs, rhs in
                switch sortOrder {
                case .name:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                case .date:
                    let lDate = lhs.versionDate ?? ""
                    let rDate = rhs.versionDate ?? ""
                    return lDate > rDate
                case .size:
                    let lSize = lhs.size ?? 0
                    let rSize = rhs.size ?? 0
                    return lSize > rSize
                }
            }
            return (grouped, sorted)
        }.value
        
        guard generation == displayGeneration else { return }
        self.allAppsByVariant = grouped
        self.displayApps = displayList
        catalogRevision += 1
    }
    
    // Updated to use the correct key logic
    func getVersions(for app: AppItem) -> [AppItem] {
        let key = AppStoreViewModel.generateGroupingKey(for: app, strict: self.strictGrouping)
        guard let list = allAppsByVariant[key] else { return [] }
        
        return list.sorted {
            $0.version.compare($1.version, options: .numeric) == .orderedDescending
        }
    }
}


