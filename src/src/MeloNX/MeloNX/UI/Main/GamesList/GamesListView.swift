//
//  GamesListView.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import SwiftUI
import UniformTypeIdentifiers
import GameController
import Melo_Controller

enum ActiveSheet: Identifiable, Equatable{
    case gameInfo(game: GameInfo)
    case perGameSettings(game: GameInfo)
    // needs to be a full screen sheet so commented out
    // case gameController(game: Game)
    case dlc(game: GameInfo)
    case update(game: GameInfo)
    case mods(game: GameInfo)
    case account

    var id: String {
        switch self {
        case .gameInfo(let game),
             .perGameSettings(let game),
             // .gameController(let game),
             .dlc(let game),
             .mods(let game),
             .update(let game):
            return "\(type(of: self))-\(game.id)"
        case .account:
            return "account"
        }
    }
}



func bindingGame(_ game: Binding<GameInfo?>) -> Binding<Bool> {
    Binding(
        get: { game.wrappedValue != nil },
        set: { newValue in
            if !newValue {
                game.wrappedValue = nil
            }
        }
    )
}

extension UTType {
    static let nsp = UTType(exportedAs: "com.nintendo.switch-package")
    static let xci = UTType(exportedAs: "com.nintendo.switch-cartridge")
}

struct GamesListView: View {
    @EnvironmentObject public var ryujinxController: RyujinxController
    @StateObject var nativeSettings = NativeSettingsManager.shared
    @State var showingAccounts = false
    @State var activeSheet: ActiveSheet?
    @State var controllerEditor: GameInfo?
    @State var scrollTo: GameInfo?
    
    @State var previousDpadHandlers: [GCController: GCControllerDirectionPadValueChangedHandler?] = [:]
    @State var previousButtonAHandlers: [GCController: GCControllerButtonValueChangedHandler?] = [:]
    
    // Theme
    @Environment(\.appTheme) var theme
    
    // CarouselView
    @State var selectedIndex: Int = 0
    
    @State var spinTrigger: Int = 0
    @State var spinReset: Bool = false
    
    @State private var lastNavigationTime: Date = .distantPast
    @State private var isStickReset = true
    
    var controllerEdit: Binding<Bool> {
        bindingGame($controllerEditor)
    }
    
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass
    
