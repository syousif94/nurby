import SwiftUI

/// The part studio: a full-bleed 3D viewport, the CAD operations (or sketch tools) floating at
/// the bottom, and one sidebar on the right: the editor (features / parameters, or a feature's
/// panel) above the agent (transcript + composer). Drag the gap between them to share the
/// height; drag the gap or the sidebar's left edge sideways to put it away, and pull it back
/// from the right edge. When the window is taller than wide (iPad or iPhone Duo held upright) the
/// two panels sit side by side along the bottom instead, under the tools: drag their top edge to
/// resize, or down to put them away; the tools above them drag the same way. On a narrow screen
/// (iPhone upright) the two panels scroll sideways, each as wide as the screen allows up to a
/// limit, so the 3D view always stays in sight. Pen markup freezes the view and draws on it.
struct StudioView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    let design: DesignModel
    let agent: AgentSession
    var goHome: () -> Void
    var openSettings: () -> Void
    @State private var showSidebar = true
    @State private var drawerTab: DrawerTab = .features
    @State private var draft = ""
    @State private var sketcher = SketchController()
    @State private var panel: FeatureKind?
    @State private var editingFeature: DesignModel.Feature?
    @State private var images: [UIImage] = []
    @State private var viewport = ViewportHandle()
    @State private var markupBase: UIImage?
    /// Something in the sidebar was tapped while a sketch is open: save it, discard it or stay.
    @State private var askLeaveSketch = false
    @FocusState private var composerFocused: Bool
    /// The editor's share of the sidebar's height (the agent gets the rest).
    @AppStorage("sidebarSplit") private var split = 0.5
    @State private var splitStart: Double?
    /// Live sideways drag of the sidebar (points, + = towards the right edge).
    @State private var slide: CGFloat = 0
    @State private var gapAxis: Axis?
    /// The studio's size (decides side or bottom panels).
    @State private var screen: CGSize = .zero
    /// The bottom panels' share of the screen height.
    @AppStorage("dockSplit") private var dockShare = 0.42
    @State private var dockStart: Double?
    /// Live downward drag of the bottom panels (points, + = towards the bottom edge).
    @State private var dockDrag: CGFloat = 0
    /// The screen's safe-area insets: a hidden panel slides past them too, fully off screen.
    @State private var insets = EdgeInsets()
    /// Which bottom panel is in view when they scroll sideways (0 selected, 1 editor, 2 agent).
    @State private var dockPage: Int? = 1
    /// The axis a drag on the tools locked to (only up/down resizes the bottom panels).
    @State private var toolsAxis: Axis?
    @State private var keyboardUp = false

    private var compact: Bool { hSize == .compact }
    /// Too narrow for the sidebar button beside the tools: it sits above them instead.
    private var narrow: Bool { compact || (screen.width > 0 && screen.width < 700) }
    /// The sidebar is put away, so its button shows.
    private var sidebarAway: Bool { docked ? dockOffset > 0 : sidebarOffset > 0 }
    /// The agent shrinks to its composer while editing, except on its own page of the paged dock
    /// (narrow screens), where it has the room.
    private var agentCollapsed: Bool { editing && !(docked && dockPaged) }
    /// A sketch or a feature panel is open: the agent shrinks to its composer.
    private var editing: Bool { design.sketch != nil || panel != nil }
    /// Panels along the bottom, side by side: the window is taller than it is wide.
    private var docked: Bool { screen.height > screen.width }
    /// Typing with the panels along the bottom: the keyboard takes the room, so the tools step aside.
    private var typingDocked: Bool { docked && keyboardUp }
    /// Widest a bottom panel gets when they scroll sideways.
    private let dockPanelMax: CGFloat = 440
    /// Narrowest a bottom panel gets before they scroll sideways instead of sharing the width.
    private let dockPanelMin: CGFloat = 300
    /// The bottom panels don't both fit across: they scroll sideways, one (and a sliver of the
    /// next) in view at a time.
    private var dockPaged: Bool { screen.width - margin * 2 < dockPanelMin * 2 + gap }
    /// Each panel's width when paged: centred, leaving a peek at its neighbours each side, up to a limit.
    private var dockPanelWidth: CGFloat { max(min(screen.width - (gap + 24) * 2, dockPanelMax), 200) }
    private var dockHeight: CGFloat { (screen.height * dockShare).rounded() }
    /// How far down the bottom panels sit: 0 shown, `dockHeight + margin * 2` fully off screen.
    private var dockOffset: CGFloat {
        let off = dockOff
        return min(max((showSidebar ? 0 : off) + dockDrag, 0), off)
    }
    /// How much of the screen's height the bottom panels cover (0 unless docked).
    private var dockVisible: CGFloat { docked ? max(dockHeight + margin - dockOffset, 0) : 0 }
    /// How far the bottom panels move to be wholly off screen (past the safe area and their shadow).
    private var dockOff: CGFloat { dockHeight + margin * 2 + insets.bottom + 16 }
    /// The same for the sidebar, past the right edge.
    private var sidebarOff: CGFloat { sidebarWidth + margin * 2 + insets.trailing + 16 }
    /// The tools' band above the bottom panels.
    private let toolsBand: CGFloat = 70
    private let sidebarWidth: CGFloat = 380
    private let margin: CGFloat = 12
    private let gap: CGFloat = 12
    /// How far right the sidebar sits: 0 shown, `sidebarOff` fully off screen.
    private var sidebarOffset: CGFloat {
        let off = sidebarOff
        return min(max((showSidebar ? 0 : off) + slide, 0), off)
    }

    var body: some View {
        ZStack {
            Theme.ground(scheme).ignoresSafeArea()
            ViewportView(meshes: design.meshes, revision: design.revision, selection: design.selection, affected: design.affected,
                         sketch: design.sketch, sketchCenter: sketcher.center, sketchPPM: sketcher.ppm,
                         visibleWidth: 0.9, offscreen: reserved, offscreenBottom: reservedBottom, layoutKey: docked ? 1 : 0,
                         handle: viewport, onResize: { sketcher.size = $0 },
                         regions: design.sketch == nil ? design.regionPick : nil,
                         onRegion: { design.toggleRegion($0) }) { pick in
                Task { await design.toggle(pick) }
            }
            .padding(.leading, -reserved)
            .padding(.top, -reservedBottom)
            .ignoresSafeArea()

            if let sketch = design.sketch {
                ZStack {
                    SketchCanvas(sketch: sketch, controller: sketcher)
                    SketchTouchLayer(controller: sketcher, sketch: sketch,
                                     commitChain: { pts, closed in Task { await design.addPolyline(pts, closed: closed, construction: sketcher.construction) } },
                                     commitRect: { a, b in Task { await design.addRectangle(a, b, construction: sketcher.construction) } },
                                     commitCircle: { c, r in Task { await design.addCircle(center: c, radius: r, construction: sketcher.construction) } },
                                     project: { at, view in
                                         if let pick = viewport.pick(at: at, in: view) { Task { await design.project(pick) } }
                                     })
                }
                .padding(.leading, -reserved)
                .padding(.top, -reservedBottom)
                .ignoresSafeArea()
            }

            // The tools, centred in the part of the screen the sidebar leaves.
            HStack(spacing: 0) {
                VStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        if narrow && sidebarAway { sidebarButton }
                        HStack(spacing: 10) {
                            if let sketch = design.sketch {
                                SketchBar(design: design, sketch: sketch, controller: sketcher)
                            } else {
                                // A resize that starts on a tool doesn't run it when the finger lifts.
                                OperationsBar(design: design, feature: { k in if toolsAxis != .vertical { open(k, editing: nil) } }) { prompt in
                                    guard toolsAxis != .vertical else { return }
                                    draft = prompt
                                    reveal()
                                    withAnimation { dockPage = 2 }
                                    composerFocused = true
                                }
                            }
                            if !narrow && sidebarAway { sidebarButton }
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.bottom, 14 + dockVisible)
                    .simultaneousGesture(toolsDrag, isEnabled: docked)
                    // While typing to the agent the keyboard takes the room the tools had.
                    .opacity(typingDocked ? 0 : 1)
                    .allowsHitTesting(!typingDocked)
                    .animation(.easeOut(duration: 0.2), value: typingDocked)
                }
                .frame(maxWidth: .infinity)
                if !docked { Color.clear.frame(width: max(sidebarWidth + margin * 2 - sidebarOffset, 0)) }
            }

            selectionOverlay

            if docked {
                dock
            } else {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    sidebar
                        .frame(width: sidebarWidth)
                        .overlay(alignment: .leading) { slideHandle.offset(x: -margin - 6) }
                        .padding(margin)
                        .offset(x: sidebarOffset)
                }
                .overlay(alignment: .trailing) {
                    if sidebarOffset > 0 { slideHandle }   // pull it back from the right edge
                }
            }

            if let base = markupBase {
                MarkupView(base: base, crop: visibleArea.insetBy(dx: -20, dy: -20)) { marked in
                    if let marked { images.append(marked); reveal(); withAnimation { dockPage = 2 }; composerFocused = true }
                    withAnimation(.easeOut(duration: 0.2)) { markupBase = nil }
                }
                .padding(.leading, -reserved)
                .padding(.top, -reservedBottom)
                .transition(.opacity)
            }
        }
        .onChange(of: design.sketch.map { "\($0.id) \($0.name)" }) { _, key in
            sketcher.picked = []; sketcher.chain = []; sketcher.drag = nil
            if key != nil { sketcher.fit(design.sketch, in: visibleArea); closePanel() }
        }
        .onChange(of: design.originIDs) { _, ids in if !ids.isEmpty && panel == nil { drawerTab = .features } }
        .onChange(of: design.sketch?.points) { _, pts in sketcher.snapPoints = pts ?? [] }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .alert("Leave the sketch?", isPresented: $askLeaveSketch) {
            Button("Save Sketch") { Task { await design.finishSketch() } }
            Button("Discard Sketch", role: .destructive) { Task { await design.cancelSketch() } }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Save the sketch or discard its changes before using the sidebar.")
        }
        // The status bar would take a strip down the side in landscape on some devices (the
        // system decides where it goes; an app can't move it), so the studio hides it and the
        // sidebar runs to the screen edge.
        .statusBarHidden(true)
    }

    private var sidebarButton: some View {
        Button { reveal() } label: {
            Image(systemName: docked ? "rectangle.bottomhalf.inset.filled" : "sidebar.right").font(.system(size: 18))
                .frame(width: 52, height: 52)
        }
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Show sidebar")
    }

    /// What is selected, top left of the open area, while nothing else lists it (no sketch or
    /// feature panel open).
    private var selectionOverlay: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    if design.sketch == nil && panel == nil && markupBase == nil && !design.selection.isEmpty
                        && !(docked && dockPaged && dockOffset == 0) {
                        SelectionPanel(design: design, compact: narrow && docked)
                            .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if design.sketch == nil && markupBase == nil {
                        NavigationGizmo(handle: viewport).transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(margin)
            .frame(maxWidth: .infinity)
            if !docked { Color.clear.frame(width: max(sidebarWidth + margin * 2 - sidebarOffset, 0)).allowsHitTesting(false) }
        }
        .animation(.snappy(duration: 0.25), value: design.selection.isEmpty)
    }

    // MARK: Sidebar

    /// Editor above, agent below, with the gap between them as the (invisible) divider.
    private var sidebar: some View {
        GeometryReader { geo in
            let total = max(geo.size.height - gap, 1)
            let top = min(max(total * split, 140), max(total - 180, 140))
            VStack(spacing: 0) {
                if editing {
                    editor.frame(maxHeight: .infinity)
                    Color.clear.frame(height: gap)
                    agentPanel.fixedSize(horizontal: false, vertical: true)
                } else {
                    editor.frame(height: top)
                    Color.clear
                        .frame(height: gap)
                        .contentShape(.rect.inset(by: -6))
                        .gesture(gapDrag(total: total))
                        .accessibilityLabel("Resize")
                    agentPanel.frame(maxHeight: .infinity)
                }
            }
            .animation(.spring(duration: 0.35), value: editing)
        }
    }

    /// While a sketch is open, a tap anywhere on a sidebar panel asks whether to save or
    /// discard the sketch first, instead of reaching what is underneath.
    private func sketchGuard(_ content: some View) -> some View {
        content.overlay {
            if design.sketch != nil {
                Color.clear.contentShape(.rect)
                    .onTapGesture { askLeaveSketch = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Leave the sketch")
            }
        }
    }

    /// One glass panel that stays put; only what is inside it (the drawer, or a feature's
    /// panel) slides when a feature is opened or closed.
    private var editor: some View { sketchGuard(editorPanel) }

    private var editorPanel: some View {
        ZStack(alignment: .top) {
            if let panel, design.sketch == nil {
                FeaturePanel(kind: panel, design: design, editing: editingFeature, close: closePanel)
                    .id("\(panel.rawValue) \(editingFeature?.id ?? "new")")
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                DrawerView(design: design, tab: $drawerTab, hide: hide,
                       hideSymbol: docked ? "rectangle.bottomhalf.inset.filled" : "sidebar.right", goHome: goHome,
                           editFeature: { f in if let kind = DrawerView.editable(f) { open(kind, editing: f) } })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(.rect(cornerRadius: Theme.panelRadius, style: .continuous))
        .glassEffect(in: .rect(cornerRadius: Theme.panelRadius))
    }

    private var agentPanel: some View {
        sketchGuard(AgentPanel(agent: agent, design: design, hide: hide, openSettings: settings,
                               draft: $draft, focus: { composerFocused = true }, collapsed: agentCollapsed) { composer })
    }

    // MARK: Bottom panels

    /// Editor and agent side by side along the bottom, under the tools.
    private var dock: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if dockPaged {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: gap) {
                            // A horizontal scroll view doesn't bound its pages' height: a page
                            // taller than the dock (e.g. a long chat) would stretch them all and
                            // spill over the tools, so each is pinned to the dock's height.
                            selectedCard.frame(width: dockPanelWidth, height: dockHeight).id(0)
                            editor.frame(width: dockPanelWidth, height: dockHeight).id(1)
                            dockAgent.frame(width: dockPanelWidth, height: dockHeight).id(2)
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $dockPage)
                    .defaultScrollAnchor(.center)
                    .contentMargins(.horizontal, (screen.width - dockPanelWidth) / 2, for: .scrollContent)
                    .scrollClipDisabled()   // keep the glass shadows
                    .padding(.horizontal, -margin)   // run to the screen edges
                } else {
                    HStack(spacing: gap) {
                        editor.frame(maxWidth: .infinity)
                        dockAgent.frame(maxWidth: .infinity)
                    }
                }
            }
            .animation(.spring(duration: 0.35), value: editing)
            .frame(height: dockHeight)
            .overlay(alignment: .top) { dockHandle.offset(y: -13) }
            .padding(margin)
            .offset(y: dockOffset)
        }
        .overlay(alignment: .bottom) {
            if dockOffset > 0 { dockHandle }   // pull them back up from the bottom edge
        }
    }

    /// On a narrow screen, the first page: what is selected in the view, with ✕ / Clear.
    private var selectedCard: some View {
        let faces = design.selection.filter { $0.kind == .face }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Selected").font(.headline)
                if !design.selection.isEmpty {
                    Text(SelectionPanel.summary(faces: faces, edges: design.selection.count - faces))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !design.selection.isEmpty {
                    Button("Clear") { Task { await design.toggle(nil) } }
                        .font(.subheadline.weight(.medium)).tint(Theme.accent)
                }
            }
            .frame(minHeight: 36)
            if design.selection.isEmpty {
                Spacer(minLength: 0)
                Label("Tap faces or edges in the view to select them.", systemImage: "hand.tap")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            } else {
                ScrollView { PickList(design: design) }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(in: .rect(cornerRadius: Theme.panelRadius))
    }

    private var dockAgent: some View {
        agentPanel
            .fixedSize(horizontal: false, vertical: agentCollapsed)
            .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// A thin invisible strip along the panels' top edge: drag to resize them, or down past
    /// their smallest height to put them away (and up from the bottom edge to bring them back).
    private var dockHandle: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(.rect)
            .gesture(dockDragGesture)
    }

    /// Dragging the tools up or down does what the panels' top edge does (sideways drags are left
    /// to the tools' own scrolling, and taps to their buttons).
    private var toolsDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                if toolsAxis == nil { toolsAxis = abs(v.translation.height) > abs(v.translation.width) ? .vertical : .horizontal }
                if toolsAxis == .vertical { dockResize(v) }
            }
            .onEnded { v in
                if toolsAxis == .vertical { dockSettle(v) }
                // Let go after the tool under the finger has seen the lift (and stayed disabled).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { toolsAxis = nil }
            }
    }

    private var dockDragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged(dockResize)
            .onEnded(dockSettle)
    }

    private func dockResize(_ v: DragGesture.Value) {
        guard showSidebar, screen.height > 0 else { dockDrag = v.translation.height; return }
        let start = dockStart ?? dockShare
        dockStart = start
        let want = start - v.translation.height / screen.height
        let lo = 0.22, hi = 0.75
        if want < lo {
            dockShare = lo
            dockDrag = (lo - want) * screen.height
        } else {
            dockShare = min(want, hi)
            dockDrag = 0
        }
    }

    private func dockSettle(_ v: DragGesture.Value) {
        let off = dockOff
        withAnimation(.spring(duration: 0.35)) {
            if showSidebar {
                if dockDrag > 80 || (dockDrag > 0 && v.predictedEndTranslation.height - v.translation.height > 150) { showSidebar = false }
            } else {
                showSidebar = off + v.predictedEndTranslation.height < off * 0.6
            }
            dockDrag = 0
        }
        dockStart = nil
    }

    /// Up/down shares the height between editor and agent; sideways slides the sidebar.
    private func gapDrag(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in
                if gapAxis == nil { gapAxis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical }
                if gapAxis == .vertical {
                    let start = splitStart ?? split
                    splitStart = start
                    split = min(max(start + v.translation.height / total, 0.12), 0.88)
                } else {
                    slide = v.translation.width
                }
            }
            .onEnded { v in
                if gapAxis == .horizontal { settleSlide(v) }
                gapAxis = nil
                splitStart = nil
            }
    }

    /// A thin invisible strip that slides the sidebar on or off screen.
    private var slideHandle: some View {
        Color.clear
            .frame(width: 22)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { slide = $0.translation.width }
                .onEnded(settleSlide))
    }

    private func settleSlide(_ v: DragGesture.Value) {
        let off = sidebarOff
        let end = (showSidebar ? 0 : off) + v.predictedEndTranslation.width
        withAnimation(.spring(duration: 0.35)) {
            showSidebar = end < off / 2
            slide = 0
        }
    }

    private func settings() { openSettings() }

    private func hide() { composerFocused = false; withAnimation(.spring) { showSidebar = false } }
    private func reveal() { withAnimation(.spring) { showSidebar = true } }

    private func open(_ kind: FeatureKind, editing f: DesignModel.Feature?) {
        reveal()
        withAnimation(.spring(duration: 0.3)) { editingFeature = f; panel = kind; dockPage = 1 }
    }

    private func closePanel() {
        withAnimation(.spring(duration: 0.3)) { panel = nil; editingFeature = nil }
    }

    // MARK: Agent composer

    /// The 3D view runs under the sidebar but also extends this far past the screen's left edge,
    /// so its centre (where the camera looks) is the middle of the area the sidebar leaves open.
    private var reserved: CGFloat { docked ? 0 : max(sidebarWidth + margin - sidebarOffset, 0) }
    /// With the panels along the bottom, the 3D view runs this far past the screen's top edge so
    /// its centre is the middle of the area above the panels and tools.
    private var reservedBottom: CGFloat { dockVisible > 0 ? dockVisible + toolsBand : 0 }

    /// The part of the viewport on screen and clear of the sidebar and tools (viewport coordinates).
    private var visibleArea: CGRect {
        let s = sketcher.size
        let below = reservedBottom > 0 ? reservedBottom * 2 + 10 : 90
        return CGRect(x: reserved + 20, y: reservedBottom + 60, width: max(s.width - reserved * 2 - 40, 100), height: max(s.height - 60 - below, 100))
    }

    private var composer: some View {
        AgentComposer(agent: agent, design: design, draft: $draft, images: $images, focused: $composerFocused,
                      snapshot: {
                          if let img = shot() {
                              let keep = visibleArea.insetBy(dx: -20, dy: -20).intersection(CGRect(origin: .zero, size: img.size))
                              images.append(MarkupView.crop(composite: [img], size: img.size, scale: img.scale, to: keep.isEmpty ? CGRect(origin: .zero, size: img.size) : keep))
                          }
                      },
                      markup: {
                          composerFocused = false
                          guard let img = shot() else { return }
                          withAnimation(.easeOut(duration: 0.2)) { markupBase = img }
                      },
                      openSettings: settings)
    }

    private func shot() -> UIImage? {
        viewport.snapshot(background: UIColor(Theme.ground(scheme)))
    }
}