    var games: Binding<[GameInfo]> {
        Binding(
            get: { ryujinxController.games },
            set: { ryujinxController.games = $0 }
        )
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                if ryujinxController.games.isEmpty {
                    emptyStateView
                        .toolbar {
                            toolbarHandler()
                        }
                } else {
                    Group {
                        switch nativeSettings.cardLayout(CardType.card).value {
                        case .list:
                            ScrollView {
                                ScrollViewReader { proxy in
                                    ForEach(ryujinxController.games) { game in
                                        Section {
                                            GameRowView(game: game)
                                                .id(game)
                                                .padding(.horizontal)
                                                .padding(.vertical, 5)
                                                .contextMenu {
                                                    gameContextMenu(for: game)
                                                }
                                        }
                                    }
                                    .onAppear() {
                                        setupControllerObservers(scrollProxy: proxy)
                                    }
                                    .onDisappear() {
                                        resetControllerObservers()
                                    }
                                }
                            }
                            .modifier(HiddenScrollBackground())
                            .themedBackground()
                            .toolbar {
                                toolbarHandler()
                            }
                        case .carousel:
                            ZStack {
                                Text("")
                                    .toolbar {
                                        toolbarHandler()
                                    }
                                
                                let cartridges: [CartridgeData] = ryujinxController.games.compactMap({ CartridgeData(labelImage: $0.icon ?? UIImage(), colors: [UIColor(hex: "171717"), .yellow]) })
                                
                                CartridgeCarouselView(cartridges: cartridges, selectedIndex: $selectedIndex, uiMenu: gameContextUIMenu, spinTrigger: $spinTrigger, reset: $spinReset, spun: { index in
                                    let game = ryujinxController.games[index]
                                    DispatchQueue.main.async {
                                        ryujinxController.startGame(game)
                                    }
                                })
                                .onAppear() {
                                    setupControllerObserversFor3DMode()
                                }
                                .onDisappear() {
                                    resetControllerObservers()
                                }
                            }
                            .modifier(HiddenScrollBackground())
                            .themedBackground()
                            .if(!(horizontalSizeClass == .compact && verticalSizeClass == .regular)) { view in
                                view
                                    .ignoresSafeArea(.all, edges: UIDevice.current.userInterfaceIdiom == .pad ? .bottom : .top)
                            }
                            
                        default:
                            ScrollView {
                                var columns: [GridItem] {
                                    switch nativeSettings.cardLayout(CardType.card).value {
                                    case .card, .compactCard: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)]
                                    case .compactCardNoBackground: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)]
                                    case .compactCardSmall: [GridItem(.adaptive(minimum: 105, maximum: 120), spacing: 16)]
                                    default: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)]
                                    }
                                }
                                
                                
                                LazyVGrid(columns: columns, spacing: columns.first?.spacing ?? 16) {
                                    ForEach(ryujinxController.games) { game in
                                        GameCardView(game: game)
                                            .id(game)
                                            .contextMenu {
                                                gameContextMenu(for: game)
                                            }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.top)
                            }
                            .modifier(HiddenScrollBackground())
                            .themedBackground()
                            .toolbar {
                                toolbarHandler()
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if ryujinxController.isJITEnabled {
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .frame(width: 12, height: 12)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundColor(checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit") ? Color.green : Color.orange)
                            .padding()
                    }
                    Spacer()
                }
                .offset(x: 0, y: -25)
            }
        }
        .navigationTitle("Library")
        .accentColor(theme.accent.primary)
        .fullScreenCover(isPresented: controllerEdit) {
            ControllerView(controller: VirtualControllerManager.shared, isEditing: true, gameId: controllerEditor?.titleId ?? "")
                .interactiveDismissDisabled(true)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .gameInfo(let game):
                GameInfoSheet(game: game)
            case .perGameSettings(let game):
                PerGameSettingsView(game.titleId)
            case .dlc(let game):
                DLCManagerSheet(game: game)
            case .update(let game):
                UpdateManagerSheet(game: game)
            case .mods(let game):
                ModsManagerSheet(game: game)
            case .account:
                AccountManagerView()
            }
        }
    }
    
    private var emptyStateView: some View {
        Group {
            if #available(iOS 17, *) {
                ContentUnavailableView(
                    "No Games Found",
                    systemImage: "square.and.arrow.down",
                    description: Text("Tap the + button to add legally dumped ROMs!")
                )
            } else {
                VStack(spacing: 20) {
                    Spacer()
                    
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    
                    Text("No Games Found")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Tap the + button to add legally dumped ROMs!")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
            }
        }
    }
    
    
    private func gameContextMenu(for game: GameInfo) -> some View {
        Group {
            Section {
                Button {
                    ryujinxController.startGame(game)
                } label: {
                    Label("Play Now", systemImage: "play.fill")
                }
                
                Button {
                    activeSheet = .gameInfo(game: game)
                } label: {
                    Label("Game Info", systemImage: "info.circle")
                }
                
                Button {
                    activeSheet = .perGameSettings(game: game)
                } label: {
                    Label("\(game.titleName) Settings", systemImage: ryujinxController.perSettings[game.titleId] == nil ? "gear" : "checkmark.circle")
                }
                
                Button {
                    controllerEditor = game
                } label: {
                    Label("Controller Layout", systemImage: "formfitting.gamecontroller")
                }
            }
            
            Section {
                Button {
                    activeSheet = .update(game: game)
                } label: {
                    Label("Update Manager", systemImage: "arrow.up.circle")
                }
                
                Button {
                    activeSheet = .dlc(game: game)
                } label: {
                    Label("DLC Manager", systemImage: "plus.circle")
                }
                
                Button {
                    activeSheet = .mods(game: game)
                } label: {
                    Label("Mod Manager", systemImage: "folder.circle")
                }
            }
            
            Section {
                
                Button(role: .destructive) {
                    ryujinxController.clearShaderCacheWithConfirmation(game)
                } label: {
                    Label("Clear Shader Cache", systemImage: "trash")
                }
                
                Button(role: .destructive) {
                    deleteGame(game: game)
                } label: {
                    Label("Delete Game", systemImage: "trash")
                }
            }
        }
    }
    
    private func gameContextUIMenu(for index: Int) -> UIMenu {
        let game = ryujinxController.games[index]
        
        let playAction = UIAction(
            title: "Play Now",
            image: UIImage(systemName: "play.fill")
        ) { _ in
            ryujinxController.startGame(game)
        }
        
        let infoAction = UIAction(
            title: "Game Info",
            image: UIImage(systemName: "info.circle")
        ) { _ in
            activeSheet = .gameInfo(game: game)
        }
        
        let settingsAction = UIAction(
            title: "\(game.titleName) Settings",
            image: UIImage(systemName: ryujinxController.perSettings[game.titleId] == nil ? "gear" : "checkmark.circle")
        ) { _ in
            activeSheet = .perGameSettings(game: game)
        }
        
        let controllerLayoutAction = UIAction(
            title: "Controller Layout",
            image: UIImage(systemName: "formfitting.gamecontroller")
        ) { _ in
            controllerEditor = game
        }
        
        let coreSection = UIMenu(
            title: "",
            options: .displayInline,
            children: [playAction, infoAction, settingsAction, controllerLayoutAction]
        )
        
        let updateAction = UIAction(
            title: "Update Manager",
            image: UIImage(systemName: "arrow.up.circle")
        ) { _ in
            activeSheet = .update(game: game)
        }
        
        let dlcAction = UIAction(
            title: "DLC Manager",
            image: UIImage(systemName: "plus.circle")
        ) { _ in
            activeSheet = .dlc(game: game)
        }
        
        let modsAction = UIAction(
            title: "Mod Manager",
            image: UIImage(systemName: "folder.circle")
        ) { _ in
            activeSheet = .mods(game: game)
        }
        
        let managersSection = UIMenu(
            title: "",
            options: .displayInline,
            children: [updateAction, dlcAction, modsAction]
        )
        
        let clearShaderCacheAction = UIAction(
            title: "Clear Shader Cache",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { _ in
            ryujinxController.clearShaderCacheWithConfirmation(game)
        }
        
        let deleteGameAction = UIAction(
            title: "Delete Game",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { _ in
            deleteGame(game: game)
        }
        
        let destructiveSection = UIMenu(
            title: "",
            options: .displayInline,
            children: [clearShaderCacheAction, deleteGameAction]
        )
        
        return UIMenu(
            title: "",
            children: [coreSection, managersSection, destructiveSection]
        )
    }
    
    private func setupControllerObservers(scrollProxy: ScrollViewProxy) {
        if !GCController.controllers().isEmpty {
            if scrollTo == nil {
                scrollTo = ryujinxController.games.first
            }
        }
        
        let dpadHandler: GCControllerDirectionPadValueChangedHandler = { _, _, yValue in
            guard !ryujinxController.games.isEmpty else { return }
            
            guard let scrollTo, let index = ryujinxController.games.firstIndex(of: scrollTo) else { return }
            let newIndex = yValue == 1.0 ? max(0, index - 1) : yValue == -1.0 ? min(ryujinxController.games.count - 1, index + 1) : index
            let game = ryujinxController.games[newIndex]
            
            self.scrollTo = game
            scrollProxy.scrollTo(game)
        }
        
        for controller in GCController.controllers() {
            controller.playerIndex = .index1
            
            previousDpadHandlers[controller] = controller.extendedGamepad?.dpad.valueChangedHandler
            previousButtonAHandlers[controller] = controller.extendedGamepad?.buttonA.pressedChangedHandler
            
            controller.microGamepad?.dpad.valueChangedHandler = dpadHandler
            controller.extendedGamepad?.dpad.valueChangedHandler = dpadHandler
            
            controller.extendedGamepad?.buttonA.pressedChangedHandler = { _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        if let scrollTo {
                            ryujinxController.startGame(scrollTo)
                        }
                    }
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { _ in
            setupControllerObservers(scrollProxy: scrollProxy)
        }
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { notif in
            if let controller = notif.object as? GCController {
                previousDpadHandlers.removeValue(forKey: controller)
            }
            if GCController.controllers().isEmpty {
                scrollTo = nil
            }
        }
    }
    
    private func resetControllerObservers() {
        for (controller, valueChanged) in previousDpadHandlers {
            controller.extendedGamepad?.dpad.valueChangedHandler = valueChanged
            controller.microGamepad?.dpad.valueChangedHandler = valueChanged
        }
        
        for (controller, valueChanged) in previousButtonAHandlers {
            controller.extendedGamepad?.buttonA.pressedChangedHandler = valueChanged
        }
        
        previousDpadHandlers = [:]
        previousButtonAHandlers = [:]
    }
    
    private func setupControllerObserversFor3DMode() {
        if !GCController.controllers().isEmpty {
            if scrollTo == nil {
                scrollTo = ryujinxController.games.first
            }
        }
        
        let dpadHandler: GCControllerDirectionPadValueChangedHandler = { _, xValue, yValue in
            guard !ryujinxController.games.isEmpty else { return }
            
            let newIndex = xValue == -1.0 ? max(0, selectedIndex - 1) : xValue == 1.0 ? min(ryujinxController.games.count - 1, selectedIndex + 1) : selectedIndex

            selectedIndex = newIndex
        }
        
        for controller in GCController.controllers() {
            controller.playerIndex = .index1
            
            previousDpadHandlers[controller] = controller.extendedGamepad?.dpad.valueChangedHandler
            previousButtonAHandlers[controller] = controller.extendedGamepad?.buttonA.pressedChangedHandler
            
            controller.microGamepad?.dpad.valueChangedHandler = dpadHandler
            controller.extendedGamepad?.dpad.valueChangedHandler = dpadHandler
            
            controller.extendedGamepad?.buttonA.pressedChangedHandler = { _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        spinTrigger += 1
                    }
                }
            }
            
            controller.extendedGamepad?.leftShoulder.pressedChangedHandler = { _, _, pressed in
                if pressed {
                    if selectedIndex > 0 { selectedIndex -= 1 }
                }
            }
            
            controller.extendedGamepad?.rightShoulder.pressedChangedHandler = { _, _, pressed in
                if pressed {
                    if selectedIndex < ryujinxController.games.count - 1 { selectedIndex += 1 }
                }
            }
            

            controller.extendedGamepad?.leftThumbstick.valueChangedHandler = { _, xValue, yValue in
                print("wow2: \(xValue), \(yValue)")
                
                guard !self.ryujinxController.games.isEmpty else { return }
                
                print("wow: \(xValue), \(yValue)")
                
                let now = Date()
                let timeSinceLastNav = now.timeIntervalSince(self.lastNavigationTime)
                
                if abs(xValue) < 0.3 {
                    self.isStickReset = true
                    return
                }
                
                let readyToNavigate = self.isStickReset || (timeSinceLastNav >= 0.20)
                guard readyToNavigate else { return }
                
                if xValue <= -0.5 {
                    self.selectedIndex = max(0, self.selectedIndex - 1)
                    self.lastNavigationTime = now
                    self.isStickReset = false
                } else if xValue >= 0.5 {
                    self.selectedIndex = min(self.ryujinxController.games.count - 1, self.selectedIndex + 1)
                    self.lastNavigationTime = now
                    self.isStickReset = false
                }
            }

        }
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { _ in
            setupControllerObserversFor3DMode()
        }
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { notif in
            if let controller = notif.object as? GCController {
                previousDpadHandlers.removeValue(forKey: controller)
            }
        }
    }
    
    private func deleteGame(game: GameInfo) {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: game.fileURL)
            
        } catch {
        }
    }
}

struct ClearListBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct HiddenScrollBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
                .background(ClearListBackground())
                .onAppear {
                    UITableView.appearance().backgroundColor = .clear
                }
        }
    }
}
