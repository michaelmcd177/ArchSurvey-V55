import SwiftUI
import Foundation
import UIKit
import PDFKit
import CoreLocation
import UniformTypeIdentifiers
import Combine
import Compression
import AudioToolbox
import AVFoundation
import MapKit
import AuthenticationServices
import CryptoKit
import Security
import ARKit
import SceneKit
import Metal
import CoreImage

@main
struct AvenzaStyleFieldMapperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var location = FieldLocationManager()
    @StateObject private var compass = CompassManager()
    @StateObject private var layerStore = LayerStore()
    @StateObject private var dprFormStore = DPRFormStore()
    @StateObject private var templateStore = TemplateStore()
    @StateObject private var mapProxy = MapProxy()
    @StateObject private var arcGISAuth = ArcGISAuthManager()
    /// Unified raster/reference layer stack for GeoPDFs, USGS topo, imagery, terrain overlays, and online previews.
    /// This is separate from LayerStore, which stores field-recorded points/lines/polygons.
    @StateObject private var surveyLayerStore = SurveyLayerStore()

    @State private var pdfDocument: PDFDocument?
    @State private var georef: GeoReference?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var showingCalibration = false
    @State private var showingLayerList = false
    @State private var showingBearingSheet = false
    @State private var showingBearingTools = false
    @State private var exportFileURL: URL?
    @State private var importMessage = "Import a georeferenced PDF map to begin."
    @State private var followMode: MapFollowMode = .free
    @State private var manualMapRotationDegrees: Double = 0
    @State private var mapTool: MapTool = .navigate
    @State private var measurePoints: [CLLocationCoordinate2D] = []
    @State private var polygonPoints: [CLLocationCoordinate2D] = []
    @State private var bearingLine: [CLLocationCoordinate2D] = []
    @State private var bearingLineDegrees: Double?

    // Walk Transect: vibrate when drifting off the bearing line.
    @State private var walkTransectEnabled = false
    @State private var isOffTransect = false
    @State private var lastTransectAlert = Date.distantPast
    @State private var transectModeActive = false
    @AppStorage("transectAlertDistanceMeters") private var transectAlertDistance = 15.0
    @AppStorage("transectAlertStyle") private var transectAlertStyleRaw = TransectAlertStyle.vibrate.rawValue

    private var transectAlertStyle: TransectAlertStyle {
        TransectAlertStyle(rawValue: transectAlertStyleRaw) ?? .vibrate
    }

    // Survey settings (shared with SurveySettingsView via AppStorage)
    @AppStorage("recorderName") private var recorderName = ""
    @AppStorage("coordinateDisplayFormat") private var coordinateFormatRaw = CoordinateDisplayFormat.decimalDegrees.rawValue
    @AppStorage("gpsAveragingEnabled") private var gpsAveragingEnabled = false
    @AppStorage("gpsAveragingTargetFixes") private var gpsAveragingTargetFixes = 30
    @AppStorage("distanceUnits") private var distanceUnitsRaw = DistanceUnits.metric.rawValue
    @State private var showingSurveySettings = false
    /// Which kind of file the single fileImporter is being used for.
    /// SwiftUI only supports one .fileImporter per view, so map (PDF)
    /// and data (KML/GeoJSON) imports share it.
    @State private var fileImportKind: FileImportKind = .map
    @State private var averagingRequest: GPSAveragingRequest?

    private var coordinateFormat: CoordinateDisplayFormat {
        CoordinateDisplayFormat(rawValue: coordinateFormatRaw) ?? .decimalDegrees
    }

    private var distanceUnits: DistanceUnits {
        DistanceUnits(rawValue: distanceUnitsRaw) ?? .metric
    }

    /// Draw-time settings for the currently loaded PDF/raster basemap.
    /// The Layer Manager stores layer order/opacity; this keeps the active map
    /// from hiding terrain, topo, or imagery comparisons.
    private var currentMapLayerOpacity: Double {
        guard let path = currentMapURL?.standardizedFileURL.path,
              let layer = surveyLayerStore.layers.first(where: { $0.localFilePath == path }) else { return 1.0 }
        return layer.isVisible ? layer.opacity : 0.0
    }

    private var currentMapLayerBlendMode: SurveyLayerBlendMode {
        guard let path = currentMapURL?.standardizedFileURL.path,
              let layer = surveyLayerStore.layers.first(where: { $0.localFilePath == path }) else { return .normal }
        return layer.blendMode
    }

    // Transect array + walked-coverage buffer
    @State private var transectArrayLines: [[CLLocationCoordinate2D]] = []
    @State private var activeTransectIndex = 0
    @AppStorage("showCoverageBuffer") private var showCoverage = false
    @AppStorage("coverageWidthMeters") private var coverageWidthMeters = 15.0
    @AppStorage("bufferSavedLines") private var bufferSavedLines = false
    @State private var showingCustomBufferAlert = false
    @State private var customBufferText = ""
    /// Walk-to-draw: GPS positions stream in as line/polygon vertices.
    @State private var autoVertexEnabled = false
    @State private var showingTransectArraySheet = false
    @State private var showingExportPicker = false
    @State private var showingOnlineDataCatalog = false
    @State private var showingHomeOfflineBasemapSetup = false
    /// Offline imagery/topo download center: public orthoimagery, USGS topo, historical topo,
    /// Apple satellite online preview notice, and user-imported imagery.
    @State private var showingOfflineImageryTopoDownload = false
    @State private var showingOfflineMapStorage = false
    /// Full map-layer manager: draw order, visibility, opacity, blend modes, presets, and offline readiness.
    @State private var showingMapLayerManager = false
    /// The top navigation used to be built with several nested SwiftUI Menus.
    /// On current iOS/Xcode builds that could crash while instantiating Menu metadata.
    /// These lightweight sheet hubs keep the same tools available without nested Menu builders.
    @State private var showingImportActionHub = false
    @State private var showingFieldActionHub = false
    @State private var showingTerrainActionHub = false
    @State private var showingGNSSActionHub = false
    @State private var currentMapURL: URL?
    @State private var showingTerrainViz = false
    /// Optional RVT/VAT raster drawn transparently over the current PDF/offline basemap.
    @State private var terrainOverlay: TerrainRasterOverlay?
    @AppStorage("terrainOverlayOpacity") private var terrainOverlayOpacity = 0.45
    /// Temporarily hide the overlay (toggle) without discarding it.
    @State private var terrainOverlayHidden = false
    /// Show the floating opacity slider on the map.
    @State private var showingFloatingOpacity = false
    /// Whether the floating terrain control pill is shown on the map.
    /// Off by default; turned on when the user chooses to while creating
    /// an overlay, and toggled from the Terrain menu.
    @State private var showingFloatingTerrainControl = false
    /// A user-imported DEM waiting for RVT/VAT processing options.
    @State private var importedDEMTerrainRequest: ImportedDEMTerrainRequest?
    /// The live-adjust panel for the active overlay's parameters.
    @State private var showingTerrainControlPanel = false
    /// Current parameters of the active overlay (for live re-rendering).
    @State private var activeTerrainParameters = TerrainVizParameters()
    /// The kind of the active overlay (for live re-rendering).
    @State private var activeTerrainKind: TerrainVisualizationKind = .vatHillshade
    /// The DEM backing the active overlay, kept so the live panel can
    /// re-render without re-downloading.
    @State private var activeTerrainDEM: DEMGrid?
    /// True while a live re-render is running.
    @State private var liveRenderInFlight = false
    /// Set when parameters change during a render, so we re-render once
    /// the in-flight job finishes (debounce/coalesce).
    @State private var liveRenderPending = false
    /// Offline elevation grid for the current map (crosshair readout
    /// and elevation stamping). Loaded per map from ElevationGridStore.
    @State private var elevationGrid: DEMGrid?
    /// Geographic coordinate under the center crosshair, updated live.
    @State private var crosshairCoordinate: CLLocationCoordinate2D?
    /// Collapsed = just the location bar and a + button.
    @AppStorage("bottomBarExpanded") private var bottomBarExpanded = true
    @State private var toolMessage = "Pan and zoom the map normally. Tap the compass badge to follow your GPS."

    /// A feature whose attributes are being filled in before it is saved.
    @State private var pendingLayer: MapLayer?
    /// Which tool's working geometry to clear once the pending feature is saved.
    @State private var pendingClearTool: MapTool?
    /// A saved feature opened for viewing/editing from the Layers list or by selecting Edit.
    @State private var editingSavedLayer: MapLayer?
    /// A saved feature opened read-only after tapping it on the map.
    @State private var viewingSavedLayer: MapLayer?
    /// Selected map feature. Vertices are hidden until a feature is selected.
    @State private var selectedLayerID: UUID?
    /// Selected vertex within the selected feature. Tap a new map location to move it.
    @State private var selectedVertexIndex: Int?
    /// Original copy used while vertex editing, so edits can be cancelled.
    @State private var originalLayerBeforeVertexEdit: MapLayer?
    /// True after at least one vertex has moved and before Save/Cancel is pressed.
    @State private var hasUnsavedVertexEdits = false
    /// Lightweight unit picker for quick distance/area measurements.
    @State private var showingMeasurementUnits = false
    /// Shows quick-add actions in a sheet instead of a nested SwiftUI Menu.
    /// This avoids EXC_BAD_ACCESS crashes from large Menu view-builder metadata.
    @State private var showingQuickAddSheet = false
    /// Starts an iPhone LiDAR scan tied to a GPS/map coordinate.
    @State private var lidarScanRequest: LiDARScanRequest?
    /// Starts a non-LiDAR photo-based 3D model capture tied to a GPS/map coordinate.
    @State private var photo3DModelScanRequest: LiDARScanRequest?
    /// Opens a saved PLY point cloud in the in-app 3D viewer.
    @State private var viewingLiDARPointCloud: LiDARPointCloudDocument?
    /// Sends one or more saved LiDAR files to Files, AirDrop, email, or another app.
    @State private var sharingLiDARScan: LiDARSharePackage?
    /// Opens a buffer-creation sheet for a selected line or track feature.
    @State private var bufferFeatureRequest: FeatureBufferRequest?
    /// Opens a transect-array sheet seeded from a selected line or track feature.
    @State private var transectArrayFeatureRequest: TransectArrayFromLayerRequest?

    // MARK: Field recorder UI / crew workflow
    /// Cleaner field-recorder mode: keeps the main screen focused on record/review/export tasks.
    @AppStorage("fieldRecorderModeEnabled") private var fieldRecorderModeEnabled = true
    @State private var showingFieldDashboard = false
    @State private var showingFieldRecorderSheet = false
    @State private var showingDataCheck = false
    @State private var showingTransectMission = false
    @State private var showingCrewPackage = false
    @State private var showingDPRForms = false
    @State private var dprFormsContextLayerID: UUID?
    @State private var editingDPRForm: DPRFormEditorRequest?
    /// Prompt shown after a GeoPDF/map import so recorders can download
    /// all offline layers needed to auto-fill DPR 523 location fields.
    @State private var showingDPRAutofillSetup = false

    /// One-tap full-map mode. When on, top/bottom controls and the
    /// field-recorder deck disappear, leaving only the map, crosshair,
    /// heading badge, and a small restore button.
    @AppStorage("mapChromeCollapsed") private var mapChromeCollapsed = false
    /// Collapses the large field-recorder action deck into a small pill.
    @AppStorage("fieldRecorderDeckCollapsed") private var fieldRecorderDeckCollapsed = true

    @AppStorage("preferExternalGNSS") private var preferExternalGNSS = false

    var body: some View {
        ZStack(alignment: .top) {
            if let pdfDocument = pdfDocument {
                GeometryReader { geometry in
                    // Oversize the map view to the screen diagonal so the
                    // corners never show through when the map is rotated.
                    let diagonal = sqrt(
                        geometry.size.width * geometry.size.width +
                        geometry.size.height * geometry.size.height
                    )

                    GeoPDFView(
                    document: pdfDocument,
                    georef: georef,
                    locations: location.track,
                    currentLocation: location.currentLocation,
                    headingDegrees: compass.trueHeadingDegrees,
                    mapTool: mapTool,
                    measurePoints: measurePoints,
                    polygonPoints: polygonPoints,
                    bearingLine: bearingLine,
                    previewCoordinate: liveMeasurementPreviewCoordinate,
                    distanceUnits: distanceUnits,
                    savedLayers: layerStore.layers,
                    selectedLayerID: selectedLayerID,
                    selectedVertexIndex: selectedVertexIndex,
                    transectArrayLines: transectArrayLines,
                    activeTransectIndex: activeTransectIndex,
                    coverageSwathMeters: showCoverage ? coverageWidthMeters : 0,
                    bufferSavedLinesWidthMeters: bufferSavedLines ? coverageWidthMeters : 0,
                    terrainOverlay: terrainOverlay,
                    terrainOverlayOpacity: terrainOverlayHidden ? 0 : terrainOverlayOpacity,
                    currentMapOpacity: currentMapLayerOpacity,
                    currentMapBlendMode: currentMapLayerBlendMode,
                    followMode: followMode,
                    viewportSize: geometry.size,
                    onCenterCoordinateChanged: { coordinate in
                        crosshairCoordinate = coordinate
                    },
                    onMapTap: handleMapTap,
                    onFeatureTap: { featureID in
                        openFeatureInfo(featureID)
                    },
                    onVertexTap: { featureID, vertexIndex in
                        selectVertex(layerID: featureID, vertexIndex: vertexIndex)
                    },
                    onUserPan: {
                        if followMode != .free {
                            if followMode == .oriented {
                                // Keep the current rotation so the map doesn't snap.
                                manualMapRotationDegrees = -(compass.continuousHeadingDegrees ?? 0)
                            }
                            followMode = .free
                            toolMessage = "Free pan. Tap the compass badge to follow GPS again."
                        }
                    },
                    onUserRotate: { deltaDegrees in
                        if followMode == .oriented {
                            // Hand control to the user from the map's current angle.
                            manualMapRotationDegrees = -(compass.continuousHeadingDegrees ?? 0)
                            followMode = .centered
                        }
                        manualMapRotationDegrees += deltaDegrees
                    },
                    proxy: mapProxy
                )
                    .frame(width: diagonal, height: diagonal)
                    .rotationEffect(.degrees(effectiveMapRotationDegrees))
                    .animation(.easeInOut(duration: 0.25), value: followMode)
                    .animation(.linear(duration: 0.3), value: effectiveMapRotationDegrees)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .ignoresSafeArea()
            } else {
                welcomeScreen
            }

            // Crosshair marking the exact screen center. Always visible
            // (dimmed when idle) so Drop Point @ Crosshair is always
            // aimable; bold while a collection tool is active.
            if pdfDocument != nil, !transectModeActive {
                CrosshairView(dimmed: mapTool == .navigate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            // Heading/north badge floating in the top-right of the map.
            if pdfDocument != nil, !transectModeActive {
                floatingHeadingBadge
            }

            // Floating RVT/VAT overlay control: a compact pill that
            // expands into an opacity slider. Only present when an
            // overlay exists AND the user opted to show it.
            if terrainOverlay != nil, showingFloatingTerrainControl, !transectModeActive {
                terrainOverlayFloatingControl
            }

            // Live parameter panel: real-time sliders that re-render the
            // active overlay as you drag. Slides up from the bottom.
            if showingTerrainControlPanel, terrainOverlay != nil, !transectModeActive {
                terrainLiveControlPanel
            }

            // Floating Collect button: sits just above the bottom bar,
            // center, on the map. Holds the data-capture tools (point,
            // line, polygon, measure) and track recording.
            if pdfDocument != nil, !transectModeActive, mapTool == .navigate,
               !showingTerrainControlPanel, !fieldRecorderModeEnabled, !mapChromeCollapsed {
                floatingCollectButton
            }

            if pdfDocument != nil, !transectModeActive, mapTool == .navigate,
               !showingTerrainControlPanel, fieldRecorderModeEnabled, !mapChromeCollapsed {
                fieldRecorderControlDeck
            }

            if pdfDocument != nil {
                mapChromeToggleButton
            }

            VStack(spacing: 0) {
                if !mapChromeCollapsed {
                    topBar
                }
                if transectModeActive {
                    transectHUD
                }
                Spacer()
                if !mapChromeCollapsed {
                    if transectModeActive {
                        transectBottomBar
                    } else if mapTool != .navigate {
                        collectBottomBar
                    } else {
                        bottomFieldControls
                    }
                }
            }
        }
        .onAppear {
            location.requestPermission()
            compass.start()
            if terrainOverlay == nil {
                terrainOverlay = TerrainOverlayStore.loadLast()
            }
            seedDefaultMapLayerStackEntries()
            registerCurrentMapInLayerStackIfPossible()
            registerActiveTerrainOverlayInLayerStackIfPossible()
        }
        .onReceive(location.$currentLocation) { newLocation in
            checkTransect(newLocation)
            appendWalkVertexIfNeeded(newLocation)
        }
        // The file importer lives on its own hidden anchor view via
        // .background. SwiftUI does not reliably present a .fileImporter
        // that is stacked above ~15+ .sheet modifiers on the same view;
        // isolating it here guarantees GeoPDF and DEM import always open.
        .background(
            Color.clear
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: dataImportTypes,
                    allowsMultipleSelection: false
                ) { result in
                    routeImportedFile(result)
                }
        )
        .sheet(isPresented: $showingExporter) {
            if let exportFileURL = exportFileURL {
                ShareSheet(activityItems: [exportFileURL])
            }
        }
        .sheet(isPresented: $showingCalibration) {
            CalibrationView { calibratedReference in
                georef = calibratedReference
                importMessage = "Manual calibration set. GPS position and tracks will draw when you are inside the entered map extent."
                showingCalibration = false
            }
        }
        .sheet(isPresented: $showingLayerList) {
            LayerListView(
                store: layerStore,
                templateStore: templateStore,
                onWalkLayer: { layer in
                    walkSavedLayer(layer)
                },
                onBufferLayer: { layer in
                    showingLayerList = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        bufferFeatureRequest = FeatureBufferRequest(layer: layer)
                    }
                }
            )
        }
        .sheet(isPresented: $showingExportPicker) {
            LayerExportPickerView(layers: layerStore.layers) { selectedLayers, format in
                exportLayers(selectedLayers, format: format)
            }
        }
        .alert("Custom Buffer Width", isPresented: $showingCustomBufferAlert) {
            TextField("Width in \(distanceUnits.shortDistanceLabel)", text: $customBufferText)
                .keyboardType(.decimalPad)
            Button("Set") {
                if let value = Double(customBufferText), value > 0 {
                    let meters = UnitFormat.metersFromInput(value, units: distanceUnits)
                    coverageWidthMeters = min(max(meters, 1), 500)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Total corridor width used for the walked-track buffer, saved-line buffers, and buffer-to-polygon saves.")
        }
        .sheet(isPresented: $showingSurveySettings) {
            SurveySettingsView()
        }
        .sheet(isPresented: $showingOnlineDataCatalog) {
            OnlineDataCatalogView(
                mapExtent: georef?.downloadExtent,
                currentCoordinate: location.currentLocation?.coordinate,
                arcGISAuth: arcGISAuth,
                onDownloadDPRPack: {
                    await downloadDPRAutofillPackForCurrentMap()
                },
                onImport: { downloadedLayers, sourceName in
                    if pdfDocument == nil {
                        let fallbackExtent = georef?.downloadExtent
                            ?? location.currentLocation.map { GeoExtent.around($0.coordinate, radiusMeters: 1_000) }
                        if let extent = fallbackExtent {
                            createBlankOfflineMap(for: extent, title: "Offline Map")
                        }
                    }
                    for layer in downloadedLayers {
                        layerStore.add(layer)
                    }
                    toolMessage = "Downloaded \(downloadedLayers.count) online feature\(downloadedLayers.count == 1 ? "" : "s") from \(sourceName). Saved for offline use."
                }
            )
        }
        .sheet(isPresented: $showingHomeOfflineBasemapSetup) {
            OfflineBasemapSetupView(
                currentCoordinate: location.currentLocation?.coordinate
            ) { extent, downloadedLayers, sourceName, rasterStyle in
                Task {
                    await createOfflineMap(for: extent, title: "Offline OSM Map", rasterStyle: rasterStyle)
                    for layer in downloadedLayers {
                        layerStore.add(layer)
                    }
                    let rasterText = rasterStyle == .blankVector ? "blank vector map" : rasterStyle.label
                    toolMessage = "Created offline \(rasterText) basemap and saved \(downloadedLayers.count) \(sourceName) feature\(downloadedLayers.count == 1 ? "" : "s")."
                }
            }
        }
        .sheet(isPresented: $showingOfflineImageryTopoDownload) {
            OfflineImageryTopoDownloadView(
                mapExtent: georef?.downloadExtent,
                currentCoordinate: location.currentLocation?.coordinate,
                hasCurrentMap: pdfDocument != nil,
                onCreateBasemap: { request in
                    await createOfflineImageryTopoBasemap(request)
                },
                onImportOwnRaster: {
                    showingOfflineImageryTopoDownload = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        fileImportKind = .map
                        showingImporter = true
                    }
                },
                onDownloadTNMProduct: { product in
                    await downloadAndOpenTNMProduct(product)
                }
            )
        }
        .sheet(isPresented: $showingOfflineMapStorage) {
            OfflineMapStorageView(currentMapURL: currentMapURL) { deletedURLs in
                guard let currentMapURL = currentMapURL else { return }
                if deletedURLs.contains(currentMapURL.standardizedFileURL) {
                    clearCurrentMapAfterDeleted()
                }
            }
        }
        .sheet(isPresented: $showingMapLayerManager) {
            MapLayerManagerView(store: surveyLayerStore)
        }
        .sheet(isPresented: $showingImportActionHub) {
            importActionHubSheet
        }
        .sheet(isPresented: $showingFieldActionHub) {
            fieldActionHubSheet
        }
        .sheet(isPresented: $showingTerrainActionHub) {
            terrainActionHubSheet
        }
        .sheet(isPresented: $showingGNSSActionHub) {
            gnssActionHubSheet
        }
        .sheet(isPresented: $showingBearingTools) {
            bearingToolsSheet
        }
        .sheet(isPresented: $showingTerrainViz) {
            TerrainVisualizationView(
                mapExtent: georef?.downloadExtent,
                gpsCoordinate: location.currentLocation?.coordinate
            ) { url, extent, dem, kind, image, outputMode, parameters in
                applyTerrainVisualizationResult(
                    url: url,
                    extent: extent,
                    dem: dem,
                    kind: kind,
                    image: image,
                    outputMode: outputMode,
                    parameters: parameters,
                    sourceLabel: "USGS 3DEP lidar"
                )
            }
        }
        .sheet(item: $importedDEMTerrainRequest) { request in
            ImportedDEMTerrainToolboxView(
                request: request,
                hasCurrentPDFBasemap: pdfDocument != nil
            ) { url, extent, dem, kind, image, outputMode, parameters in
                applyTerrainVisualizationResult(
                    url: url,
                    extent: extent,
                    dem: dem,
                    kind: kind,
                    image: image,
                    outputMode: outputMode,
                    parameters: parameters,
                    sourceLabel: "imported DEM: \(request.sourceName)"
                )
                importedDEMTerrainRequest = nil
            }
        }
        // Second half of the modal sheets live on a separate hidden
        // anchor. SwiftUI grows unreliable when ~15+ presentation
        // modifiers stack on one view (the symptom: the file importer
        // and some sheets silently fail to open); splitting the stack
        // across two anchors keeps every modal working.
        .background(
            Color.clear
            .sheet(isPresented: $showingMeasurementUnits) {
                MeasurementUnitsView(distanceUnitsRaw: $distanceUnitsRaw)
            }
            .sheet(isPresented: $showingQuickAddSheet) {
                quickAddActionSheet
            }
            .sheet(item: $lidarScanRequest) { request in
                LiDARScanView(
                    request: request,
                    onSave: { result in
                        lidarScanRequest = nil
                        addLiDARScanLayer(result)
                        let document = LiDARPointCloudDocument(
                            name: result.name,
                            plyURL: result.plyURL,
                            lasURL: result.lasURL,
                            photoURLs: result.photoFilenames.compactMap { PhotoStore.existingURL(filename: $0) },
                            originCoordinate: result.originCoordinate,
                            pointCount: result.vertexCount,
                            createdAt: result.createdAt
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            viewingLiDARPointCloud = document
                        }
                    },
                    onCancel: {
                        lidarScanRequest = nil
                    }
                )
            }
            .sheet(item: $photo3DModelScanRequest) { request in
                Photo3DModelScanView(
                    request: request,
                    onSave: { result in
                        photo3DModelScanRequest = nil
                        addPhoto3DModelLayer(result)
                        let document = LiDARPointCloudDocument(
                            name: result.name,
                            plyURL: result.plyURL,
                            lasURL: result.lasURL,
                            photoURLs: result.photoFilenames.compactMap { PhotoStore.existingURL(filename: $0) },
                            originCoordinate: result.originCoordinate,
                            pointCount: result.vertexCount,
                            createdAt: result.createdAt
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            viewingLiDARPointCloud = document
                        }
                    },
                    onCancel: {
                        photo3DModelScanRequest = nil
                    }
                )
            }
            .sheet(item: $viewingLiDARPointCloud) { document in
                LiDARPointCloudViewer(document: document)
            }
            .sheet(item: $sharingLiDARScan) { package in
                ShareSheet(activityItems: package.urls)
            }
            .sheet(item: $averagingRequest) { request in
                GPSAveragingView(
                    location: location,
                    coordinateFormat: coordinateFormat,
                    targetFixes: gpsAveragingTargetFixes,
                    onComplete: request.onComplete
                )
            }
            .sheet(isPresented: $showingTransectArraySheet) {
                TransectArrayView(
                    currentCoordinate: gpsIsOnCurrentMap ? location.currentLocation?.coordinate : nil,
                    crosshairProvider: { mapProxy.centerCoordinate() },
                    onCreate: { lines, spacing in
                        applyTransectArray(lines, spacing: spacing)
                    }
                )
            }

        )
        // Field-recorder mode sheets live on their own anchor so the heavy
        // map/import/scan presentation stack stays stable.
        .background(
            Color.clear
            .sheet(isPresented: $showingFieldDashboard) {
                FieldDashboardView(
                    layers: layerStore.layers,
                    recorderName: recorderName,
                    mapLoaded: pdfDocument != nil,
                    mapName: currentMapURL?.deletingPathExtension().lastPathComponent ?? "Current map",
                    gpsStatus: location.currentLocation.map { formatAccuracy($0.horizontalAccuracy) } ?? "waiting",
                    currentCoordinate: location.currentLocation?.coordinate,
                    isRecordingTrack: location.isRecording,
                    dataIssueCount: FieldDataCheckIssue.issues(for: layerStore.layers).count,
                    onStartSurvey: { showingFieldDashboard = false },
                    onRecordFeature: { showingFieldDashboard = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showingFieldRecorderSheet = true } },
                    onOpenLayers: { showingFieldDashboard = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showingLayerList = true } },
                    onDataCheck: { showingFieldDashboard = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showingDataCheck = true } },
                    onCrewPackage: { showingFieldDashboard = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showingCrewPackage = true } }
                )
            }
            .sheet(isPresented: $showingFieldRecorderSheet) {
                FieldRecorderActionView(
                    gpsAvailable: location.currentLocation != nil,
                    crosshairAvailable: crosshairCoordinate != nil,
                    isRecordingTrack: location.isRecording,
                    gpsActionSuffix: gpsActionSuffix,
                    onRecordPoint: { source in
                        showingFieldRecorderSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            beginFieldRecorderPoint(source)
                        }
                    },
                    onStartLine: {
                        showingFieldRecorderSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { startFieldRecorderLine() }
                    },
                    onStartPolygon: {
                        showingFieldRecorderSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { startFieldRecorderPolygon() }
                    },
                    onToggleTrack: {
                        showingFieldRecorderSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { toggleTrackRecording() }
                    },
                    onLiDARScan: {
                        showingFieldRecorderSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { beginLiDARScanAtCrosshair() }
                    },
                    onOpenForms: {
                        showingFieldRecorderSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { openDPRForms(layerID: nil) }
                    },
                    onClose: { showingFieldRecorderSheet = false }
                )
            }
            .sheet(isPresented: $showingDataCheck) {
                FieldDataCheckView(layers: layerStore.layers)
            }
            .sheet(isPresented: $showingTransectMission) {
                TransectMissionView(
                    layers: layerStore.layers,
                    onWalk: { layer in
                        showingTransectMission = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { walkSavedLayer(layer) }
                    },
                    onSetStatus: { layerID, status in
                        setTransectMissionStatus(layerID, status: status)
                    },
                    onExportGroup: { groupName in
                        exportLayerGroup(named: groupName, prefix: "TransectMission")
                    }
                )
            }
            .sheet(isPresented: $showingCrewPackage) {
                CrewPackageExportView(
                    layers: layerStore.layers,
                    onExport: { scope, format in
                        exportCrewPackage(scope: scope, format: format)
                    }
                )
            }
            .sheet(isPresented: $showingDPRForms) {
                DPRFormsListView(
                    store: dprFormStore,
                    layers: layerStore.layers,
                    contextLayerID: dprFormsContextLayerID,
                    onNew: { kind, layerID in
                        showingDPRForms = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            editingDPRForm = DPRFormEditorRequest(kind: kind, linkedLayerID: layerID)
                        }
                    },
                    onEdit: { form in
                        showingDPRForms = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            editingDPRForm = DPRFormEditorRequest(existingForm: form)
                        }
                    },
                    onExport: { form, format in
                        exportDPRForm(form, format: format)
                    },
                    onExportPacket: { layerID in
                        exportDPRPacket(for: layerID)
                    }
                )
            }
            .sheet(isPresented: $showingDPRAutofillSetup) {
                DPRAutofillSetupView(
                    mapName: currentMapURL?.lastPathComponent ?? "Current Map",
                    extentDescription: georef?.extentDescription ?? "Current georeferenced map extent",
                    hasElevationGrid: elevationGrid != nil,
                    onDownloadAll: {
                        await downloadDPRAutofillPackForCurrentMap()
                    },
                    onOpenCatalog: {
                        showingDPRAutofillSetup = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showingOnlineDataCatalog = true
                        }
                    },
                    onOpenImageryTopo: {
                        showingDPRAutofillSetup = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showingOfflineImageryTopoDownload = true
                        }
                    }
                )
            }
            .sheet(item: $editingDPRForm) { request in
                DPRFormEditorView(
                    request: request,
                    linkedLayer: request.linkedLayerID.flatMap { id in layerStore.layers.first(where: { $0.id == id }) },
                    store: dprFormStore,
                    allLayers: layerStore.layers,
                    recorderName: recorderName,
                    coordinateFormat: coordinateFormat,
                    distanceUnits: distanceUnits,
                    elevationProvider: elevationGrid.map { grid in { coordinate in grid.elevation(at: coordinate) } }
                )
            }
        )
        .onChange(of: transectModeActive) { active in
            // Keep the screen awake while walking a transect.
            UIApplication.shared.isIdleTimerDisabled = active
        }
        // Third anchor for the remaining sheets, keeping every view's
        // presentation-modifier count well within SwiftUI's reliable
        // range so import and all modals open dependably.
        .background(
            Color.clear
            .sheet(isPresented: $showingBearingSheet) {
                BearingLineView(
                    // When planning a map you're not on, default the start
                    // to the crosshair instead of the far-away GPS.
                    currentCoordinate: gpsIsOnCurrentMap
                        ? location.currentLocation?.coordinate
                        : (mapProxy.centerCoordinate() ?? location.currentLocation?.coordinate),
                    lastLineEnd: bearingLine.last
                ) { start, trueBearingDegrees, distanceMeters in
                    let end = MeasurementMath.destination(
                        from: start,
                        bearingDegrees: trueBearingDegrees,
                        distanceMeters: distanceMeters
                    )

                    // If the new segment starts where the existing line ends,
                    // chain it on (compass traverse); otherwise start fresh.
                    if let last = bearingLine.last,
                       abs(last.latitude - start.latitude) < 0.0000001,
                       abs(last.longitude - start.longitude) < 0.0000001 {
                        bearingLine.append(end)
                    } else {
                        bearingLine = [start, end]
                    }
                    bearingLineDegrees = trueBearingDegrees
                    toolMessage = String(
                        format: "Bearing segment set: %.1f deg true for %.0f m. Walk it and watch the offset readout.",
                        trueBearingDegrees,
                        distanceMeters
                    )
                }
            }
            .sheet(item: $viewingSavedLayer) { layer in
                FeatureInfoView(
                    layer: layer,
                    onClose: {
                        viewingSavedLayer = nil
                        finishVertexEditing(silent: true)
                        toolMessage = "Feature closed."
                    },
                    onEditAttributes: { featureID in
                        guard let latest = layerStore.layers.first(where: { $0.id == featureID }) else { return }
                        viewingSavedLayer = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            editingSavedLayer = latest
                        }
                    },
                    onEditGeometry: { featureID in
                        viewingSavedLayer = nil
                        beginGeometryEditing(featureID)
                    },
                    onLiDARScan: { featureID in
                        viewingSavedLayer = nil
                        beginLiDARScanForFeature(featureID)
                    },
                    onViewLiDARScan: { featureID in
                        viewingSavedLayer = nil
                        viewLiDARScanForFeature(featureID)
                    },
                    onShareLiDARScan: { featureID in
                        shareLiDARScanForFeature(featureID)
                    },
                    onBufferLayer: { featureID in
                        viewingSavedLayer = nil
                        beginBufferForFeature(featureID)
                    },
                    onCreateTransectArray: { featureID in
                        viewingSavedLayer = nil
                        beginTransectArrayForFeature(featureID)
                    },
                    onExportTransectArray: { featureID in
                        viewingSavedLayer = nil
                        exportTransectArrayForFeature(featureID)
                    },
                    onExportLayer: { featureID, format in
                        viewingSavedLayer = nil
                        exportFeature(featureID, format: format)
                    },
                    dprFormCount: dprFormStore.forms(for: layer.id).count,
                    onOpenDPRForms: { featureID in
                        viewingSavedLayer = nil
                        openDPRForms(layerID: featureID)
                    },
                    onExportDPRPacket: { featureID in
                        viewingSavedLayer = nil
                        exportDPRPacket(for: featureID)
                    },
                    onDelete: { featureID in
                        deleteFeatureFromInfo(featureID)
                    }
                )
            }
            .sheet(item: $bufferFeatureRequest) { request in
                FeatureBufferView(request: request) { widthMeters, exportMode in
                    createBufferFromFeature(request.layer, widthMeters: widthMeters, exportMode: exportMode)
                    bufferFeatureRequest = nil
                }
            }
            .sheet(item: $transectArrayFeatureRequest) { request in
                TransectArrayFromLayerView(request: request) { newLayers, shouldExportKML in
                    saveTransectArrayLayers(newLayers, exportKML: shouldExportKML)
                    transectArrayFeatureRequest = nil
                }
            }
            .sheet(item: $editingSavedLayer) { layer in
                AttributeEditorView(
                    layer: layer,
                    templateStore: templateStore,
                    existingGroups: layerStore.groupNames,
                    title: "Edit Feature",
                    onSave: { updated in
                        layerStore.update(updated)
                        editingSavedLayer = nil
                    },
                    onCancel: {
                        editingSavedLayer = nil
                    },
                    onDelete: { featureID in
                        layerStore.remove(id: featureID)
                        editingSavedLayer = nil
                        toolMessage = "Feature deleted."
                    }
                )
            }
            .sheet(item: $pendingLayer) { layer in
                AttributeEditorView(
                    layer: layer,
                    templateStore: templateStore,
                    existingGroups: layerStore.groupNames,
                    title: "New Feature",
                    onSave: { saved in
                        layerStore.add(saved)
                        selectedLayerID = saved.id
                        finishPendingSave(savedName: saved.name)
                        if saved.kind == .track || saved.kind == .measure {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                viewingSavedLayer = saved
                            }
                        }
                    },
                    onCancel: {
                        pendingLayer = nil
                        pendingClearTool = nil
                    }
                )
            }

        )
    }

    /// Startup screen shown before a map is imported: dark slate
    /// background with drawn topo contours echoing the app icon. If an
    /// image named "LaunchTerrain" exists in the asset catalog (drop the
    /// app icon PNG in as an image set), it is shown as a hero card.
    private var welcomeScreen: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.07, blue: 0.12),
                    Color(red: 0.10, green: 0.16, blue: 0.23)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ContourArtView()
                .ignoresSafeArea()

            VStack(spacing: 16) {
                if let heroImage = UIImage(named: "LaunchTerrain") {
                    Image(uiImage: heroImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 124, height: 124)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 14, y: 7)
                } else {
                    Image(systemName: "map.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Color(red: 0.97, green: 0.68, blue: 0.27))
                        .shadow(color: .black.opacity(0.5), radius: 8)
                }

                Text("Archaeology Survey")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6)

                Text("Import a georeferenced PDF or create an offline OpenStreetMap vector basemap area before heading into the field. Then record tracks, points, lines, and polygons with attributes and photos for GIS.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 36)

                VStack(spacing: 10) {
                    Button {
                        fileImportKind = .map
                        showingImporter = true
                    } label: {
                        Label("Import GeoPDF", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button {
                        fileImportKind = .demTerrain
                        showingImporter = true
                    } label: {
                        Label("Import DEM / RVT-VAT", systemImage: "mountain.2.fill")
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        showingHomeOfflineBasemapSetup = true
                    } label: {
                        Label("Create Offline Map Area", systemImage: "map.fill")
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button {
                        showingOfflineImageryTopoDownload = true
                    } label: {
                        Label("Imagery / Topo Basemaps", systemImage: "photo.on.rectangle.angled")
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)

                    Button {
                        showingOfflineMapStorage = true
                    } label: {
                        Label("Manage Offline Maps", systemImage: "externaldrive.fill")
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button {
                        showingMapLayerManager = true
                    } label: {
                        Label("Map Layer Stack / Transparency", systemImage: "square.stack.3d.up")
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)

                    Button {
                        showingFieldDashboard = true
                    } label: {
                        Label("Open Field Dashboard", systemImage: "checklist.checked")
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandAmber)

                    Text("Choose a GPS/manual center and download a small offline raster basemap plus optional OSM vector layers for use without a GeoPDF.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 34)
                }
                .padding(.top, 8)
            }
            .padding(.bottom, 24)
        }
    }

    /// Compact, draggable-free floating control for the active terrain
    /// overlay: hide/show toggle, inline opacity slider, and quick access
    /// to full controls. Positioned at the leading edge below the top bar
    /// so it never collides with the compass badge or bottom tools.
    /// Short noun for the active overlay used in the floating pill, so an
    /// imagery/topo overlay does not say "Terrain".
    private var activeOverlayNoun: String {
        guard let overlay = terrainOverlay else { return "Overlay" }
        let text = "\(overlay.title) \(overlay.sourceLabel)".lowercased()
        if text.contains("imagery") || text.contains("satellite") || text.contains("orthophoto") || text.contains("naip") {
            return "Imagery"
        }
        if text.contains("topo") {
            return "Topo"
        }
        if text.contains("hillshade") || text.contains("svf") || text.contains("openness")
            || text.contains("relief") || text.contains("slope") || text.contains("vat")
            || text.contains("msti") || text.contains("index") {
            return "Terrain"
        }
        return "Overlay"
    }

    private var activeOverlayIcon: String {
        switch activeOverlayNoun {
        case "Imagery": return "photo.fill"
        case "Topo": return "map.fill"
        default: return "mountain.2.fill"
        }
    }

    private var terrainOverlayFloatingControl: some View {
        AnyView(
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: activeOverlayIcon)
                            .font(.caption)
                            .foregroundStyle(Color.brandAmber)

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingFloatingOpacity.toggle()
                            }
                        } label: {
                            Text(terrainOverlayHidden ? "\(activeOverlayNoun) hidden" : "\(activeOverlayNoun) \(Int(terrainOverlayOpacity * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                terrainOverlayHidden.toggle()
                            }
                        } label: {
                            Image(systemName: terrainOverlayHidden ? "eye.slash.fill" : "eye.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if activeTerrainDEM != nil {
                                    showingFloatingOpacity = false
                                    showingTerrainControlPanel = true
                                } else {
                                    // Imagery/topo overlay: only opacity applies.
                                    showingFloatingOpacity.toggle()
                                }
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                    }

                    if showingFloatingOpacity, !terrainOverlayHidden {
                        HStack(spacing: 8) {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                            Slider(value: $terrainOverlayOpacity, in: 0.05...0.95, step: 0.05)
                                .frame(width: 150)
                                .tint(Color.brandAmber)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.brandSlate.opacity(0.88))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                Spacer()
            }
            .padding(.leading, 12)
            .padding(.top, 92)

            Spacer()
        }
        .allowsHitTesting(true)
        )
    }

    /// Real-time parameter panel for the active overlay. Sliders update
    /// `activeTerrainParameters` and trigger an immediate background
    /// re-render, so the map reflects changes within a moment of dragging.
    private var terrainLiveControlPanel: some View {
        AnyView(
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "mountain.2.fill")
                        .foregroundStyle(Color.brandAmber)
                    Text(activeTerrainKind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    if liveRenderInFlight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingTerrainControlPanel = false
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                // Opacity is always relevant.
                liveSliderRow(
                    title: "Overlay opacity",
                    value: Binding(
                        get: { terrainOverlayOpacity },
                        set: { terrainOverlayOpacity = $0 }
                    ),
                    range: 0.05...0.95, step: 0.05,
                    display: "\(Int(terrainOverlayOpacity * 100))%",
                    liveRender: false
                )

                Button {
                    enhanceTerrainForCurrentZoom()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.magnifyingglass")
                        Text("Sharpen for this view")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.brandAmber.opacity(0.22))
                    )
                    .foregroundStyle(Color.brandAmber)
                }
                .disabled(liveRenderInFlight)

                if activeTerrainDEM == nil {
                    Text("Parameter editing is available for overlays created this session. Re-create this visualization from the Terrain menu to adjust its parameters live.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if activeTerrainDEM != nil, activeTerrainKind.usesAzimuth {
                            liveSliderRow(
                                title: "Sun azimuth",
                                value: $activeTerrainParameters.azimuthDegrees,
                                range: 0...360, step: 5,
                                display: "\(Int(activeTerrainParameters.azimuthDegrees))°"
                            )
                        }
                        if activeTerrainDEM != nil, activeTerrainKind.usesHillshadeParameters {
                            liveSliderRow(
                                title: "Sun altitude",
                                value: $activeTerrainParameters.altitudeDegrees,
                                range: 10...80, step: 5,
                                display: "\(Int(activeTerrainParameters.altitudeDegrees))°"
                            )
                            liveSliderRow(
                                title: "Vertical exaggeration",
                                value: $activeTerrainParameters.verticalExaggeration,
                                range: 1...3, step: 0.1,
                                display: String(format: "%.1f×", activeTerrainParameters.verticalExaggeration)
                            )
                        }
                        if activeTerrainDEM != nil, activeTerrainKind.usesDirections {
                            liveSliderRow(
                                title: "Directions",
                                value: Binding(
                                    get: { Double(activeTerrainParameters.directions) },
                                    set: { activeTerrainParameters.directions = Int($0) }
                                ),
                                range: 4...32, step: 4,
                                display: "\(activeTerrainParameters.directions)"
                            )
                        }
                        if activeTerrainDEM != nil, activeTerrainKind.usesRadius {
                            liveSliderRow(
                                title: "Search radius",
                                value: $activeTerrainParameters.radiusMeters,
                                range: 3...40, step: 1,
                                display: "\(Int(activeTerrainParameters.radiusMeters)) m"
                            )
                        }
                        if activeTerrainDEM != nil, activeTerrainKind.usesLRMRadius {
                            liveSliderRow(
                                title: "Trend radius",
                                value: $activeTerrainParameters.lrmRadiusMeters,
                                range: 5...60, step: 1,
                                display: "\(Int(activeTerrainParameters.lrmRadiusMeters)) m"
                            )
                        }
                        if activeTerrainDEM != nil, activeTerrainKind.usesHillshadeBlend {
                            liveSliderRow(
                                title: "Hillshade blend",
                                value: $activeTerrainParameters.hillshadeBlend,
                                range: 0...1, step: 0.05,
                                display: "\(Int(activeTerrainParameters.hillshadeBlend * 100))%"
                            )
                        }
                        if activeTerrainDEM != nil, activeTerrainKind.usesMSTIBlend {
                            liveSliderRow(
                                title: "MSTI multiply",
                                value: $activeTerrainParameters.mstiBlend,
                                range: 0...1, step: 0.05,
                                display: "\(Int(activeTerrainParameters.mstiBlend * 100))%"
                            )
                        }
                        // Gamma applies to all grayscale products.
                        if activeTerrainDEM != nil, !activeTerrainKind.producesColorImage {
                            liveSliderRow(
                                title: "Contrast (gamma)",
                                value: $activeTerrainParameters.gamma,
                                range: 0.4...2.5, step: 0.1,
                                display: String(format: "%.1f", activeTerrainParameters.gamma)
                            )
                        }
                        if activeTerrainDEM != nil, activeTerrainKind.supportsWarmRamp {
                            Toggle(isOn: Binding(
                                get: { activeTerrainParameters.warmColorRamp },
                                set: { activeTerrainParameters.warmColorRamp = $0; liveRerenderTerrainOverlay() }
                            )) {
                                Text("Warm archaeological ramp")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                            }
                            .tint(Color.brandAmber)
                        }
                    }
                }
                .frame(maxHeight: 230)

                Text("Changes render live from the downloaded elevation — no re-download.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.brandSlate.opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        )
    }

    /// A labeled slider row for the live panel. `liveRender` true (the
    /// default) re-renders the overlay on each change; false is used for
    /// opacity, which is a cheap draw-time property.
    private func liveSliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: String,
        liveRender: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(display)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandAmber)
            }
            Slider(
                value: value,
                in: range,
                step: step,
                onEditingChanged: { editing in
                    // Re-render when the user releases the thumb to avoid
                    // flooding renders mid-drag; the coalescing logic in
                    // liveRerenderTerrainOverlay handles rapid taps too.
                    if !editing && liveRender { liveRerenderTerrainOverlay() }
                }
            )
            .tint(Color.brandAmber)
        }
    }

    private var mapChromeToggleButton: some View {
        VStack {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mapChromeCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: mapChromeCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.brandSlate.opacity(0.88)))
                        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mapChromeCollapsed ? "Show map controls" : "Hide map controls")

                if mapChromeCollapsed {
                    Text("Map only")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.brandSlate.opacity(0.78)))
                }

                Spacer()
            }
            .padding(.leading, 12)
            .padding(.top, mapChromeCollapsed ? 12 : 70)

            Spacer()
        }
        .allowsHitTesting(true)
    }

    private var topBar: some View {
        AnyView(
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    mapChromeCollapsed = true
                }
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(Color.brandSlate)
            .accessibilityLabel("Hide map controls")

            // The old version used several nested SwiftUI Menu controls here.
            // That was causing EXC_BAD_ACCESS on device while SwiftUI built menu
            // metadata. The buttons below open simple Form sheets instead.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    topBarHubButton("Import", systemImage: "tray.and.arrow.down.fill", tint: .blue) {
                        showingImportActionHub = true
                    }

                    topBarHubButton("Field", systemImage: "figure.walk", tint: Color.brandSlate) {
                        showingFieldActionHub = true
                    }

                    topBarHubButton("Terrain", systemImage: "mountain.2.fill", tint: Color.brandAmber) {
                        showingTerrainActionHub = true
                    }

                    topBarHubButton("GNSS", systemImage: "antenna.radiowaves.left.and.right", tint: .green) {
                        showingGNSSActionHub = true
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Color.brandAmber.frame(height: 2)
        }
        )
    }

    private func topBarHubButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func closeTopBarActionHubs() {
        showingImportActionHub = false
        showingFieldActionHub = false
        showingTerrainActionHub = false
        showingGNSSActionHub = false
    }

    private func runTopBarAction(_ action: @escaping () -> Void) {
        closeTopBarActionHubs()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            action()
        }
    }

    private var importActionHubSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Maps and basemaps"), footer: Text("Use these before going offline. The Layer Stack lets you set transparency and draw order so a GeoPDF does not hide USGS topo or imagery.")) {
                    Button {
                        runTopBarAction {
                            fileImportKind = .map
                            showingImporter = true
                        }
                    } label: {
                        Label("Import GeoPDF Map", systemImage: "map.fill")
                    }

                    Button {
                        runTopBarAction {
                            fileImportKind = .data
                            showingImporter = true
                        }
                    } label: {
                        Label("Import KML / GeoJSON Layers", systemImage: "tray.and.arrow.down.fill")
                    }

                    Button {
                        runTopBarAction {
                            showingHomeOfflineBasemapSetup = true
                        }
                    } label: {
                        Label("Create Offline Map Area", systemImage: "map.fill")
                    }

                    Button {
                        runTopBarAction {
                            showingOfflineImageryTopoDownload = true
                        }
                    } label: {
                        Label("Offline Imagery / Topo Basemaps", systemImage: "photo.on.rectangle.angled")
                    }

                    Button {
                        runTopBarAction {
                            showingOfflineMapStorage = true
                        }
                    } label: {
                        Label("Manage Offline Maps", systemImage: "externaldrive.fill")
                    }

                    Button {
                        runTopBarAction {
                            showingMapLayerManager = true
                        }
                    } label: {
                        Label("Map Layer Stack / Transparency", systemImage: "square.stack.3d.up")
                    }
                }

                Section(header: Text("Online downloads")) {
                    Button {
                        runTopBarAction {
                            showingOnlineDataCatalog = true
                        }
                    } label: {
                        Label("Download Online Layers", systemImage: "icloud.and.arrow.down.fill")
                    }

                    Button {
                        runTopBarAction {
                            downloadElevationForCurrentMap()
                        }
                    } label: {
                        Label("Download Elevation for This Map", systemImage: "arrow.down.to.line")
                    }
                    .disabled(georef == nil || currentMapURL == nil)
                }

                Section(header: Text("Calibration")) {
                    Button {
                        runTopBarAction {
                            showingCalibration = true
                        }
                    } label: {
                        Label("Manual Map Calibration", systemImage: "scope")
                    }
                    .disabled(pdfDocument == nil)
                }
            }
            .navigationTitle("Import")
            .navigationBarItems(trailing: Button("Done") { showingImportActionHub = false })
        }
    }

    private var fieldActionHubSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Mode")) {
                    Toggle("Field Recorder Mode", isOn: $fieldRecorderModeEnabled)
                }

                Section(header: Text("Daily fieldwork")) {
                    Button {
                        runTopBarAction { showingFieldDashboard = true }
                    } label: {
                        Label("Today’s Survey Dashboard", systemImage: "checklist.checked")
                    }

                    Button {
                        runTopBarAction { showingFieldRecorderSheet = true }
                    } label: {
                        Label("Record Feature", systemImage: "plus.viewfinder")
                    }

                    Button {
                        runTopBarAction { showingMapLayerManager = true }
                    } label: {
                        Label("Map Layer Stack / Transparency", systemImage: "square.stack.3d.up")
                    }

                    Button {
                        runTopBarAction { showingLayerList = true }
                    } label: {
                        Label("Saved Field Layers", systemImage: "square.3.layers.3d")
                    }

                    Button {
                        runTopBarAction { showingDataCheck = true }
                    } label: {
                        Label("Data Check", systemImage: "checkmark.shield")
                    }
                }

                Section(header: Text("Missions and exports")) {
                    Button {
                        runTopBarAction { showingTransectMission = true }
                    } label: {
                        Label("Transect Mission", systemImage: "figure.walk.motion")
                    }

                    Button {
                        runTopBarAction { showingCrewPackage = true }
                    } label: {
                        Label("Crew Package / Export", systemImage: "shippingbox.fill")
                    }

                    Button {
                        runTopBarAction { openDPRForms(layerID: nil) }
                    } label: {
                        Label("DPR 523 Forms", systemImage: "doc.text.fill")
                    }
                }
            }
            .navigationTitle("Field")
            .navigationBarItems(trailing: Button("Done") { showingFieldActionHub = false })
        }
    }

    private var terrainActionHubSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Terrain visualization"), footer: Text("Use this for LiDAR-derived terrain views, RVT/VAT products, hillshade, and DEM-based overlays.")) {
                    Button {
                        runTopBarAction { showingTerrainViz = true }
                    } label: {
                        Label("LiDAR Terrain Visualization", systemImage: "mountain.2.fill")
                    }

                    Button {
                        runTopBarAction {
                            fileImportKind = .demTerrain
                            showingImporter = true
                        }
                    } label: {
                        Label("Import DEM for Toolbox", systemImage: "square.and.arrow.down.on.square")
                    }
                }

                Section(header: Text("Active overlay")) {
                    Button {
                        runTopBarAction {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingTerrainControlPanel = true
                            }
                        }
                    } label: {
                        Label("Adjust Visualization Live", systemImage: "slider.horizontal.3")
                    }
                    .disabled(terrainOverlay == nil)

                    Button {
                        runTopBarAction {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingFloatingTerrainControl.toggle()
                            }
                        }
                    } label: {
                        Label(showingFloatingTerrainControl ? "Hide Opacity Pill" : "Show Opacity Pill",
                              systemImage: showingFloatingTerrainControl ? "rectangle.slash" : "rectangle.badge.checkmark")
                    }
                    .disabled(terrainOverlay == nil)

                    Button {
                        runTopBarAction {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                terrainOverlayHidden.toggle()
                            }
                        }
                    } label: {
                        Label(terrainOverlayHidden ? "Show Overlay" : "Hide Overlay",
                              systemImage: terrainOverlayHidden ? "eye.fill" : "eye.slash")
                    }
                    .disabled(terrainOverlay == nil)

                    Button(role: .destructive) {
                        runTopBarAction { clearTerrainOverlay() }
                    } label: {
                        Label("Clear Overlay", systemImage: "trash")
                    }
                    .disabled(terrainOverlay == nil)
                }
            }
            .navigationTitle("Terrain")
            .navigationBarItems(trailing: Button("Done") { showingTerrainActionHub = false })
        }
    }

    private var gnssActionHubSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Receiver")) {
                    Toggle("Prefer External GNSS", isOn: $preferExternalGNSS)
                }

                Section(header: Text("Current position")) {
                    if let currentLocation = location.currentLocation {
                        Text("Position: \(CoordinateFormatter.string(for: currentLocation.coordinate, format: coordinateFormat))")
                        Text("Horizontal: \(formatAccuracy(currentLocation.horizontalAccuracy))")
                        Text("Vertical: \(formatAccuracy(currentLocation.verticalAccuracy))")
                        Text("Altitude: \(formatAltitude(currentLocation))")
                        Text("Speed: \(formatSpeed(currentLocation.speed))")
                        if location.track.count > 1 {
                            Text("Track: \(formatDistance(trackDistanceMeters)) | \(trackDurationText ?? "--") | \(location.track.count) pts")
                        }
                        Text(gnssProviderMessage(for: currentLocation))
                    } else {
                        Text("Waiting for GPS fix")
                    }
                }

                Section(header: Text("Settings")) {
                    Button {
                        runTopBarAction { showingSurveySettings = true }
                    } label: {
                        Label("Survey Settings", systemImage: "gearshape.fill")
                    }
                }
            }
            .navigationTitle("GNSS")
            .navigationBarItems(trailing: Button("Done") { showingGNSSActionHub = false })
        }
    }

    /// The heading/north badge now floats over the map in the top-right
    /// corner (below the top bar) so it is always fully visible and never
    /// crowded by the menu buttons. Tap to cycle follow modes.
    /// Floating Collect button on the map, just above the bottom bar.
    /// Opens a menu of the capture tools (point, line, polygon, measure)
    /// plus track recording — consolidating the data-capture entry points
    /// the user reaches for most.
    private var floatingCollectButton: some View {
        AnyView(
        VStack {
            Spacer()
            HStack {
                Spacer()
                Menu {
                    Section(header: Text("Collect feature")) {
                        collectMenuButton(.point, label: "Point", icon: "mappin")
                        collectMenuButton(.measure, label: "Line", icon: "line.diagonal")
                        collectMenuButton(.polygon, label: "Polygon", icon: "skew")
                    }

                    Section(header: Text("Track")) {
                        Button {
                            toggleTrackRecording()
                        } label: {
                            Label(location.isRecording ? "Stop Track Recording" : "Start Track Recording",
                                  systemImage: location.isRecording ? "stop.circle.fill" : "figure.walk")
                        }
                    }

                    Section(header: Text("Measure")) {
                        Button {
                            startQuickMeasureDistance()
                        } label: {
                            Label("Measure Distance", systemImage: "ruler")
                        }
                        Button {
                            startQuickMeasureArea()
                        } label: {
                            Label("Measure Area", systemImage: "skew")
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.viewfinder")
                            .font(.headline)
                        Text(location.isRecording ? "Collect · REC" : "Collect")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(location.isRecording ? Color.red : Color.brandAmber)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                }
                .disabled(georef == nil)
                Spacer()
            }
            // Clear the bottom bar (taller when expanded).
            .padding(.bottom, bottomBarExpanded ? 150 : 96)
        }
        .allowsHitTesting(true)
        )
    }

    /// Field-recorder mode: a clean, large-action deck for crews.
    /// It keeps advanced GIS tools available through Field / Terrain menus
    /// while putting daily recording tasks one tap away.
    private var fieldRecorderControlDeck: some View {
        VStack {
            Spacer()

            if fieldRecorderDeckCollapsed {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            fieldRecorderDeckCollapsed = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.grid.2x2.fill")
                            Text("Field Tools")
                                .font(.subheadline.weight(.semibold))
                            if location.isRecording {
                                Text("REC")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.red.opacity(0.85)))
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.brandSlate.opacity(0.92)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.bottom, bottomBarExpanded ? 112 : 58)
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        FieldRecorderMiniStatus(
                            title: location.isRecording ? "REC" : "GPS",
                            value: location.currentLocation.map { formatAccuracy($0.horizontalAccuracy) } ?? "waiting",
                            systemImage: location.isRecording ? "record.circle.fill" : "location.fill",
                            isWarning: location.currentLocation?.horizontalAccuracy ?? 0 > 10
                        )

                        FieldRecorderMiniStatus(
                            title: "Features",
                            value: "\(layerStore.layers.filter { !$0.isImported }.count)",
                            systemImage: "mappin.and.ellipse",
                            isWarning: false
                        )

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                fieldRecorderDeckCollapsed = true
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.88))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 8) {
                        FieldRecorderDeckButton(title: "Record", subtitle: "Point / line / poly", systemImage: "plus.viewfinder", prominent: true) {
                            showingFieldRecorderSheet = true
                        }

                        FieldRecorderDeckButton(title: "Review", subtitle: "Layers / QA", systemImage: "square.3.layers.3d", prominent: false) {
                            showingLayerList = true
                        }
                    }

                    HStack(spacing: 8) {
                        FieldRecorderDeckButton(title: "Forms", subtitle: "DPR 523", systemImage: "doc.text.fill", prominent: false) {
                            openDPRForms(layerID: nil)
                        }

                        FieldRecorderDeckButton(title: "Mission", subtitle: "Transects", systemImage: "figure.walk.motion", prominent: false) {
                            showingTransectMission = true
                        }

                        FieldRecorderDeckButton(title: "Export", subtitle: "Crew", systemImage: "square.and.arrow.up", prominent: false) {
                            showingCrewPackage = true
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.brandSlate.opacity(0.90))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .padding(.horizontal, 10)
                .padding(.bottom, bottomBarExpanded ? 126 : 72)
            }
        }
        .allowsHitTesting(true)
    }

    private var floatingHeadingBadge: some View {
        AnyView(
        VStack {
            HStack {
                Spacer()
                Button {
                    handleBearingButtonTap()
                } label: {
                    BearingBadge(
                        degrees: compass.trueHeadingDegrees,
                        mode: followMode,
                        mapRotationDegrees: effectiveMapRotationDegrees
                    )
                }
                .buttonStyle(.plain)
                .disabled(georef == nil || location.currentLocation == nil)
            }
            .padding(.trailing, 12)
            .padding(.top, 70)
            Spacer()
        }
        .allowsHitTesting(true)
        )
    }

    /// Quick actions shared by the expanded "+" menu and the collapsed
    /// bar's "+" button: point, line, polygon, and bearing — all from
    /// the crosshair or GPS, no tool selection needed first.
    @ViewBuilder
    private var quickAddMenuItems: some View {
        if selectedLayerID != nil {
            if selectedVertexIndex != nil {
                Button {
                    addVertexAtGPS()
                } label: {
                    Label("Move Selected Vertex @ GPS", systemImage: "location.fill")
                }
                .disabled(location.currentLocation == nil)

                Button {
                    addVertexAtCrosshair()
                } label: {
                    Label("Move Selected Vertex @ Crosshair", systemImage: "plus.viewfinder")
                }
            }

            if hasUnsavedVertexEdits {
                Button {
                    saveVertexEditsAndFinish()
                } label: {
                    Label("Save Feature Edits", systemImage: "checkmark.circle.fill")
                }

                Button(role: .destructive) {
                    cancelVertexEdits()
                } label: {
                    Label("Cancel Feature Edits", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    finishVertexEditing()
                } label: {
                    Label("Finish Editing", systemImage: "checkmark")
                }
            }

            Divider()
        }

        Button {
            dropPointAtCurrentLocation()
        } label: {
            Label("Drop Point @ GPS…\(gpsActionSuffix)", systemImage: "location.fill")
        }
        .disabled(location.currentLocation == nil)

        Button {
            dropPointAtCrosshair()
        } label: {
            Label("Drop Point @ Crosshair…", systemImage: "plus.viewfinder")
        }

        Divider()

        // 3D scans and measuring grouped into submenus so the Add
        // menu always fits on screen without scrolling (long scrolling
        // menus jump around, especially over a scroll view).
        Menu {
            Button {
                beginLiDARScanAtGPS()
            } label: {
                Label("LiDAR Scan @ GPS…\(gpsActionSuffix)", systemImage: "cube.transparent")
            }
            .disabled(location.currentLocation == nil || !LiDARScanCoordinator.isSupported)

            Button {
                beginLiDARScanAtCrosshair()
            } label: {
                Label("LiDAR Scan @ Crosshair…", systemImage: "viewfinder")
            }
            .disabled(!LiDARScanCoordinator.isSupported)

            Button {
                beginPhoto3DModelAtGPS()
            } label: {
                Label("Photo 3D Model @ GPS…\(gpsActionSuffix)", systemImage: "camera.viewfinder")
            }
            .disabled(location.currentLocation == nil || !Photo3DModelScanCoordinator.isSupported)

            Button {
                beginPhoto3DModelAtCrosshair()
            } label: {
                Label("Photo 3D Model @ Crosshair…", systemImage: "camera.metering.center.weighted")
            }
            .disabled(!Photo3DModelScanCoordinator.isSupported)
        } label: {
            Label("3D Scan", systemImage: "cube.transparent")
        }

        Menu {
            Button {
                startQuickMeasureDistance()
            } label: {
                Label("Measure Distance", systemImage: "ruler")
            }

            Button {
                startQuickMeasureArea()
            } label: {
                Label("Measure Area", systemImage: "skew")
            }

            Button {
                showingMeasurementUnits = true
            } label: {
                Label("Measurement Units…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Label("Measure", systemImage: "ruler")
        }

        Divider()

        Button {
            toggleTool(.measure)
            if mapTool == .measure { addVertexAtCrosshair() }
        } label: {
            Label("Start Line @ Crosshair", systemImage: "line.diagonal")
        }

        Button {
            toggleTool(.polygon)
            if mapTool == .polygon { addVertexAtCrosshair() }
        } label: {
            Label("Start Polygon @ Crosshair", systemImage: "skew")
        }

        Divider()

        Button {
            showingBearingSheet = true
        } label: {
            Label("Set Bearing Line…", systemImage: "location.north.line")
        }
    }

    /// Full-screen replacement for the old Add menu. The nested Add menu
    /// was still crashing SwiftUI on some iPhones with EXC_BAD_ACCESS while
    /// building generic menu metadata. A sheet keeps the actions available
    /// while avoiding the unstable nested Menu builder.
    private var quickAddActionSheet: some View {
        NavigationView {
            Form {
                if selectedLayerID != nil {
                    quickAddFeatureEditingSection
                }

                Section {
                    Button {
                        runQuickAddAction {
                            dropPointAtCurrentLocation()
                        }
                    } label: {
                        Label("Drop Point @ GPS…\(gpsActionSuffix)", systemImage: "location.fill")
                    }
                    .disabled(location.currentLocation == nil)

                    Button {
                        runQuickAddAction {
                            dropPointAtCrosshair()
                        }
                    } label: {
                        Label("Drop Point @ Crosshair…", systemImage: "plus.viewfinder")
                    }
                } header: {
                    Text("Points")
                }

                Section {
                    Button {
                        runQuickAddAction {
                            beginLiDARScanAtGPS()
                        }
                    } label: {
                        Label("LiDAR Scan @ GPS…\(gpsActionSuffix)", systemImage: "cube.transparent")
                    }
                    .disabled(location.currentLocation == nil || !LiDARScanCoordinator.isSupported)

                    Button {
                        runQuickAddAction {
                            beginLiDARScanAtCrosshair()
                        }
                    } label: {
                        Label("LiDAR Scan @ Crosshair…", systemImage: "viewfinder")
                    }
                    .disabled(!LiDARScanCoordinator.isSupported)

                    Button {
                        runQuickAddAction {
                            beginPhoto3DModelAtGPS()
                        }
                    } label: {
                        Label("Photo 3D Model @ GPS…\(gpsActionSuffix)", systemImage: "camera.viewfinder")
                    }
                    .disabled(location.currentLocation == nil || !Photo3DModelScanCoordinator.isSupported)

                    Button {
                        runQuickAddAction {
                            beginPhoto3DModelAtCrosshair()
                        }
                    } label: {
                        Label("Photo 3D Model @ Crosshair…", systemImage: "camera.metering.center.weighted")
                    }
                    .disabled(!Photo3DModelScanCoordinator.isSupported)
                } header: {
                    Text("3D Scan")
                } footer: {
                    Text("LiDAR-capable phones use LiDAR. Other ARKit-capable phones can use the photo 3D model workflow.")
                }

                Section {
                    Button {
                        runQuickAddAction {
                            startQuickMeasureDistance()
                        }
                    } label: {
                        Label("Measure Distance", systemImage: "ruler")
                    }

                    Button {
                        runQuickAddAction {
                            startQuickMeasureArea()
                        }
                    } label: {
                        Label("Measure Area", systemImage: "skew")
                    }

                    Button {
                        runQuickAddAction {
                            showingMeasurementUnits = true
                        }
                    } label: {
                        Label("Measurement Units…", systemImage: "slider.horizontal.3")
                    }
                } header: {
                    Text("Measure")
                }

                Section {
                    Button {
                        runQuickAddAction {
                            toggleTool(.measure)
                            if mapTool == .measure { addVertexAtCrosshair() }
                        }
                    } label: {
                        Label("Start Line @ Crosshair", systemImage: "line.diagonal")
                    }

                    Button {
                        runQuickAddAction {
                            toggleTool(.polygon)
                            if mapTool == .polygon { addVertexAtCrosshair() }
                        }
                    } label: {
                        Label("Start Polygon @ Crosshair", systemImage: "skew")
                    }

                    Button {
                        runQuickAddAction {
                            showingBearingSheet = true
                        }
                    } label: {
                        Label("Set Bearing Line…", systemImage: "location.north.line")
                    }
                } header: {
                    Text("Lines, Polygons, and Bearing")
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showingQuickAddSheet = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var quickAddFeatureEditingSection: some View {
        Section {
            if selectedVertexIndex != nil {
                Button {
                    runQuickAddAction {
                        addVertexAtGPS()
                    }
                } label: {
                    Label("Move Selected Vertex @ GPS", systemImage: "location.fill")
                }
                .disabled(location.currentLocation == nil)

                Button {
                    runQuickAddAction {
                        addVertexAtCrosshair()
                    }
                } label: {
                    Label("Move Selected Vertex @ Crosshair", systemImage: "plus.viewfinder")
                }
            }

            if hasUnsavedVertexEdits {
                Button {
                    runQuickAddAction {
                        saveVertexEditsAndFinish()
                    }
                } label: {
                    Label("Save Feature Edits", systemImage: "checkmark.circle.fill")
                }

                Button(role: .destructive) {
                    runQuickAddAction {
                        cancelVertexEdits()
                    }
                } label: {
                    Label("Cancel Feature Edits", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    runQuickAddAction {
                        finishVertexEditing()
                    }
                } label: {
                    Label("Finish Editing", systemImage: "checkmark")
                }
            }
        } header: {
            Text("Selected Feature")
        }
    }

    private func runQuickAddAction(_ action: @escaping () -> Void) {
        showingQuickAddSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            action()
        }
    }

    /// Location bar: live crosshair coordinate plus the context status.
    private var locationBar: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "plus.viewfinder")
                if let coordinate = crosshairCoordinate {
                    Text(CoordinateFormatter.string(for: coordinate, format: coordinateFormat))
                    if let elevation = crosshairElevationText(for: coordinate) {
                        Text(elevation)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("outside map extent")
                }
            }

            Text(compactStatusText)
                .font(.caption2.monospacedDigit())
                .fontWeight(walkTransectEnabled && isOffTransect ? .bold : .regular)
                .foregroundStyle(walkTransectEnabled && isOffTransect ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        }
        .font(.footnote.monospacedDigit().weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bottomFieldControls: some View {
        AnyView(
            VStack(spacing: 8) {
                if bottomBarExpanded {
                    expandedBottomPrimaryRow
                    expandedBottomSecondaryRow
                }

                if selectedLayerID != nil {
                    selectedFeatureEditControls
                }

                bottomLocationRow
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Color.brandAmber.frame(height: 2)
            }
        )
    }

    /// Split out from bottomFieldControls to avoid a SwiftUI generic-metadata
    /// EXC_BAD_ACCESS crash on some devices/Xcode builds. Keeping each row
    /// small makes the bottom toolbar much more stable at runtime.
    private var expandedBottomPrimaryRow: some View {
        AnyView(
            HStack(spacing: 10) {
                layersButton
                Spacer(minLength: 0)
                addMenuButton
            }
        )
    }

    private var layersButton: some View {
        Menu {
            Button {
                showingLayerList = true
            } label: {
                Label("Saved Feature Layers (\(layerStore.layers.count))", systemImage: "mappin.and.ellipse")
            }

            Button {
                showingMapLayerManager = true
            } label: {
                Label("Map Layer Stack / Transparency", systemImage: "square.stack.3d.up")
            }
        } label: {
            Label("Layers \(layerStore.layers.count)", systemImage: "square.3.layers.3d")
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
    }

    private var addMenuButton: some View {
        Button {
            showingQuickAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.headline.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.brandAmber)
        .disabled(georef == nil)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var expandedBottomSecondaryRow: some View {
        AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    bearingToolsButton
                    saveExportMenu
                    clearMenu
                }
                .padding(.horizontal, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        )
    }

    private var bearingToolsButton: some View {
        Button {
            showingBearingTools = true
        } label: {
            Label("Bearing", systemImage: "location.north.line")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .disabled(georef == nil)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var saveExportMenu: some View {
        Menu {
            Section(header: Text("Save")) {
            Button("Save GPS Track…") {
                var extras: [FeatureField] = [
                    FeatureField(key: "track_distance_m", value: String(format: "%.1f", trackDistanceMeters)),
                    FeatureField(key: "track_points", value: "\(location.track.count)")
                ]
                if let duration = trackDurationText {
                    extras.insert(FeatureField(key: "track_time", value: duration), at: 0)
                }
                beginSave(
                    kind: .track,
                    defaultName: "GPS Track \(layerStore.layers.count + 1)",
                    coordinates: location.track.map { $0.coordinate },
                    clearTool: nil,
                    extraFields: extras
                )
            }
            .disabled(location.track.count < 2)

            Button("Save Line…") {
                beginSave(
                    kind: .measure,
                    defaultName: "Line \(layerStore.layers.count + 1)",
                    coordinates: measurePoints,
                    clearTool: .measure
                )
            }
            .disabled(measurePoints.count < 2)

            Button("Save Polygon…") {
                beginSave(
                    kind: .polygon,
                    defaultName: "Polygon \(layerStore.layers.count + 1)",
                    coordinates: polygonPoints,
                    clearTool: .polygon
                )
            }
            .disabled(polygonPoints.count < 3)

            Button("Save Bearing Line…") {
                beginSave(
                    kind: .measure,
                    defaultName: bearingLineDegrees.map { String(format: "Bearing %.1f deg", $0) } ?? "Bearing Line",
                    coordinates: bearingLine,
                    clearTool: nil
                )
            }
            .disabled(bearingLine.count < 2)

            Button("Drop GPS Point…") {
                dropPointAtCurrentLocation()
            }
            .disabled(location.currentLocation == nil)
            }

            Section(header: Text("Export")) {
            Button {
                showingExportPicker = true
            } label: {
                Label("Choose Layers / Groups…", systemImage: "checklist")
            }
            .disabled(layerStore.layers.isEmpty)

            Button("All Layers GeoJSON (GIS)") {
                exportSavedLayersGeoJSON()
            }
            .disabled(layerStore.layers.isEmpty)

            Button("All Layers KML") {
                exportSavedLayers()
            }
            .disabled(layerStore.layers.isEmpty)

            Button("Current Track GPX") {
                exportTrack(as: .gpx)
            }
            .disabled(location.track.isEmpty)

            Button("Current Track KML") {
                exportTrack(as: .kml)
            }
            .disabled(location.track.isEmpty)
            }
        } label: {
            Label("Save / Export", systemImage: "square.and.arrow.down.on.square")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(.green)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var clearMenu: some View {
        Menu {
            Button("Undo Last Tool Point") {
                undoLastMapPoint()
            }
            .disabled(!canUndoMapPoint)

            Button("Clear Current Tool") {
                measurePoints.removeAll()
                polygonPoints.removeAll()
                toolMessage = "Current tool geometry cleared."
            }
            .disabled(measurePoints.isEmpty && polygonPoints.isEmpty)

            Button("Clear Bearing Line") {
                clearBearingLine()
            }
            .disabled(bearingLine.isEmpty)

            Button("Clear Live GPS Track") {
                location.clearTrack()
            }
            .disabled(location.track.isEmpty)
        } label: {
            Label("Clear", systemImage: "eraser")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(.gray)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var bottomLocationRow: some View {
        HStack(spacing: 10) {
            bottomBarCollapseButton
            locationBar
            collapsedAddMenuButton
        }
    }

    private var bottomBarCollapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                bottomBarExpanded.toggle()
            }
        } label: {
            Image(systemName: bottomBarExpanded ? "chevron.down" : "chevron.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.brandAmber)
                .frame(width: 28, height: 28)
                .background(Color.brandSlate.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var collapsedAddMenuButton: some View {
        if !bottomBarExpanded {
            Button {
                showingQuickAddSheet = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.brandAmber)
            }
            .buttonStyle(.plain)
            .disabled(georef == nil)
        }
    }

    /// Compact edit strip shown after tapping a saved line, track,
    /// polygon, or point. Vertices stay visible until Done/Save/Cancel.
    private var selectedFeatureEditControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(selectedFeatureEditLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                if hasUnsavedVertexEdits {
                    Button {
                        saveVertexEditsAndFinish()
                    } label: {
                        Label("Save Edit", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button(role: .destructive) {
                        cancelVertexEdits()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        finishVertexEditing()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.brandSlate)
                }

                if selectedVertexIndex != nil {
                    Button {
                        addVertexAtCrosshair()
                    } label: {
                        Label("Move @ Crosshair", systemImage: "plus.viewfinder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        addVertexAtGPS()
                    } label: {
                        Label("Move @ GPS", systemImage: "location.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(location.currentLocation == nil)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var selectedFeatureEditLabel: String {
        guard let layerID = selectedLayerID,
              let layer = layerStore.layers.first(where: { $0.id == layerID }) else {
            return "No feature selected"
        }
        if let vertexIndex = selectedVertexIndex {
            return "Editing \(layer.name) vertex \(vertexIndex + 1)"
        }
        return "Selected \(layer.name): tap a vertex to edit"
    }

    /// Full-screen replacement for the old Bearing menu. The old long
    /// SwiftUI Menu could jump back to the top while scrolling because
    /// live GPS/transect state changes rebuilt the menu contents. A sheet
    /// with a Form is stable while scrolling and gives the labels room to
    /// stay readable.
    private var bearingToolsSheet: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        showingBearingTools = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showingBearingSheet = true
                        }
                    } label: {
                        Label("Set Bearing Line", systemImage: "location.north.line")
                    }

                    Button {
                        showingBearingTools = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            walkSavedLinePrompt()
                        }
                    } label: {
                        Label("Walk a Saved Line", systemImage: "scribble")
                    }
                    .disabled(!layerStore.layers.contains { $0.kind == .measure || $0.kind == .track })

                    if bearingLine.count >= 2 {
                        Button {
                            walkTransectEnabled = true
                            if followMode == .free {
                                followMode = .centered
                            }
                            transectModeActive = true
                            showingBearingTools = false
                        } label: {
                            Label("Start Transect Mode", systemImage: "figure.walk")
                        }

                        Button {
                            flipActiveTransect()
                        } label: {
                            Label("Flip Transect Direction", systemImage: "arrow.left.arrow.right")
                        }

                        Button(role: .destructive) {
                            clearBearingLine()
                        } label: {
                            Label("Clear Transect Line", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Transect Line")
                } footer: {
                    Text("A transect line is the single bearing line you walk. The app can show left/right offset and alert when you drift off line.")
                }

                Section {
                    Button {
                        showingBearingTools = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showingTransectArraySheet = true
                        }
                    } label: {
                        Label("Create Transect Array", systemImage: "rectangle.split.3x1")
                    }

                    if !transectArrayLines.isEmpty {
                        Button("Next Transect (\(activeTransectIndex + 1) of \(transectArrayLines.count))") {
                            selectTransect(activeTransectIndex + 1)
                        }
                        .disabled(activeTransectIndex >= transectArrayLines.count - 1)

                        Button("Previous Transect") {
                            selectTransect(activeTransectIndex - 1)
                        }
                        .disabled(activeTransectIndex <= 0)

                        Button {
                            saveTransectArrayLayers()
                        } label: {
                            Label("Save Array as Layers", systemImage: "square.3.layers.3d")
                        }

                        Button(role: .destructive) {
                            clearTransectArray()
                        } label: {
                            Label("Clear Transect Array", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Transect Array")
                } footer: {
                    Text("Generate parallel lines at a chosen spacing, then step through them as survey transects.")
                }

                Section {
                    Toggle(isOn: $showCoverage) {
                        Label("Buffer Walked Track", systemImage: "square.dashed")
                    }

                    Toggle(isOn: $bufferSavedLines) {
                        Label("Buffer Saved Lines and Tracks", systemImage: "square.stack.3d.up")
                    }

                    Picker("Buffer Width", selection: $coverageWidthMeters) {
                        Text("5 m / 16 ft").tag(5.0)
                        Text("10 m / 33 ft").tag(10.0)
                        Text("15 m / 49 ft").tag(15.0)
                        Text("20 m / 66 ft").tag(20.0)
                        Text("30 m / 98 ft").tag(30.0)
                        if ![5.0, 10.0, 15.0, 20.0, 30.0].contains(coverageWidthMeters) {
                            Text(currentCustomBufferLabel).tag(coverageWidthMeters)
                        }
                    }

                    Button {
                        customBufferText = ""
                        showingBearingTools = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showingCustomBufferAlert = true
                        }
                    } label: {
                        Label("Custom Buffer Width", systemImage: "ruler")
                    }

                    Button {
                        showingBearingTools = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            saveTrackBufferPolygon()
                        }
                    } label: {
                        Label("Save Track Buffer as Polygon", systemImage: "rectangle.dashed")
                    }
                    .disabled(location.track.count < 2)
                } header: {
                    Text("Coverage Buffers")
                } footer: {
                    Text("Shade walked coverage or saved line corridors using the selected total corridor width.")
                }

                Section {
                    Toggle(isOn: $walkTransectEnabled) {
                        Label("Walk Transect Alerts", systemImage: "iphone.radiowaves.left.and.right")
                    }

                    Picker("Alert Distance", selection: $transectAlertDistance) {
                        Text("5 m / 16 ft off line").tag(5.0)
                        Text("10 m / 33 ft off line").tag(10.0)
                        Text("15 m / 49 ft off line").tag(15.0)
                        Text("20 m / 66 ft off line").tag(20.0)
                        Text("25 m / 82 ft off line").tag(25.0)
                    }

                    Picker("Alert Style", selection: $transectAlertStyleRaw) {
                        Text("Vibrate").tag(TransectAlertStyle.vibrate.rawValue)
                        Text("Loud Sound").tag(TransectAlertStyle.sound.rawValue)
                        Text("Vibrate + Sound").tag(TransectAlertStyle.both.rawValue)
                    }
                } header: {
                    Text("Off-Line Alerts")
                } footer: {
                    Text("Alerts fire when your GPS drifts beyond the selected distance from the active transect line.")
                }
            }
            .navigationTitle("Bearing Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingBearingTools = false
                    }
                }
            }
        }
    }

    // MARK: - GPS track segments

    private func toggleTrackRecording() {
        if location.isRecording {
            stopAndSaveCurrentTrack()
        } else {
            finishVertexEditing(silent: true)
            location.startRecording()
            toolMessage = "Recording a new GPS track segment."
        }
    }

    private func stopAndSaveCurrentTrack() {
        location.stopRecording()

        let coordinates = location.track.map { $0.coordinate }
        guard coordinates.count >= 2 else {
            location.clearTrack()
            toolMessage = "Track stopped. Not enough GPS points to save."
            return
        }

        let formatter = ISO8601DateFormatter()
        let firstLocation = location.track.first
        let lastLocation = location.track.last
        let startTime = firstLocation.map { formatter.string(from: $0.timestamp) } ?? ""
        let stopTime = lastLocation.map { formatter.string(from: $0.timestamp) } ?? ""
        let durationSeconds = max(0, Int((lastLocation?.timestamp ?? Date()).timeIntervalSince(firstLocation?.timestamp ?? Date())))
        let totalDistance = trackDistanceMeters
        let startToEndBearing = MeasurementMath.bearingDegrees(from: coordinates.first!, to: coordinates.last!)
        let firstSegmentBearing = coordinates.count >= 2
            ? MeasurementMath.bearingDegrees(from: coordinates[0], to: coordinates[1])
            : startToEndBearing
        let finalSegmentBearing = MeasurementMath.finalSegmentBearingDegrees(for: coordinates) ?? startToEndBearing

        var fields: [FeatureField] = [
            FeatureField(key: "track_start_time", value: startTime),
            FeatureField(key: "track_stop_time", value: stopTime),
            FeatureField(key: "track_duration_s", value: "\(durationSeconds)"),
            FeatureField(key: "track_time", value: trackDurationText ?? ""),
            FeatureField(key: "track_distance_m", value: String(format: "%.1f", totalDistance)),
            FeatureField(key: "track_distance", value: formatDistance(totalDistance)),
            FeatureField(key: "track_points", value: "\(location.track.count)"),
            FeatureField(key: "bearing_start_end_deg", value: String(format: "%.1f", startToEndBearing)),
            FeatureField(key: "bearing_first_segment_deg", value: String(format: "%.1f", firstSegmentBearing)),
            FeatureField(key: "bearing_final_segment_deg", value: String(format: "%.1f", finalSegmentBearing))
        ]
        if let accuracy = location.currentLocation?.horizontalAccuracy, accuracy >= 0 {
            fields.append(FeatureField(key: "gps_accuracy_m", value: String(format: "%.1f", accuracy)))
        }

        let layer = MapLayer(
            name: "GPS Track \(layerStore.layers.count + 1)",
            kind: .track,
            coordinates: coordinates.map { LayerCoordinate($0) },
            fields: autoMetadataFields(
                coordinate: MeasurementMath.centroid(for: coordinates) ?? coordinates.first,
                gpsDerived: true,
                stats: nil
            ) + fields,
            color: .red
        )
        layerStore.add(layer)
        selectedLayerID = layer.id
        selectedVertexIndex = nil
        originalLayerBeforeVertexEdit = nil
        hasUnsavedVertexEdits = false
        location.clearTrack()
        toolMessage = "Saved new GPS track layer with time, distance, and bearing attributes: \(layer.name)."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            viewingSavedLayer = layer
        }
    }

    // MARK: - Saving with attributes

    private func beginSave(
        kind: MapLayerKind,
        defaultName: String,
        coordinates: [CLLocationCoordinate2D],
        clearTool: MapTool?,
        extraFields: [FeatureField] = []
    ) {
        pendingClearTool = clearTool
        pendingLayer = MapLayer(
            name: defaultName,
            kind: kind,
            coordinates: coordinates.map { LayerCoordinate($0) },
            fields: autoMetadataFields(
                coordinate: kind == .point ? coordinates.first : (MeasurementMath.centroid(for: coordinates) ?? coordinates.first),
                gpsDerived: false,
                stats: nil
            ) + extraFields
        )
    }

    private var trackDistanceMeters: Double {
        MeasurementMath.totalDistanceMeters(for: location.track.map { $0.coordinate })
    }

    private var trackDurationText: String? {
        guard let first = location.track.first, let last = location.track.last else { return nil }
        let seconds = max(0, Int(last.timestamp.timeIntervalSince(first.timestamp)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    /// All importable content types for the shared picker. Built so no
    /// extension is represented by two conflicting identifiers (which can
    /// make iOS gray out matching files), and so PDF + TIFF are always
    /// present regardless of which tool opened the picker.
    private var dataImportTypes: [UTType] {
        var types: [UTType] = [.pdf]
        if let kml = UTType(filenameExtension: "kml") { types.append(kml) }
        if let geojson = UTType(filenameExtension: "geojson") { types.append(geojson) }
        types.append(.json)
        // Canonical TIFF only. .tiff already matches both .tif and .tiff
        // files; adding a second filenameExtension-derived type for "tif"
        // creates a competing dynamic UTI that can disable .tif DEMs.
        types.append(.tiff)
        // De-duplicate while preserving order.
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    /// Import KML or GeoJSON features as saved layers (geometry,
    /// names, notes, and attributes preserved).
    private func importDataFile(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let canAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if canAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let data = try Data(contentsOf: sourceURL)
            let fileExtension = sourceURL.pathExtension.lowercased()

            var imported: [MapLayer]
            if fileExtension == "kml" {
                imported = KMLImporter.layers(from: data)
                if imported.isEmpty { imported = GeoJSONImporter.layers(from: data) }
            } else {
                imported = GeoJSONImporter.layers(from: data)
                if imported.isEmpty { imported = KMLImporter.layers(from: data) }
            }

            guard !imported.isEmpty else {
                toolMessage = "No importable features found in \(sourceURL.lastPathComponent)."
                return
            }

            let importName = sourceURL.lastPathComponent
            for var layer in imported {
                if !layer.fields.contains(where: { $0.key == "import_source" }) {
                    layer.fields.append(FeatureField(key: "import_source", value: importName))
                }
                layerStore.add(layer)
            }
            toolMessage = "Imported \(imported.count) feature\(imported.count == 1 ? "" : "s") from \(importName)."
        } catch {
            toolMessage = "Data import failed: \(error.localizedDescription)"
        }
    }

    private func finishPendingSave(savedName: String) {
        switch pendingClearTool {
        case .measure:
            measurePoints.removeAll()
        case .polygon:
            polygonPoints.removeAll()
        default:
            break
        }
        pendingClearTool = nil
        pendingLayer = nil
        toolMessage = "Saved layer: \(savedName)."
    }

    private func dropPointAtCurrentLocation() {
        if planningOffMap {
            importMessage = "Heads up: your GPS is off this map. This point will save at your real position and will not be visible on this map. Use Drop Point @ Crosshair to place points on the map."
        }
        recordGPSCoordinate { coordinate, stats in
            createPendingPoint(
                at: coordinate,
                name: "GPS Point \(layerStore.layers.count + 1)",
                gpsDerived: true,
                stats: stats
            )
        }
    }

    private func beginLiDARScanAtGPS() {
        guard LiDARScanCoordinator.isSupported else {
            beginPhoto3DModelAtGPS()
            return
        }
        recordGPSCoordinate { coordinate, _ in
            beginLiDARScan(
                at: coordinate,
                defaultName: "LiDAR Scan \(layerStore.layers.count + 1)",
                source: "gps"
            )
        }
    }

    private func beginLiDARScanAtCrosshair() {
        guard LiDARScanCoordinator.isSupported else {
            beginPhoto3DModelAtCrosshair()
            return
        }
        guard let coordinate = mapProxy.centerCoordinate() else {
            toolMessage = "Crosshair is outside the map extent."
            return
        }
        beginLiDARScan(
            at: coordinate,
            defaultName: "LiDAR Scan \(layerStore.layers.count + 1)",
            source: "crosshair"
        )
    }

    private func beginLiDARScanForFeature(_ featureID: UUID) {
        guard let layer = layerStore.layers.first(where: { $0.id == featureID }),
              let coordinate = layer.clCoordinates.first else {
            toolMessage = "Select a point feature before starting a 3D scan."
            return
        }

        if LiDARScanCoordinator.isSupported {
            beginLiDARScan(
                at: coordinate,
                defaultName: "LiDAR Scan - \(layer.name)",
                source: "feature"
            )
        } else {
            beginPhoto3DModelScan(
                at: coordinate,
                defaultName: "Photo 3D Model - \(layer.name)",
                source: "feature"
            )
        }
    }

    private func beginLiDARScan(at coordinate: CLLocationCoordinate2D, defaultName: String, source: String) {
        let altitude = location.currentLocation?.verticalAccuracy ?? -1 >= 0 ? location.currentLocation?.altitude : nil
        lidarScanRequest = LiDARScanRequest(
            name: defaultName,
            originCoordinate: coordinate,
            originAltitude: altitude,
            headingDegrees: compass.trueHeadingDegrees,
            source: source
        )
        toolMessage = "LiDAR scan started at \(CoordinateFormatter.string(for: coordinate, format: coordinateFormat))."
    }

    private func beginPhoto3DModelAtGPS() {
        guard Photo3DModelScanCoordinator.isSupported else {
            toolMessage = "ARKit world tracking is not available on this device."
            return
        }
        recordGPSCoordinate { coordinate, _ in
            beginPhoto3DModelScan(
                at: coordinate,
                defaultName: "Photo 3D Model \(layerStore.layers.count + 1)",
                source: "gps"
            )
        }
    }

    private func beginPhoto3DModelAtCrosshair() {
        guard Photo3DModelScanCoordinator.isSupported else {
            toolMessage = "ARKit world tracking is not available on this device."
            return
        }
        guard let coordinate = mapProxy.centerCoordinate() else {
            toolMessage = "Crosshair is outside the map extent."
            return
        }
        beginPhoto3DModelScan(
            at: coordinate,
            defaultName: "Photo 3D Model \(layerStore.layers.count + 1)",
            source: "crosshair"
        )
    }

    private func beginPhoto3DModelScan(at coordinate: CLLocationCoordinate2D, defaultName: String, source: String) {
        let altitude = location.currentLocation?.verticalAccuracy ?? -1 >= 0 ? location.currentLocation?.altitude : nil
        photo3DModelScanRequest = LiDARScanRequest(
            name: defaultName,
            originCoordinate: coordinate,
            originAltitude: altitude,
            headingDegrees: compass.trueHeadingDegrees,
            source: "photo_3d_\(source)"
        )
        toolMessage = "Photo 3D model capture started at \(CoordinateFormatter.string(for: coordinate, format: coordinateFormat))."
    }

    private func addLiDARScanLayer(_ result: LiDARScanResult) {
        var fields = autoMetadataFields(coordinate: result.originCoordinate, gpsDerived: result.source == "gps", stats: nil)
        fields.append(contentsOf: [
            FeatureField(key: "feature_type", value: "iphone_lidar_scan"),
            FeatureField(key: "scan_ply_file", value: result.plyURL.lastPathComponent),
            FeatureField(key: "scan_las_file", value: result.lasURL.lastPathComponent),
            FeatureField(key: "scan_photo_count", value: "\(result.photoFilenames.count)"),
            FeatureField(key: "scan_photos", value: result.photoFilenames.joined(separator: ", ")),
            FeatureField(key: "scan_format", value: "PLY + approximate georeferenced LAS, WGS84 UTM meters + high-quality JPEG photos"),
            FeatureField(key: "scan_vertices", value: "\(result.vertexCount)"),
            FeatureField(key: "scan_mesh_anchors", value: "\(result.anchorCount)"),
            FeatureField(key: "scan_source", value: result.source),
            FeatureField(key: "scan_origin", value: CoordinateFormatter.string(for: result.originCoordinate, format: coordinateFormat)),
            FeatureField(key: "scan_origin_utm", value: CoordinateFormatter.utmString(for: result.originCoordinate)),
            FeatureField(key: "scan_altitude_m", value: result.originAltitude.map { String(format: "%.2f", $0) } ?? "unknown"),
            FeatureField(key: "scan_heading_deg", value: result.headingDegrees.map { String(format: "%.1f", $0) } ?? "unknown"),
            FeatureField(key: "scan_created", value: ISO8601DateFormatter().string(from: result.createdAt)),
            FeatureField(key: "georef_note", value: "Approximate georeference from iPhone GPS, compass, and ARKit gravity/heading world alignment")
        ])

        layerStore.add(MapLayer(
            name: result.name,
            kind: .point,
            coordinates: [LayerCoordinate(result.originCoordinate)],
            notes: "iPhone LiDAR scan saved as \(result.plyURL.lastPathComponent) and \(result.lasURL.lastPathComponent). LAS georeferencing is approximate unless the origin point came from survey-grade GNSS.",
            fields: fields,
            color: .teal,
            photoFilenames: result.photoFilenames,
            group: "LiDAR Scans"
        ))
        let photoText = result.photoFilenames.isEmpty ? "" : " and \(result.photoFilenames.count) high-quality photo\(result.photoFilenames.count == 1 ? "" : "s")"
        toolMessage = "Saved LiDAR scan with \(result.vertexCount) exported points\(photoText). LAS and PLY files are stored in LiDARScans."
    }

    private func addPhoto3DModelLayer(_ result: LiDARScanResult) {
        var fields = autoMetadataFields(coordinate: result.originCoordinate, gpsDerived: result.source.contains("gps"), stats: nil)
        fields.append(contentsOf: [
            FeatureField(key: "feature_type", value: "iphone_photo_3d_model"),
            FeatureField(key: "scan_ply_file", value: result.plyURL.lastPathComponent),
            FeatureField(key: "scan_las_file", value: result.lasURL.lastPathComponent),
            FeatureField(key: "scan_photo_count", value: "\(result.photoFilenames.count)"),
            FeatureField(key: "scan_photos", value: result.photoFilenames.joined(separator: ", ")),
            FeatureField(key: "scan_format", value: "Multi-photo ARKit feature-point model package: high-quality JPEG photos + sparse PLY + approximate georeferenced LAS"),
            FeatureField(key: "scan_vertices", value: "\(result.vertexCount)"),
            FeatureField(key: "scan_mesh_anchors", value: "0"),
            FeatureField(key: "scan_source", value: result.source),
            FeatureField(key: "scan_origin", value: CoordinateFormatter.string(for: result.originCoordinate, format: coordinateFormat)),
            FeatureField(key: "scan_origin_utm", value: CoordinateFormatter.utmString(for: result.originCoordinate)),
            FeatureField(key: "scan_altitude_m", value: result.originAltitude.map { String(format: "%.2f", $0) } ?? "unknown"),
            FeatureField(key: "scan_heading_deg", value: result.headingDegrees.map { String(format: "%.1f", $0) } ?? "unknown"),
            FeatureField(key: "scan_created", value: ISO8601DateFormatter().string(from: result.createdAt)),
            FeatureField(key: "georef_note", value: "Approximate georeference from iPhone GPS/map point, compass, and ARKit visual-inertial world tracking. Photos are included for external photogrammetry processing.")
        ])

        layerStore.add(MapLayer(
            name: result.name,
            kind: .point,
            coordinates: [LayerCoordinate(result.originCoordinate)],
            notes: "Photo-based 3D model package saved as \(result.plyURL.lastPathComponent) and \(result.lasURL.lastPathComponent), with \(result.photoFilenames.count) high-quality source photos. The LAS is an approximate ARKit sparse point cloud; use the photos for dense photogrammetry processing when needed.",
            fields: fields,
            color: .orange,
            photoFilenames: result.photoFilenames,
            group: "Photo 3D Models"
        ))
        toolMessage = "Saved photo 3D model package with \(result.vertexCount) AR feature points and \(result.photoFilenames.count) photos. PLY/LAS/photos can be shared from Feature Info."
    }

    private func viewLiDARScanForFeature(_ featureID: UUID) {
        guard let layer = layerStore.layers.first(where: { $0.id == featureID }) else { return }
        guard let plyURL = LiDARScanFileStore.existingURL(filename: layer.lidarPLYFilename) else {
            toolMessage = "No PLY point cloud file was found for \(layer.name)."
            return
        }
        viewingLiDARPointCloud = LiDARPointCloudDocument(
            name: layer.name,
            plyURL: plyURL,
            lasURL: LiDARScanFileStore.existingURL(filename: layer.lidarLASFilename),
            photoURLs: layer.photoFilenames.compactMap { PhotoStore.existingURL(filename: $0) },
            originCoordinate: layer.clCoordinates.first,
            pointCount: Int(layer.lidarPointCountText ?? "") ?? 0,
            createdAt: layer.createdAt
        )
    }

    private func shareLiDARScanForFeature(_ featureID: UUID) {
        guard let layer = layerStore.layers.first(where: { $0.id == featureID }) else { return }
        let urls = LiDARScanFileStore.existingURLs(for: layer)
        guard !urls.isEmpty else {
            toolMessage = "No LiDAR scan files were found for \(layer.name)."
            return
        }
        sharingLiDARScan = LiDARSharePackage(name: layer.name, urls: urls)
    }

    /// Get a GPS coordinate, going through the averaging session when
    /// the survey setting is on.
    private func recordGPSCoordinate(_ completion: @escaping (CLLocationCoordinate2D, GPSAverageResult?) -> Void) {
        if gpsAveragingEnabled {
            averagingRequest = GPSAveragingRequest { result in
                completion(result.coordinate, result)
            }
        } else if let coordinate = location.currentLocation?.coordinate {
            completion(coordinate, nil)
        } else {
            toolMessage = "Waiting for GPS."
        }
    }

    private func createPendingPoint(
        at coordinate: CLLocationCoordinate2D,
        name: String,
        gpsDerived: Bool,
        stats: GPSAverageResult?
    ) {
        pendingClearTool = nil
        pendingLayer = MapLayer(
            name: name,
            kind: .point,
            coordinates: [LayerCoordinate(coordinate)],
            fields: autoMetadataFields(coordinate: coordinate, gpsDerived: gpsDerived, stats: stats)
        )
    }

    /// Metadata stamped automatically onto new features: recorder name,
    /// UTM coordinate (points), and GPS quality (fix count, RMS spread,
    /// accuracy) when the coordinate came from GPS.
    private func autoMetadataFields(
        coordinate: CLLocationCoordinate2D?,
        gpsDerived: Bool,
        stats: GPSAverageResult?
    ) -> [FeatureField] {
        var fields: [FeatureField] = []

        let recorder = recorderName.trimmingCharacters(in: .whitespaces)
        if !recorder.isEmpty {
            fields.append(FeatureField(key: "recorded_by", value: recorder))
        }

        if let coordinate = coordinate {
            fields.append(FeatureField(key: "utm", value: CoordinateFormatter.utmString(for: coordinate)))
            if let elevation = elevationGrid?.elevation(at: coordinate) {
                fields.append(FeatureField(key: "elevation_m", value: String(format: "%.1f", elevation)))
            }
        }

        if let stats = stats {
            fields.append(FeatureField(key: "gps_fixes", value: "\(stats.fixCount)"))
            fields.append(FeatureField(key: "gps_rms_m", value: String(format: "%.2f", stats.rmsMeters)))
            fields.append(FeatureField(key: "gps_accuracy_m", value: String(format: "%.1f", stats.meanAccuracy)))
        } else if gpsDerived,
                  let accuracy = location.currentLocation?.horizontalAccuracy, accuracy >= 0 {
            fields.append(FeatureField(key: "gps_accuracy_m", value: String(format: "%.1f", accuracy)))
        }

        return fields
    }

    // MARK: - Status

    /// True when there is a GPS fix and it falls inside the loaded map.
    private var gpsIsOnCurrentMap: Bool {
        guard let georef = georef,
              let coordinate = location.currentLocation?.coordinate else { return false }
        return georef.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// True when planning remotely: a map is loaded, GPS exists, and the
    /// GPS position is somewhere off this map.
    private var planningOffMap: Bool {
        georef != nil && location.currentLocation != nil && !gpsIsOnCurrentMap
    }

    /// Short "(off map)" suffix for GPS-based action labels while
    /// planning on a map of somewhere else.
    private var gpsActionSuffix: String {
        planningOffMap ? " (off map)" : ""
    }

    /// "14.2 km NE" — where the GPS actually is, relative to the map.
    private var gpsOffMapDistanceText: String? {
        guard planningOffMap,
              let gps = location.currentLocation?.coordinate,
              let georef = georef,
              let mapCenter = georef.coordinate(forNormalizedPoint: CGPoint(x: 0.5, y: 0.5)) else { return nil }
        let distance = MeasurementMath.totalDistanceMeters(for: [mapCenter, gps])
        let bearing = MeasurementMath.bearingDegrees(from: mapCenter, to: gps)
        let cardinals = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((bearing + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return formatDistance(distance) + " " + cardinals[max(0, min(7, index))]
    }

    /// Ground elevation under the crosshair, from the stored grid.
    private func crosshairElevationText(for coordinate: CLLocationCoordinate2D) -> String? {
        guard let elevation = elevationGrid?.elevation(at: coordinate) else { return nil }
        if distanceUnits == .imperial {
            return String(format: "el. %.0f ft", elevation * 3.28084)
        }
        return String(format: "el. %.0f m", elevation)
    }

    private var compactStatusText: String {
        if let guidance = bearingGuidanceText {
            return guidance
        }

        if mapTool == .measure {
            if let previewDistance = liveMeasurePreviewDistanceMeters,
               let previewBearing = liveMeasurePreviewBearingDegrees {
                let previewTotal = totalMeasureDistanceMeters + previewDistance
                return "Line preview \(formatDistance(previewTotal)) | segment \(formatDistance(previewDistance)) @ \(formatBearing(previewBearing))"
            }
            return "Line \(formatDistance(totalMeasureDistanceMeters)) | bearing \(formatBearing(currentMeasureBearingDegrees))"
        }

        if mapTool == .polygon {
            if let preview = liveMeasurementPreviewCoordinate,
               !polygonPoints.isEmpty {
                let previewArea = MeasurementMath.areaSquareMeters(for: polygonPoints + [preview])
                return "Polygon preview \(formatArea(previewArea))"
            }
            return "Polygon \(formatArea(polygonAreaSquareMeters))"
        }

        if let selectedLayerID = selectedLayerID,
           let layer = layerStore.layers.first(where: { $0.id == selectedLayerID }) {
            if let selectedVertexIndex = selectedVertexIndex {
                return "Editing \(layer.name) vertex \(selectedVertexIndex + 1): tap new location to move it"
            }
            return "Selected \(layer.name): tap a vertex to edit it"
        }

        if let currentLocation = location.currentLocation {
            let offMapPrefix = gpsOffMapDistanceText.map { "GPS off this map (\($0)) | " } ?? ""
            if location.isRecording, location.track.count > 1 {
                return offMapPrefix + "REC \(formatDistance(trackDistanceMeters)) | \(trackDurationText ?? "0:00:00") | H \(formatAccuracy(currentLocation.horizontalAccuracy))"
            }
            return offMapPrefix + "GPS H \(formatAccuracy(currentLocation.horizontalAccuracy)) | layers \(layerStore.layers.count)"
        }

        return toolMessage
    }

    /// Live walk-the-line guidance while a bearing line is active.
    /// With a chained traverse, guidance follows the most recent segment.
    private var bearingGuidanceText: String? {
        guard bearingLine.count >= 2, let target = bearingLineDegrees else { return nil }
        guard let currentLocation = location.currentLocation else {
            return String(format: "Bearing line %.1f deg set. Waiting for GPS.", target)
        }

        let crossTrack = MeasurementMath.crossTrackDistanceMeters(
            lineStart: bearingLine[bearingLine.count - 2],
            lineEnd: bearingLine[bearingLine.count - 1],
            point: currentLocation.coordinate
        )
        let side = crossTrack >= 0 ? "right" : "left"
        var text = String(format: "Bearing %.1f deg | ", target)
            + formatDistance(abs(crossTrack)) + " \(side) of line"

        if walkTransectEnabled {
            text = (abs(crossTrack) > transectAlertDistance ? "OFF LINE | " : "On line | ") + text
        }

        if let heading = compass.trueHeadingDegrees {
            let turn = MeasurementMath.normalizedAngle180(target - heading)
            text += String(format: " | turn %@ %.0f deg", turn >= 0 ? "right" : "left", abs(turn))
        }

        return text
    }

    /// Load a generated (terrain / GeoTIFF) PDF as the current basemap.
    private func loadGeneratedMap(url: URL, extent: GeoExtent) {
        pdfDocument = PDFDocument(url: url)
        currentMapURL = url.standardizedFileURL
        georef = GeoReference.fromExtent(
            minLatitude: extent.minLatitude,
            maxLatitude: extent.maxLatitude,
            minLongitude: extent.minLongitude,
            maxLongitude: extent.maxLongitude
        )
        measurePoints.removeAll()
        polygonPoints.removeAll()
        selectedLayerID = nil
        selectedVertexIndex = nil
        mapTool = .navigate
        followMode = .free
        elevationGrid = ElevationGridStore.load(forMapNamed: url.lastPathComponent)
        registerCurrentMapInLayerStackIfPossible(
            name: url.deletingPathExtension().lastPathComponent,
            kind: .other,
            group: .downloadedOfflineMaps,
            offlineStatus: .downloaded,
            sourceDescription: "Generated or imported offline basemap"
        )
    }

    /// Fetch and store an offline elevation grid for whatever map is
    /// loaded (works for imported GeoPDFs too).
    private func downloadElevationForCurrentMap() {
        guard georef?.downloadExtent != nil, currentMapURL?.lastPathComponent != nil else {
            toolMessage = "Load a georeferenced map first."
            return
        }
        toolMessage = "Downloading elevation from USGS 3DEP…"
        Task {
            let result = await downloadElevationGridForCurrentMap()
            await MainActor.run {
                toolMessage = result
            }
        }
    }

    @MainActor
    private func downloadDPRAutofillPackForCurrentMap() async -> String {
        guard let extent = georef?.downloadExtent else {
            return "Load a georeferenced GeoPDF/offline map before downloading DPR autofill data."
        }

        var savedLayerCount = 0
        var failures: [String] = []

        for dataset in OnlineDataset.dprAutofill where extent.approximateAreaSquareKilometers <= dataset.recommendedMaxAreaSquareKilometers {
            do {
                let layers = try await OnlineDataFetcher.layers(for: dataset, extent: extent)
                for layer in layers { layerStore.add(layer) }
                savedLayerCount += layers.count
            } catch {
                failures.append(dataset.title)
            }
        }

        var messages: [String] = []
        if savedLayerCount > 0 {
            messages.append("Saved \(savedLayerCount) DPR autofill feature\(savedLayerCount == 1 ? "" : "s") for PLSS, USGS 7.5' quads, and counties.")
        } else {
            messages.append("No DPR autofill boundary features were saved for this extent.")
        }

        let elevationMessage = await downloadElevationGridForCurrentMap()
        messages.append(elevationMessage)

        if !failures.isEmpty {
            messages.append("Some downloads failed or returned no usable features: \(failures.joined(separator: ", ")).")
        }

        let finalMessage = messages.joined(separator: " ")
        toolMessage = finalMessage
        return finalMessage
    }

    @MainActor
    private func downloadElevationGridForCurrentMap() async -> String {
        guard let extent = georef?.downloadExtent, let mapName = currentMapURL?.lastPathComponent else {
            return "Elevation was not downloaded because no georeferenced map is loaded."
        }

        do {
            let dem = try await DEMDownloader.fetch3DEP(extent: extent, longEdgePixels: 280)
            ElevationGridStore.save(dem, forMapNamed: mapName)
            elevationGrid = dem
            return "Elevation saved for this map; new points, lines, polygons, and DPR forms can use elevation_m."
        } catch {
            return "Elevation download failed: \(error.localizedDescription)"
        }
    }

    /// Import an RVT (or any) GeoTIFF as a georeferenced basemap.
    private func importGeoTIFFBasemap(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let canAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if canAccess { sourceURL.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: sourceURL)
            let tiff = try GeoTIFFReader.read(data: data)
            guard let extent = tiff.extent else { throw GeoTIFFError.noGeoreference }

            let image: UIImage
            if let rgba = tiff.rgba,
               let rendered = TerrainRenderer.image(fromRGBA: rgba, width: tiff.width, height: tiff.height) {
                image = rendered
            } else if var values = tiff.floatValues {
                // Float visualization (e.g. RVT SVF): contrast-stretch to gray.
                if let noData = tiff.noDataValue {
                    for index in values.indices where values[index] == noData { values[index] = .nan }
                }
                let valid = values.filter { $0.isFinite }
                let fallback = valid.min() ?? 0
                for index in values.indices where !values[index].isFinite { values[index] = fallback }
                TerrainRenderer.stretch(&values, lowPercentile: 0.02, highPercentile: 0.98)
                let pixels = TerrainRenderer.grayImage(values, width: tiff.width, height: tiff.height)
                guard let rendered = TerrainRenderer.image(fromRGBA: pixels, width: tiff.width, height: tiff.height) else {
                    throw GeoTIFFError.unsupported("image rendering")
                }
                image = rendered
            } else {
                throw GeoTIFFError.unsupported("pixel layout")
            }

            let name = sourceURL.deletingPathExtension().lastPathComponent
            let url = try TerrainMapWriter.writePDFMap(
                image: image,
                extent: extent,
                title: name,
                label: "\(name) • imported GeoTIFF"
            )
            loadGeneratedMap(url: url, extent: extent)
            registerCurrentMapInLayerStackIfPossible(
                name: name,
                kind: .geoTIFF,
                group: .importedMaps,
                offlineStatus: .importedLocal,
                sourceDescription: "User-imported GeoTIFF raster basemap",
                opacity: 1.0,
                blendMode: .normal
            )
            importMessage = "GeoTIFF imported as a georeferenced basemap. Draw, navigate, and collect on it like any map."
            toolMessage = "GeoTIFF basemap active: \(name)."
        } catch {
            importMessage = "GeoTIFF import failed: \(error.localizedDescription)"
        }
    }


    /// Import a georeferenced DEM GeoTIFF, then open the on-device
    /// RVT/VAT toolbox so the user can choose VAT hillshade, SVF,
    /// openness, local relief, slope, or hillshade outputs.
    private func importDEMTerrain(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let canAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if canAccess { sourceURL.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: sourceURL)
            let tiff = try GeoTIFFReader.read(data: data)
            let dem = try DEMGrid.fromGeoTIFF(tiff)
            let name = sourceURL.deletingPathExtension().lastPathComponent
            importedDEMTerrainRequest = ImportedDEMTerrainRequest(sourceName: name, dem: dem)
            importMessage = "DEM loaded. Choose a VAT/RVT visualization to create an offline basemap or transparent overlay."
            toolMessage = "Imported DEM ready: \(name) (\(dem.width)×\(dem.height))."
        } catch let error as GeoTIFFError {
            importMessage = "DEM import failed: \(error.localizedDescription)"
            toolMessage = "Tip: a DEM must be a single-band elevation GeoTIFF (Float32 or Int16) with georeferencing in EPSG:4326 (WGS84) or a WGS84/NAD83 UTM zone. In QGIS: Raster ▸ Projections ▸ Warp, target EPSG:4326, then export as GeoTIFF."
        } catch {
            importMessage = "DEM import failed: \(error.localizedDescription)"
            toolMessage = "Could not read that file as a DEM. Make sure it is an uncompressed or LZW/Deflate GeoTIFF."
        }
    }

    /// Re-render the active overlay from its stored DEM with the current
    /// live parameters. Coalesces rapid slider changes: if a render is
    /// already running, it marks a pending pass to run on completion.
    private func liveRerenderTerrainOverlay() {
        guard let dem = activeTerrainDEM, let existing = terrainOverlay else { return }
        if liveRenderInFlight {
            liveRenderPending = true
            return
        }
        liveRenderInFlight = true
        let kind = activeTerrainKind
        let parameters = activeTerrainParameters
        let extent = existing.extent
        let title = existing.title
        let sourceLabel = existing.sourceLabel
        let isColorImage = kind.producesColorImage
            || (parameters.warmColorRamp && kind.supportsWarmRamp)

        Task {
            let rendered = await MainActor.run {
                TerrainRenderer.render(kind: kind, dem: dem, parameters: parameters)
            }
            await MainActor.run {
                if let image = rendered {
                    // Swap the image in place; keep the same extent/source.
                    terrainOverlay = TerrainRasterOverlay(
                        title: title,
                        image: image,
                        extent: extent,
                        createdAt: Date(),
                        sourceLabel: sourceLabel,
                        fileURL: terrainOverlay?.fileURL,
                        isColor: isColorImage
                    )
                }
                liveRenderInFlight = false
                if liveRenderPending {
                    liveRenderPending = false
                    liveRerenderTerrainOverlay()
                }
            }
        }
    }

    /// Re-render the active overlay for the currently visible map area at
    /// higher relative resolution, so zooming in reveals finer shadows
    /// and micro-relief. Re-downloads (3DEP) or re-samples (imported DEM)
    /// just the visible extent. Falls back silently if unavailable.
    private func enhanceTerrainForCurrentZoom() {
        guard let existing = terrainOverlay,
              let visible = mapProxy.visibleExtent() else {
            toolMessage = "Zoom to the area you want sharpened, then try again."
            return
        }
        // Only worth it when zoomed inside the current overlay extent.
        let current = existing.extent
        let visibleSpan = (visible.maxLatitude - visible.minLatitude)
        let currentSpan = (current.maxLatitude - current.minLatitude)
        guard currentSpan > 0, visibleSpan < currentSpan * 0.92 else {
            toolMessage = "Already showing full detail for this view. Zoom in further to sharpen a smaller area."
            return
        }

        let kind = activeTerrainKind
        let parameters = activeTerrainParameters
        let sourceLabel = existing.sourceLabel
        let title = existing.title
        let isColorImage = kind.producesColorImage
            || (parameters.warmColorRamp && kind.supportsWarmRamp)
        let fromImportedDEM = activeTerrainDEM != nil && sourceLabel.contains("imported DEM")
        let baseDEM = activeTerrainDEM

        liveRenderInFlight = true
        toolMessage = "Sharpening terrain for this view…"

        Task {
            do {
                let zoomDEM: DEMGrid
                if fromImportedDEM, let baseDEM = baseDEM {
                    // Crop the imported DEM to the visible extent.
                    guard let cropped = baseDEM.cropped(to: visible) else {
                        throw DEMDownloadError.noCoverage
                    }
                    zoomDEM = cropped
                } else {
                    // Re-download just the visible window at high detail.
                    zoomDEM = try await DEMDownloader.fetch3DEP(extent: visible, longEdgePixels: 1400)
                }
                let rendered = await MainActor.run {
                    TerrainRenderer.render(kind: kind, dem: zoomDEM, parameters: parameters)
                }
                await MainActor.run {
                    if let image = rendered {
                        terrainOverlay = TerrainRasterOverlay(
                            title: title,
                            image: image,
                            extent: visible,
                            createdAt: Date(),
                            sourceLabel: sourceLabel,
                            fileURL: nil,
                            isColor: isColorImage
                        )
                        activeTerrainDEM = zoomDEM
                        toolMessage = "Terrain sharpened for this view. Zoom out and use Adjust to return to the full area."
                    } else {
                        toolMessage = "Could not render the sharpened view."
                    }
                    liveRenderInFlight = false
                }
            } catch {
                await MainActor.run {
                    liveRenderInFlight = false
                    toolMessage = "Could not sharpen this view: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyTerrainVisualizationResult(
        url: URL,
        extent: GeoExtent,
        dem: DEMGrid,
        kind: TerrainVisualizationKind,
        image: UIImage,
        outputMode: TerrainOutputMode,
        parameters: TerrainVizParameters,
        sourceLabel: String
    ) {
        // A color overlay (blend .normal) is produced by the diverging
        // Local Relief Model, or by SVF/openness when the warm ramp is on.
        let isColorImage = kind.producesColorImage
            || (parameters.warmColorRamp && kind.supportsWarmRamp)

        // Remember context so the live-adjust panel can re-render this
        // overlay from its DEM without re-downloading.
        if outputMode == .overlay {
            activeTerrainKind = kind
            activeTerrainParameters = parameters
            activeTerrainDEM = dem
        }
        switch outputMode {
        case .overlay:
            do {
                let overlay = try TerrainOverlayStore.save(
                    image: image,
                    extent: extent,
                    title: kind.title,
                    sourceLabel: sourceLabel,
                    isColor: isColorImage
                )
                terrainOverlay = overlay
                terrainOverlayHidden = false
                showingFloatingTerrainControl = true
                terrainOverlayOpacity = min(max(terrainOverlayOpacity, 0.15), 0.85)
                registerActiveTerrainOverlayInLayerStackIfPossible()

                if let mapName = currentMapURL?.lastPathComponent {
                    ElevationGridStore.save(dem, forMapNamed: mapName)
                }
                elevationGrid = dem.downsampled(maxDimension: 280)
                importMessage = "\(kind.title) created as a transparent overlay on the current PDF/offline basemap. It is saved offline in TerrainOverlays and also stored as a georeferenced PDF in GeneratedMaps."
                toolMessage = "RVT/VAT overlay active at \(Int(terrainOverlayOpacity * 100))% opacity. Tap the terrain pill or Terrain ▸ Adjust to fine-tune it."
            } catch {
                terrainOverlay = TerrainRasterOverlay(
                    title: kind.title,
                    image: image,
                    extent: extent,
                    createdAt: Date(),
                    sourceLabel: sourceLabel,
                    fileURL: nil,
                    isColor: isColorImage
                )
                terrainOverlayHidden = false
                showingFloatingTerrainControl = true
                elevationGrid = dem.downsampled(maxDimension: 280)
                registerActiveTerrainOverlayInLayerStackIfPossible()
                importMessage = "\(kind.title) overlay is active for this session, but offline overlay storage failed: \(error.localizedDescription)"
                toolMessage = "RVT/VAT overlay active for this session."
            }
        case .basemap:
            loadGeneratedMap(url: url, extent: extent)
            registerCurrentMapInLayerStackIfPossible(
                name: kind.title,
                kind: .rvtVat,
                group: .terrainVisualization,
                offlineStatus: .downloaded,
                sourceDescription: sourceLabel,
                opacity: 1.0,
                blendMode: isColorImage ? .normal : .multiply
            )
            ElevationGridStore.save(dem, forMapNamed: url.lastPathComponent)
            elevationGrid = dem.downsampled(maxDimension: 280)
            importMessage = "\(kind.title) created and loaded as an offline georeferenced basemap. It is stored in GeneratedMaps."
            toolMessage = "RVT/VAT basemap active. The crosshair now reads ground elevation."
        }
    }

    private func clearTerrainOverlay() {
        terrainOverlay = nil
        terrainOverlayHidden = false
        showingFloatingOpacity = false
        showingFloatingTerrainControl = false
        showingTerrainControlPanel = false
        activeTerrainDEM = nil
        TerrainOverlayStore.clearAll()
        toolMessage = "Map overlay cleared."
    }

    // MARK: - PDF import

    /// Single entry point for the shared file picker. Resolves the URL
    // MARK: - Map layer stack integration

    /// Seed always-on field/reference entries in the map-layer stack. These are
    /// metadata/control rows for the Layer Manager; actual field geometry still
    /// lives in LayerStore and draws through TrackOverlayView.
    private func seedDefaultMapLayerStackEntries() {
        let defaults: [SurveyMapLayer] = [
            SurveyMapLayer(
                name: "Current GPS Location",
                subtitle: "Locked field overlay",
                group: .fieldData,
                kind: .fieldFeature,
                isVisible: true,
                isLocked: true,
                opacity: 1.0,
                blendMode: .normal,
                offlineStatus: .downloaded,
                sourceDescription: "Live device or external GNSS position"
            ),
            SurveyMapLayer(
                name: "GPS Tracks, Waypoints, Lines, Polygons",
                subtitle: "Locked field overlay",
                group: .fieldData,
                kind: .gpsTrack,
                isVisible: true,
                isLocked: true,
                opacity: 1.0,
                blendMode: .normal,
                offlineStatus: .downloaded,
                sourceDescription: "Saved field features stored on this device"
            ),
            SurveyMapLayer(
                name: "DPR 523 Forms and Autofill Layers",
                subtitle: "Locked field overlay",
                group: .fieldData,
                kind: .dprForms,
                isVisible: true,
                isLocked: true,
                opacity: 1.0,
                blendMode: .normal,
                offlineStatus: .downloaded,
                sourceDescription: "DPR form records and local PLSS/quad/county/elevation lookup data"
            )
        ]
        defaults.forEach { surveyLayerStore.addOrReplace($0) }
    }

    /// Register the currently loaded map as a controllable map-stack row.
    /// GeoPDFs default to 70% opacity so USGS topo/imagery and terrain layers
    /// can be compared instead of being hidden by an opaque PDF.
    private func registerCurrentMapInLayerStackIfPossible(
        name: String? = nil,
        kind: SurveyLayerKind = .geoPDF,
        group: SurveyLayerGroup = .importedMaps,
        offlineStatus: LayerOfflineStatus = .importedLocal,
        sourceDescription: String = "Current map loaded in the app",
        yearLabel: String? = nil,
        opacity: Double? = nil,
        blendMode: SurveyLayerBlendMode? = nil
    ) {
        guard let url = currentMapURL else { return }
        let layerName = name ?? url.lastPathComponent
        let layerOpacity = opacity ?? (kind == .geoPDF ? 0.70 : 1.0)
        let layerBlend = blendMode ?? ((kind == .usgsHistoricalTopo || kind == .usgsCurrentTopo) ? .multiply : .normal)
        let coverage = georef?.extentDescription
        let storage = formattedFileSizeIfAvailable(url: url)

        let layer = SurveyMapLayer(
            name: layerName,
            subtitle: kind.rawValue,
            group: group,
            kind: kind,
            isVisible: true,
            isLocked: false,
            opacity: layerOpacity,
            blendMode: layerBlend,
            offlineStatus: offlineStatus,
            sourceDescription: sourceDescription,
            yearLabel: yearLabel,
            coverageLabel: coverage,
            storageLabel: storage,
            localFilePath: url.standardizedFileURL.path
        )
        surveyLayerStore.addOrReplace(layer)
    }

    /// Register an active transparent terrain/RVT/VAT overlay as a layer stack row.
    private func registerActiveTerrainOverlayInLayerStackIfPossible() {
        guard let overlay = terrainOverlay else { return }
        let localPath = overlay.fileURL?.standardizedFileURL.path
        let layer = SurveyMapLayer(
            name: overlay.title,
            subtitle: "Transparent terrain overlay",
            group: .terrainVisualization,
            kind: .rvtVat,
            isVisible: !terrainOverlayHidden,
            isLocked: false,
            opacity: terrainOverlayOpacity,
            blendMode: overlay.isColor ? .normal : .multiply,
            offlineStatus: overlay.fileURL == nil ? .notDownloaded : .downloaded,
            sourceDescription: overlay.sourceLabel,
            coverageLabel: String(format: "Lat %.5f to %.5f, Lon %.5f to %.5f", overlay.extent.minLatitude, overlay.extent.maxLatitude, overlay.extent.minLongitude, overlay.extent.maxLongitude),
            localFilePath: localPath
        )
        surveyLayerStore.addOrReplace(layer)
    }

    private func formattedFileSizeIfAvailable(url: URL) -> String? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return nil }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    private func surveyLayerKind(for source: OfflineImageryTopoSource) -> SurveyLayerKind {
        switch source {
        case .bestAvailablePublicImagery, .usgsImageryOnly:
            return .naipImagery
        case .usgsImageryTopo:
            return .usgsImagery
        case .usgsTopo:
            return .usgsCurrentTopo
        case .appleSatellitePreview:
            return .appleSatellitePreview
        case .customArcGISRasterService:
            return .usgsImagery
        }
    }

    private func surveyLayerKind(for product: TNMProduct) -> SurveyLayerKind {
        let title = product.title.lowercased()
        if title.contains("historical") || title.contains("historic") || (product.year ?? 2100) < 2009 {
            return .usgsHistoricalTopo
        }
        return .usgsCurrentTopo
    }

    /// once and routes it, using the file extension first, then the
    /// content type, then the tool that opened the picker. This avoids
    /// double-consuming the Result and avoids misrouting when iOS reports
    /// a generic extension/type for a DEM or GeoPDF.
    private func routeImportedFile(_ result: Result<[URL], Error>) {
        let url: URL
        switch result {
        case .failure(let error):
            importMessage = "Import failed: \(error.localizedDescription)"
            return
        case .success(let urls):
            guard let first = urls.first else {
                importMessage = "No file was selected."
                return
            }
            url = first
        }

        let ext = url.pathExtension.lowercased()
        let isTIFF = ext == "tif" || ext == "tiff"
            || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .tiff)) == true
        let isPDF = ext == "pdf"
            || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true

        let single = Result<[URL], Error>.success([url])

        if isTIFF {
            // A TIFF means terrain. If the DEM toolbox opened the picker,
            // process it as an elevation DEM; otherwise treat it as a
            // ready-made raster (e.g. an RVT image export) basemap.
            if fileImportKind == .demTerrain {
                importDEMTerrain(single)
            } else {
                importGeoTIFFBasemap(single)
            }
        } else if isPDF {
            importPDF(single)
        } else {
            // KML / GeoJSON / JSON vector data.
            importDataFile(single)
        }
    }

    private func importPDF(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let canAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if canAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let localURL = try copyPDFIntoAppStorage(from: sourceURL)

            guard let document = PDFDocument(url: localURL) else {
                importMessage = "Could not open that PDF."
                return
            }

            pdfDocument = document
            currentMapURL = localURL.standardizedFileURL
            georef = GeoPDFParser.parse(url: localURL)
            registerCurrentMapInLayerStackIfPossible(
                name: localURL.lastPathComponent,
                kind: .geoPDF,
                group: .importedMaps,
                offlineStatus: .importedLocal,
                sourceDescription: "User-imported georeferenced PDF",
                opacity: 0.70,
                blendMode: .normal
            )
            elevationGrid = ElevationGridStore.load(forMapNamed: localURL.lastPathComponent)
            measurePoints.removeAll()
            polygonPoints.removeAll()
            bearingLine.removeAll()
            bearingLineDegrees = nil
            selectedLayerID = nil
            selectedVertexIndex = nil
            originalLayerBeforeVertexEdit = nil
            hasUnsavedVertexEdits = false
            mapTool = .navigate
            followMode = .free

            if georef == nil {
                importMessage = "PDF opened, but no usable GeoPDF registration was found. Use Map > Manual Calibration to enter the map corners."
                toolMessage = "This PDF is not georeferenced in a format the app can read. Try Manual Calibration."
            } else {
                var loadedMessage = "GeoPDF loaded. GPS position and tracks will draw over the map when you are inside the map extent."
                var loadedTool = "Map extent: \(georef!.extentDescription). Pick a tool, then tap directly on the map."
                if let gps = location.currentLocation?.coordinate,
                   let loadedGeoref = georef,
                   !loadedGeoref.contains(latitude: gps.latitude, longitude: gps.longitude) {
                    loadedMessage = "GeoPDF loaded. You are not on this map — remote planning mode."
                    loadedTool = "Remote planning: tap the map or use the crosshair tools to draw points, lines, and polygons anywhere on it. GPS-based tools record your real position, which is off this map."
                }
                importMessage = loadedMessage
                toolMessage = loadedTool
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    showingDPRAutofillSetup = true
                }
            }
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func createOfflineMap(
        for extent: GeoExtent,
        title: String,
        rasterStyle: OfflineRasterBasemapStyle
    ) async {
        guard rasterStyle != .blankVector else {
            createBlankOfflineMap(for: extent, title: title)
            return
        }

        do {
            let url = try await OfflineRasterBasemapRenderer.createPDF(
                for: extent,
                title: title,
                style: rasterStyle
            )
            pdfDocument = PDFDocument(url: url)
            currentMapURL = url.standardizedFileURL
            georef = GeoReference.fromExtent(
                minLatitude: extent.minLatitude,
                maxLatitude: extent.maxLatitude,
                minLongitude: extent.minLongitude,
                maxLongitude: extent.maxLongitude
            )
            elevationGrid = ElevationGridStore.load(forMapNamed: url.lastPathComponent)
            importMessage = "Offline raster basemap created from \(rasterStyle.label). Downloaded vector layers will draw on top."
            followMode = .free
            registerCurrentMapInLayerStackIfPossible(
                name: title,
                kind: rasterStyle == .blankVector ? .osmVectors : .usgsImagery,
                group: .downloadedOfflineMaps,
                offlineStatus: .downloaded,
                sourceDescription: "Offline raster basemap created from \(rasterStyle.label)"
            )
        } catch {
            createBlankOfflineMap(for: extent, title: title)
            toolMessage = "Raster basemap failed, so a blank offline map was created instead: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func createOfflineImageryTopoBasemap(_ request: OfflineImageryTopoRequest) async -> String {
        guard request.source.isOfflineDownloadable else {
            let message = "Apple Satellite Preview is online only in this app. It was not saved as an offline basemap; choose USGS imagery/topo or import your own GeoTIFF/GeoPDF for offline field use."
            toolMessage = message
            return message
        }

        let serviceURL = request.customServiceURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.customServiceURL!.trimmingCharacters(in: .whitespacesAndNewlines)
            : request.source.serviceURL
        guard let serviceURL, !serviceURL.isEmpty else {
            let message = "No raster service URL was available for that option."
            toolMessage = message
            return message
        }

        let label = request.mapLabel

        // If a GeoPDF/basemap is already loaded, present the downloaded
        // imagery/topo as a TRANSPARENT OVERLAY on top of it (with the
        // floating opacity pill), instead of replacing the basemap and
        // blurring it. Topo blends multiply (reads as ink over the map);
        // imagery blends normally to keep true color. With no basemap
        // loaded there is nothing to overlay, so fall back to making it
        // the basemap as before.
        if pdfDocument != nil {
            do {
                let image = try await OfflineRasterMapServiceExporter.fetchImage(
                    serviceURL: serviceURL,
                    extent: request.extent,
                    year: request.year
                )
                // Topo-style products are line/label art and read best as a
                // multiply overlay; imagery is photographic and stays normal.
                let isImagery = request.source != .usgsTopo
                presentDownloadedRasterOverlay(
                    image: image,
                    extent: request.extent,
                    title: request.title,
                    sourceLabel: label,
                    blendsNormally: isImagery
                )
                importMessage = "\(label) added as a transparent overlay on the current map. Use the imagery pill or Map Layers to set its opacity."
                toolMessage = "\(label) overlay active at \(Int(terrainOverlayOpacity * 100))% opacity. Tap the pill to adjust."
                return "Added \(label) as a transparent overlay."
            } catch {
                let message = "Imagery overlay download failed: \(error.localizedDescription)"
                toolMessage = message
                return message
            }
        }

        do {
            let url = try await OfflineRasterMapServiceExporter.createPDF(
                serviceURL: serviceURL,
                extent: request.extent,
                title: request.title,
                label: label,
                year: request.year
            )
            loadGeneratedMap(url: url, extent: request.extent)
            registerCurrentMapInLayerStackIfPossible(
                name: request.title,
                kind: surveyLayerKind(for: request.source),
                group: .downloadedOfflineMaps,
                offlineStatus: .downloaded,
                sourceDescription: request.mapLabel,
                yearLabel: request.year.map { String($0) },
                opacity: 1.0,
                blendMode: request.source == .usgsTopo ? .multiply : .normal
            )
            importMessage = "Offline raster basemap loaded: \(label). It is stored in GeneratedMaps and works offline."
            toolMessage = "Offline raster basemap saved: \(label)."
            return "Saved and opened \(label)."
        } catch {
            let message = "Raster basemap download failed: \(error.localizedDescription)"
            toolMessage = message
            return message
        }
    }

    /// Present a downloaded imagery/topo raster as a transparent overlay on
    /// the current basemap, reusing the same overlay rendering + floating
    /// opacity pill as the RVT/VAT terrain overlays. `blendsNormally` keeps
    /// photographic imagery in true color; false uses multiply for topo art.
    private func presentDownloadedRasterOverlay(
        image: UIImage,
        extent: GeoExtent,
        title: String,
        sourceLabel: String,
        blendsNormally: Bool
    ) {
        let overlay: TerrainRasterOverlay
        if let saved = try? TerrainOverlayStore.save(
            image: image,
            extent: extent,
            title: title,
            sourceLabel: sourceLabel,
            isColor: blendsNormally
        ) {
            overlay = saved
        } else {
            overlay = TerrainRasterOverlay(
                title: title,
                image: image,
                extent: extent,
                createdAt: Date(),
                sourceLabel: sourceLabel,
                fileURL: nil,
                isColor: blendsNormally
            )
        }
        terrainOverlay = overlay
        terrainOverlayHidden = false
        showingFloatingTerrainControl = true
        terrainOverlayOpacity = min(max(terrainOverlayOpacity, 0.20), 0.90)
        registerActiveTerrainOverlayInLayerStackIfPossible()
    }

    @MainActor
    private func downloadAndOpenTNMProduct(_ product: TNMProduct) async -> String {
        guard let downloadURL = product.bestDownloadURL else {
            return "No downloadable GeoPDF/GeoTIFF URL was found for \(product.title)."
        }

        do {
            var request = URLRequest(url: downloadURL)
            request.setValue("AvenzaStyleFieldMapper/1.0 field survey app", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return "USGS map download failed for \(product.title)."
            }

            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("ImportedMaps", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let extensionName = downloadURL.pathExtension.isEmpty ? "pdf" : downloadURL.pathExtension
            let safeBase = product.title.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
            let localURL = folder.appendingPathComponent("USGS-\(safeBase)-\(Int(Date().timeIntervalSince1970)).\(extensionName)")
            try data.write(to: localURL, options: .atomic)

            let ext = localURL.pathExtension.lowercased()
            if ext == "pdf" {
                importPDF(.success([localURL]))
            } else if ext == "tif" || ext == "tiff" {
                importGeoTIFFBasemap(.success([localURL]))
            }
            registerCurrentMapInLayerStackIfPossible(
                name: product.title,
                kind: surveyLayerKind(for: product),
                group: .downloadedOfflineMaps,
                offlineStatus: .downloaded,
                sourceDescription: "USGS TNM product: \(product.subtitle)",
                yearLabel: product.year.map { String($0) },
                opacity: 0.90,
                blendMode: .multiply
            )
            return "Downloaded \(product.displayYearText) \(product.title) and opened it as an offline map when georeferencing was readable."
        } catch {
            return "USGS map download failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func createBlankOfflineMap(for extent: GeoExtent, title: String) {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let mapsFolder = documents.appendingPathComponent("GeneratedMaps", isDirectory: true)
            try FileManager.default.createDirectory(at: mapsFolder, withIntermediateDirectories: true)
            let url = mapsFolder.appendingPathComponent("OfflineMap-\(Int(Date().timeIntervalSince1970)).pdf")

            let pageRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                UIColor(white: 0.96, alpha: 1).setFill()
                context.cgContext.fill(pageRect)

                UIColor(white: 0.78, alpha: 1).setStroke()
                context.cgContext.setLineWidth(1)
                for i in stride(from: 100, through: 900, by: 100) {
                    context.cgContext.move(to: CGPoint(x: CGFloat(i), y: 0))
                    context.cgContext.addLine(to: CGPoint(x: CGFloat(i), y: 1000))
                    context.cgContext.move(to: CGPoint(x: 0, y: CGFloat(i)))
                    context.cgContext.addLine(to: CGPoint(x: 1000, y: CGFloat(i)))
                }
                context.cgContext.strokePath()

                let text = title + "\nBlank/vector-only offline map\n"
                    + String(format: "Lat %.5f to %.5f\nLon %.5f to %.5f", extent.minLatitude, extent.maxLatitude, extent.minLongitude, extent.maxLongitude)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                    .foregroundColor: UIColor.darkGray
                ]
                text.draw(in: CGRect(x: 40, y: 40, width: 920, height: 140), withAttributes: attributes)
            }

            pdfDocument = PDFDocument(url: url)
            currentMapURL = url.standardizedFileURL
            georef = GeoReference.fromExtent(
                minLatitude: extent.minLatitude,
                maxLatitude: extent.maxLatitude,
                minLongitude: extent.minLongitude,
                maxLongitude: extent.maxLongitude
            )
            elevationGrid = ElevationGridStore.load(forMapNamed: url.lastPathComponent)
            importMessage = "Blank offline map created from GPS/download extent. Downloaded OSM vector layers will draw on it."
            followMode = .free
            registerCurrentMapInLayerStackIfPossible(
                name: title,
                kind: .osmVectors,
                group: .downloadedOfflineMaps,
                offlineStatus: .downloaded,
                sourceDescription: "Blank/vector-only offline map with downloaded OSM vectors"
            )
        } catch {
            toolMessage = "Could not create offline map page: \(error.localizedDescription)"
        }
    }

    private func copyPDFIntoAppStorage(from sourceURL: URL) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let mapsFolder = documents.appendingPathComponent("ImportedMaps", isDirectory: true)
        try FileManager.default.createDirectory(at: mapsFolder, withIntermediateDirectories: true)

        let safeName = sourceURL.lastPathComponent.isEmpty ? "ImportedMap.pdf" : sourceURL.lastPathComponent
        let destinationURL = mapsFolder.appendingPathComponent(safeName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    @MainActor
    private func clearCurrentMapAfterDeleted() {
        pdfDocument = nil
        georef = nil
        currentMapURL = nil
        elevationGrid = nil
        followMode = .free
        mapTool = .navigate
        measurePoints.removeAll()
        polygonPoints.removeAll()
        bearingLine.removeAll()
        bearingLineDegrees = nil
        selectedLayerID = nil
        selectedVertexIndex = nil
        originalLayerBeforeVertexEdit = nil
        hasUnsavedVertexEdits = false
        importMessage = "The currently open offline map was deleted. Import or create another map to continue."
        toolMessage = "Offline map deleted. Saved feature layers remain in Layers until you delete them there."
    }

    // MARK: - Collection mode (points, lines, polygons)

    /// Dedicated bottom bar while a drawing tool is active: add a vertex
    /// at the GPS position or at the screen-center crosshair, alongside
    /// tapping the map directly.
    private var collectBottomBar: some View {
        AnyView(
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    addVertexAtGPS()
                } label: {
                    Label("Add @ GPS\(gpsActionSuffix)", systemImage: "location.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(location.currentLocation == nil)

                Button {
                    addVertexAtCrosshair()
                } label: {
                    Label("Add @ Crosshair", systemImage: "plus.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                if mapTool == .measure || mapTool == .polygon {
                    Button {
                        autoVertexEnabled.toggle()
                        if autoVertexEnabled && planningOffMap {
                            toolMessage = "Walk-to-draw ON, but your GPS is OFF this map - walked vertices will land at your real position, not on this map. Use taps or the crosshair to draw here."
                        } else {
                            toolMessage = autoVertexEnabled
                                ? "Walk-to-draw ON: GPS adds a vertex as you move. Tap Walk again to pause and place points manually."
                                : "Walk-to-draw off. Add points by tap, GPS, or crosshair."
                        }
                    } label: {
                        Label("Walk", systemImage: "figure.walk")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(autoVertexEnabled ? Color.brandAmber : .gray)
                    .disabled(location.currentLocation == nil)
                }
            }

            HStack(spacing: 8) {
                if mapTool != .point {
                    Button("Undo") {
                        undoLastMapPoint()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canUndoMapPoint)

                    Button("Clear") {
                        measurePoints.removeAll()
                        polygonPoints.removeAll()
                        toolMessage = "Current tool geometry cleared."
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canUndoMapPoint)

                    Button("Save…") {
                        saveCurrentCollection()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!canSaveCurrentCollection)

                    Button("Units") {
                        showingMeasurementUnits = true
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Done") {
                    mapTool = .navigate
                    autoVertexEnabled = false
                    toolMessage = "Tool off. Pan and zoom freely; tap a saved feature to view or edit it."
                }
                .buttonStyle(.bordered)
            }

            Text(collectHeaderText)
                .font(.caption.monospacedDigit())
                .lineLimit(2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        )
    }

    private var collectHeaderText: String {
        switch mapTool {
        case .measure:
            if let previewDistance = liveMeasurePreviewDistanceMeters,
               let previewBearing = liveMeasurePreviewBearingDegrees {
                return "Line: \(measurePoints.count) pts + crosshair | total \(formatDistance(totalMeasureDistanceMeters + previewDistance)) | segment \(formatDistance(previewDistance)) @ \(formatBearing(previewBearing))"
            }
            return "Line: \(measurePoints.count) pts | \(formatDistance(totalMeasureDistanceMeters)) | bearing \(formatBearing(currentMeasureBearingDegrees))"
        case .polygon:
            if let preview = liveMeasurementPreviewCoordinate,
               !polygonPoints.isEmpty {
                let previewArea = MeasurementMath.areaSquareMeters(for: polygonPoints + [preview])
                return "Polygon: \(polygonPoints.count) pts + crosshair | \(formatArea(previewArea))"
            }
            return "Polygon: \(polygonPoints.count) pts | \(formatArea(polygonAreaSquareMeters))"
        case .point:
            return "Point: tap the map or use the Add buttons. Each point opens its attribute form."
        case .navigate:
            return ""
        }
    }

    private func addVertexAtGPS() {
        let warnOffMap = planningOffMap
        recordGPSCoordinate { coordinate, stats in
            if mapTool == .point {
                createPendingPoint(
                    at: coordinate,
                    name: "Point \(layerStore.layers.count + 1)",
                    gpsDerived: true,
                    stats: stats
                )
            } else {
                handleMapTap(coordinate)
                if warnOffMap {
                    toolMessage = "Vertex added at your real GPS position, which is OFF this map. Use map taps or Add @ Crosshair to draw on this map."
                }
            }
        }
    }

    private func addVertexAtCrosshair() {
        guard let coordinate = mapProxy.centerCoordinate() else {
            toolMessage = "Crosshair is outside the map extent."
            return
        }
        handleMapTap(coordinate)
    }

    private var canSaveCurrentCollection: Bool {
        switch mapTool {
        case .measure:
            return measurePoints.count >= 2
        case .polygon:
            return polygonPoints.count >= 3
        default:
            return false
        }
    }

    private func saveCurrentCollection() {
        switch mapTool {
        case .measure:
            beginSave(
                kind: .measure,
                defaultName: "Line \(layerStore.layers.count + 1)",
                coordinates: measurePoints,
                clearTool: .measure
            )
        case .polygon:
            beginSave(
                kind: .polygon,
                defaultName: "Polygon \(layerStore.layers.count + 1)",
                coordinates: polygonPoints,
                clearTool: .polygon
            )
        default:
            break
        }
    }

    // MARK: - Tools and map following

    /// The map's on-screen rotation: heading-driven in oriented mode,
    /// otherwise whatever the user has twisted it to.
    private var effectiveMapRotationDegrees: Double {
        if followMode == .oriented {
            return -(compass.continuousHeadingDegrees ?? 0)
        }
        return manualMapRotationDegrees
    }

    private func toolButton(_ tool: MapTool, label: String) -> some View {
        Button(label) {
            toggleTool(tool)
        }
        .buttonStyle(.borderedProminent)
        .tint(mapTool == tool ? .blue : .gray)
        .disabled(georef == nil)
    }

    /// Menu row for the Collect drop-down: shows a checkmark when the
    /// tool is active; tapping toggles it like the old buttons did.
    private func collectMenuButton(_ tool: MapTool, label: String, icon: String) -> some View {
        Button {
            toggleTool(tool)
        } label: {
            Label(label, systemImage: mapTool == tool ? "checkmark" : icon)
        }
    }

    /// Drop a point at the screen-center crosshair, opening the
    /// attribute form, without needing a tool active.
    private func dropPointAtCrosshair() {
        guard let coordinate = mapProxy.centerCoordinate() else {
            toolMessage = "Crosshair is outside the map extent."
            return
        }
        createPendingPoint(
            at: coordinate,
            name: "Point \(layerStore.layers.count + 1)",
            gpsDerived: false,
            stats: nil
        )
    }

    private func toggleTool(_ tool: MapTool) {
        if mapTool == tool {
            mapTool = .navigate
            autoVertexEnabled = false
            toolMessage = "Tool off. Pan and zoom freely; tap a saved feature to view or edit it."
        } else {
            selectedLayerID = nil
            selectedVertexIndex = nil
            mapTool = tool
            if followMode == .oriented {
                // Drawing on a rotating map is disorienting; drop to north-up follow.
                followMode = .centered
                manualMapRotationDegrees = 0
            }
            updateToolMessage(for: tool)
        }
    }

    // MARK: - Walk Transect monitoring

    /// Cross-track offset to the active (most recent) bearing segment.
    private var transectCrossTrackMeters: Double? {
        guard bearingLine.count >= 2,
              let coordinate = location.currentLocation?.coordinate else { return nil }
        return MeasurementMath.crossTrackDistanceMeters(
            lineStart: bearingLine[bearingLine.count - 2],
            lineEnd: bearingLine[bearingLine.count - 1],
            point: coordinate
        )
    }

    private var transectHUDColor: Color {
        guard let crossTrack = transectCrossTrackMeters else { return Color(white: 0.25) }
        return abs(crossTrack) > transectAlertDistance
            ? Color(red: 0.72, green: 0.05, blue: 0.05)
            : Color(red: 0.0, green: 0.45, blue: 0.17)
    }

    /// Banner over the map: ON/OFF LINE, offset, and which way to correct.
    /// The map stays visible underneath so the bearing line itself, the
    /// GPS dot, and the terrain remain in view.
    private var transectHUD: some View {
        VStack(spacing: 4) {
            if let crossTrack = transectCrossTrackMeters {
                let off = abs(crossTrack) > transectAlertDistance

                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(off ? "OFF LINE" : "ON LINE")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                    Text(formatDistance(abs(crossTrack)))
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

                if abs(crossTrack) >= 1 {
                    HStack(spacing: 10) {
                        if crossTrack > 0 {
                            Image(systemName: "arrow.left")
                            Text("MOVE LEFT")
                        } else {
                            Text("MOVE RIGHT")
                            Image(systemName: "arrow.right")
                        }
                    }
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                } else {
                    Text("HOLD THIS LINE")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                }

                Text(transectDetailText)
                    .font(.footnote.monospacedDigit().bold())
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("WAITING FOR GPS")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal)
        .background(transectHUDColor)
        .animation(.easeInOut(duration: 0.3), value: transectHUDColor)
    }

    /// Minimal controls while walking: record finds, manage the track, exit.
    private var transectBottomBar: some View {
        AnyView(
        HStack(spacing: 8) {
            Button(location.isRecording ? "Stop Track" : "Track") {
                toggleTrackRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(location.isRecording ? .red : .green)

            Button("Drop Point…") {
                dropPointAtCurrentLocation()
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(location.currentLocation == nil)

            Spacer()

            Button("Exit Transect") {
                transectModeActive = false
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        )
    }

    private var transectDetailText: String {
        guard bearingLine.count >= 2,
              let coordinate = location.currentLocation?.coordinate else { return "" }

        let start = bearingLine[bearingLine.count - 2]
        let end = bearingLine[bearingLine.count - 1]
        let alongTrack = MeasurementMath.alongTrackDistanceMeters(
            lineStart: start,
            lineEnd: end,
            point: coordinate
        )
        let segmentLength = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let remaining = max(0, segmentLength - alongTrack)

        var text = formatDistance(max(0, alongTrack)) + " along | " + formatDistance(remaining) + " to end"

        if let target = bearingLineDegrees, let heading = compass.trueHeadingDegrees {
            let turn = MeasurementMath.normalizedAngle180(target - heading)
            text += String(format: " | turn %@ %.0f", turn >= 0 ? "R" : "L", abs(turn))
        }

        if let accuracy = location.currentLocation?.horizontalAccuracy, accuracy >= 0 {
            text += " | GPS " + formatAccuracy(accuracy)
        }

        return text
    }

    private func clearBearingLine() {
        bearingLine.removeAll()
        bearingLineDegrees = nil
        walkTransectEnabled = false
        isOffTransect = false
        transectModeActive = false
        transectArrayLines.removeAll()
        toolMessage = "Bearing line cleared."
    }

    // MARK: - Transect array

    private func applyTransectArray(_ lines: [[CLLocationCoordinate2D]], spacing: Double) {
        transectArrayLines = lines
        coverageWidthMeters = spacing
        showCoverage = true
        selectTransect(0)
        toolMessage = "Transect array created: \(lines.count) lines at \(Int(spacing)) m spacing. Record your Track to see walked coverage."
    }

    private var currentCustomBufferLabel: String {
        UnitFormat.distance(coverageWidthMeters, units: distanceUnits) + " (custom)"
    }

    /// Save the current GPS track's coverage corridor as a polygon layer
    /// (exportable like any other feature).
    private func saveTrackBufferPolygon() {
        let coordinates = MeasurementMath.bufferPolygon(
            around: location.track.map { $0.coordinate },
            widthMeters: coverageWidthMeters
        )
        guard coordinates.count >= 3 else {
            toolMessage = "Track is too short to buffer."
            return
        }
        beginSave(
            kind: .polygon,
            defaultName: "Track Buffer " + UnitFormat.distance(coverageWidthMeters, units: distanceUnits),
            coordinates: coordinates,
            clearTool: nil,
            extraFields: [
                FeatureField(key: "buffer_width_m", value: String(format: "%.1f", coverageWidthMeters)),
                FeatureField(key: "buffer_source", value: "gps_track")
            ]
        )
    }

    /// Buffer a saved line/track into a new polygon layer at the current
    /// buffer width (from the Layers list long-press menu).
    private func bufferSavedLayer(_ layer: MapLayer) {
        let coordinates = MeasurementMath.bufferPolygon(
            around: layer.clCoordinates,
            widthMeters: coverageWidthMeters
        )
        guard coordinates.count >= 3 else {
            toolMessage = "\(layer.name) is too short to buffer."
            return
        }
        var fields = autoMetadataFields(coordinate: nil, gpsDerived: false, stats: nil)
        fields.append(FeatureField(key: "buffer_width_m", value: String(format: "%.1f", coverageWidthMeters)))
        fields.append(FeatureField(key: "buffer_source", value: layer.name))
        layerStore.add(MapLayer(
            name: "\(layer.name) Buffer",
            kind: .polygon,
            coordinates: coordinates.map { LayerCoordinate($0) },
            fields: fields,
            color: layer.effectiveColor,
            group: layer.group,
            fillOpacity: 0.18
        ))
        toolMessage = "Saved \(layer.name) buffer (" + UnitFormat.distance(coverageWidthMeters, units: distanceUnits) + " wide) as a polygon."
    }

    private func beginBufferForFeature(_ featureID: UUID) {
        guard let layer = layerStore.layers.first(where: { $0.id == featureID }),
              layer.kind == .measure || layer.kind == .track else {
            toolMessage = "Select a saved line or track to buffer."
            return
        }
        bufferFeatureRequest = FeatureBufferRequest(layer: layer)
    }

    private func createBufferFromFeature(
        _ layer: MapLayer,
        widthMeters: Double,
        exportMode: FeatureBufferExportMode
    ) {
        let coordinates = MeasurementMath.bufferPolygon(
            around: layer.clCoordinates,
            widthMeters: widthMeters
        )
        guard coordinates.count >= 3 else {
            toolMessage = "\(layer.name) is too short to buffer."
            return
        }

        var fields = autoMetadataFields(coordinate: nil, gpsDerived: false, stats: nil)
        fields.append(FeatureField(key: "buffer_width_m", value: String(format: "%.1f", widthMeters)))
        fields.append(FeatureField(key: "buffer_source", value: layer.name))
        fields.append(FeatureField(key: "buffer_source_id", value: layer.id.uuidString))
        fields.append(FeatureField(key: "buffer_created_from", value: layer.kind.displayName))

        let bufferLayer = MapLayer(
            name: "\(layer.name) Buffer \(UnitFormat.distance(widthMeters, units: distanceUnits))",
            kind: .polygon,
            coordinates: coordinates.map { LayerCoordinate($0) },
            notes: "Buffer polygon generated from \(layer.name) at \(UnitFormat.distance(widthMeters, units: distanceUnits)) total corridor width.",
            fields: fields,
            color: layer.effectiveColor,
            group: layer.group.isEmpty ? "Buffers" : layer.group,
            fillOpacity: 0.18
        )

        layerStore.add(bufferLayer)
        selectedLayerID = bufferLayer.id
        toolMessage = "Saved buffer polygon for \(layer.name) at \(UnitFormat.distance(widthMeters, units: distanceUnits)) wide."

        switch exportMode {
        case .none:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                viewingSavedLayer = bufferLayer
            }
        case .sourceKML:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                exportText(LayerKMLExporter.kml(layers: [layer]), filePrefix: "SourceLine", fileExtension: "kml")
            }
        case .bufferKML:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                exportText(LayerKMLExporter.kml(layers: [bufferLayer]), filePrefix: "BufferedLine", fileExtension: "kml")
            }
        case .sourceAndBufferKML:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                exportText(LayerKMLExporter.kml(layers: [layer, bufferLayer]), filePrefix: "LineAndBuffer", fileExtension: "kml")
            }
        }
    }

    private func beginTransectArrayForFeature(_ featureID: UUID) {
        guard let layer = layerStore.layers.first(where: { $0.id == featureID }),
              layer.kind == .measure || layer.kind == .track else {
            toolMessage = "Select a saved line or track to create a transect array."
            return
        }
        guard layer.clCoordinates.count >= 2 else {
            toolMessage = "\(layer.name) needs at least two vertices to create a transect array."
            return
        }
        transectArrayFeatureRequest = TransectArrayFromLayerRequest(layer: layer)
    }

    private func saveTransectArrayLayers(_ newLayers: [MapLayer], exportKML: Bool) {
        guard !newLayers.isEmpty else { return }

        // Save every generated transect as a normal visible map layer first.
        // The optional KML export happens afterward, so the user always sees
        // the full array on the map even when they choose to share it.
        let visibleLayers = newLayers.map { original -> MapLayer in
            var copy = original
            copy.isVisible = true
            return copy
        }

        for layer in visibleLayers {
            layerStore.add(layer)
        }

        transectArrayLines = visibleLayers.map { $0.clCoordinates }
        activeTransectIndex = 0
        selectedVertexIndex = nil
        originalLayerBeforeVertexEdit = nil
        hasUnsavedVertexEdits = false

        if let first = visibleLayers.first {
            selectedLayerID = first.id
            selectTransect(0)
        }

        let groupName = visibleLayers.first?.group.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groupText = groupName.isEmpty ? "" : " in group “\(groupName)”"
        toolMessage = "Saved \(visibleLayers.count) transect array line\(visibleLayers.count == 1 ? "" : "s") to the map\(groupText). Use Layers or tap a transect to export the whole array later."

        if exportKML {
            // Delay just long enough for SwiftUI to dismiss the creation sheet
            // and redraw the new visible layers before the share sheet opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                exportText(LayerKMLExporter.kml(layers: visibleLayers), filePrefix: "TransectArray", fileExtension: "kml")
            }
        }
    }


    private func exportTransectArrayForFeature(_ featureID: UUID) {
        guard let selected = layerStore.layers.first(where: { $0.id == featureID }) else { return }

        let sourceID = selected.transectArraySourceID
        let selectedGroup = selected.group.trimmingCharacters(in: .whitespacesAndNewlines)
        let arrayLayers = layerStore.layers.filter { layer in
            if let sourceID = sourceID, layer.transectArraySourceID == sourceID {
                return true
            }
            if !selectedGroup.isEmpty,
               layer.group.trimmingCharacters(in: .whitespacesAndNewlines) == selectedGroup,
               layer.isTransectArrayMember {
                return true
            }
            return layer.id == featureID
        }
        .sorted { lhs, rhs in
            let leftIndex = Int(lhs.fields.first { $0.key == "transect_index" }?.value ?? "") ?? Int.max
            let rightIndex = Int(rhs.fields.first { $0.key == "transect_index" }?.value ?? "") ?? Int.max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        guard !arrayLayers.isEmpty else {
            toolMessage = "No transect array layers were found to export."
            return
        }
        exportText(LayerKMLExporter.kml(layers: arrayLayers), filePrefix: "TransectArray", fileExtension: "kml")
        toolMessage = "Exporting \(arrayLayers.count) transect array line\(arrayLayers.count == 1 ? "" : "s") as KML for sharing."
    }

    private func exportFeature(_ featureID: UUID, format: LayerExportFormat) {
        guard let layer = layerStore.layers.first(where: { $0.id == featureID }) else { return }
        switch format {
        case .geojson:
            guard let text = GeoJSONExporter.featureCollection(layers: [layer]) else {
                importMessage = "GeoJSON export failed."
                return
            }
            exportText(text, filePrefix: "Feature", fileExtension: "geojson")
        case .kml:
            exportText(LayerKMLExporter.kml(layers: [layer]), filePrefix: "Feature", fileExtension: "kml")
        }
    }

    private func deleteFeatureFromInfo(_ featureID: UUID) {
        guard let layer = layerStore.layers.first(where: { $0.id == featureID }) else { return }
        layerStore.remove(id: featureID)
        viewingSavedLayer = nil
        if selectedLayerID == featureID {
            selectedLayerID = nil
            selectedVertexIndex = nil
            originalLayerBeforeVertexEdit = nil
            hasUnsavedVertexEdits = false
        }
        toolMessage = "Deleted feature: \(layer.name)."
    }

    /// Walk-to-draw: stream GPS positions in as vertices of the active
    /// line or polygon. Toggled from the collection bar; respects the
    /// track distance cadence setting (minimum 1 m).
    private func appendWalkVertexIfNeeded(_ newLocation: CLLocation?) {
        guard autoVertexEnabled,
              mapTool == .measure || mapTool == .polygon,
              let newLocation = newLocation,
              newLocation.horizontalAccuracy >= 0,
              newLocation.horizontalAccuracy <= 25 else { return }

        let storedDistance = UserDefaults.standard.double(forKey: "trackFilterDistance")
        let spacing = max(1.0, storedDistance > 0 ? storedDistance : 2.0)

        let existing = mapTool == .measure ? measurePoints : polygonPoints
        if let last = existing.last {
            let lastLocation = CLLocation(latitude: last.latitude, longitude: last.longitude)
            guard newLocation.distance(from: lastLocation) >= spacing else { return }
        }
        handleMapTap(newLocation.coordinate)
    }

    /// Open the Layers list with a hint; swipe a line right and tap
    /// Walk to use it as the active transect.
    private func walkSavedLinePrompt() {
        toolMessage = "Swipe a line or track to the right in the list and tap Walk."
        showingLayerList = true
    }

    /// Use a saved line/track as the active transect (endpoints define
    /// the guidance line) and a saved point as a navigation target.
    private func walkSavedLayer(_ layer: MapLayer) {
        let coordinates = layer.clCoordinates
        showingLayerList = false

        switch layer.kind {
        case .measure, .track, .polygon:
            guard let first = coordinates.first, let last = coordinates.last, coordinates.count >= 2 else { return }
            bearingLine = [first, last]
            bearingLineDegrees = MeasurementMath.bearingDegrees(from: first, to: last)
            transectArrayLines.removeAll()
            var message = String(format: "Walking %@ | bearing %.1f deg", layer.name, bearingLineDegrees ?? 0)
            if coordinates.count > 2 {
                message += " (straight line between endpoints)"
            }
            toolMessage = message
        case .point:
            guard let target = coordinates.first,
                  let here = location.currentLocation?.coordinate else {
                toolMessage = "Waiting for GPS to navigate."
                return
            }
            bearingLine = [here, target]
            bearingLineDegrees = MeasurementMath.bearingDegrees(from: here, to: target)
            transectArrayLines.removeAll()
            if followMode == .free { followMode = .centered }
            let distance = MeasurementMath.totalDistanceMeters(for: [here, target])
            toolMessage = "Navigate to \(layer.name): " + formatDistance(distance)
                + String(format: " at %.0f deg", bearingLineDegrees ?? 0)
        }
    }

    private func selectTransect(_ index: Int) {
        guard !transectArrayLines.isEmpty else { return }
        let clamped = max(0, min(index, transectArrayLines.count - 1))
        activeTransectIndex = clamped
        let line = transectArrayLines[clamped]
        bearingLine = line
        bearingLineDegrees = MeasurementMath.bearingDegrees(from: line[0], to: line[1])
        toolMessage = String(
            format: "Transect %d of %d | bearing %.1f deg",
            clamped + 1,
            transectArrayLines.count,
            bearingLineDegrees ?? 0
        )
    }

    /// Reverse the active transect so guidance matches a return leg.
    private func flipActiveTransect() {
        if !transectArrayLines.isEmpty {
            transectArrayLines[activeTransectIndex].reverse()
            bearingLine = transectArrayLines[activeTransectIndex]
        } else if bearingLine.count >= 2 {
            bearingLine.reverse()
        } else {
            return
        }
        if bearingLine.count >= 2 {
            bearingLineDegrees = MeasurementMath.bearingDegrees(
                from: bearingLine[bearingLine.count - 2],
                to: bearingLine[bearingLine.count - 1]
            )
            toolMessage = String(format: "Transect direction flipped. Bearing %.1f deg.", bearingLineDegrees ?? 0)
        }
    }

    private func saveTransectArrayLayers() {
        for (index, line) in transectArrayLines.enumerated() {
            var fields = autoMetadataFields(coordinate: nil, gpsDerived: false, stats: nil)
            fields.append(FeatureField(
                key: "bearing_deg",
                value: String(format: "%.1f", MeasurementMath.bearingDegrees(from: line[0], to: line[1]))
            ))
            layerStore.add(MapLayer(
                name: "Transect \(index + 1)",
                kind: .measure,
                coordinates: line.map { LayerCoordinate($0) },
                fields: fields,
                color: .orange
            ))
        }
        toolMessage = "Saved \(transectArrayLines.count) transects as layers."
    }

    private func clearTransectArray() {
        transectArrayLines.removeAll()
        toolMessage = "Transect array cleared."
    }

    /// Checks each GPS fix against the active bearing line and vibrates
    /// when the user drifts farther than the alert distance off the
    /// transect. Re-buzzes every few seconds while off line, and gives a
    /// light confirmation tap on returning.
    private func checkTransect(_ newLocation: CLLocation?) {
        guard walkTransectEnabled,
              bearingLine.count >= 2,
              let newLocation = newLocation,
              newLocation.horizontalAccuracy >= 0,
              newLocation.horizontalAccuracy <= 25 else { return }

        let crossTrack = abs(MeasurementMath.crossTrackDistanceMeters(
            lineStart: bearingLine[bearingLine.count - 2],
            lineEnd: bearingLine[bearingLine.count - 1],
            point: newLocation.coordinate
        ))

        if crossTrack > transectAlertDistance {
            // Alert on first crossing, then every 5 seconds while off line.
            if !isOffTransect || Date().timeIntervalSince(lastTransectAlert) > 5 {
                isOffTransect = true
                lastTransectAlert = Date()
                TransectAlert.shared.offLine(style: transectAlertStyle)
            }
        } else if isOffTransect, crossTrack < transectAlertDistance * 0.6 {
            // Hysteresis: only declare back-on-line once well inside the
            // threshold, so GPS noise at the boundary doesn't flap.
            isOffTransect = false
            TransectAlert.shared.backOnLine(style: transectAlertStyle)
        }
    }

    /// Compass badge cycles: free pan -> follow GPS -> follow + rotate to heading -> free pan.
    private func handleBearingButtonTap() {
        guard let georef = georef, let currentLocation = location.currentLocation else { return }

        switch followMode {
        case .free:
            followMode = .centered
            manualMapRotationDegrees = 0
            recenterMapOnCurrentGPS(georef: georef, coordinate: currentLocation.coordinate)
            toolMessage = "Following GPS, north-up. Tap the badge again to rotate the map to your heading."
        case .centered:
            followMode = .oriented
            recenterMapOnCurrentGPS(georef: georef, coordinate: currentLocation.coordinate)
            toolMessage = "Map rotates to match your heading. Tap the badge again for free panning."
        case .oriented:
            followMode = .free
            manualMapRotationDegrees = 0
            toolMessage = "Free pan, reset to north-up. Two-finger twist rotates the map by hand."
        }
    }

    private func recenterMapOnCurrentGPS(georef: GeoReference, coordinate: CLLocationCoordinate2D) {
        DispatchQueue.main.async {
            mapProxy.centerOnCoordinate(coordinate, georef: georef)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                mapProxy.centerOnCoordinate(coordinate, georef: georef)
            }
        }
    }

    // MARK: - Export

    private func exportTrack(as type: ExportType) {
        let text: String
        let extensionName: String

        switch type {
        case .gpx:
            text = TrackExporter.gpx(locations: location.track, name: "Field Track")
            extensionName = "gpx"
        case .kml:
            text = TrackExporter.kml(locations: location.track, name: "Field Track")
            extensionName = "kml"
        }

        exportText(text, filePrefix: "FieldTrack", fileExtension: extensionName)
    }

    private func exportSavedLayers() {
        guard !layerStore.layers.isEmpty else { return }
        let text = LayerKMLExporter.kml(layers: layerStore.layers)
        exportText(text, filePrefix: "SavedMapLayers", fileExtension: "kml")
    }

    private func exportSavedLayersGeoJSON() {
        guard !layerStore.layers.isEmpty,
              let text = GeoJSONExporter.featureCollection(layers: layerStore.layers) else {
            importMessage = "GeoJSON export failed."
            return
        }
        exportText(text, filePrefix: "SavedMapLayers", fileExtension: "geojson")
    }

    /// Export a chosen subset of layers in the chosen format.
    private func exportLayers(_ layers: [MapLayer], format: LayerExportFormat) {
        guard !layers.isEmpty else { return }
        switch format {
        case .geojson:
            guard let text = GeoJSONExporter.featureCollection(layers: layers) else {
                importMessage = "GeoJSON export failed."
                return
            }
            exportText(text, filePrefix: "SurveyLayers", fileExtension: "geojson")
        case .kml:
            exportText(LayerKMLExporter.kml(layers: layers), filePrefix: "SurveyLayers", fileExtension: "kml")
        }
    }

    private func exportText(_ text: String, filePrefix: String, fileExtension: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filePrefix)-\(Int(Date().timeIntervalSince1970)).\(fileExtension)")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportFileURL = url
            showingExporter = true
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - DPR 523 forms

    private func openDPRForms(layerID: UUID?) {
        dprFormsContextLayerID = layerID
        showingDPRForms = true
    }

    private func exportDPRForm(_ form: DPRFormRecord, format: DPRFormExportFormat) {
        let linkedLayer = form.linkedLayerID.flatMap { id in
            layerStore.layers.first(where: { $0.id == id })
        }
        do {
            switch format {
            case .pdf:
                exportFileURL = try DPRFormDocumentExporter.exportPDF(form: form, linkedLayer: linkedLayer)
            case .word:
                exportFileURL = try DPRFormDocumentExporter.exportWordCompatibleDocument(form: form, linkedLayer: linkedLayer)
            }
            showingExporter = true
            toolMessage = "Exporting \(form.kind.shortCode) form: \(form.resourceNameOrUntitled)."
        } catch {
            importMessage = "DPR form export failed: \(error.localizedDescription)"
        }
    }

    private func exportDPRPacket(for layerID: UUID) {
        let forms = dprFormStore.forms(for: layerID)
        guard !forms.isEmpty else {
            toolMessage = "No DPR forms are attached to this feature yet."
            return
        }
        let linkedLayer = layerStore.layers.first(where: { $0.id == layerID })
        do {
            exportFileURL = try DPRFormDocumentExporter.exportPDFPacket(forms: forms, linkedLayer: linkedLayer)
            showingExporter = true
            toolMessage = "Exporting DPR form packet with \(forms.count) form\(forms.count == 1 ? "" : "s")."
        } catch {
            importMessage = "DPR packet export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Tool geometry

    private var canUndoMapPoint: Bool {
        switch mapTool {
        case .navigate, .point:
            return false
        case .measure:
            return !measurePoints.isEmpty
        case .polygon:
            return !polygonPoints.isEmpty
        }
    }

    private var totalMeasureDistanceMeters: CLLocationDistance {
        guard measurePoints.count > 1 else { return 0 }
        return zip(measurePoints.dropLast(), measurePoints.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    private var polygonAreaSquareMeters: Double {
        MeasurementMath.areaSquareMeters(for: polygonPoints)
    }

    private var currentMeasureBearingDegrees: Double? {
        MeasurementMath.finalSegmentBearingDegrees(for: measurePoints)
    }

    /// Live endpoint used for the rubber-band measurement preview.
    /// The map overlay draws from the last placed vertex to the screen
    /// crosshair and updates the distance/bearing as the map moves.
    private var liveMeasurementPreviewCoordinate: CLLocationCoordinate2D? {
        guard let coordinate = crosshairCoordinate else { return nil }
        switch mapTool {
        case .measure:
            return measurePoints.isEmpty ? nil : coordinate
        case .polygon:
            return polygonPoints.isEmpty ? nil : coordinate
        default:
            return nil
        }
    }

    private var liveMeasurePreviewDistanceMeters: CLLocationDistance? {
        guard mapTool == .measure,
              let last = measurePoints.last,
              let preview = liveMeasurementPreviewCoordinate else { return nil }
        return CLLocation(latitude: last.latitude, longitude: last.longitude)
            .distance(from: CLLocation(latitude: preview.latitude, longitude: preview.longitude))
    }

    private var liveMeasurePreviewBearingDegrees: Double? {
        guard mapTool == .measure,
              let last = measurePoints.last,
              let preview = liveMeasurementPreviewCoordinate else { return nil }
        return MeasurementMath.bearingDegrees(from: last, to: preview)
    }

    private func startQuickMeasureDistance() {
        finishVertexEditing(silent: true)
        mapTool = .measure
        measurePoints.removeAll()
        autoVertexEnabled = false
        toolMessage = "Quick distance measure: tap points, use GPS, or use crosshair. Units are currently \(distanceUnits.title)."
    }

    private func startQuickMeasureArea() {
        finishVertexEditing(silent: true)
        mapTool = .polygon
        polygonPoints.removeAll()
        autoVertexEnabled = false
        toolMessage = "Quick area measure: tap polygon vertices. Units are currently \(distanceUnits.title)."
    }

    private func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        if mapTool == .navigate, selectedLayerID != nil, selectedVertexIndex != nil {
            moveSelectedVertex(to: coordinate)
            return
        }

        switch mapTool {
        case .navigate:
            selectedLayerID = nil
            selectedVertexIndex = nil
            toolMessage = "No feature selected."
        case .measure:
            measurePoints.append(coordinate)
            toolMessage = "Line point \(measurePoints.count). Distance: \(formatDistance(totalMeasureDistanceMeters)). Bearing: \(formatBearing(currentMeasureBearingDegrees))."
        case .polygon:
            polygonPoints.append(coordinate)
            toolMessage = "Polygon point \(polygonPoints.count). Area: \(formatArea(polygonAreaSquareMeters))."
        case .point:
            createPendingPoint(
                at: coordinate,
                name: "Point \(layerStore.layers.count + 1)",
                gpsDerived: false,
                stats: nil
            )
        }
    }

    private func openFeatureInfo(_ id: UUID) {
        selectLayer(id)
        if let layer = layerStore.layers.first(where: { $0.id == id }) {
            viewingSavedLayer = layer
            toolMessage = "Selected \(layer.name). Feature info is open; choose Edit Attributes or Edit Geometry."
        }
    }

    private func beginGeometryEditing(_ id: UUID) {
        if selectedLayerID != id {
            originalLayerBeforeVertexEdit = nil
            hasUnsavedVertexEdits = false
        }
        selectedLayerID = id
        selectedVertexIndex = nil
        mapTool = .navigate
        if let layer = layerStore.layers.first(where: { $0.id == id }) {
            toolMessage = "Editing geometry for \(layer.name). Tap a vertex, then tap the map, GPS, or crosshair location to move it."
        }
    }

    private func selectLayer(_ id: UUID) {
        if selectedLayerID != id {
            originalLayerBeforeVertexEdit = nil
            hasUnsavedVertexEdits = false
        }
        selectedLayerID = id
        selectedVertexIndex = nil
        mapTool = .navigate
        if let layer = layerStore.layers.first(where: { $0.id == id }) {
            toolMessage = "Selected \(layer.name). Review feature info, or choose Edit Geometry to move vertices."
        }
    }

    private func selectVertex(layerID: UUID, vertexIndex: Int) {
        if selectedLayerID != layerID {
            originalLayerBeforeVertexEdit = nil
            hasUnsavedVertexEdits = false
        }
        selectedLayerID = layerID
        selectedVertexIndex = vertexIndex
        mapTool = .navigate
        toolMessage = "Vertex \(vertexIndex + 1) selected. Tap the map, GPS, or crosshair location to move it."
    }

    private func moveSelectedVertex(to coordinate: CLLocationCoordinate2D) {
        guard let layerID = selectedLayerID,
              let vertexIndex = selectedVertexIndex,
              var layer = layerStore.layers.first(where: { $0.id == layerID }),
              layer.coordinates.indices.contains(vertexIndex) else { return }

        if originalLayerBeforeVertexEdit == nil {
            originalLayerBeforeVertexEdit = layer
        }
        layer.coordinates[vertexIndex] = LayerCoordinate(coordinate)
        layerStore.update(layer)
        hasUnsavedVertexEdits = true
        toolMessage = "Moved vertex \(vertexIndex + 1) in \(layer.name). Tap Save Edit to finish or Cancel to restore."
    }

    private func saveVertexEditsAndFinish() {
        let name = selectedLayerID.flatMap { id in layerStore.layers.first(where: { $0.id == id })?.name } ?? "feature"
        selectedLayerID = nil
        selectedVertexIndex = nil
        originalLayerBeforeVertexEdit = nil
        hasUnsavedVertexEdits = false
        toolMessage = "Saved vertex edits for \(name)."
    }

    private func finishVertexEditing(silent: Bool = false) {
        selectedLayerID = nil
        selectedVertexIndex = nil
        originalLayerBeforeVertexEdit = nil
        hasUnsavedVertexEdits = false
        if !silent {
            toolMessage = "Finished editing. Vertices are hidden until you select a feature again."
        }
    }

    private func cancelVertexEdits() {
        if let original = originalLayerBeforeVertexEdit {
            layerStore.update(original)
            toolMessage = "Cancelled edits and restored \(original.name)."
        } else {
            toolMessage = "No unsaved vertex edits to cancel."
        }
        selectedLayerID = nil
        selectedVertexIndex = nil
        originalLayerBeforeVertexEdit = nil
        hasUnsavedVertexEdits = false
    }

    private func undoLastMapPoint() {
        switch mapTool {
        case .navigate, .point:
            break
        case .measure:
            _ = measurePoints.popLast()
            toolMessage = "Line point removed: \(measurePoints.count) left. Distance: \(formatDistance(totalMeasureDistanceMeters))."
        case .polygon:
            _ = polygonPoints.popLast()
            toolMessage = "Polygon point removed: \(polygonPoints.count) left. Area: \(formatArea(polygonAreaSquareMeters))."
        }
    }

    private func updateToolMessage(for tool: MapTool) {
        if georef == nil {
            toolMessage = "Tools need a georeferenced PDF or manual calibration."
            return
        }

        switch tool {
        case .navigate:
            toolMessage = "Tool off. Pan and zoom freely; tap a saved feature to view or edit it."
        case .measure:
            toolMessage = "Line: tap two or more points directly on the map."
        case .polygon:
            toolMessage = "Polygon: tap three or more points directly on the map."
        case .point:
            toolMessage = "Point: tap the map to place a point and fill in its attributes."
        }
    }

    // MARK: - Field recorder workflow

    private func beginFieldRecorderPoint(_ source: FieldRecordCoordinateSource) {
        let saveAt: (CLLocationCoordinate2D, GPSAverageResult?) -> Void = { coordinate, stats in
            var fields = autoMetadataFields(
                coordinate: coordinate,
                gpsDerived: source == .gps,
                stats: stats
            )
            fields.append(FeatureField(key: "feature_type", value: "Point"))
            fields.append(FeatureField(key: "record_source", value: source.rawValue))
            fields.append(FeatureField(key: "review_status", value: "unreviewed"))

            pendingClearTool = nil
            pendingLayer = MapLayer(
                name: "Point \(layerStore.layers.count + 1)",
                kind: .point,
                coordinates: [LayerCoordinate(coordinate)],
                notes: "",
                fields: fields,
                color: .blue,
                group: "Field Records"
            )
        }

        switch source {
        case .gps:
            recordGPSCoordinate(saveAt)
        case .crosshair:
            guard let coordinate = mapProxy.centerCoordinate() ?? crosshairCoordinate else {
                toolMessage = "Crosshair is outside the map extent."
                return
            }
            saveAt(coordinate, nil)
        }
    }

    private func beginFieldTemplatePoint(_ template: FieldQuickTemplate, source: FieldRecordCoordinateSource) {
        let saveAt: (CLLocationCoordinate2D, GPSAverageResult?) -> Void = { coordinate, stats in
            var fields = autoMetadataFields(
                coordinate: coordinate,
                gpsDerived: source == .gps,
                stats: stats
            )
            fields.append(contentsOf: template.defaultFields)
            fields.append(FeatureField(key: "field_template", value: template.title))
            fields.append(FeatureField(key: "record_source", value: source.rawValue))
            fields.append(FeatureField(key: "review_status", value: "needs_review"))

            pendingClearTool = nil
            pendingLayer = MapLayer(
                name: "\(template.title) \(layerStore.layers.count + 1)",
                kind: .point,
                coordinates: [LayerCoordinate(coordinate)],
                notes: template.defaultNote,
                fields: fields,
                color: template.color,
                group: "Field Records"
            )
        }

        switch source {
        case .gps:
            recordGPSCoordinate(saveAt)
        case .crosshair:
            guard let coordinate = mapProxy.centerCoordinate() ?? crosshairCoordinate else {
                toolMessage = "Crosshair is outside the map extent."
                return
            }
            saveAt(coordinate, nil)
        }
    }

    private func startFieldRecorderLine() {
        finishVertexEditing(silent: true)
        mapTool = .measure
        if measurePoints.isEmpty, let coordinate = mapProxy.centerCoordinate() ?? crosshairCoordinate {
            measurePoints = [coordinate]
            toolMessage = "Line started at the crosshair. Tap the map or use Add @ GPS/Crosshair to add vertices, then Save."
        } else {
            toolMessage = "Line tool active. Tap the map to add vertices, then Save."
        }
    }

    private func startFieldRecorderPolygon() {
        finishVertexEditing(silent: true)
        mapTool = .polygon
        if polygonPoints.isEmpty, let coordinate = mapProxy.centerCoordinate() ?? crosshairCoordinate {
            polygonPoints = [coordinate]
            toolMessage = "Polygon started at the crosshair. Walk or tap around the boundary, then Save."
        } else {
            toolMessage = "Polygon tool active. Tap the map to add boundary vertices, then Save."
        }
    }

    private func setTransectMissionStatus(_ layerID: UUID, status: TransectMissionStatus) {
        guard var layer = layerStore.layers.first(where: { $0.id == layerID }) else { return }
        layer.fields.removeAll { $0.key == "mission_status" || $0.key == "mission_status_utc" }
        layer.fields.append(FeatureField(key: "mission_status", value: status.rawValue))
        layer.fields.append(FeatureField(key: "mission_status_utc", value: ISO8601DateFormatter().string(from: Date())))
        layerStore.update(layer)
        toolMessage = "Marked \(layer.name) as \(status.title)."
    }

    private func exportLayerGroup(named groupName: String, prefix: String) {
        let layers = layerStore.layers
            .filter { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) == groupName }
            .sorted { lhs, rhs in
                let leftIndex = Int(lhs.fields.first { $0.key == "transect_index" }?.value ?? "") ?? Int.max
                let rightIndex = Int(rhs.fields.first { $0.key == "transect_index" }?.value ?? "") ?? Int.max
                if leftIndex != rightIndex { return leftIndex < rightIndex }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        guard !layers.isEmpty else {
            toolMessage = "No layers found in \(groupName)."
            return
        }
        exportText(LayerKMLExporter.kml(layers: layers), filePrefix: prefix, fileExtension: "kml")
        toolMessage = "Exporting \(layers.count) layer\(layers.count == 1 ? "" : "s") from \(groupName)."
    }

    private func exportCrewPackage(scope: CrewPackageExportScope, format: LayerExportFormat) {
        let layers: [MapLayer]
        switch scope {
        case .visibleLayers:
            layers = layerStore.layers.filter { $0.isVisible }
        case .createdToday:
            layers = layerStore.layers.filter { Calendar.current.isDateInToday($0.createdAt) && !$0.isImported }
        case .transectArrays:
            layers = layerStore.layers.filter { $0.isTransectArrayMember || $0.group.hasPrefix("Transect Array -") }
        case .allCreated:
            layers = layerStore.layers.filter { !$0.isImported }
        }

        guard !layers.isEmpty else {
            toolMessage = "No layers matched that crew package export."
            return
        }

        switch format {
        case .kml:
            exportText(LayerKMLExporter.kml(layers: layers), filePrefix: "CrewPackage", fileExtension: "kml")
        case .geojson:
            guard let text = GeoJSONExporter.featureCollection(layers: layers) else {
                toolMessage = "Crew package GeoJSON export failed."
                return
            }
            exportText(text, filePrefix: "CrewPackage", fileExtension: "geojson")
        }
        toolMessage = "Exporting crew package with \(layers.count) layer\(layers.count == 1 ? "" : "s")."
    }

    // MARK: - Formatting

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        UnitFormat.distance(meters, units: distanceUnits)
    }

    private func formatArea(_ squareMeters: Double) -> String {
        if squareMeters <= 0 {
            return "add at least 3 points"
        }
        return UnitFormat.area(squareMeters, units: distanceUnits)
    }

    private func formatBearing(_ degrees: Double?) -> String {
        guard let degrees = degrees else {
            return "add at least 2 points"
        }
        return String(format: "%.1f deg", degrees)
    }

    private func formatAccuracy(_ accuracy: CLLocationAccuracy?) -> String {
        guard let accuracy = accuracy, accuracy >= 0 else {
            return "unavailable"
        }
        return UnitFormat.accuracy(accuracy, units: distanceUnits)
    }

    private func formatAltitude(_ location: CLLocation) -> String {
        guard location.verticalAccuracy >= 0 else {
            return "unavailable"
        }
        return UnitFormat.distance(location.altitude, units: distanceUnits)
    }

    private func formatSpeed(_ speed: CLLocationSpeed) -> String {
        guard speed >= 0 else {
            return "unavailable"
        }
        return UnitFormat.speed(speed, units: distanceUnits)
    }

    private func gnssProviderMessage(for location: CLLocation?) -> String {
        guard let location = location, location.horizontalAccuracy >= 0 else {
            return preferExternalGNSS ? "External GNSS: waiting for fix" : "Internal GPS: waiting for fix"
        }

        if preferExternalGNSS {
            if location.horizontalAccuracy <= 1.0 {
                return "External GNSS: high-accuracy fix likely active"
            }
            return "External GNSS: connect receiver; iOS will use it automatically"
        }

        if location.horizontalAccuracy <= 1.0 {
            return "High-accuracy location active"
        }
        return "Internal iPhone GPS"
    }
}

enum ExportType {
    case gpx
    case kml
}

/// What the shared fileImporter is currently being used to import.
enum FileImportKind {
    case map
    case data
    case demTerrain
}

/// How the user wants to be alerted when off the transect.
enum TransectAlertStyle: String, CaseIterable {
    case vibrate
    case sound
    case both
}

/// Haptic, vibration, and sound alerts for the Walk Transect feature.
/// The alarm tone is synthesized in-app (no asset needed) and played
/// through the .playback audio session category, so it sounds at full
/// volume even when the ringer switch is on silent.
final class TransectAlert {
    static let shared = TransectAlert()

    private var alarmPlayer: AVAudioPlayer?

    private init() {}

    /// Strong alert when drifting past the allowed distance.
    func offLine(style: TransectAlertStyle) {
        if style == .vibrate || style == .both {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        if style == .sound || style == .both {
            playAlarm()
        }
    }

    /// Light confirmation when back within tolerance.
    func backOnLine(style: TransectAlertStyle) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func playAlarm() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.duckOthers])
            try session.setActive(true)

            if alarmPlayer == nil {
                alarmPlayer = try AVAudioPlayer(data: Self.alarmToneWAV, fileTypeHint: AVFileType.wav.rawValue)
                alarmPlayer?.volume = 1.0
                alarmPlayer?.prepareToPlay()
            }
            alarmPlayer?.currentTime = 0
            alarmPlayer?.play()
        } catch {
            // Fall back to vibration if audio is unavailable.
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    /// Three loud 1.6 kHz beeps, generated as a 16-bit mono WAV in memory.
    private static let alarmToneWAV: Data = makeAlarmToneWAV()

    private static func makeAlarmToneWAV() -> Data {
        let sampleRate = 44100.0
        let frequency = 1600.0
        let beepFrames = Int(sampleRate * 0.22)
        let gapFrames = Int(sampleRate * 0.12)
        let beepCount = 3
        let rampFrames = 350.0

        var samples: [Int16] = []
        samples.reserveCapacity((beepFrames + gapFrames) * beepCount)

        for beepIndex in 0..<beepCount {
            for frame in 0..<beepFrames {
                let time = Double(frame) / sampleRate
                // Short attack/decay envelope avoids clicks at beep edges.
                let envelope = min(1.0, Double(frame) / rampFrames, Double(beepFrames - frame) / rampFrames)
                let value = sin(2 * .pi * frequency * time) * envelope
                samples.append(Int16(value * 32000))
            }
            if beepIndex < beepCount - 1 {
                samples.append(contentsOf: [Int16](repeating: 0, count: gapFrames))
            }
        }

        var data = Data()

        func appendString(_ text: String) {
            data.append(text.data(using: .ascii) ?? Data())
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        let byteCount = samples.count * MemoryLayout<Int16>.size

        appendString("RIFF")
        appendUInt32(UInt32(36 + byteCount))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)                          // PCM chunk size
        appendUInt16(1)                           // PCM format
        appendUInt16(1)                           // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate) * 2)      // byte rate
        appendUInt16(2)                           // block align
        appendUInt16(16)                          // bits per sample
        appendString("data")
        appendUInt32(UInt32(byteCount))

        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }
}

/// How the map view follows the user, cycled by the compass badge.
enum MapFollowMode {
    /// User pans and zooms freely; map stays north-up.
    case free
    /// Map keeps the GPS position centered; north-up.
    case centered
    /// Map keeps GPS centered and rotates to match the phone's heading.
    case oriented
}

enum MapTool: String, CaseIterable, Identifiable {
    case navigate
    case measure
    case polygon
    case point

    var id: String { rawValue }

    var title: String {
        switch self {
        case .navigate:
            return "Nav"
        case .measure:
            return "Line"
        case .polygon:
            return "Poly"
        case .point:
            return "Point"
        }
    }
}

// MARK: - Layer model with attributes

enum MapLayerKind: String, Codable {
    case track
    case measure
    case polygon
    case point

    var kmlStyleID: String {
        switch self {
        case .track:
            return "gpsTrackStyle"
        case .measure:
            return "measureStyle"
        case .polygon:
            return "polygonStyle"
        case .point:
            return "pointStyle"
        }
    }

    var displayName: String {
        switch self {
        case .track:
            return "GPS Track"
        case .measure:
            return "Line"
        case .polygon:
            return "Polygon"
        case .point:
            return "Point"
        }
    }

    var systemImage: String {
        switch self {
        case .track:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .measure:
            return "ruler"
        case .polygon:
            return "skew"
        case .point:
            return "mappin.circle"
        }
    }
}

struct LayerCoordinate: Codable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// One user-defined attribute (key/value) on a feature. These become
/// attribute-table columns when the GeoJSON is loaded in QGIS or ArcGIS.
struct FeatureField: Identifiable, Codable, Equatable {
    var id = UUID()
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// Palette for color-coding features. Carried into map drawing,
/// KML styles, and a "color" hex property in GeoJSON.
enum LayerColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, brown, white

    var id: String { rawValue }

    var hexString: String {
        switch self {
        case .red: return "#FF3B30"
        case .orange: return "#FF9500"
        case .yellow: return "#FFCC00"
        case .green: return "#34C759"
        case .teal: return "#30B0C7"
        case .blue: return "#007AFF"
        case .purple: return "#AF52DE"
        case .pink: return "#FF2D55"
        case .brown: return "#A2845E"
        case .white: return "#FFFFFF"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .brown: return UIColor(red: 0.64, green: 0.52, blue: 0.37, alpha: 1)
        case .white: return .white
        }
    }

    var color: Color { Color(uiColor) }

    /// KML colors are aabbggrr.
    var kmlLineColor: String {
        let hex = hexString.dropFirst()
        let rr = hex.prefix(2)
        let gg = hex.dropFirst(2).prefix(2)
        let bb = hex.dropFirst(4).prefix(2)
        return "ff\(bb)\(gg)\(rr)".lowercased()
    }

    var kmlFillColor: String {
        "55" + kmlLineColor.dropFirst(2)
    }
}

enum PolygonFillStyle: String, Codable, CaseIterable, Identifiable {
    case solid
    case hatch
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: return "Solid"
        case .hatch: return "Hatched"
        case .none: return "Outline Only"
        }
    }
}

struct MapLayer: Identifiable, Codable {
    var id = UUID()
    var name: String
    var kind: MapLayerKind
    var coordinates: [LayerCoordinate]
    var notes: String = ""
    var fields: [FeatureField] = []
    var isVisible: Bool = true
    var createdAt: Date = Date()
    /// User-chosen color; nil means the default for the feature kind.
    var color: LayerColor?
    /// JPEG filenames in the app's LayerPhotos folder.
    var photoFilenames: [String] = []
    /// Optional group name for organizing the Layers list and exports.
    var group: String = ""
    /// Polygon fill color; nil means match the outline color.
    var fillColor: LayerColor?
    /// Polygon fill transparency (0 = invisible fill, 1 = solid).
    var fillOpacity: Double = 0.25
    /// Polygon fill rendering style.
    var fillStyle: PolygonFillStyle = .solid

    var clCoordinates: [CLLocationCoordinate2D] {
        coordinates.map { $0.coordinate }
    }

    /// True for features brought in from outside (downloaded layers,
    /// imported KML/GeoJSON), as opposed to features created in-app.
    /// Detected from the import metadata the importers stamp on.
    var isImported: Bool {
        fields.contains { field in
            field.key == "download_source" || field.key == "source_url" || field.key == "import_source"
        }
    }

    /// Fill color resolved against the outline default.
    var effectiveFillColor: LayerColor {
        fillColor ?? effectiveColor
    }

    var effectiveColor: LayerColor {
        if let color = color { return color }
        switch kind {
        case .track: return .red
        case .measure: return .yellow
        case .polygon: return .green
        case .point: return .purple
        }
    }

    /// Short human summary used in the layer list and editor.
    func geometrySummary(units: DistanceUnits) -> String {
        switch kind {
        case .track, .measure:
            let distance = MeasurementMath.totalDistanceMeters(for: clCoordinates)
            return "\(coordinates.count) pts, " + UnitFormat.distance(distance, units: units)
        case .polygon:
            let area = MeasurementMath.areaSquareMeters(for: clCoordinates)
            return "\(coordinates.count) pts, " + UnitFormat.area(area, units: units)
        case .point:
            guard let coordinate = coordinates.first else { return "no coordinate" }
            return String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        }
    }

    // Custom Codable so layers saved by older versions of the app
    // (without notes/fields/visibility/color/photos) still load.
    enum CodingKeys: String, CodingKey {
        case id, name, kind, coordinates, notes, fields, isVisible, createdAt, color, photoFilenames, group
        case fillColor, fillOpacity, fillStyle
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: MapLayerKind,
        coordinates: [LayerCoordinate],
        notes: String = "",
        fields: [FeatureField] = [],
        isVisible: Bool = true,
        createdAt: Date = Date(),
        color: LayerColor? = nil,
        photoFilenames: [String] = [],
        group: String = "",
        fillColor: LayerColor? = nil,
        fillOpacity: Double = 0.25,
        fillStyle: PolygonFillStyle = .solid
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.coordinates = coordinates
        self.notes = notes
        self.fields = fields
        self.isVisible = isVisible
        self.createdAt = createdAt
        self.color = color
        self.photoFilenames = photoFilenames
        self.group = group
        self.fillColor = fillColor
        self.fillOpacity = fillOpacity
        self.fillStyle = fillStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(MapLayerKind.self, forKey: .kind)
        coordinates = try container.decode([LayerCoordinate].self, forKey: .coordinates)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        fields = try container.decodeIfPresent([FeatureField].self, forKey: .fields) ?? []
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        color = try container.decodeIfPresent(LayerColor.self, forKey: .color)
        photoFilenames = try container.decodeIfPresent([String].self, forKey: .photoFilenames) ?? []
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        fillColor = try container.decodeIfPresent(LayerColor.self, forKey: .fillColor)
        fillOpacity = try container.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 0.25
        fillStyle = try container.decodeIfPresent(PolygonFillStyle.self, forKey: .fillStyle) ?? .solid
    }
}


extension MapLayer {
    private func fieldValue(_ key: String) -> String? {
        fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var lidarPLYFilename: String? {
        let value = fieldValue("scan_ply_file")
        return (value?.isEmpty == false) ? value : nil
    }

    var lidarLASFilename: String? {
        let value = fieldValue("scan_las_file")
        return (value?.isEmpty == false) ? value : nil
    }

    var lidarPointCountText: String? {
        let value = fieldValue("scan_vertices")
        return (value?.isEmpty == false) ? value : nil
    }

    var hasLiDARScanFiles: Bool {
        lidarPLYFilename != nil || lidarLASFilename != nil
    }

    var transectArraySourceID: String? {
        let value = fieldValue("array_source_id")
        return (value?.isEmpty == false) ? value : nil
    }

    var transectArrayLabel: String? {
        let value = fieldValue("transect_label")
        return (value?.isEmpty == false) ? value : nil
    }

    var isTransectArrayMember: Bool {
        transectArraySourceID != nil || transectArrayLabel != nil || group.hasPrefix("Transect Array -")
    }
}

final class LayerStore: ObservableObject {
    @Published private(set) var layers: [MapLayer] = []

    private let fileURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = documents.appendingPathComponent("SavedMapLayers.json")
        load()
    }

    func add(_ layer: MapLayer) {
        layers.append(layer)
        save()
    }

    func update(_ layer: MapLayer) {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        layers[index] = layer
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets {
            PhotoStore.delete(layers[index].photoFilenames)
        }
        layers.remove(atOffsets: offsets)
        save()
    }

    func remove(id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        PhotoStore.delete(layers[index].photoFilenames)
        layers.remove(at: index)
        save()
    }

    func toggleVisibility(_ layer: MapLayer) {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        layers[index].isVisible.toggle()
        save()
    }

    /// Assign a layer to a group ("" removes it from any group).
    func setGroup(_ group: String, id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].group = group
        save()
    }

    /// Assign many layers to a group in one save operation.
    func setGroup(_ group: String, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in layers.indices where ids.contains(layers[index].id) {
            layers[index].group = group
        }
        save()
    }

    /// Delete many layers in one save operation.
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for layer in layers where ids.contains(layer.id) {
            PhotoStore.delete(layer.photoFilenames)
        }
        layers.removeAll { ids.contains($0.id) }
        save()
    }

    /// Show/hide a set of layers at once (used for group toggles).
    func setVisibility(_ visible: Bool, ids: Set<UUID>) {
        for index in layers.indices where ids.contains(layers[index].id) {
            layers[index].isVisible = visible
        }
        save()
    }

    /// Existing non-empty group names, sorted.
    var groupNames: [String] {
        Array(Set(layers.map { $0.group }.filter { !$0.isEmpty })).sorted()
    }

    func clear() {
        for layer in layers {
            PhotoStore.delete(layer.photoFilenames)
        }
        layers.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MapLayer].self, from: data) else {
            layers = []
            return
        }
        layers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(layers) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}


// MARK: - Online public data downloads

/// Small geographic extent used to clip online downloads to the current
/// GeoPDF map or a modest GPS fallback area.
struct GeoExtent: Hashable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    var isValid: Bool {
        minLatitude >= -90 && maxLatitude <= 90 &&
        minLongitude >= -180 && maxLongitude <= 180 &&
        maxLatitude > minLatitude && maxLongitude > minLongitude
    }

    var bboxDescription: String {
        String(format: "%.4f, %.4f to %.4f, %.4f", minLatitude, minLongitude, maxLatitude, maxLongitude)
    }

    /// Rough area for download-size guardrails (equirectangular).
    var approximateAreaSquareKilometers: Double {
        let midLatitude = (minLatitude + maxLatitude) / 2
        let heightKm = (maxLatitude - minLatitude) * 110.54
        let widthKm = (maxLongitude - minLongitude) * 111.32 * cos(midLatitude * .pi / 180)
        return abs(heightKm * widthKm)
    }

    /// A square extent of the given radius around a coordinate, used as
    /// a GPS fallback when no GeoPDF is loaded.
    static func around(_ coordinate: CLLocationCoordinate2D, radiusMeters: Double) -> GeoExtent {
        let latitudeDelta = radiusMeters / 110_540.0
        let longitudeDelta = radiusMeters / max(1.0, 111_320.0 * cos(coordinate.latitude * .pi / 180))
        return GeoExtent(
            minLatitude: coordinate.latitude - latitudeDelta,
            maxLatitude: coordinate.latitude + latitudeDelta,
            minLongitude: coordinate.longitude - longitudeDelta,
            maxLongitude: coordinate.longitude + longitudeDelta
        )
    }
}


enum OfflineRasterBasemapStyle: String, CaseIterable, Identifiable {
    case blankVector
    case appleStandard
    case appleMutedStandard
    case appleSatellite
    case appleHybrid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blankVector:
            return "Blank / vector only"
        case .appleStandard:
            return "Standard map image"
        case .appleMutedStandard:
            return "Light terrain-style map image"
        case .appleSatellite:
            return "Satellite image"
        case .appleHybrid:
            return "Satellite hybrid image"
        }
    }

    var subtitle: String {
        switch self {
        case .blankVector:
            return "Smallest download. Roads, water, parks, and buildings draw as editable vector layers only."
        case .appleStandard:
            return "Creates a georeferenced raster map snapshot behind your offline vector layers."
        case .appleMutedStandard:
            return "A quieter map-style raster background that keeps field layers readable."
        case .appleSatellite:
            return "Creates a georeferenced satellite-image background for the selected area."
        case .appleHybrid:
            return "Satellite imagery with map labels where available."
        }
    }

    var mapType: MKMapType? {
        switch self {
        case .blankVector:
            return nil
        case .appleStandard:
            return .standard
        case .appleMutedStandard:
            return .mutedStandard
        case .appleSatellite:
            return .satellite
        case .appleHybrid:
            return .hybrid
        }
    }
}

struct OfflineRasterBasemapRenderer {
    @MainActor
    static func createPDF(
        for extent: GeoExtent,
        title: String,
        style: OfflineRasterBasemapStyle
    ) async throws -> URL {
        guard let mapType = style.mapType else {
            throw NSError(domain: "FieldMapper", code: 1, userInfo: [NSLocalizedDescriptionKey: "No raster style selected."])
        }

        let mapRect = mapRect(for: extent)
        guard mapRect.width.isFinite, mapRect.height.isFinite, mapRect.width > 0, mapRect.height > 0 else {
            throw NSError(domain: "FieldMapper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid map extent."])
        }

        let aspect = CGFloat(max(0.25, min(4.0, mapRect.width / mapRect.height)))
        let basePDFSize: CGFloat = 1000
        let pageSize = aspect >= 1
            ? CGSize(width: basePDFSize, height: basePDFSize / aspect)
            : CGSize(width: basePDFSize * aspect, height: basePDFSize)

        // Keep the snapshot large enough to look like a real basemap, but
        // bounded so field phones do not run out of memory on big areas.
        let maxSnapshotDimension: CGFloat = 1800
        let snapshotSize = aspect >= 1
            ? CGSize(width: maxSnapshotDimension, height: maxSnapshotDimension / aspect)
            : CGSize(width: maxSnapshotDimension * aspect, height: maxSnapshotDimension)

        let image = try await snapshot(
            mapRect: mapRect,
            mapType: mapType,
            size: snapshotSize
        )

        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let mapsFolder = documents.appendingPathComponent("GeneratedMaps", isDirectory: true)
        try FileManager.default.createDirectory(at: mapsFolder, withIntermediateDirectories: true)
        let safeStyleName = style.rawValue.replacingOccurrences(of: " ", with: "_")
        let url = mapsFolder.appendingPathComponent("OfflineRaster-\(safeStyleName)-\(Int(Date().timeIntervalSince1970)).pdf")

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: pageSize))
            image.draw(in: CGRect(origin: .zero, size: pageSize))

            let label = title + " • " + style.label + "\n" +
                String(format: "Lat %.5f to %.5f  Lon %.5f to %.5f", extent.minLatitude, extent.maxLatitude, extent.minLongitude, extent.maxLongitude)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(10, pageSize.width * 0.018), weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let textSize = label.size(withAttributes: attributes)
            let pad: CGFloat = 8
            let rect = CGRect(
                x: pad,
                y: pageSize.height - textSize.height - pad * 2,
                width: min(pageSize.width - pad * 2, textSize.width + pad * 2),
                height: textSize.height + pad
            )
            UIColor.black.withAlphaComponent(0.50).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
            label.draw(in: rect.insetBy(dx: pad, dy: pad / 2), withAttributes: attributes)
        }

        return url
    }

    private static func snapshot(
        mapRect: MKMapRect,
        mapType: MKMapType,
        size: CGSize
    ) async throws -> UIImage {
        let options = MKMapSnapshotter.Options()
        options.mapRect = mapRect
        options.mapType = mapType
        options.size = size
        options.scale = 1
        options.showsBuildings = true
        options.pointOfInterestFilter = .includingAll

        return try await withCheckedThrowingContinuation { continuation in
            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { snapshot, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let snapshot = snapshot {
                    continuation.resume(returning: snapshot.image)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "FieldMapper",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No map image was returned."]
                    ))
                }
            }
        }
    }

    private static func mapRect(for extent: GeoExtent) -> MKMapRect {
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: extent.maxLatitude, longitude: extent.minLongitude))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: extent.minLatitude, longitude: extent.maxLongitude))
        let minX = min(nw.x, se.x)
        let maxX = max(nw.x, se.x)
        let minY = min(nw.y, se.y)
        let maxY = max(nw.y, se.y)
        return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

struct ArcGISLayerEndpoint: Hashable {
    let layerURL: String
    let defaultLayerID: Int

    init(_ layerURL: String, defaultLayerID: Int = 0) {
        self.layerURL = layerURL
        self.defaultLayerID = defaultLayerID
    }
}

/// Built-in public datasets that can be downloaded while online and saved
/// into the app as normal layers for offline use. These are intentionally
/// context layers, not restricted archaeological site records.
struct OnlineDataset: Identifiable, Hashable {
    enum SourceKind: Hashable {
        case overpass(OverpassPreset)
        case arcGISREST(ArcGISLayerEndpoint)
    }

    let id: String
    let title: String
    let subtitle: String
    let caution: String
    let sourceKind: SourceKind
    let groupName: String
    let color: LayerColor
    let recommendedMaxAreaSquareKilometers: Double

    static let builtIn: [OnlineDataset] = [
        OnlineDataset(
            id: "osm_roads_trails",
            title: "OpenStreetMap Roads & Trails",
            subtitle: "Roads, tracks, paths, footways, and other mapped access lines in the current map extent.",
            caution: "OSM is public/crowdsourced. Verify important access routes in the field.",
            sourceKind: .overpass(.roadsTrails),
            groupName: "Online: OSM Roads & Trails",
            color: .orange,
            recommendedMaxAreaSquareKilometers: 120
        ),
        OnlineDataset(
            id: "osm_water",
            title: "OpenStreetMap Waterways & Water",
            subtitle: "Streams, rivers, ditches, canals, and mapped water polygons.",
            caution: "Useful for field context; not a substitute for hydrology/regulatory datasets.",
            sourceKind: .overpass(.water),
            groupName: "Online: OSM Water",
            color: .teal,
            recommendedMaxAreaSquareKilometers: 160
        ),
        OnlineDataset(
            id: "osm_buildings",
            title: "OpenStreetMap Buildings",
            subtitle: "Building footprints in the current map extent.",
            caution: "Can be very dense. Keep the map extent small before downloading.",
            sourceKind: .overpass(.buildings),
            groupName: "Online: OSM Buildings",
            color: .brown,
            recommendedMaxAreaSquareKilometers: 12
        ),
        OnlineDataset(
            id: "osm_public_land",
            title: "OpenStreetMap Parks / Protected / Forest",
            subtitle: "Public-context polygons such as parks, protected areas, nature reserves, and mapped forest/recreation areas.",
            caution: "Ownership and access rights may be incomplete. Confirm with authoritative land records when needed.",
            sourceKind: .overpass(.publicLand),
            groupName: "Online: OSM Parks & Public Land",
            color: .green,
            recommendedMaxAreaSquareKilometers: 250
        ),
        OnlineDataset(
            id: "osm_historic_public",
            title: "OpenStreetMap Historic/Public Landmarks",
            subtitle: "Public OSM features tagged historic, including public landmarks and ruins where mapped.",
            caution: "Do not treat this as an official archaeology site record. Avoid exporting or sharing sensitive cultural-resource locations.",
            sourceKind: .overpass(.historicPublic),
            groupName: "Online: OSM Historic/Public",
            color: .purple,
            recommendedMaxAreaSquareKilometers: 250
        )
    ]

    static let plss: [OnlineDataset] = [
        OnlineDataset(
            id: "blm_plss_township_range",
            title: "BLM PLSS Township / Range",
            subtitle: "Township and range polygons from the BLM National Public Land Survey System service for the current map extent.",
            caution: "Useful for DPR legal-location context. Verify official legal descriptions before final reporting.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://gis.blm.gov/arcgis/rest/services/Cadastral/BLM_Natl_PLSS_CadNSDI/MapServer/1")),
            groupName: "PLSS: Township / Range",
            color: .red,
            recommendedMaxAreaSquareKilometers: 2_500
        ),
        OnlineDataset(
            id: "blm_plss_sections",
            title: "BLM PLSS Sections",
            subtitle: "Section / first-division polygons from the BLM National Public Land Survey System service for the current map extent.",
            caution: "Downloads can be dense. Keep the map extent reasonable and confirm legal descriptions before final reporting.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://gis.blm.gov/arcgis/rest/services/Cadastral/BLM_Natl_PLSS_CadNSDI/MapServer/2")),
            groupName: "PLSS: Sections",
            color: .yellow,
            recommendedMaxAreaSquareKilometers: 2_500
        )
    ]

    static let dprLocationAutofill: [OnlineDataset] = [
        OnlineDataset(
            id: "usgs_75_quad_current",
            title: "USGS 7.5' Quadrangle / Map Date",
            subtitle: "Current US Topo 7.5-minute quadrangle availability footprints from The National Map.",
            caution: "Auto-fills DPR Quad/Date fields. Verify final form text against the project map and agency requirements.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://index.nationalmap.gov/arcgis/rest/services/USTopoAvailability/MapServer/2")),
            groupName: "DPR Autofill: USGS 7.5 Quads",
            color: .green,
            recommendedMaxAreaSquareKilometers: 2_500
        ),
        OnlineDataset(
            id: "census_counties",
            title: "County Boundaries",
            subtitle: "County or county-equivalent polygons from the U.S. Census TIGERweb State/County service.",
            caution: "Auto-fills DPR county fields. Verify boundary results near county lines.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/State_County/MapServer/1")),
            groupName: "DPR Autofill: Counties",
            color: .blue,
            recommendedMaxAreaSquareKilometers: 10_000
        )
    ]

    static let dprAutofill: [OnlineDataset] = plss + dprLocationAutofill

    static let forestService: [OnlineDataset] = [
        OnlineDataset(
            id: "fs_roads",
            title: "USFS Roads",
            subtitle: "National Forest System road segments from the Forest Service EDW RoadBasic service.",
            caution: "Public context layer. Verify access, closures, and current conditions before relying on a road.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RoadBasic_01/MapServer/0")),
            groupName: "Forest Service: Roads",
            color: .orange,
            recommendedMaxAreaSquareKilometers: 600
        ),
        OnlineDataset(
            id: "fs_closed_roads",
            title: "USFS Roads Closed to Motorized Use",
            subtitle: "RoadBasic layer showing NFS roads closed to motorized uses where published.",
            caution: "Check current forest orders and local notices. This is a planning layer, not legal advice.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RoadBasic_01/MapServer/1")),
            groupName: "Forest Service: Closed Roads",
            color: .red,
            recommendedMaxAreaSquareKilometers: 600
        ),
        OnlineDataset(
            id: "fs_trails",
            title: "USFS Trails",
            subtitle: "National Forest System trail centerlines and trail attributes where approved for publication.",
            caution: "Trail data completeness varies by Forest. Confirm in the field and with current Forest Service information.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_TrailNFSPublish_01/MapServer/0")),
            groupName: "Forest Service: Trails",
            color: .brown,
            recommendedMaxAreaSquareKilometers: 600
        ),
        OnlineDataset(
            id: "fs_mvum_roads",
            title: "USFS MVUM Roads",
            subtitle: "Motor Vehicle Use Map road layer with designated motorized route information where available.",
            caution: "Use with the official MVUM and current Forest orders for legal motorized access decisions.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_MVUM_01/MapServer/1")),
            groupName: "Forest Service: MVUM Roads",
            color: .orange,
            recommendedMaxAreaSquareKilometers: 600
        ),
        OnlineDataset(
            id: "fs_mvum_trails",
            title: "USFS MVUM Trails",
            subtitle: "Motor Vehicle Use Map trail layer with designated motorized route information where available.",
            caution: "Use with the official MVUM and current Forest orders for legal motorized access decisions.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_MVUM_01/MapServer/2")),
            groupName: "Forest Service: MVUM Trails",
            color: .yellow,
            recommendedMaxAreaSquareKilometers: 600
        ),
        OnlineDataset(
            id: "fs_forest_boundaries",
            title: "USFS Forest System Boundaries",
            subtitle: "Administrative Forest System boundary polygons for broad land-management context.",
            caution: "Administrative boundaries can include mixed ownership. Do not use as a parcel ownership substitute.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_ForestSystemBoundaries_01/MapServer/0")),
            groupName: "Forest Service: Forest Boundaries",
            color: .green,
            recommendedMaxAreaSquareKilometers: 2_500
        ),
        OnlineDataset(
            id: "fs_ranger_districts",
            title: "USFS Ranger Districts",
            subtitle: "Ranger District boundary polygons for administrative context.",
            caution: "Administrative context only. Check the local forest office for current jurisdiction questions.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RangerDistricts_01/MapServer/0")),
            groupName: "Forest Service: Ranger Districts",
            color: .teal,
            recommendedMaxAreaSquareKilometers: 2_500
        ),
        OnlineDataset(
            id: "fs_wilderness",
            title: "USFS Wilderness",
            subtitle: "Wilderness boundary polygons from the Forest Service EDW Wilderness service.",
            caution: "Useful for access constraints and survey planning; verify restrictions with the local unit.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_Wilderness_01/MapServer/0")),
            groupName: "Forest Service: Wilderness",
            color: .purple,
            recommendedMaxAreaSquareKilometers: 2_500
        ),
        OnlineDataset(
            id: "fs_roadless",
            title: "USFS Inventoried Roadless Areas",
            subtitle: "Inventoried Roadless Area polygons used for the 2001 Roadless Rule dataset.",
            caution: "Planning context only. Some states have state-specific roadless datasets.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_InventoriedRoadlessAreas2001_01/MapServer/0")),
            groupName: "Forest Service: Roadless Areas",
            color: .pink,
            recommendedMaxAreaSquareKilometers: 2_500
        ),
        OnlineDataset(
            id: "fs_rec_sites",
            title: "USFS Recreation Sites",
            subtitle: "Public recreation site point locations from the RecInfra Recreation Sites service.",
            caution: "Good for field logistics. Check current status before relying on open/closed conditions.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RecInfraRecreationSites_02/MapServer/0")),
            groupName: "Forest Service: Recreation Sites",
            color: .blue,
            recommendedMaxAreaSquareKilometers: 2_500
        ),
        OnlineDataset(
            id: "fs_fire_perimeters",
            title: "USFS Fire Occurrence / Perimeters",
            subtitle: "Forest Service fire occurrence locations and fire perimeter context where available.",
            caution: "Fire datasets can be dense and multi-layered. Keep extent small if the first download is slow.",
            sourceKind: .arcGISREST(ArcGISLayerEndpoint("https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_FireOccurrenceAndPerimeter_01/MapServer/0")),
            groupName: "Forest Service: Fire History",
            color: .red,
            recommendedMaxAreaSquareKilometers: 1_000
        )
    ]
}

enum OverpassPreset: String, Hashable {
    case roadsTrails
    case water
    case buildings
    case publicLand
    case historicPublic

    func query(extent: GeoExtent) -> String {
        let south = extent.minLatitude
        let west = extent.minLongitude
        let north = extent.maxLatitude
        let east = extent.maxLongitude
        let bbox = "\(south),\(west),\(north),\(east)"

        let selector: String
        switch self {
        case .roadsTrails:
            selector = """
              way["highway"](\(bbox));
              relation["highway"](\(bbox));
              way["route"="hiking"](\(bbox));
              relation["route"="hiking"](\(bbox));
            """
        case .water:
            selector = """
              way["waterway"](\(bbox));
              relation["waterway"](\(bbox));
              way["natural"="water"](\(bbox));
              relation["natural"="water"](\(bbox));
              way["water"](\(bbox));
              relation["water"](\(bbox));
            """
        case .buildings:
            selector = """
              way["building"](\(bbox));
              relation["building"](\(bbox));
            """
        case .publicLand:
            selector = """
              way["leisure"="park"](\(bbox));
              relation["leisure"="park"](\(bbox));
              way["boundary"="protected_area"](\(bbox));
              relation["boundary"="protected_area"](\(bbox));
              way["landuse"="forest"](\(bbox));
              relation["landuse"="forest"](\(bbox));
              way["natural"="wood"](\(bbox));
              relation["natural"="wood"](\(bbox));
            """
        case .historicPublic:
            selector = """
              node["historic"](\(bbox));
              way["historic"](\(bbox));
              relation["historic"](\(bbox));
              node["tourism"="attraction"](\(bbox));
            """
        }

        return """
        [out:json][timeout:30];
        (
        \(selector)
        );
        out body geom;
        """
    }
}

struct ArcGISPortalSearchItem: Identifiable, Hashable {
    let id: String
    let title: String
    let type: String
    let url: String?
    let owner: String?
}

struct ArcGISPortalGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let owner: String?
    let description: String?
    let itemCount: Int?
}

struct ArcGISOAuthToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let portalURL: String
    let username: String?

    var isValid: Bool {
        expiresAt > Date().addingTimeInterval(90)
    }
}

enum ArcGISAuthError: LocalizedError {
    case missingConfiguration
    case invalidPortalURL
    case invalidRedirectURI
    case cancelled
    case callbackMissingCode
    case tokenExchangeFailed(String)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Enter an ArcGIS OAuth client ID and redirect URI first."
        case .invalidPortalURL:
            return "The ArcGIS portal URL is not valid. Use something like https://www.arcgis.com or your Enterprise portal URL."
        case .invalidRedirectURI:
            return "The redirect URI is not valid. Example: fieldmapper://auth"
        case .cancelled:
            return "ArcGIS sign-in was cancelled."
        case .callbackMissingCode:
            return "ArcGIS did not return an authorization code."
        case .tokenExchangeFailed(let message):
            return message
        case .notSignedIn:
            return "Sign in to ArcGIS first."
        }
    }
}

@MainActor
final class ArcGISAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var token: ArcGISOAuthToken?
    @Published private(set) var statusMessage = "Not signed in."

    private var currentSession: ASWebAuthenticationSession?
    private let keychainService = "AvenzaStyleFieldMapper.ArcGISOAuth"
    private let keychainAccount = "ArcGISToken"

    override init() {
        super.init()
        loadSavedToken()
    }

    var isSignedIn: Bool {
        token != nil
    }

    func signOut() {
        token = nil
        statusMessage = "Signed out."
        SimpleKeychain.delete(service: keychainService, account: keychainAccount)
    }

    func signIn(portalURL: String, clientID: String, redirectURI: String) async throws {
        let normalizedPortal = try Self.normalizedPortalURL(portalURL)
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else { throw ArcGISAuthError.missingConfiguration }
        guard let redirect = URL(string: redirectURI), let callbackScheme = redirect.scheme, !callbackScheme.isEmpty else {
            throw ArcGISAuthError.invalidRedirectURI
        }

        let verifier = PKCE.makeCodeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(url: normalizedPortal.appendingArcGISPath("sharing/rest/oauth2/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "expiration", value: "20160"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = components?.url else { throw ArcGISAuthError.invalidPortalURL }

        statusMessage = "Opening ArcGIS sign-in…"
        let callbackURL = try await performWebAuthentication(authURL: authURL, callbackScheme: callbackScheme)
        let values = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let returnedState = values.first(where: { $0.name == "state" })?.value
        guard returnedState == state else { throw ArcGISAuthError.callbackMissingCode }
        guard let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            if let error = values.first(where: { $0.name == "error_description" })?.value {
                throw ArcGISAuthError.tokenExchangeFailed(error)
            }
            throw ArcGISAuthError.callbackMissingCode
        }

        let newToken = try await exchangeCodeForToken(
            portal: normalizedPortal,
            clientID: trimmedClientID,
            redirectURI: redirectURI,
            code: code,
            verifier: verifier
        )
        token = newToken
        saveToken(newToken)
        statusMessage = "Signed in to ArcGIS."
    }

    func validAccessToken(portalURL: String, clientID: String) async throws -> String {
        if let token = token, token.isValid {
            return token.accessToken
        }
        guard let token = token, let refreshToken = token.refreshToken else {
            throw ArcGISAuthError.notSignedIn
        }
        let refreshed = try await refreshAccessToken(portalURL: portalURL, clientID: clientID, refreshToken: refreshToken)
        self.token = refreshed
        saveToken(refreshed)
        statusMessage = "ArcGIS token refreshed."
        return refreshed.accessToken
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow
            }
        }
        return ASPresentationAnchor()
    }

    private func performWebAuthentication(authURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: ArcGISAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? ArcGISAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            currentSession = session
            if !session.start() {
                continuation.resume(throwing: ArcGISAuthError.cancelled)
            }
        }
    }

    private func exchangeCodeForToken(portal: URL, clientID: String, redirectURI: String, code: String, verifier: String) async throws -> ArcGISOAuthToken {
        let body = [
            "f": "json",
            "client_id": clientID,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier
        ]
        let data = try await postForm(to: portal.appendingArcGISPath("sharing/rest/oauth2/token"), body: body)
        return try parseTokenResponse(data, portalURL: portal.absoluteString)
    }

    private func refreshAccessToken(portalURL: String, clientID: String, refreshToken: String) async throws -> ArcGISOAuthToken {
        let portal = try Self.normalizedPortalURL(portalURL)
        let body = [
            "f": "json",
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let data = try await postForm(to: portal.appendingArcGISPath("sharing/rest/oauth2/token"), body: body)
        return try parseTokenResponse(data, portalURL: portal.absoluteString, fallbackRefreshToken: refreshToken)
    }

    private func postForm(to url: URL, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ArcGISAuthError.tokenExchangeFailed("ArcGIS token request failed.")
        }
        return data
    }

    private func parseTokenResponse(_ data: Data, portalURL: String, fallbackRefreshToken: String? = nil) throws -> ArcGISOAuthToken {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ArcGISAuthError.tokenExchangeFailed("ArcGIS token response was not JSON.")
        }
        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? (error["details"] as? [String])?.joined(separator: " ") ?? "ArcGIS authorization failed."
            throw ArcGISAuthError.tokenExchangeFailed(message)
        }
        guard let accessToken = json["access_token"] as? String else {
            throw ArcGISAuthError.tokenExchangeFailed("ArcGIS token response did not contain an access token.")
        }
        let refreshToken = (json["refresh_token"] as? String) ?? fallbackRefreshToken
        let username = json["username"] as? String
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 7200
        return ArcGISOAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            portalURL: portalURL,
            username: username
        )
    }

    private func loadSavedToken() {
        guard let data = SimpleKeychain.load(service: keychainService, account: keychainAccount),
              let saved = try? JSONDecoder().decode(ArcGISOAuthToken.self, from: data) else {
            statusMessage = "Not signed in."
            return
        }
        token = saved
        statusMessage = saved.isValid ? "Signed in to ArcGIS." : "ArcGIS sign-in saved; token may need refresh."
    }

    private func saveToken(_ token: ArcGISOAuthToken) {
        if let data = try? JSONEncoder().encode(token) {
            SimpleKeychain.save(data, service: keychainService, account: keychainAccount)
        }
    }

    static func normalizedPortalURL(_ text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "https://www.arcgis.com" }
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ArcGISAuthError.invalidPortalURL
        }
        return url
    }
}

enum PKCE {
    static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension URL {
    func appendingArcGISPath(_ path: String) -> URL {
        var url = self
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        return url
    }
}

enum SimpleKeychain {
    static func save(_ data: Data, service: String, account: String) {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}



// MARK: - Offline map storage manager

struct OfflineMapStorageItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let folderName: String
    let fileSize: Int64
    let modifiedDate: Date

    var displayName: String { url.lastPathComponent }
    var standardizedURL: URL { url.standardizedFileURL }

    var storageKind: String {
        switch folderName {
        case "GeneratedMaps":
            return displayName.hasPrefix("OfflineRaster") ? "Offline raster map" : "Offline blank map"
        case "ImportedMaps":
            return "Imported GeoPDF"
        default:
            return folderName
        }
    }
}

struct OfflineMapStorageView: View {
    let currentMapURL: URL?
    let onDeleted: (Set<URL>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [OfflineMapStorageItem] = []
    @State private var message = "Offline maps are stored inside this app on your iPhone. Delete old map PDFs here to free storage."
    @State private var confirmingDeleteAll = false

    private var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    private var groupedItems: [(String, [OfflineMapStorageItem])] {
        let grouped = Dictionary(grouping: items) { $0.folderName }
        return grouped.keys.sorted().map { key in
            (key, grouped[key, default: []].sorted { $0.modifiedDate > $1.modifiedDate })
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.xmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No offline map files saved")
                            .font(.headline)
                        Text("Imported GeoPDFs and generated offline raster/blank map PDFs will appear here after you create them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding()
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Map file storage: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                                    .font(.headline)
                                Text("Saved feature layers and downloaded OSM/ArcGIS/Forest Service vectors are managed separately in Layers.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        ForEach(groupedItems, id: \.0) { groupEntry in
                            Section(groupTitle(groupEntry.0)) {
                                ForEach(groupEntry.1) { item in
                                    row(for: item)
                                }
                                .onDelete { offsets in
                                    let selected = offsets.map { groupEntry.1[$0] }
                                    delete(selected)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Offline Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refresh") { loadItems() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete All", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                    .disabled(items.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
            }
            .confirmationDialog(
                "Delete all saved map PDFs? Saved feature layers will remain.",
                isPresented: $confirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All Offline Map Files", role: .destructive) {
                    delete(items)
                }
            }
            .onAppear(perform: loadItems)
        }
    }

    private func row(for item: OfflineMapStorageItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName(for: item))
                .foregroundStyle(isCurrent(item) ? Color.blue : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if isCurrent(item) {
                        Text("OPEN")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                Text(item.storageKind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)) • \(item.modifiedDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                delete([item])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func loadItems() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let folders = ["ImportedMaps", "GeneratedMaps"]
        var loaded: [OfflineMapStorageItem] = []

        for folder in folders {
            let folderURL = documents.appendingPathComponent(folder, isDirectory: true)
            guard let urls = try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls where url.pathExtension.lowercased() == "pdf" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                loaded.append(OfflineMapStorageItem(
                    url: url.standardizedFileURL,
                    folderName: folder,
                    fileSize: Int64(values?.fileSize ?? fileSize(at: url)),
                    modifiedDate: values?.contentModificationDate ?? Date.distantPast
                ))
            }
        }

        items = loaded.sorted { $0.modifiedDate > $1.modifiedDate }
        message = items.isEmpty
            ? "No offline map PDFs are currently stored in this app."
            : "Map PDFs use \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)). Swipe a row or tap the trash icon to delete old maps."
    }

    private func delete(_ selectedItems: [OfflineMapStorageItem]) {
        guard !selectedItems.isEmpty else { return }
        let fm = FileManager.default
        var deleted: Set<URL> = []
        var failed: [String] = []

        for item in selectedItems {
            do {
                try fm.removeItem(at: item.url)
                deleted.insert(item.standardizedURL)
            } catch {
                failed.append(item.displayName)
            }
        }

        loadItems()
        onDeleted(deleted)

        if failed.isEmpty {
            message = "Deleted \(deleted.count) map file\(deleted.count == 1 ? "" : "s"). Saved feature layers were not changed."
        } else {
            message = "Deleted \(deleted.count) map file\(deleted.count == 1 ? "" : "s"). Could not delete: \(failed.joined(separator: ", "))."
        }
    }

    private func groupTitle(_ folderName: String) -> String {
        switch folderName {
        case "ImportedMaps": return "Imported GeoPDFs"
        case "GeneratedMaps": return "Generated Offline Maps"
        default: return folderName
        }
    }

    private func iconName(for item: OfflineMapStorageItem) -> String {
        if item.folderName == "GeneratedMaps" {
            return item.displayName.hasPrefix("OfflineRaster") ? "map.fill" : "square.grid.3x3.fill"
        }
        return "doc.richtext.fill"
    }

    private func isCurrent(_ item: OfflineMapStorageItem) -> Bool {
        guard let currentMapURL = currentMapURL else { return false }
        return item.standardizedURL == currentMapURL.standardizedFileURL
    }

    private func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int ?? 0
    }
}


// MARK: - Offline imagery / topo basemap downloads

struct OfflineImageryTopoRequest {
    let source: OfflineImageryTopoSource
    let extent: GeoExtent
    let customServiceURL: String?
    let year: Int?

    var title: String {
        if let year = year {
            return "\(source.shortLabel) \(year)"
        }
        return source.shortLabel
    }

    var mapLabel: String {
        var parts = [source.longLabel]
        if let year = year { parts.append("Year \(year)") }
        parts.append(source.offlineStatusLabel)
        return parts.joined(separator: " • ")
    }
}

enum OfflineImageryTopoSource: String, CaseIterable, Identifiable {
    case bestAvailablePublicImagery
    case usgsImageryOnly
    case usgsImageryTopo
    case usgsTopo
    case appleSatellitePreview
    case customArcGISRasterService

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .bestAvailablePublicImagery: return "Best Public Imagery"
        case .usgsImageryOnly: return "USGS Imagery"
        case .usgsImageryTopo: return "USGS Imagery Topo"
        case .usgsTopo: return "USGS Topo"
        case .appleSatellitePreview: return "Apple Satellite Preview"
        case .customArcGISRasterService: return "Custom Raster Service"
        }
    }

    var longLabel: String {
        switch self {
        case .bestAvailablePublicImagery:
            return "Best available public offline imagery"
        case .usgsImageryOnly:
            return "USGS Imagery Only / NAIP-style orthophoto"
        case .usgsImageryTopo:
            return "USGS Imagery with topo labels"
        case .usgsTopo:
            return "USGS current topo basemap"
        case .appleSatellitePreview:
            return "Apple satellite preview"
        case .customArcGISRasterService:
            return "Custom ArcGIS raster/image service"
        }
    }

    var icon: String {
        switch self {
        case .bestAvailablePublicImagery: return "sparkles.rectangle.stack"
        case .usgsImageryOnly: return "photo.fill"
        case .usgsImageryTopo: return "map.fill"
        case .usgsTopo: return "mountain.2.fill"
        case .appleSatellitePreview: return "globe.americas.fill"
        case .customArcGISRasterService: return "link"
        }
    }

    var isOfflineDownloadable: Bool {
        switch self {
        case .appleSatellitePreview:
            return false
        default:
            return true
        }
    }

    var offlineStatusLabel: String {
        isOfflineDownloadable ? "offline PDF basemap" : "online only"
    }

    var serviceURL: String? {
        switch self {
        case .bestAvailablePublicImagery, .usgsImageryOnly:
            return "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer"
        case .usgsImageryTopo:
            return "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer"
        case .usgsTopo:
            return "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer"
        case .appleSatellitePreview, .customArcGISRasterService:
            return nil
        }
    }

    var fieldNote: String {
        switch self {
        case .bestAvailablePublicImagery:
            return "Recommended first. Uses The National Map imagery service, which is commonly NAIP or partner orthophoto imagery where available. If it returns poor coverage, try imagery + topo, current topo, or import your own orthomosaic."
        case .usgsImageryOnly:
            return "Downloadable public orthophoto-style image from The National Map. Good for offline field basemaps where coverage exists."
        case .usgsImageryTopo:
            return "Orthophoto with topo/vector reference labels. Useful when crews need roads, hydrography, and names visible on the imagery."
        case .usgsTopo:
            return "Current USGS topo-style basemap. Best fallback where orthophoto coverage is weak or when terrain/reference context is more useful than imagery."
        case .appleSatellitePreview:
            return "Online preview only. Apple imagery is useful for a quick look with service, but this app does not save Apple imagery as an offline basemap."
        case .customArcGISRasterService:
            return "Paste an ArcGIS MapServer or ImageServer URL from a public/authorized imagery service. If it is time-enabled, discover years and export one year at a time."
        }
    }
}

struct TNMProduct: Identifiable, Hashable {
    let id: String
    let title: String
    let year: Int?
    let scale: String
    let productFormat: String
    let downloadURLString: String?

    var bestDownloadURL: URL? {
        guard let downloadURLString = downloadURLString else { return nil }
        return URL(string: downloadURLString)
    }

    var displayYearText: String {
        year.map { "\($0)" } ?? "undated"
    }

    var subtitle: String {
        [displayYearText, scale, productFormat].filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

struct OfflineImageryTopoDownloadView: View {
    @Environment(\.dismiss) private var dismiss

    let mapExtent: GeoExtent?
    let currentCoordinate: CLLocationCoordinate2D?
    let hasCurrentMap: Bool
    let onCreateBasemap: (OfflineImageryTopoRequest) async -> String
    let onImportOwnRaster: () -> Void
    let onDownloadTNMProduct: (TNMProduct) async -> String

    @State private var selectedSource: OfflineImageryTopoSource = .bestAvailablePublicImagery
    @State private var radiusMeters = 1_000.0
    @State private var customServiceURL = ""
    @State private var selectedYear: Int?
    @State private var discoveredYears: [Int] = []
    @State private var tnmProducts: [TNMProduct] = []
    @State private var statusMessage = "Choose a downloadable public basemap, view Apple Satellite as online-only, or import your own orthomosaic/GeoTIFF/GeoPDF."
    @State private var isWorking = false

    private var workingExtent: GeoExtent? {
        if let mapExtent = mapExtent { return mapExtent }
        if let currentCoordinate = currentCoordinate { return GeoExtent.around(currentCoordinate, radiusMeters: radiusMeters) }
        return nil
    }

    private var extentText: String {
        guard let extent = workingExtent else { return "No map extent or GPS location yet." }
        let source = mapExtent == nil ? "GPS fallback" : "current map"
        return String(format: "%@ extent: %@ | %.1f sq km", source, extent.bboxDescription, extent.approximateAreaSquareKilometers)
    }

    private var customURLRequired: Bool {
        selectedSource == .customArcGISRasterService
    }

    private var canCreate: Bool {
        guard workingExtent != nil, !isWorking else { return false }
        if selectedSource == .appleSatellitePreview { return true }
        if customURLRequired { return URL(string: customServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }
        return selectedSource.serviceURL != nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("Online vs offline"),
                    footer: Text("Apple Satellite is labeled online-only. USGS/TNM and authorized custom raster services can be saved as offline georeferenced PDF basemaps. User-imported GeoTIFF/GeoPDF imagery remains the best option for drone orthomosaics, county imagery, or project-specific satellite data.")
                ) {
                    Label("Offline-capable sources are saved into GeneratedMaps", systemImage: "externaldrive.fill")
                    Label("Apple Satellite Preview is not stored offline", systemImage: "wifi")
                }

                Section(header: Text("Area")) {
                    Text(extentText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if mapExtent == nil {
                        Picker("GPS fallback radius", selection: $radiusMeters) {
                            Text("500 m").tag(500.0)
                            Text("1 km").tag(1_000.0)
                            Text("2 km").tag(2_000.0)
                            Text("5 km").tag(5_000.0)
                        }
                    }
                }

                Section(header: Text("Swipe through basemap options")) {
                    TabView(selection: $selectedSource) {
                        ForEach(OfflineImageryTopoSource.allCases) { source in
                            VStack(alignment: .leading, spacing: 10) {
                                Label(source.longLabel, systemImage: source.icon)
                                    .font(.headline)
                                Text(source.isOfflineDownloadable ? "Downloadable for offline use" : "Online preview only")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(source.isOfflineDownloadable ? Color.green : Color.orange)
                                Text(source.fieldNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.brandSlate.opacity(0.08))
                            )
                            .tag(source)
                        }
                    }
                    .frame(height: 190)
                    .tabViewStyle(.page(indexDisplayMode: .automatic))

                    Picker("Selected source", selection: $selectedSource) {
                        ForEach(OfflineImageryTopoSource.allCases) { source in
                            Text(source.shortLabel).tag(source)
                        }
                    }
                }

                if selectedSource == .customArcGISRasterService {
                    Section(
                        header: Text("Custom imagery or historical service"),
                        footer: Text("Paste a public or authorized ArcGIS MapServer/ImageServer URL. Time-enabled services can expose years for historical imagery. The app exports the selected year into an offline PDF basemap when the service allows export.")
                    ) {
                        TextField("https://.../MapServer or .../ImageServer", text: $customServiceURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            Task { await discoverHistoricalYears() }
                        } label: {
                            Label("Discover Historical Years", systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(isWorking || URL(string: customServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)

                        if !discoveredYears.isEmpty {
                            Picker("Year", selection: Binding(
                                get: { selectedYear ?? discoveredYears.first },
                                set: { selectedYear = $0 }
                            )) {
                                ForEach(discoveredYears, id: \.self) { year in
                                    Text("\(year)").tag(Optional(year))
                                }
                            }
                        }
                    }
                }

                Section(
                    header: Text("USGS topo maps"),
                    footer: Text("Finds current US Topo and Historical Topographic Map Collection products for the current extent when TNM returns downloadable products. Historical maps usually include a map year/date in the title or metadata.")
                ) {
                    Button {
                        Task { await findTNMTopos() }
                    } label: {
                        Label("Find Current + Historical USGS Topos", systemImage: "map")
                    }
                    .disabled(isWorking || workingExtent == nil)

                    ForEach(tnmProducts) { product in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.title)
                                .font(.subheadline.weight(.semibold))
                            Text(product.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await downloadTNM(product) }
                            } label: {
                                Label("Download / Open", systemImage: "arrow.down.doc.fill")
                            }
                            .disabled(isWorking)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("Import your own imagery")) {
                    Button {
                        onImportOwnRaster()
                    } label: {
                        Label("Import GeoTIFF / GeoPDF Imagery", systemImage: "square.and.arrow.down")
                    }
                    Text("Use this for drone orthomosaics, county orthophotos, purchased satellite imagery, or RVT/DEM-derived raster maps. GeoTIFF and GeoPDF are displayable now. MBTiles/tile-package rendering will require a dedicated tile renderer in a later build.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Create basemap")) {
                    Button {
                        Task { await createSelectedBasemap() }
                    } label: {
                        Label(isWorking ? "Working…" : "Create / Preview Selected Basemap", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)

                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(isWorking ? Color.brandAmber : .secondary)
                }
            }
            .navigationTitle("Imagery / Topo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func createSelectedBasemap() async {
        guard let extent = workingExtent else {
            statusMessage = "Load a georeferenced map or wait for GPS before creating a basemap."
            return
        }
        isWorking = true
        statusMessage = selectedSource.isOfflineDownloadable ? "Creating offline basemap…" : "Opening online-only preview note…"
        let request = OfflineImageryTopoRequest(
            source: selectedSource,
            extent: extent,
            customServiceURL: customURLRequired ? customServiceURL : nil,
            year: selectedYear
        )
        statusMessage = await onCreateBasemap(request)
        isWorking = false
    }

    private func discoverHistoricalYears() async {
        let serviceURL = customServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceURL.isEmpty else { return }
        isWorking = true
        statusMessage = "Checking service metadata for time-enabled imagery…"
        do {
            discoveredYears = try await OfflineRasterMapServiceExporter.discoverYears(serviceURL: serviceURL)
            selectedYear = discoveredYears.first
            statusMessage = discoveredYears.isEmpty
                ? "No timeInfo/time extent was found. You can still download the current/default image."
                : "Found \(discoveredYears.count) possible year option\(discoveredYears.count == 1 ? "" : "s"). Swipe/pick a year, then create the basemap."
        } catch {
            statusMessage = "Could not discover years: \(error.localizedDescription)"
        }
        isWorking = false
    }

    private func findTNMTopos() async {
        guard let extent = workingExtent else { return }
        isWorking = true
        statusMessage = "Searching The National Map for topo products…"
        do {
            let current = (try? await TNMProductSearcher.search(extent: extent, datasetName: "US Topo")) ?? []
            let historic = (try? await TNMProductSearcher.search(extent: extent, datasetName: "Historical Topographic Maps")) ?? []
            let combined = Array((current + historic).prefix(50))
            tnmProducts = combined.sorted { left, right in
                (left.year ?? 0) > (right.year ?? 0)
            }
            statusMessage = combined.isEmpty
                ? "No downloadable USGS topo products were returned for this extent. Try reducing the map area or use the USGS Topo basemap option."
                : "Found \(combined.count) USGS topo product\(combined.count == 1 ? "" : "s"). Tap Download / Open on the map year you want."
        } catch {
            statusMessage = "USGS topo search failed: \(error.localizedDescription)"
        }
        isWorking = false
    }

    private func downloadTNM(_ product: TNMProduct) async {
        isWorking = true
        statusMessage = "Downloading \(product.title)…"
        statusMessage = await onDownloadTNMProduct(product)
        isWorking = false
    }
}

enum OfflineRasterMapServiceExporter {
    static func createPDF(
        serviceURL: String,
        extent: GeoExtent,
        title: String,
        label: String,
        year: Int?
    ) async throws -> URL {
        let image = try await exportImage(serviceURL: serviceURL, extent: extent, year: year)
        return try TerrainMapWriter.writePDFMap(
            image: image,
            extent: extent,
            title: title,
            label: label
        )
    }

    /// Fetch just the rendered raster (no PDF wrapper) so imagery/topo can
    /// be shown as a transparent overlay on the current basemap.
    static func fetchImage(
        serviceURL: String,
        extent: GeoExtent,
        year: Int?
    ) async throws -> UIImage {
        try await exportImage(serviceURL: serviceURL, extent: extent, year: year)
    }

    static func discoverYears(serviceURL: String) async throws -> [Int] {
        guard var components = URLComponents(string: normalizedServiceURL(serviceURL)) else { return [] }
        components.queryItems = [URLQueryItem(name: "f", value: "json")]
        guard let url = components.url else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timeInfo = json["timeInfo"] as? [String: Any],
              let extent = timeInfo["timeExtent"] as? [Any],
              extent.count >= 2,
              let startMS = numericMilliseconds(extent[0]),
              let endMS = numericMilliseconds(extent[1]),
              endMS > startMS else { return [] }

        let calendar = Calendar(identifier: .gregorian)
        let startYear = calendar.component(.year, from: Date(timeIntervalSince1970: startMS / 1000.0))
        let endYear = calendar.component(.year, from: Date(timeIntervalSince1970: endMS / 1000.0))
        guard startYear > 1800, endYear >= startYear else { return [] }
        let years = Array(startYear...endYear).reversed()
        return Array(years.prefix(80))
    }

    private static func exportImage(serviceURL: String, extent: GeoExtent, year: Int?) async throws -> UIImage {
        let normalized = normalizedServiceURL(serviceURL)
        let isImageServer = normalized.lowercased().contains("/imageserver")
        let endpoint = normalized + (isImageServer ? "/exportImage" : "/export")
        guard var components = URLComponents(string: endpoint) else {
            throw NSError(domain: "FieldMapper", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid imagery service URL."])
        }

        let maxDim = 2200
        let lonWidth = max(0.000001, extent.maxLongitude - extent.minLongitude)
        let latHeight = max(0.000001, extent.maxLatitude - extent.minLatitude)
        let aspect = max(0.25, min(4.0, lonWidth / latHeight))
        let width = aspect >= 1 ? maxDim : max(700, Int(Double(maxDim) * aspect))
        let height = aspect >= 1 ? max(700, Int(Double(maxDim) / aspect)) : maxDim

        var query: [URLQueryItem] = [
            URLQueryItem(name: "bbox", value: "\(extent.minLongitude),\(extent.minLatitude),\(extent.maxLongitude),\(extent.maxLatitude)"),
            URLQueryItem(name: "bboxSR", value: "4326"),
            URLQueryItem(name: isImageServer ? "imageSR" : "imageSR", value: "4326"),
            URLQueryItem(name: "size", value: "\(width),\(height)"),
            URLQueryItem(name: "format", value: isImageServer ? "jpgpng" : "jpg"),
            URLQueryItem(name: "transparent", value: "false"),
            URLQueryItem(name: "f", value: "image")
        ]
        if !isImageServer {
            query.append(URLQueryItem(name: "dpi", value: "96"))
        }
        if let year = year {
            let start = epochMilliseconds(year: year, month: 1, day: 1)
            let end = epochMilliseconds(year: year, month: 12, day: 31)
            query.append(URLQueryItem(name: "time", value: "\(start),\(end)"))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw NSError(domain: "FieldMapper", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not build export URL."])
        }

        var request = URLRequest(url: url)
        request.setValue("AvenzaStyleFieldMapper/1.0 field survey app", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "FieldMapper", code: 12, userInfo: [NSLocalizedDescriptionKey: "Imagery service export failed."])
        }
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "FieldMapper", code: 13, userInfo: [NSLocalizedDescriptionKey: "The service did not return an image. It may not allow export for this extent/year."])
        }
        return image
    }

    private static func normalizedServiceURL(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let queryRange = text.range(of: "?") { text = String(text[..<queryRange.lowerBound]) }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/export") { text = String(text.dropLast(7)) }
        if text.lowercased().hasSuffix("/exportimage") { text = String(text.dropLast(12)) }
        return text
    }

    private static func numericMilliseconds(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func epochMilliseconds(year: Int, month: Int, day: Int) -> Int64 {
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        comps.year = year
        comps.month = month
        comps.day = day
        let date = comps.date ?? Date()
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

enum TNMProductSearcher {
    static func search(extent: GeoExtent, datasetName: String) async throws -> [TNMProduct] {
        guard var components = URLComponents(string: "https://tnmaccess.nationalmap.gov/api/v1/products") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "bbox", value: "\(extent.minLongitude),\(extent.minLatitude),\(extent.maxLongitude),\(extent.maxLatitude)"),
            URLQueryItem(name: "datasets", value: datasetName),
            URLQueryItem(name: "prodFormats", value: "GeoPDF,GeoTIFF"),
            URLQueryItem(name: "max", value: "50"),
            URLQueryItem(name: "outputFormat", value: "JSON")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("AvenzaStyleFieldMapper/1.0 field survey app", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.compactMap { product(from: $0, fallbackDataset: datasetName) }
    }

    private static func product(from json: [String: Any], fallbackDataset: String) -> TNMProduct? {
        let title = (json["title"] as? String)
            ?? (json["name"] as? String)
            ?? (json["quadName"] as? String)
            ?? fallbackDataset
        let id = (json["sourceId"] as? String)
            ?? (json["id"] as? String)
            ?? (json["downloadURL"] as? String)
            ?? UUID().uuidString
        let format = (json["format"] as? String)
            ?? (json["productFormat"] as? String)
            ?? "USGS map product"
        let scale = (json["scale"] as? String)
            ?? (json["scaleText"] as? String)
            ?? ""
        let downloadURL = (json["downloadURL"] as? String)
            ?? (json["downloadUrl"] as? String)
            ?? (json["url"] as? String)
        let year = inferYear(from: json, title: title)
        return TNMProduct(id: id, title: title, year: year, scale: scale, productFormat: format, downloadURLString: downloadURL)
    }

    private static func inferYear(from json: [String: Any], title: String) -> Int? {
        for key in ["publicationDate", "date", "dateOnMap", "year"] {
            if let value = json[key] as? String, let year = firstYear(in: value) { return year }
            if let value = json[key] as? NSNumber { return value.intValue }
        }
        return firstYear(in: title)
    }

    private static func firstYear(in text: String) -> Int? {
        let pattern = #"\b(18\d{2}|19\d{2}|20\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

struct OfflineBasemapSetupView: View {
    @Environment(\.dismiss) private var dismiss

    let currentCoordinate: CLLocationCoordinate2D?
    let onComplete: (GeoExtent, [MapLayer], String, OfflineRasterBasemapStyle) -> Void

    @State private var centerLatitudeText: String
    @State private var centerLongitudeText: String
    @State private var radiusMeters = 1_000.0
    @State private var customRadiusText = ""
    @State private var useCustomRadius = false
    @State private var includeRoadsTrails = true
    @State private var includeWater = true
    @State private var includePublicLand = true
    @State private var includeHistoric = false
    @State private var includeBuildings = false
    @State private var rasterStyle: OfflineRasterBasemapStyle = .appleStandard
    @State private var isDownloading = false
    @State private var message = "Choose an area while you have cell service. The app can create a real raster map-image background and save OSM vector layers for offline use."

    init(
        currentCoordinate: CLLocationCoordinate2D?,
        onComplete: @escaping (GeoExtent, [MapLayer], String, OfflineRasterBasemapStyle) -> Void
    ) {
        self.currentCoordinate = currentCoordinate
        self.onComplete = onComplete
        _centerLatitudeText = State(initialValue: currentCoordinate.map { String(format: "%.6f", $0.latitude) } ?? "")
        _centerLongitudeText = State(initialValue: currentCoordinate.map { String(format: "%.6f", $0.longitude) } ?? "")
    }

    private var parsedCenter: CLLocationCoordinate2D? {
        guard let latitude = Double(centerLatitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let longitude = Double(centerLongitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var selectedRadiusMeters: Double? {
        if useCustomRadius {
            guard let value = Double(customRadiusText.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
            return min(max(value, 100), 10_000)
        }
        return radiusMeters
    }

    private var selectedExtent: GeoExtent? {
        guard let center = parsedCenter, let radius = selectedRadiusMeters else { return nil }
        let extent = GeoExtent.around(center, radiusMeters: radius)
        return extent.isValid ? extent : nil
    }

    private var selectedDatasets: [OnlineDataset] {
        OnlineDataset.builtIn.filter { dataset in
            switch dataset.id {
            case "osm_roads_trails":
                return includeRoadsTrails
            case "osm_water":
                return includeWater
            case "osm_buildings":
                return includeBuildings
            case "osm_public_land":
                return includePublicLand
            case "osm_historic_public":
                return includeHistoric
            default:
                return false
            }
        }
    }

    private var extentSummary: String {
        guard let extent = selectedExtent else { return "Enter a valid center coordinate and radius." }
        return String(format: "%@ | about %.1f sq km", extent.bboxDescription, extent.approximateAreaSquareKilometers)
    }

    private var canDownload: Bool {
        selectedExtent != nil && (!selectedDatasets.isEmpty || rasterStyle != .blankVector) && !isDownloading
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Area center")) {
                    if let currentCoordinate = currentCoordinate {
                        Button {
                            centerLatitudeText = String(format: "%.6f", currentCoordinate.latitude)
                            centerLongitudeText = String(format: "%.6f", currentCoordinate.longitude)
                        } label: {
                            Label("Use Current GPS Location", systemImage: "location.fill")
                        }
                    } else {
                        Text("Waiting for GPS. You can also type a latitude and longitude manually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Center latitude", text: $centerLatitudeText)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Center longitude", text: $centerLongitudeText)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(header: Text("Area size")) {
                    Toggle("Custom radius", isOn: $useCustomRadius)

                    if useCustomRadius {
                        TextField("Radius in meters, 100 to 10000", text: $customRadiusText)
                            .keyboardType(.decimalPad)
                    } else {
                        Picker("Radius", selection: $radiusMeters) {
                            Text("250 m").tag(250.0)
                            Text("500 m").tag(500.0)
                            Text("1 km").tag(1_000.0)
                            Text("2 km").tag(2_000.0)
                            Text("5 km").tag(5_000.0)
                        }
                    }

                    Text(extentSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Raster background")) {
                    Picker("Basemap image", selection: $rasterStyle) {
                        ForEach(OfflineRasterBasemapStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Text(rasterStyle.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Editable OSM vector layers")) {
                    Toggle("Roads, tracks, trails, paths", isOn: $includeRoadsTrails)
                    Toggle("Waterways and water polygons", isOn: $includeWater)
                    Toggle("Parks, forest, protected areas", isOn: $includePublicLand)
                    Toggle("Historic/public landmarks", isOn: $includeHistoric)
                    Toggle("Buildings (small areas only)", isOn: $includeBuildings)
                }

                Section {
                    Button {
                        Task { await downloadOfflineBasemap() }
                    } label: {
                        Label(isDownloading ? "Downloading…" : "Create Offline Map Area", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!canDownload)

                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isDownloading ? Color.brandAmber : .secondary)
                }
            }
            .navigationTitle("Offline Map Area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func downloadOfflineBasemap() async {
        guard let extent = selectedExtent else {
            message = "Enter a valid center coordinate and radius."
            return
        }

        let datasets = selectedDatasets
        guard !datasets.isEmpty || rasterStyle != .blankVector else {
            message = "Choose a raster background or turn on at least one OSM vector layer."
            return
        }

        isDownloading = true
        message = rasterStyle == .blankVector
            ? "Downloading OSM vector basemap layers…"
            : "Creating raster basemap and downloading selected OSM vector layers…"
        defer { isDownloading = false }

        var allLayers: [MapLayer] = []
        var skipped: [String] = []
        var failures: [String] = []

        for dataset in datasets {
            guard extent.approximateAreaSquareKilometers <= dataset.recommendedMaxAreaSquareKilometers else {
                skipped.append(dataset.title)
                continue
            }

            do {
                let layers = try await OnlineDataFetcher.layers(for: dataset, extent: extent)
                allLayers.append(contentsOf: layers)
            } catch {
                failures.append(dataset.title)
            }
        }

        if allLayers.isEmpty, rasterStyle == .blankVector {
            if !skipped.isEmpty {
                message = "That area is too large for: \(skipped.joined(separator: ", ")). Reduce the radius or turn off dense layers like Buildings."
            } else if !failures.isEmpty {
                message = "Download failed for: \(failures.joined(separator: ", ")). Check service/cell connection and try again."
            } else {
                message = "No OSM features found for this area."
            }
            return
        }

        onComplete(extent, allLayers, "OSM offline basemap", rasterStyle)

        var status = rasterStyle == .blankVector
            ? "Downloaded \(allLayers.count) OSM feature\(allLayers.count == 1 ? "" : "s") and created an offline map."
            : "Created \(rasterStyle.label) and downloaded \(allLayers.count) OSM feature\(allLayers.count == 1 ? "" : "s")."
        if !skipped.isEmpty {
            status += " Skipped large layers: \(skipped.joined(separator: ", "))."
        }
        if !failures.isEmpty {
            status += " Some layers failed: \(failures.joined(separator: ", "))."
        }
        message = status
        dismiss()
    }
}


struct DPRAutofillSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let mapName: String
    let extentDescription: String
    let hasElevationGrid: Bool
    let onDownloadAll: () async -> String
    let onOpenCatalog: () -> Void
    let onOpenImageryTopo: () -> Void

    @State private var isDownloading = false
    @State private var statusMessage = "Download once while online. The layers and elevation grid are then stored locally for DPR form autofill."

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("DPR autofill for this map")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(mapName, systemImage: "map.fill")
                            .font(.headline)
                        Text(extentDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(isDownloading ? Color.brandAmber : .secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(
                    header: Text("Download offline autofill data"),
                    footer: Text("This stores BLM PLSS township/range/section polygons, USGS 7.5-minute quadrangle/date footprints, county boundaries, and a USGS 3DEP elevation grid for the current map extent. DPR forms attached to points, lines, tracks, or polygons can then auto-fill UTM, elevation, county, quad/date, and legal-location fields offline.")
                ) {
                    Button {
                        Task { await downloadAll() }
                    } label: {
                        Label("Download PLSS + Quad + County + Elevation", systemImage: "arrow.down.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading)

                    Button {
                        onOpenCatalog()
                    } label: {
                        Label("Open Advanced Download Options", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(isDownloading)

                    Button {
                        onOpenImageryTopo()
                    } label: {
                        Label("Open Imagery / Topo Basemap Options", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(isDownloading)
                }

                Section(header: Text("Autofill targets")) {
                    Label("DPR 523A County, Quad/Date, Township/Range/Section, UTM, elevation", systemImage: "doc.text")
                    Label("DPR 523C elevation, dimensions, location context", systemImage: "doc.text")
                    Label("DPR 523E line location and segment length", systemImage: "doc.text")
                    Label("DPR 523J/K map name and date fields when applicable", systemImage: "map")
                }

                Section(header: Text("Status")) {
                    Label(hasElevationGrid ? "Elevation grid already exists for this map" : "Elevation grid not saved yet", systemImage: hasElevationGrid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
            }
            .navigationTitle("DPR Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func downloadAll() async {
        isDownloading = true
        statusMessage = "Downloading DPR autofill pack…"
        let result = await onDownloadAll()
        statusMessage = result
        isDownloading = false
    }
}

struct OnlineDataCatalogView: View {
    @Environment(\.dismiss) private var dismiss

    let mapExtent: GeoExtent?
    let currentCoordinate: CLLocationCoordinate2D?
    @ObservedObject var arcGISAuth: ArcGISAuthManager
    let onDownloadDPRPack: (() async -> String)?
    let onImport: ([MapLayer], String) -> Void

    @State private var isDownloading = false
    @State private var message = "Download public datasets while you have service. They are saved as normal app layers for offline use."
    @State private var customURLText = ""

    @AppStorage("arcGISPortalURL") private var arcGISPortalURL = "https://www.arcgis.com"
    @AppStorage("arcGISOAuthClientID") private var arcGISClientID = ""
    @AppStorage("arcGISRedirectURI") private var arcGISRedirectURI = "fieldmapper://auth"
    @State private var arcGISLayerText = ""
    @State private var arcGISLayerIDText = "0"
    @State private var arcGISSearchText = ""
    @State private var arcGISSearchResults: [ArcGISPortalSearchItem] = []
    @State private var arcGISGroups: [ArcGISPortalGroup] = []
    @State private var selectedArcGISGroup: ArcGISPortalGroup?
    @State private var arcGISGroupItems: [ArcGISPortalSearchItem] = []
    @State private var arcGISGroupFilterText = ""

    private var downloadExtent: GeoExtent? {
        if let mapExtent = mapExtent, mapExtent.isValid {
            return mapExtent
        }
        if let currentCoordinate = currentCoordinate {
            return GeoExtent.around(currentCoordinate, radiusMeters: 1_000)
        }
        return nil
    }

    private var extentLabel: String {
        guard let extent = downloadExtent else { return "No map extent or GPS fix available yet." }
        let source = mapExtent == nil ? "GPS 1 km fallback" : "current GeoPDF extent"
        return String(format: "Using %@: %@ (about %.1f sq km)", source, extent.bboxDescription, extent.approximateAreaSquareKilometers)
    }

    private var filteredArcGISGroups: [ArcGISPortalGroup] {
        let filter = arcGISGroupFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !filter.isEmpty else { return arcGISGroups }
        return arcGISGroups.filter { group in
            group.title.lowercased().contains(filter)
            || group.id.lowercased().contains(filter)
            || (group.owner?.lowercased().contains(filter) ?? false)
            || (group.description?.lowercased().contains(filter) ?? false)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(extentLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isDownloading ? Color.brandAmber : .secondary)
                } header: {
                    Text("Download area")
                }

                Section(header: Text("DPR 523 autofill setup")) {
                    Button {
                        Task { await downloadDPRAutofillPack() }
                    } label: {
                        Label("Download DPR Autofill Pack", systemImage: "doc.badge.gearshape")
                    }
                    .disabled(isDownloading || downloadExtent == nil)

                    ForEach(OnlineDataset.dprLocationAutofill) { dataset in
                        datasetRow(dataset)
                    }

                    Text("One field-office setup download for this map: PLSS township/range/section, USGS 7.5-minute quad/date, county boundaries, and offline elevation. DPR forms then auto-fill UTM, elevation, county, quad/date, and legal-location fields from local data.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Offline imagery / topo basemaps")) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Use Import > Offline Imagery / Topo…", systemImage: "photo.on.rectangle.angled")
                    }
                    Text("For raster basemaps, use the dedicated Imagery / Topo download center. It separates online-only Apple Satellite preview from downloadable public USGS imagery/topo sources and user-imported GeoTIFF/GeoPDF imagery.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("PLSS township / range / sections")) {
                    Button {
                        Task { await downloadPLSSPack() }
                    } label: {
                        Label("Download PLSS Township/Range + Sections", systemImage: "square.grid.3x3")
                    }
                    .disabled(isDownloading || downloadExtent == nil)

                    ForEach(OnlineDataset.plss) { dataset in
                        datasetRow(dataset)
                    }

                    Text("Downloads BLM PLSS township/range and section polygons for the current extent. Once saved offline, linked DPR forms can auto-fill township, range, section, and PLSS legal-location text from the local layers.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Forest Service public layers")) {
                    ForEach(OnlineDataset.forestService) { dataset in
                        datasetRow(dataset)
                    }
                }

                Section(header: Text("OpenStreetMap public layers")) {
                    ForEach(OnlineDataset.builtIn) { dataset in
                        datasetRow(dataset)
                    }
                }

                Section(header: Text("Offline OpenStreetMap vector basemap")) {
                    Button {
                        Task { await downloadOSMVectorBasemapPack() }
                    } label: {
                        Label("Download OSM Basemap Pack", systemImage: "map.fill")
                    }
                    .disabled(isDownloading || downloadExtent == nil)

                    Text("Downloads roads/trails, water, parks/public land, public historic landmarks, and buildings when the area is small enough. These are saved as normal offline layers. If no GeoPDF is open, the app creates a blank georeferenced map around your GPS fix.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("ArcGIS Online / Enterprise private org")) {
                    TextField("Portal URL", text: $arcGISPortalURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("OAuth Client ID", text: $arcGISClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Redirect URI", text: $arcGISRedirectURI)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    HStack(spacing: 10) {
                        Button {
                            Task { await signInToArcGIS() }
                        } label: {
                            Label(arcGISAuth.isSignedIn ? "Reauthorize" : "Sign In", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDownloading)

                        Button("Sign Out") {
                            arcGISAuth.signOut()
                            arcGISSearchResults.removeAll()
                            arcGISGroups.removeAll()
                            arcGISGroupItems.removeAll()
                            selectedArcGISGroup = nil
                        }
                        .disabled(!arcGISAuth.isSignedIn || isDownloading)
                    }

                    Text(arcGISAuth.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("The Sign In button opens the official ArcGIS Online or Enterprise login page. After sign-in, use My Groups to browse group content you are allowed to access, then download layers into this app for offline use.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("ArcGIS My Groups")) {
                    HStack(spacing: 10) {
                        TextField("Filter groups", text: $arcGISGroupFilterText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            Task { await loadArcGISGroups() }
                        } label: {
                            Label("Load", systemImage: "person.3")
                                .labelStyle(.titleOnly)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!arcGISAuth.isSignedIn || isDownloading)
                    }

                    if let group = selectedArcGISGroup {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Selected: \(group.title)")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(arcGISGroupItems.count) item\(arcGISGroupItems.count == 1 ? "" : "s") loaded")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Clear") {
                                selectedArcGISGroup = nil
                                arcGISGroupItems.removeAll()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    ForEach(filteredArcGISGroups) { group in
                        arcGISGroupRow(group)
                    }

                    if arcGISGroups.isEmpty {
                        Text("Tap Load after signing in to list groups from your ArcGIS account. Only content your account can access will appear.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if selectedArcGISGroup != nil {
                    Section(header: Text("Selected Group Items")) {
                        ForEach(arcGISGroupItems) { item in
                            arcGISItemRow(item, sourceLabel: selectedArcGISGroup?.title ?? "ArcGIS Group")
                        }

                        if arcGISGroupItems.isEmpty {
                            Text("No downloadable Feature Service or Map Service items were found for this group yet. Some Web Maps can still be downloaded if they contain operational FeatureServer/MapServer layers.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(header: Text("ArcGIS Search / Direct Download")) {
                    TextField("Feature layer URL, Web Map ID, or ArcGIS item ID", text: $arcGISLayerText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Layer ID if item/service root", text: $arcGISLayerIDText)
                        .keyboardType(.numberPad)

                    Button {
                        Task { await downloadArcGISLayerOrItem() }
                    } label: {
                        Label("Download ArcGIS Layer", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(!arcGISAuth.isSignedIn || arcGISLayerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDownloading || downloadExtent == nil)

                    TextField("Search my ArcGIS org/content", text: $arcGISSearchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await searchArcGIS() }
                    } label: {
                        Label("Search ArcGIS", systemImage: "magnifyingglass")
                    }
                    .disabled(!arcGISAuth.isSignedIn || arcGISSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDownloading)

                    ForEach(arcGISSearchResults) { item in
                        arcGISItemRow(item, sourceLabel: "ArcGIS Search")
                    }

                    Text("For private data, create an ArcGIS OAuth app, add your redirect URI to the app item, and add the same URL scheme in Xcode. Download only layers you are authorized to store offline.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Custom public KML / GeoJSON URL")) {
                    TextField("https://example.org/layer.kml or .geojson", text: $customURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        Task { await downloadCustomURL() }
                    } label: {
                        Label("Download Custom URL", systemImage: "link")
                    }
                    .disabled(customURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDownloading)

                    Text("Use this for direct public KML, GeoJSON, or ArcGIS REST query URLs that already return GeoJSON. Do not use private or restricted cultural-resource datasets unless you have permission.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Online Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func arcGISGroupRow(_ group: ArcGISPortalGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text([group.owner.map { "Owner: \($0)" }, group.itemCount.map { "\($0) item\($0 == 1 ? "" : "s")" }]
                        .compactMap { $0 }
                        .joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let description = group.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer()
                Button(selectedArcGISGroup?.id == group.id ? "Reload" : "Open") {
                    Task { await loadArcGISGroupItems(group) }
                }
                .buttonStyle(.bordered)
                .disabled(!arcGISAuth.isSignedIn || isDownloading)
            }
        }
        .padding(.vertical, 4)
    }

    private func arcGISItemRow(_ item: ArcGISPortalSearchItem, sourceLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            Text("\(item.type) • \(item.owner ?? "unknown owner")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = item.url, !url.isEmpty {
                Text(url)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await downloadArcGISItem(item, sourceLabel: sourceLabel) }
                } label: {
                    Label("Download Current Extent", systemImage: "square.and.arrow.down")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!arcGISAuth.isSignedIn || downloadExtent == nil || isDownloading)

                Button {
                    arcGISLayerText = item.id
                    message = "Loaded \(item.title). Tap Download ArcGIS Layer to fetch the current map extent."
                } label: {
                    Label("Use ID", systemImage: "doc.on.doc")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 5)
    }

    private func datasetRow(_ dataset: OnlineDataset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dataset.title)
                        .font(.headline)
                    Text(dataset.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dataset.caution)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") {
                    Task { await download(dataset) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDownload(dataset) || isDownloading)
            }

            if let extent = downloadExtent,
               extent.approximateAreaSquareKilometers > dataset.recommendedMaxAreaSquareKilometers {
                Text(String(format: "Zoom in first. Recommended max %.0f sq km; current extent is %.1f sq km.", dataset.recommendedMaxAreaSquareKilometers, extent.approximateAreaSquareKilometers))
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 5)
    }

    private func canDownload(_ dataset: OnlineDataset) -> Bool {
        guard let extent = downloadExtent, extent.isValid else { return false }
        return extent.approximateAreaSquareKilometers <= dataset.recommendedMaxAreaSquareKilometers
    }

    private func downloadDPRAutofillPack() async {
        guard downloadExtent != nil else {
            message = "No GeoPDF extent or GPS fix available. Import a georeferenced map or wait for GPS."
            return
        }
        isDownloading = true
        message = "Downloading DPR autofill data…"
        defer { isDownloading = false }

        if let onDownloadDPRPack = onDownloadDPRPack {
            message = await onDownloadDPRPack()
        } else {
            await downloadDPRAutofillLayersOnly()
        }
    }

    private func downloadDPRAutofillLayersOnly() async {
        guard let extent = downloadExtent else { return }
        var allLayers: [MapLayer] = []
        var failures: [String] = []

        for dataset in OnlineDataset.dprAutofill where extent.approximateAreaSquareKilometers <= dataset.recommendedMaxAreaSquareKilometers {
            do {
                let layers = try await OnlineDataFetcher.layers(for: dataset, extent: extent)
                allLayers.append(contentsOf: layers)
            } catch {
                failures.append(dataset.title)
            }
        }

        guard !allLayers.isEmpty else {
            message = failures.isEmpty ? "No DPR autofill features were found for this extent." : "DPR autofill download failed for: \(failures.joined(separator: ", "))."
            return
        }
        onImport(allLayers, "DPR 523 Autofill Pack")
        message = failures.isEmpty
            ? "Saved \(allLayers.count) DPR autofill feature\(allLayers.count == 1 ? "" : "s") for offline form fillout."
            : "Saved \(allLayers.count) DPR autofill features. Some downloads failed: \(failures.joined(separator: ", "))."
    }

    private func downloadOSMVectorBasemapPack() async {
        guard let extent = downloadExtent else {
            message = "No GeoPDF extent or GPS fix available. Import a georeferenced map or wait for GPS."
            return
        }

        isDownloading = true
        message = "Downloading OSM vector basemap pack…"
        defer { isDownloading = false }

        var allLayers: [MapLayer] = []
        var failures: [String] = []

        for dataset in OnlineDataset.builtIn where extent.approximateAreaSquareKilometers <= dataset.recommendedMaxAreaSquareKilometers {
            do {
                let layers = try await OnlineDataFetcher.layers(for: dataset, extent: extent)
                allLayers.append(contentsOf: layers)
            } catch {
                failures.append(dataset.title)
            }
        }

        guard !allLayers.isEmpty else {
            message = failures.isEmpty
                ? "No OSM basemap features were found, or the extent is too large for the available OSM presets."
                : "OSM basemap download failed for: \(failures.joined(separator: ", "))."
            return
        }

        onImport(allLayers, "OSM Offline Vector Basemap")
        if failures.isEmpty {
            message = "Saved \(allLayers.count) OSM basemap feature\(allLayers.count == 1 ? "" : "s") for offline use."
        } else {
            message = "Saved \(allLayers.count) OSM basemap features. Some downloads failed: \(failures.joined(separator: ", "))."
        }
    }

    private func downloadPLSSPack() async {
        guard let extent = downloadExtent else {
            message = "No GeoPDF extent or GPS fix available. Import a georeferenced map or wait for GPS."
            return
        }
        isDownloading = true
        message = "Downloading PLSS township/range and section layers…"
        defer { isDownloading = false }

        var allLayers: [MapLayer] = []
        var failures: [String] = []
        for dataset in OnlineDataset.plss where extent.approximateAreaSquareKilometers <= dataset.recommendedMaxAreaSquareKilometers {
            do {
                let layers = try await OnlineDataFetcher.layers(for: dataset, extent: extent)
                allLayers.append(contentsOf: layers)
            } catch {
                failures.append(dataset.title)
            }
        }

        guard !allLayers.isEmpty else {
            message = failures.isEmpty
                ? "No PLSS features were found. PLSS coverage may not exist for this area or the extent may be too large."
                : "PLSS download failed for: \(failures.joined(separator: ", "))."
            return
        }

        onImport(allLayers, "BLM PLSS")
        if failures.isEmpty {
            message = "Saved \(allLayers.count) PLSS township/range and section feature\(allLayers.count == 1 ? "" : "s") for offline DPR autofill."
        } else {
            message = "Saved \(allLayers.count) PLSS features. Some downloads failed: \(failures.joined(separator: ", "))."
        }
    }

    private func download(_ dataset: OnlineDataset) async {
        guard let extent = downloadExtent else {
            message = "No GeoPDF extent or GPS fix available. Import a georeferenced map or wait for GPS."
            return
        }

        isDownloading = true
        message = "Downloading \(dataset.title)…"
        defer { isDownloading = false }

        do {
            let layers = try await OnlineDataFetcher.layers(for: dataset, extent: extent)
            guard !layers.isEmpty else {
                message = "No features found for \(dataset.title) in this extent."
                return
            }
            onImport(layers, dataset.title)
            message = "Saved \(layers.count) feature\(layers.count == 1 ? "" : "s") from \(dataset.title) for offline use."
        } catch {
            message = "Download failed: \(error.localizedDescription)"
        }
    }

    private func signInToArcGIS() async {
        isDownloading = true
        message = "Signing in to ArcGIS…"
        defer { isDownloading = false }
        do {
            try await arcGISAuth.signIn(portalURL: arcGISPortalURL, clientID: arcGISClientID, redirectURI: arcGISRedirectURI)
            message = "Signed in. Tap Load under My Groups to browse private group content."
        } catch {
            message = "ArcGIS sign-in failed: \(error.localizedDescription)"
        }
    }

    private func loadArcGISGroups() async {
        isDownloading = true
        message = "Loading ArcGIS groups…"
        defer { isDownloading = false }
        do {
            let token = try await arcGISAuth.validAccessToken(portalURL: arcGISPortalURL, clientID: arcGISClientID)
            let groups = try await OnlineDataFetcher.arcGISUserGroups(
                portalURL: arcGISPortalURL,
                token: token
            )
            arcGISGroups = groups
            selectedArcGISGroup = nil
            arcGISGroupItems.removeAll()
            message = groups.isEmpty ? "No ArcGIS groups were returned for this account." : "Loaded \(groups.count) ArcGIS group\(groups.count == 1 ? "" : "s"). Tap Open on a group to list its items."
        } catch {
            message = "ArcGIS group load failed: \(error.localizedDescription)"
        }
    }

    private func loadArcGISGroupItems(_ group: ArcGISPortalGroup) async {
        isDownloading = true
        message = "Loading group items from \(group.title)…"
        defer { isDownloading = false }
        do {
            let token = try await arcGISAuth.validAccessToken(portalURL: arcGISPortalURL, clientID: arcGISClientID)
            let items = try await OnlineDataFetcher.arcGISGroupItems(
                portalURL: arcGISPortalURL,
                token: token,
                groupID: group.id
            )
            selectedArcGISGroup = group
            arcGISGroupItems = items
            message = items.isEmpty ? "No Feature Service, Map Service, or Web Map items found in \(group.title)." : "Loaded \(items.count) item\(items.count == 1 ? "" : "s") from \(group.title)."
        } catch {
            message = "ArcGIS group item load failed: \(error.localizedDescription)"
        }
    }

    private func downloadArcGISItem(_ item: ArcGISPortalSearchItem, sourceLabel: String) async {
        arcGISLayerText = item.id
        await downloadArcGISLayerOrItem(defaultGroup: "ArcGIS: \(sourceLabel)", defaultColor: .blue)
    }

    private func searchArcGIS() async {
        isDownloading = true
        message = "Searching ArcGIS…"
        defer { isDownloading = false }
        do {
            let token = try await arcGISAuth.validAccessToken(portalURL: arcGISPortalURL, clientID: arcGISClientID)
            let results = try await OnlineDataFetcher.searchArcGISPortal(
                portalURL: arcGISPortalURL,
                token: token,
                query: arcGISSearchText
            )
            arcGISSearchResults = results
            message = results.isEmpty ? "No ArcGIS items found." : "Found \(results.count) ArcGIS item\(results.count == 1 ? "" : "s")."
        } catch {
            message = "ArcGIS search failed: \(error.localizedDescription)"
        }
    }

    private func downloadArcGISLayerOrItem(defaultGroup: String = "ArcGIS Online / Enterprise", defaultColor: LayerColor = .blue) async {
        guard let extent = downloadExtent else {
            message = "No GeoPDF extent or GPS fix available."
            return
        }
        isDownloading = true
        message = "Downloading ArcGIS layer…"
        defer { isDownloading = false }
        do {
            let token = try await arcGISAuth.validAccessToken(portalURL: arcGISPortalURL, clientID: arcGISClientID)
            let layerID = Int(arcGISLayerIDText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let result = try await OnlineDataFetcher.layersFromArcGISInput(
                arcGISLayerText,
                portalURL: arcGISPortalURL,
                token: token,
                extent: extent,
                layerID: layerID,
                defaultGroup: defaultGroup,
                defaultColor: defaultColor
            )
            guard !result.layers.isEmpty else {
                message = "No ArcGIS features found in this extent."
                return
            }
            onImport(result.layers, result.sourceName)
            message = "Saved \(result.layers.count) ArcGIS feature\(result.layers.count == 1 ? "" : "s") from \(result.sourceName)."
        } catch {
            message = "ArcGIS download failed: \(error.localizedDescription)"
        }
    }

    private func downloadCustomURL() async {
        let trimmed = customURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            message = "Enter a valid http or https URL."
            return
        }

        isDownloading = true
        message = "Downloading custom layer…"
        defer { isDownloading = false }

        do {
            let layers = try await OnlineDataFetcher.layers(fromDirectURL: url)
            guard !layers.isEmpty else {
                message = "No KML or GeoJSON features were found at that URL."
                return
            }
            onImport(layers, url.lastPathComponent.isEmpty ? "Custom URL" : url.lastPathComponent)
            message = "Saved \(layers.count) custom online feature\(layers.count == 1 ? "" : "s") for offline use."
        } catch {
            message = "Custom download failed: \(error.localizedDescription)"
        }
    }
}

enum OnlineDataError: LocalizedError {
    case badResponse
    case httpStatus(Int)
    case noUsableData
    case invalidURL
    case arcGISError(String)

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The server response was not readable."
        case .httpStatus(let code):
            return "The server returned HTTP \(code)."
        case .noUsableData:
            return "The downloaded file did not contain importable KML, GeoJSON, or ArcGIS geometry."
        case .invalidURL:
            return "The online layer URL or item ID was not valid."
        case .arcGISError(let message):
            return message
        }
    }
}

enum OnlineDataFetcher {
    static func layers(for dataset: OnlineDataset, extent: GeoExtent) async throws -> [MapLayer] {
        switch dataset.sourceKind {
        case .overpass(let preset):
            let query = preset.query(extent: extent)
            let data = try await postOverpass(query)
            return OverpassImporter.layers(from: data, dataset: dataset)
        case .arcGISREST(let endpoint):
            let layers = try await queryArcGISLayer(
                layerURL: endpoint.layerURL,
                extent: extent,
                token: nil,
                groupName: dataset.groupName,
                color: dataset.color,
                sourceName: dataset.title
            )
            return layers
        }
    }

    static func layers(fromDirectURL url: URL) async throws -> [MapLayer] {
        var request = URLRequest(url: url)
        request.setValue("AvenzaStyleFieldMapper/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OnlineDataError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw OnlineDataError.httpStatus(http.statusCode) }

        let extensionName = url.pathExtension.lowercased()
        var layers: [MapLayer]
        if extensionName == "kml" || extensionName == "xml" {
            layers = KMLImporter.layers(from: data)
            if layers.isEmpty { layers = GeoJSONImporter.layers(from: data) }
            if layers.isEmpty { layers = ArcGISJSONImporter.layers(from: data) }
        } else {
            layers = GeoJSONImporter.layers(from: data)
            if layers.isEmpty { layers = ArcGISJSONImporter.layers(from: data) }
            if layers.isEmpty { layers = KMLImporter.layers(from: data) }
        }

        guard !layers.isEmpty else { throw OnlineDataError.noUsableData }
        return decorate(layers, groupName: "Online: Custom URL", color: nil, sourceName: "Custom URL", sourceURL: url.absoluteString)
    }

    static func layersFromArcGISInput(
        _ input: String,
        portalURL: String,
        token: String,
        extent: GeoExtent,
        layerID: Int,
        defaultGroup: String,
        defaultColor: LayerColor
    ) async throws -> (layers: [MapLayer], sourceName: String) {
        let resolved = try await resolveArcGISLayerURL(
            input: input,
            portalURL: portalURL,
            token: token,
            layerID: layerID
        )
        let layers = try await queryArcGISLayer(
            layerURL: resolved.layerURL.absoluteString,
            extent: extent,
            token: token,
            groupName: defaultGroup,
            color: defaultColor,
            sourceName: resolved.title
        )
        return (layers, resolved.title)
    }

    static func searchArcGISPortal(portalURL: String, token: String, query: String) async throws -> [ArcGISPortalSearchItem] {
        let portal = try ArcGISAuthManager.normalizedPortalURL(portalURL)
        let url = portal.appendingArcGISPath("sharing/rest/search")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = [
            "f": "json",
            "q": q.isEmpty ? "(type:\"Feature Service\" OR type:\"Map Service\")" : "\(q) AND (type:\"Feature Service\" OR type:\"Map Service\")",
            "num": "20",
            "token": token
        ]
        let data = try await postForm(to: url, body: body)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OnlineDataError.badResponse
        }
        try throwIfArcGISError(json)
        let results = json["results"] as? [[String: Any]] ?? []
        return results.compactMap { item in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String else { return nil }
            return ArcGISPortalSearchItem(
                id: id,
                title: title,
                type: item["type"] as? String ?? "ArcGIS Item",
                url: item["url"] as? String,
                owner: item["owner"] as? String
            )
        }
    }

    static func arcGISUserGroups(portalURL: String, token: String) async throws -> [ArcGISPortalGroup] {
        let portal = try ArcGISAuthManager.normalizedPortalURL(portalURL)

        // First try /community/self because it is the cleanest account-specific
        // endpoint when it is available on the portal/Enterprise version.
        if let selfData = try? await postForm(to: portal.appendingArcGISPath("sharing/rest/community/self"), body: ["f": "json", "token": token]),
           let selfJSON = (try? JSONSerialization.jsonObject(with: selfData)) as? [String: Any] {
            try throwIfArcGISError(selfJSON)
            let groups = parseArcGISGroups(from: selfJSON)
            if !groups.isEmpty { return sortedGroups(groups) }
        }

        // Many portals expose the current user under /portals/self as a nested
        // "user" dictionary, including username and often groups.
        var username: String?
        if let portalData = try? await postForm(to: portal.appendingArcGISPath("sharing/rest/portals/self"), body: ["f": "json", "token": token]),
           let portalJSON = (try? JSONSerialization.jsonObject(with: portalData)) as? [String: Any] {
            try throwIfArcGISError(portalJSON)
            let groups = parseArcGISGroups(from: portalJSON)
            if !groups.isEmpty { return sortedGroups(groups) }
            if let user = portalJSON["user"] as? [String: Any] {
                username = user["username"] as? String
            }
        }

        // Last, ask for the signed-in user's community profile and read groups
        // from there. This catches portals that do not put groups on /self.
        if let username = username, !username.isEmpty {
            let userData = try await postForm(
                to: portal.appendingArcGISPath("sharing/rest/community/users/\(username)"),
                body: ["f": "json", "token": token]
            )
            guard let userJSON = (try? JSONSerialization.jsonObject(with: userData)) as? [String: Any] else {
                throw OnlineDataError.badResponse
            }
            try throwIfArcGISError(userJSON)
            return sortedGroups(parseArcGISGroups(from: userJSON))
        }

        return []
    }

    static func arcGISGroupItems(portalURL: String, token: String, groupID: String) async throws -> [ArcGISPortalSearchItem] {
        let portal = try ArcGISAuthManager.normalizedPortalURL(portalURL)
        let url = portal.appendingArcGISPath("sharing/rest/content/groups/\(groupID)")
        var start = 1
        var items: [ArcGISPortalSearchItem] = []

        while start > 0 {
            let data = try await postForm(
                to: url,
                body: [
                    "f": "json",
                    "token": token,
                    "num": "100",
                    "start": "\(start)"
                ]
            )
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw OnlineDataError.badResponse
            }
            try throwIfArcGISError(json)

            let pageItems = (json["items"] as? [[String: Any]] ?? []).compactMap { portalItem(from: $0) }
            items.append(contentsOf: pageItems)

            let nextStart = (json["nextStart"] as? NSNumber)?.intValue ?? -1
            start = nextStart > 0 ? nextStart : -1
            if items.count > 1000 { break }
        }

        // Keep the list field-friendly: downloadable map/feature content first,
        // then everything else that might still resolve through a Web Map.
        return items.sorted { left, right in
            let leftRank = itemDownloadRank(left)
            let rightRank = itemDownloadRank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private static func parseArcGISGroups(from json: [String: Any]) -> [ArcGISPortalGroup] {
        if let groups = json["groups"] as? [[String: Any]] {
            return groups.compactMap { group(from: $0) }
        }
        if let user = json["user"] as? [String: Any], let groups = user["groups"] as? [[String: Any]] {
            return groups.compactMap { group(from: $0) }
        }
        if let results = json["results"] as? [[String: Any]] {
            return results.compactMap { group(from: $0) }
        }
        return []
    }

    private static func group(from json: [String: Any]) -> ArcGISPortalGroup? {
        guard let id = json["id"] as? String,
              let title = json["title"] as? String,
              !id.isEmpty,
              !title.isEmpty else { return nil }
        let description = (json["description"] as? String)
            ?? (json["snippet"] as? String)
        let itemCount = (json["numItems"] as? NSNumber)?.intValue
            ?? (json["itemCount"] as? NSNumber)?.intValue
        return ArcGISPortalGroup(
            id: id,
            title: title,
            owner: json["owner"] as? String,
            description: description,
            itemCount: itemCount
        )
    }

    private static func sortedGroups(_ groups: [ArcGISPortalGroup]) -> [ArcGISPortalGroup] {
        Dictionary(grouping: groups, by: { $0.id })
            .compactMap { $0.value.first }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func portalItem(from json: [String: Any]) -> ArcGISPortalSearchItem? {
        guard let id = json["id"] as? String,
              let title = json["title"] as? String else { return nil }
        return ArcGISPortalSearchItem(
            id: id,
            title: title,
            type: json["type"] as? String ?? "ArcGIS Item",
            url: json["url"] as? String,
            owner: json["owner"] as? String
        )
    }

    private static func itemDownloadRank(_ item: ArcGISPortalSearchItem) -> Int {
        let text = "\(item.type) \(item.url ?? "")".lowercased()
        if text.contains("feature") { return 0 }
        if text.contains("map service") || text.contains("mapserver") { return 1 }
        if text.contains("web map") { return 2 }
        return 3
    }

    private static func resolveArcGISLayerURL(input: String, portalURL: String, token: String, layerID: Int) async throws -> (layerURL: URL, title: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnlineDataError.invalidURL }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            return (normalizeArcGISLayerURL(url, layerID: layerID), url.deletingPathExtension().lastPathComponent)
        }

        let portal = try ArcGISAuthManager.normalizedPortalURL(portalURL)
        let itemURL = portal.appendingArcGISPath("sharing/rest/content/items/\(trimmed)")
        let body = ["f": "json", "token": token]
        let data = try await postForm(to: itemURL, body: body)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OnlineDataError.badResponse
        }
        try throwIfArcGISError(json)

        let title = json["title"] as? String ?? "ArcGIS Layer"
        let itemType = (json["type"] as? String ?? "").lowercased()

        if let rawURL = json["url"] as? String, let url = URL(string: rawURL) {
            return (normalizeArcGISLayerURL(url, layerID: layerID), title)
        }

        if itemType.contains("web map") {
            let operationalLayer = try await resolveWebMapOperationalLayerURL(
                portal: portal,
                itemID: trimmed,
                token: token,
                layerID: layerID
            )
            return (operationalLayer.layerURL, "\(title): \(operationalLayer.title)")
        }

        throw OnlineDataError.arcGISError("That ArcGIS item does not expose a FeatureServer or MapServer URL. Try a Feature Layer item, Map Image Layer item, Web Map with operational layers, or paste the layer URL directly.")
    }

    private static func resolveWebMapOperationalLayerURL(portal: URL, itemID: String, token: String, layerID: Int) async throws -> (layerURL: URL, title: String) {
        let dataURL = portal.appendingArcGISPath("sharing/rest/content/items/\(itemID)/data")
        let data = try await postForm(to: dataURL, body: ["f": "json", "token": token])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OnlineDataError.badResponse
        }
        try throwIfArcGISError(json)

        if let operationalLayers = json["operationalLayers"] as? [[String: Any]],
           let found = findFirstArcGISServiceURL(in: operationalLayers) {
            return (normalizeArcGISLayerURL(found.url, layerID: layerID), found.title)
        }

        throw OnlineDataError.arcGISError("The Web Map opened, but no operational FeatureServer or MapServer layer URL was found.")
    }

    private static func findFirstArcGISServiceURL(in value: Any) -> (url: URL, title: String)? {
        if let dictionary = value as? [String: Any] {
            if let urlString = dictionary["url"] as? String,
               let url = URL(string: urlString),
               isArcGISServiceURL(urlString) {
                let title = (dictionary["title"] as? String)
                    ?? (dictionary["name"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return (url, title)
            }
            for key in ["layers", "featureCollection", "layerDefinition", "operationalLayers"] {
                if let nested = dictionary[key], let found = findFirstArcGISServiceURL(in: nested) {
                    return found
                }
            }
            for nested in dictionary.values {
                if let found = findFirstArcGISServiceURL(in: nested) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = findFirstArcGISServiceURL(in: nested) {
                    return found
                }
            }
        }
        return nil
    }

    private static func isArcGISServiceURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("/featureserver") || lower.contains("/mapserver")
    }

    private static func normalizeArcGISLayerURL(_ url: URL, layerID: Int) -> URL {
        var text = url.absoluteString
        if let queryRange = text.range(of: "?") {
            text = String(text[..<queryRange.lowerBound])
        }
        if text.lowercased().hasSuffix("/query") {
            text = String(text.dropLast(6))
        }
        let lower = text.lowercased()
        if lower.hasSuffix("/featureserver") || lower.hasSuffix("/mapserver") {
            text += "/\(layerID)"
        }
        return URL(string: text) ?? url
    }

    private static func queryArcGISLayer(layerURL: String, extent: GeoExtent, token: String?, groupName: String, color: LayerColor?, sourceName: String) async throws -> [MapLayer] {
        guard var url = URL(string: layerURL) else { throw OnlineDataError.invalidURL }
        if !url.absoluteString.lowercased().hasSuffix("/query") {
            url.appendPathComponent("query")
        }

        let geometry = "\(extent.minLongitude),\(extent.minLatitude),\(extent.maxLongitude),\(extent.maxLatitude)"
        var body: [String: String] = [
            "where": "1=1",
            "geometry": geometry,
            "geometryType": "esriGeometryEnvelope",
            "inSR": "4326",
            "spatialRel": "esriSpatialRelIntersects",
            "outFields": "*",
            "returnGeometry": "true",
            "outSR": "4326",
            "f": "geojson"
        ]
        if let token = token { body["token"] = token }

        // Some MapServer layers reject f=geojson with an ArcGIS error
        // payload (which postForm throws on), so the fallback must catch
        // that error rather than only handling an empty result.
        var layers: [MapLayer] = []
        do {
            let geoJSONData = try await postForm(to: url, body: body)
            layers = GeoJSONImporter.layers(from: geoJSONData)
        } catch let error as OnlineDataError {
            if case .arcGISError = error {
                layers = []
            } else {
                throw error
            }
        }
        if layers.isEmpty {
            body["f"] = "json"
            let arcData = try await postForm(to: url, body: body)
            layers = ArcGISJSONImporter.layers(from: arcData)
            if layers.isEmpty { layers = GeoJSONImporter.layers(from: arcData) }
        }
        guard !layers.isEmpty else { throw OnlineDataError.noUsableData }
        return decorate(layers, groupName: groupName, color: color, sourceName: sourceName, sourceURL: layerURL)
    }

    private static func postOverpass(_ query: String) async throws -> Data {
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else {
            throw OnlineDataError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("AvenzaStyleFieldMapper/1.0 field survey app", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OnlineDataError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw OnlineDataError.httpStatus(http.statusCode) }
        return data
    }

    private static func postForm(to url: URL, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("AvenzaStyleFieldMapper/1.0 field survey app", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OnlineDataError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw OnlineDataError.httpStatus(http.statusCode) }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            try throwIfArcGISError(json)
        }
        return data
    }

    private static func throwIfArcGISError(_ json: [String: Any]) throws {
        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "ArcGIS REST error."
            let details = (error["details"] as? [String])?.joined(separator: " ")
            throw OnlineDataError.arcGISError([message, details].compactMap { $0 }.joined(separator: " "))
        }
    }

    private static func decorate(_ layers: [MapLayer], groupName: String, color: LayerColor?, sourceName: String, sourceURL: String) -> [MapLayer] {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return layers.map { original in
            var layer = original
            if layer.name == "Imported" || layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                layer.name = sourceName
            }
            if layer.group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                layer.group = groupName
            }
            if layer.color == nil { layer.color = color }
            layer.fields.append(FeatureField(key: "download_source", value: sourceName))
            layer.fields.append(FeatureField(key: "source_url", value: sourceURL))
            layer.fields.append(FeatureField(key: "downloaded_utc", value: stamp))
            return layer
        }
    }
}

enum ArcGISJSONImporter {
    static func layers(from data: Data) -> [MapLayer] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        let geometryType = root["geometryType"] as? String
        var layers: [MapLayer] = []

        for (index, feature) in features.enumerated() {
            let attributes = feature["attributes"] as? [String: Any] ?? [:]
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }

            let name = preferredName(from: attributes) ?? "ArcGIS Feature \(index + 1)"
            let fields = attributes.sorted(by: { $0.key < $1.key }).map { key, value in
                FeatureField(key: key, value: stringify(value))
            }

            if let x = doubleValue(geometry["x"]), let y = doubleValue(geometry["y"]), valid(latitude: y, longitude: x) {
                layers.append(MapLayer(
                    name: name,
                    kind: .point,
                    coordinates: [LayerCoordinate(CLLocationCoordinate2D(latitude: y, longitude: x))],
                    fields: fields
                ))
            } else if let paths = geometry["paths"] as? [[[Any]]] {
                for (pathIndex, path) in paths.enumerated() {
                    let coords = path.compactMap { coordinate($0) }
                    guard coords.count >= 2 else { continue }
                    layers.append(MapLayer(
                        name: paths.count > 1 ? "\(name) \(pathIndex + 1)" : name,
                        kind: .measure,
                        coordinates: coords,
                        fields: fields
                    ))
                }
            } else if let rings = geometry["rings"] as? [[[Any]]] {
                // ESRI outer rings are clockwise; holes are counter-clockwise.
                // Import every outer ring as its own polygon, falling back
                // to all rings if the winding looks unusual.
                let parsedRings = rings.map { ring in ring.compactMap { coordinate($0) } }
                var outers = parsedRings.filter { isClockwise($0) }
                if outers.isEmpty { outers = parsedRings }

                for (ringIndex, outer) in outers.enumerated() {
                    var coords = outer
                    if coords.count > 1,
                       let first = coords.first, let last = coords.last,
                       abs(first.latitude - last.latitude) < 0.000000001,
                       abs(first.longitude - last.longitude) < 0.000000001 {
                        coords.removeLast()
                    }
                    if coords.count >= 3 {
                        layers.append(MapLayer(
                            name: outers.count > 1 ? "\(name) \(ringIndex + 1)" : name,
                            kind: .polygon,
                            coordinates: coords,
                            fields: fields
                        ))
                    }
                }
            } else if geometryType == "esriGeometryPoint" {
                continue
            }
        }
        return layers
    }

    private static func coordinate(_ pair: [Any]) -> LayerCoordinate? {
        guard pair.count >= 2,
              let lon = doubleValue(pair[0]),
              let lat = doubleValue(pair[1]),
              valid(latitude: lat, longitude: lon) else { return nil }
        return LayerCoordinate(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    /// Shoelace winding test in lon/lat space (clockwise = negative area).
    private static func isClockwise(_ ring: [LayerCoordinate]) -> Bool {
        guard ring.count >= 3 else { return false }
        var sum = 0.0
        for index in ring.indices {
            let current = ring[index]
            let next = ring[(index + 1) % ring.count]
            sum += (next.longitude - current.longitude) * (next.latitude + current.latitude)
        }
        return sum > 0
    }

    private static func valid(latitude: Double, longitude: Double) -> Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }

    private static func preferredName(from attributes: [String: Any]) -> String? {
        for key in ["name", "Name", "NAME", "cell_name", "CELL_NAME", "NAMELSAD", "COUNTYNS", "title", "Title", "LABEL", "TRAIL_NAME", "ROAD_NAME", "FORESTNAME", "DISTRICTNAME"] {
            if let value = attributes[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        if let objectID = attributes["OBJECTID"] as? NSNumber {
            return "ArcGIS Feature \(objectID)"
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] { return array.map { stringify($0) }.joined(separator: ", ") }
        if value is NSNull { return "" }
        return String(describing: value)
    }
}

enum OverpassImporter {
    static func layers(from data: Data, dataset: OnlineDataset) -> [MapLayer] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }

        let downloaded = ISO8601DateFormatter().string(from: Date())
        var layers: [MapLayer] = []

        for element in elements {
            guard let type = element["type"] as? String else { continue }
            let idText = osmID(from: element)
            let tags = stringTags(from: element["tags"])
            let baseName = featureName(tags: tags, fallback: dataset.title, idText: idText)
            let fields = featureFields(tags: tags, type: type, idText: idText, dataset: dataset, downloaded: downloaded)

            if type == "node",
               let lat = doubleValue(element["lat"]),
               let lon = doubleValue(element["lon"]),
               valid(latitude: lat, longitude: lon) {
                let pointStyle = osmStyle(tags: tags, kind: .point, fallback: dataset.color)
                layers.append(MapLayer(
                    name: baseName,
                    kind: .point,
                    coordinates: [LayerCoordinate(CLLocationCoordinate2D(latitude: lat, longitude: lon))],
                    notes: "Downloaded from OpenStreetMap Overpass API.",
                    fields: fields,
                    color: pointStyle.color,
                    group: dataset.groupName
                ))
                continue
            }

            guard type == "way",
                  let geometry = element["geometry"] as? [[String: Any]] else { continue }

            var coordinates = geometry.compactMap { vertex -> LayerCoordinate? in
                guard let lat = doubleValue(vertex["lat"]),
                      let lon = doubleValue(vertex["lon"]),
                      valid(latitude: lat, longitude: lon) else { return nil }
                return LayerCoordinate(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }

            guard coordinates.count >= 2 else { continue }

            let closed = isClosed(coordinates)
            let polygon = closed && polygonish(tags: tags)
            if polygon, coordinates.count >= 4 {
                coordinates.removeLast()
            }

            let kind: MapLayerKind = polygon ? .polygon : .measure
            guard kind == .measure ? coordinates.count >= 2 : coordinates.count >= 3 else { continue }

            let style = osmStyle(tags: tags, kind: kind, fallback: dataset.color)
            layers.append(MapLayer(
                name: baseName,
                kind: kind,
                coordinates: coordinates,
                notes: "Downloaded from OpenStreetMap Overpass API.",
                fields: fields,
                color: style.color,
                group: dataset.groupName,
                fillColor: style.fillColor,
                fillOpacity: style.fillOpacity,
                fillStyle: style.fillStyle
            ))
        }

        return layers
    }

    private static func stringTags(from value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        var tags: [String: String] = [:]
        for (key, value) in raw {
            tags[key] = String(describing: value)
        }
        return tags
    }

    private static func featureName(tags: [String: String], fallback: String, idText: String) -> String {
        if let name = tags["name"], !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let ref = tags["ref"], !ref.trimmingCharacters(in: .whitespaces).isEmpty { return "\(fallback) \(ref)" }
        if let highway = tags["highway"] { return "\(highway.capitalized) \(idText)" }
        if let waterway = tags["waterway"] { return "\(waterway.capitalized) \(idText)" }
        if let historic = tags["historic"] { return "\(historic.replacingOccurrences(of: "_", with: " ").capitalized) \(idText)" }
        return "\(fallback) \(idText)"
    }

    private static func featureFields(
        tags: [String: String],
        type: String,
        idText: String,
        dataset: OnlineDataset,
        downloaded: String
    ) -> [FeatureField] {
        var fields: [FeatureField] = [
            FeatureField(key: "source", value: "OpenStreetMap Overpass API"),
            FeatureField(key: "dataset", value: dataset.title),
            FeatureField(key: "osm_type", value: type),
            FeatureField(key: "osm_id", value: idText),
            FeatureField(key: "downloaded_utc", value: downloaded)
        ]

        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            fields.append(FeatureField(key: "osm_\(key)", value: value))
        }
        return fields
    }

    /// OSM-carto-inspired symbology mapped onto the app's color palette:
    /// motorways pink-red, trunk/primary orange, secondary yellow, minor
    /// roads white, tracks brown, paths red, cycleways blue, water teal,
    /// buildings brown, parks/forest green, protected areas hatched
    /// green, historic features purple.
    static func osmStyle(
        tags: [String: String],
        kind: MapLayerKind,
        fallback: LayerColor
    ) -> (color: LayerColor, fillColor: LayerColor?, fillOpacity: Double, fillStyle: PolygonFillStyle) {
        // Historic features take priority regardless of geometry.
        if tags["historic"] != nil {
            return (.purple, .purple, 0.30, .solid)
        }

        if let highway = tags["highway"] {
            switch highway {
            case "motorway", "motorway_link":
                return (.pink, nil, 0.25, .solid)
            case "trunk", "trunk_link", "primary", "primary_link":
                return (.orange, nil, 0.25, .solid)
            case "secondary", "secondary_link":
                return (.yellow, nil, 0.25, .solid)
            case "tertiary", "tertiary_link", "residential", "unclassified", "living_street", "service", "road":
                return (.white, nil, 0.25, .solid)
            case "track":
                return (.brown, nil, 0.25, .solid)
            case "path", "footway", "bridleway", "steps":
                return (.red, nil, 0.25, .solid)
            case "cycleway":
                return (.blue, nil, 0.25, .solid)
            default:
                return (.white, nil, 0.25, .solid)
            }
        }

        if tags["route"] == "hiking" {
            return (.red, nil, 0.25, .solid)
        }

        if tags["waterway"] != nil || tags["natural"] == "water" || tags["water"] != nil {
            return (.teal, .teal, 0.40, .solid)
        }

        if tags["building"] != nil {
            return (.brown, .brown, 0.50, .solid)
        }

        if tags["boundary"] == "protected_area" || tags["boundary"] == "national_park" {
            return (.green, .green, 0.30, .hatch)
        }

        if tags["leisure"] == "park" || tags["leisure"] == "nature_reserve" || tags["leisure"] != nil {
            return (.green, .green, 0.35, .solid)
        }

        if tags["landuse"] == "forest" || tags["natural"] == "wood" {
            return (.green, .green, 0.28, .solid)
        }

        if tags["tourism"] == "attraction" {
            return (.purple, nil, 0.25, .solid)
        }

        return (fallback, nil, 0.25, .solid)
    }

    private static func polygonish(tags: [String: String]) -> Bool {
        if tags["area"] == "yes" { return true }
        if tags["building"] != nil { return true }
        if tags["natural"] == "water" { return true }
        if tags["water"] != nil { return true }
        if tags["leisure"] != nil { return true }
        if tags["landuse"] != nil { return true }
        if tags["boundary"] != nil { return true }
        if tags["historic"] == "archaeological_site" || tags["historic"] == "ruins" { return true }
        return false
    }

    private static func isClosed(_ coordinates: [LayerCoordinate]) -> Bool {
        guard let first = coordinates.first, let last = coordinates.last else { return false }
        return abs(first.latitude - last.latitude) < 0.0000001 &&
               abs(first.longitude - last.longitude) < 0.0000001
    }

    private static func osmID(from element: [String: Any]) -> String {
        if let number = element["id"] as? NSNumber { return number.stringValue }
        if let string = element["id"] as? String { return string }
        return "unknown"
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func valid(latitude: Double, longitude: Double) -> Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }
}

// MARK: - Attribute templates (domains / drop-down menus)

enum TemplateFieldKind: String, Codable, CaseIterable, Identifiable {
    case text
    case number
    case choice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .number: return "Number"
        case .choice: return "Drop-down"
        }
    }
}

struct TemplateField: Identifiable, Codable {
    var id = UUID()
    var name: String = ""
    var kind: TemplateFieldKind = .text
    /// Domain values for .choice fields. Editable on the fly in the field.
    var choices: [String] = []
}

struct AttributeTemplate: Identifiable, Codable {
    var id = UUID()
    var name: String = "New Template"
    var fields: [TemplateField] = []
}

/// Persists user-defined attribute templates and their domains.
final class TemplateStore: ObservableObject {
    @Published var templates: [AttributeTemplate] = [] {
        didSet { if !isLoading { save() } }
    }

    private let fileURL: URL
    private var isLoading = false

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = documents.appendingPathComponent("AttributeTemplates.json")
        isLoading = true
        load()
        isLoading = false
    }

    /// Envelope for shared template files, so imports can be validated
    /// and the format can grow without breaking old files.
    struct ShareEnvelope: Codable {
        var fieldmapper_template_version: Int = 1
        var exported_utc: String = ISO8601DateFormatter().string(from: Date())
        var templates: [AttributeTemplate]
    }

    /// Encode templates as a shareable standalone JSON file.
    func exportData(for templates: [AttributeTemplate]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(ShareEnvelope(templates: templates))
    }

    /// Merge templates from a shared file: every import gets fresh IDs,
    /// and name collisions get a numeric suffix instead of overwriting
    /// the crew member's existing templates. Returns the count imported.
    func importTemplates(from data: Data) -> Int {
        let decoder = JSONDecoder()
        var incoming: [AttributeTemplate] = []
        if let envelope = try? decoder.decode(ShareEnvelope.self, from: data) {
            incoming = envelope.templates
        } else if let plain = try? decoder.decode([AttributeTemplate].self, from: data) {
            incoming = plain
        }
        guard !incoming.isEmpty else { return 0 }

        var existingNames = Set(templates.map { $0.name.lowercased() })
        for template in incoming {
            var copy = template
            copy.id = UUID()
            copy.fields = copy.fields.map { field in
                var fieldCopy = field
                fieldCopy.id = UUID()
                return fieldCopy
            }
            var name = copy.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Imported Template" }
            var candidate = name
            var suffix = 2
            while existingNames.contains(candidate.lowercased()) {
                candidate = "\(name) (\(suffix))"
                suffix += 1
            }
            copy.name = candidate
            existingNames.insert(candidate.lowercased())
            templates.append(copy)
        }
        return incoming.count
    }

    /// Add a domain value to the first template field with this name.
    func addChoice(_ value: String, forFieldNamed key: String) {
        for templateIndex in templates.indices {
            if let fieldIndex = templates[templateIndex].fields.firstIndex(where: {
                $0.name == key && $0.kind == .choice
            }) {
                if !templates[templateIndex].fields[fieldIndex].choices.contains(value) {
                    templates[templateIndex].fields[fieldIndex].choices.append(value)
                }
                return
            }
        }
    }

    /// Domain values for a field name, looked up across all templates.
    func choices(forFieldNamed key: String) -> [String]? {
        for template in templates {
            if let field = template.fields.first(where: { $0.name == key && $0.kind == .choice }) {
                return field.choices
            }
        }
        return nil
    }

    func fieldKind(forFieldNamed key: String) -> TemplateFieldKind? {
        for template in templates {
            if let field = template.fields.first(where: { $0.name == key }) {
                return field.kind
            }
        }
        return nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AttributeTemplate].self, from: data) else {
            templates = []
            return
        }
        templates = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

// MARK: - Coordinate display formats

enum CoordinateDisplayFormat: String, CaseIterable, Identifiable {
    case decimalDegrees
    case degreesMinutesSeconds
    case utm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .decimalDegrees: return "Decimal Degrees"
        case .degreesMinutesSeconds: return "Degrees Min Sec"
        case .utm: return "UTM (WGS84)"
        }
    }
}

enum CoordinateFormatter {
    static func string(for coordinate: CLLocationCoordinate2D, format: CoordinateDisplayFormat) -> String {
        switch format {
        case .decimalDegrees:
            return String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        case .degreesMinutesSeconds:
            return dmsString(coordinate.latitude, positive: "N", negative: "S")
                + "  " + dmsString(coordinate.longitude, positive: "E", negative: "W")
        case .utm:
            return utmString(for: coordinate)
        }
    }

    static func dmsString(_ value: Double, positive: String, negative: String) -> String {
        let hemisphere = value >= 0 ? positive : negative
        let absolute = abs(value)
        let degrees = Int(absolute)
        let minutesFull = (absolute - Double(degrees)) * 60
        let minutes = Int(minutesFull)
        let seconds = (minutesFull - Double(minutes)) * 60
        return String(format: "%d\u{00B0}%d' %.1f\" %@", degrees, minutes, seconds, hemisphere)
    }

    static func utmString(for coordinate: CLLocationCoordinate2D) -> String {
        let utm = utm(for: coordinate)
        return String(format: "%d%@ %.0fmE %.0fmN", utm.zone, utm.hemisphere, utm.easting, utm.northing)
    }

    /// WGS84 -> UTM (standard transverse Mercator series; sub-meter
    /// accuracy, more than enough for field recording).
    /// Inverse UTM (WGS84): easting/northing back to latitude/longitude.
    /// Used to georeference UTM-projected GeoTIFFs (RVT outputs, etc).
    static func coordinate(fromUTMZone zone: Int, northernHemisphere: Bool, easting: Double, northing: Double) -> CLLocationCoordinate2D {
        let a = 6378137.0
        let f = 1.0 / 298.257223563
        let k0 = 0.9996
        let e2 = f * (2 - f)
        let ep2 = e2 / (1 - e2)
        let e1 = (1 - sqrt(1 - e2)) / (1 + sqrt(1 - e2))

        let x = easting - 500_000.0
        let y = northernHemisphere ? northing : northing - 10_000_000.0
        let lon0 = (Double(zone - 1) * 6 - 180 + 3) * Double.pi / 180

        let m = y / k0
        let mu = m / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256))

        let phi1 = mu
            + (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu)
            + (21 * e1 * e1 / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu)
            + (151 * pow(e1, 3) / 96) * sin(6 * mu)
            + (1097 * pow(e1, 4) / 512) * sin(8 * mu)

        let sinPhi1 = sin(phi1)
        let cosPhi1 = cos(phi1)
        let tanPhi1 = tan(phi1)

        let c1 = ep2 * cosPhi1 * cosPhi1
        let t1 = tanPhi1 * tanPhi1
        let n1 = a / sqrt(1 - e2 * sinPhi1 * sinPhi1)
        let r1 = a * (1 - e2) / pow(1 - e2 * sinPhi1 * sinPhi1, 1.5)
        let d = x / (n1 * k0)

        let latitude = phi1 - (n1 * tanPhi1 / r1) * (
            d * d / 2
            - (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ep2) * pow(d, 4) / 24
            + (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * ep2 - 3 * c1 * c1) * pow(d, 6) / 720
        )
        let longitude = lon0 + (
            d
            - (1 + 2 * t1 + c1) * pow(d, 3) / 6
            + (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ep2 + 24 * t1 * t1) * pow(d, 5) / 120
        ) / cosPhi1

        return CLLocationCoordinate2D(
            latitude: latitude * 180 / Double.pi,
            longitude: longitude * 180 / Double.pi
        )
    }

    static func utm(for coordinate: CLLocationCoordinate2D) -> (zone: Int, hemisphere: String, easting: Double, northing: Double) {
        let a = 6378137.0
        let f = 1.0 / 298.257223563
        let k0 = 0.9996
        let e2 = f * (2 - f)
        let ep2 = e2 / (1 - e2)

        let zone = max(1, min(60, Int((coordinate.longitude + 180) / 6) + 1))
        let lon0 = Double(zone - 1) * 6 - 180 + 3

        let phi = coordinate.latitude * .pi / 180
        let lambdaDiff = (coordinate.longitude - lon0) * .pi / 180

        let sinPhi = sin(phi), cosPhi = cos(phi), tanPhi = tan(phi)
        let n = a / sqrt(1 - e2 * sinPhi * sinPhi)
        let t = tanPhi * tanPhi
        let c = ep2 * cosPhi * cosPhi
        let bigA = cosPhi * lambdaDiff

        let e4 = e2 * e2
        let e6 = e4 * e2
        let m = a * ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi
            - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi)
            + (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi)
            - (35 * e6 / 3072) * sin(6 * phi))

        let easting = k0 * n * (bigA + (1 - t + c) * pow(bigA, 3) / 6
            + (5 - 18 * t + t * t + 72 * c - 58 * ep2) * pow(bigA, 5) / 120) + 500000

        var northing = k0 * (m + n * tanPhi * (bigA * bigA / 2
            + (5 - t + 9 * c + 4 * c * c) * pow(bigA, 4) / 24
            + (61 - 58 * t + t * t + 600 * c - 330 * ep2) * pow(bigA, 6) / 720))

        var hemisphere = "N"
        if coordinate.latitude < 0 {
            northing += 10_000_000
            hemisphere = "S"
        }

        return (zone, hemisphere, easting, northing)
    }
}

// MARK: - Distance units

enum DistanceUnits: String, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metric: return "Meters / Kilometers"
        case .imperial: return "Feet / Miles"
        }
    }

    var shortDistanceLabel: String {
        switch self {
        case .metric: return "meters"
        case .imperial: return "feet"
        }
    }
}

enum UnitFormat {
    static let feetPerMeter = 3.28084

    static func distance(_ meters: Double, units: DistanceUnits) -> String {
        switch units {
        case .metric:
            return meters >= 1000
                ? String(format: "%.2f km", meters / 1000)
                : String(format: "%.1f m", meters)
        case .imperial:
            let feet = meters * feetPerMeter
            return feet >= 5280
                ? String(format: "%.2f mi", feet / 5280)
                : String(format: "%.0f ft", feet)
        }
    }

    static func area(_ squareMeters: Double, units: DistanceUnits) -> String {
        switch units {
        case .metric:
            return squareMeters >= 10000
                ? String(format: "%.2f ha", squareMeters / 10000)
                : String(format: "%.0f sq m", squareMeters)
        case .imperial:
            let squareFeet = squareMeters * feetPerMeter * feetPerMeter
            return squareFeet >= 43560
                ? String(format: "%.3f acres", squareFeet / 43560)
                : String(format: "%.0f sq ft", squareFeet)
        }
    }

    static func accuracy(_ meters: Double, units: DistanceUnits) -> String {
        switch units {
        case .metric: return String(format: "+/- %.1f m", meters)
        case .imperial: return String(format: "+/- %.0f ft", meters * feetPerMeter)
        }
    }

    static func speed(_ metersPerSecond: Double, units: DistanceUnits) -> String {
        switch units {
        case .metric: return String(format: "%.2f m/s", metersPerSecond)
        case .imperial: return String(format: "%.1f mph", metersPerSecond * 2.23694)
        }
    }

    /// Convert a number typed by the user in the selected units to meters.
    static func metersFromInput(_ value: Double, units: DistanceUnits) -> Double {
        units == .imperial ? value / feetPerMeter : value
    }
}

// MARK: - Brand colors

extension Color {
    /// Deep slate used across bars and secondary controls.
    static let brandSlate = Color(red: 0.11, green: 0.17, blue: 0.23)
    /// Amber accent matching the app icon's contour lines.
    static let brandAmber = Color(red: 0.88, green: 0.59, blue: 0.12)
}

// MARK: - Photo storage

/// Stores feature photos as JPEGs in Documents/LayerPhotos and hands
/// back filenames that the layers reference.
enum PhotoStore {
    static var directoryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = documents.appendingPathComponent("LayerPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func save(_ image: UIImage, compressionQuality: CGFloat = 0.85, prefix: String = "photo") -> String? {
        guard let data = image.jpegData(compressionQuality: compressionQuality) else { return nil }
        let safePrefix = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let name = "\(safePrefix.isEmpty ? "photo" : safePrefix)-\(UUID().uuidString).jpg"
        do {
            try data.write(to: directoryURL.appendingPathComponent(name), options: [.atomic])
            return name
        } catch {
            return nil
        }
    }

    static func url(for name: String) -> URL {
        directoryURL.appendingPathComponent(name)
    }

    static func existingURL(filename: String?) -> URL? {
        guard let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !filename.isEmpty else { return nil }
        let url = directoryURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func loadImage(_ name: String) -> UIImage? {
        UIImage(contentsOfFile: directoryURL.appendingPathComponent(name).path)
    }

    static func delete(_ names: [String]) {
        for name in names {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(name))
        }
    }
}

/// Camera or photo-library picker.
struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let sourceType: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: ImagePicker

        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Full-screen view of a single attached photo.
struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let filename: String

    var body: some View {
        NavigationView {
            Group {
                if let image = PhotoStore.loadImage(filename) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("Photo not found")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}




// MARK: - DPR 523 forms

enum DPRFormExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case word

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: return "Filled PDF"
        case .word: return "Word-compatible document"
        }
    }
}

struct DPRFormFieldDefinition: Identifiable, Hashable {
    let key: String
    let label: String
    let multiline: Bool
    let placeholder: String

    var id: String { key }

    init(_ key: String, _ label: String, multiline: Bool = false, placeholder: String = "") {
        self.key = key
        self.label = label
        self.multiline = multiline
        self.placeholder = placeholder
    }
}

enum DPRFormKind: String, CaseIterable, Identifiable, Codable {
    case primaryA
    case buildingB
    case archaeologicalC
    case districtD
    case linearE
    case photoI
    case locationMapJ
    case sketchMapK
    case continuationL

    var id: String { rawValue }

    var shortCode: String {
        switch self {
        case .primaryA: return "DPR 523A"
        case .buildingB: return "DPR 523B"
        case .archaeologicalC: return "DPR 523C"
        case .districtD: return "DPR 523D"
        case .linearE: return "DPR 523E"
        case .photoI: return "DPR 523I"
        case .locationMapJ: return "DPR 523J"
        case .sketchMapK: return "DPR 523K"
        case .continuationL: return "DPR 523L"
        }
    }

    var title: String {
        switch self {
        case .primaryA: return "Primary Record"
        case .buildingB: return "Building / Structure / Object"
        case .archaeologicalC: return "Archaeological Site Record"
        case .districtD: return "District Record"
        case .linearE: return "Linear Feature Record"
        case .photoI: return "Photograph Record"
        case .locationMapJ: return "Location Map"
        case .sketchMapK: return "Sketch Map"
        case .continuationL: return "Continuation Sheet"
        }
    }

    var recommendedGeometry: String {
        switch self {
        case .linearE: return "Recommended for lines, tracks, roads, trails, ditches, walls, and segments."
        case .archaeologicalC: return "Recommended for archaeological sites, scatters, deposits, features, and site polygons."
        case .buildingB: return "Recommended for buildings, structures, and objects."
        case .districtD: return "Recommended for districts and grouped resources."
        case .photoI: return "Recommended when the primary record needs a detailed photo log."
        case .locationMapJ, .sketchMapK: return "Recommended as map attachments to a primary record packet."
        case .continuationL: return "Recommended when descriptions or remarks need more space."
        case .primaryA: return "Recommended as the cover record for most resources."
        }
    }

    var fields: [DPRFormFieldDefinition] {
        let common = [
            DPRFormFieldDefinition("resource_name", "Resource Name or Number"),
            DPRFormFieldDefinition("primary_number", "Primary #"),
            DPRFormFieldDefinition("hri_number", "HRI #"),
            DPRFormFieldDefinition("trinomial", "Trinomial"),
            DPRFormFieldDefinition("recorded_by", "Recorded by"),
            DPRFormFieldDefinition("date_recorded", "Date Recorded")
        ]
        switch self {
        case .primaryA:
            return common + [
                DPRFormFieldDefinition("p1_other_identifier", "P1. Other Identifier"),
                DPRFormFieldDefinition("p2_location_restriction", "P2. Location Publication Status"),
                DPRFormFieldDefinition("county", "County"),
                DPRFormFieldDefinition("quad", "USGS 7.5' Quad / Date"),
                DPRFormFieldDefinition("p2b_township_range_section", "P2b. Township / Range / Section"),
                DPRFormFieldDefinition("township", "Township"),
                DPRFormFieldDefinition("range", "Range"),
                DPRFormFieldDefinition("section", "Section"),
                DPRFormFieldDefinition("principal_meridian", "Principal Meridian"),
                DPRFormFieldDefinition("address", "Address / City / Zip"),
                DPRFormFieldDefinition("utm", "P2d. UTM"),
                DPRFormFieldDefinition("decimal_degrees", "Decimal Degrees"),
                DPRFormFieldDefinition("elevation", "Elevation"),
                DPRFormFieldDefinition("other_location", "Other Locational Data", multiline: true),
                DPRFormFieldDefinition("p3a_description", "P3a. Description", multiline: true),
                DPRFormFieldDefinition("p3b_attributes", "P3b. Resource Attributes"),
                DPRFormFieldDefinition("p4_resources_present", "P4. Resources Present"),
                DPRFormFieldDefinition("p5b_photo_description", "P5b. Description of Photo", multiline: true),
                DPRFormFieldDefinition("p6_date_constructed_age", "P6. Date Constructed / Age and Source"),
                DPRFormFieldDefinition("p7_owner", "P7. Owner and Address", multiline: true),
                DPRFormFieldDefinition("p8_recorded_by", "P8. Recorded by", multiline: true),
                DPRFormFieldDefinition("p9_date_recorded", "P9. Date Recorded"),
                DPRFormFieldDefinition("p10_survey_type", "P10. Survey Type", multiline: true),
                DPRFormFieldDefinition("p11_report_citation", "P11. Report Citation", multiline: true),
                DPRFormFieldDefinition("attachments", "Attachments", multiline: true)
            ]
        case .buildingB:
            return common + [
                DPRFormFieldDefinition("nrhp_status_code", "NRHP Status Code"),
                DPRFormFieldDefinition("b1_historic_name", "B1. Historic Name"),
                DPRFormFieldDefinition("b2_common_name", "B2. Common Name"),
                DPRFormFieldDefinition("b3_original_use", "B3. Original Use"),
                DPRFormFieldDefinition("b4_present_use", "B4. Present Use"),
                DPRFormFieldDefinition("b5_style", "B5. Architectural Style"),
                DPRFormFieldDefinition("b6_construction_history", "B6. Construction History", multiline: true),
                DPRFormFieldDefinition("b7_moved", "B7. Moved? Date / Original Location"),
                DPRFormFieldDefinition("b8_related_features", "B8. Related Features", multiline: true),
                DPRFormFieldDefinition("b9_architect_builder", "B9. Architect / Builder"),
                DPRFormFieldDefinition("b10_significance", "B10. Significance", multiline: true),
                DPRFormFieldDefinition("b11_attributes", "B11. Additional Resource Attributes"),
                DPRFormFieldDefinition("b12_references", "B12. References", multiline: true),
                DPRFormFieldDefinition("b13_remarks", "B13. Remarks", multiline: true),
                DPRFormFieldDefinition("b14_evaluator", "B14. Evaluator"),
                DPRFormFieldDefinition("date_evaluation", "Date of Evaluation")
            ]
        case .archaeologicalC:
            return common + [
                DPRFormFieldDefinition("a1_dimensions", "A1. Dimensions / Method / Reliability", multiline: true),
                DPRFormFieldDefinition("a1_length", "A1a. Length", placeholder: "Auto-filled from linked map feature when available"),
                DPRFormFieldDefinition("a1_width", "A1b. Width", placeholder: "Auto-filled from linked polygon/site geometry when available"),
                DPRFormFieldDefinition("a2_depth", "A2. Depth / Method of Determination"),
                DPRFormFieldDefinition("a3_human_remains", "A3. Human Remains"),
                DPRFormFieldDefinition("a4_features", "A4. Features", multiline: true),
                DPRFormFieldDefinition("a5_constituents", "A5. Cultural Constituents", multiline: true),
                DPRFormFieldDefinition("a6_specimens", "A6. Specimens Collected?"),
                DPRFormFieldDefinition("a7_condition", "A7. Site Condition", multiline: true),
                DPRFormFieldDefinition("a8_nearest_water", "A8. Nearest Water"),
                DPRFormFieldDefinition("a9_elevation", "A9. Elevation"),
                DPRFormFieldDefinition("a10_environment", "A10. Environmental Setting", multiline: true),
                DPRFormFieldDefinition("a11_historical_info", "A11. Historical Information", multiline: true),
                DPRFormFieldDefinition("a12_age", "A12. Age"),
                DPRFormFieldDefinition("a13_interpretations", "A13. Interpretations", multiline: true),
                DPRFormFieldDefinition("a14_remarks", "A14. Remarks", multiline: true),
                DPRFormFieldDefinition("a15_references", "A15. References", multiline: true),
                DPRFormFieldDefinition("a16_photographs", "A16. Photographs", multiline: true),
                DPRFormFieldDefinition("a17_prepared_by", "A17. Form Prepared by / Date / Affiliation", multiline: true)
            ]
        case .districtD:
            return common + [
                DPRFormFieldDefinition("nrhp_status_code", "NRHP Status Code"),
                DPRFormFieldDefinition("d1_historic_name", "D1. Historic Name"),
                DPRFormFieldDefinition("d2_common_name", "D2. Common Name"),
                DPRFormFieldDefinition("d3_description", "D3. Detailed Description", multiline: true),
                DPRFormFieldDefinition("d4_boundary", "D4. Boundary Description", multiline: true),
                DPRFormFieldDefinition("d5_boundary_justification", "D5. Boundary Justification", multiline: true),
                DPRFormFieldDefinition("d6_significance", "D6. Significance", multiline: true),
                DPRFormFieldDefinition("d7_references", "D7. References", multiline: true),
                DPRFormFieldDefinition("d8_evaluator", "D8. Evaluator / Date / Affiliation", multiline: true)
            ]
        case .linearE:
            return common + [
                DPRFormFieldDefinition("l1_name", "L1. Historic and/or Common Name"),
                DPRFormFieldDefinition("l2a_portion", "L2a. Portion Described"),
                DPRFormFieldDefinition("l2b_location", "L2b. Location of Point or Segment", multiline: true),
                DPRFormFieldDefinition("l3_description", "L3. Description", multiline: true),
                DPRFormFieldDefinition("l4_dimensions", "L4. Dimensions", multiline: true),
                DPRFormFieldDefinition("l4a_top_width", "L4a. Top Width"),
                DPRFormFieldDefinition("l4b_bottom_width", "L4b. Bottom Width"),
                DPRFormFieldDefinition("l4c_height_depth", "L4c. Height or Depth"),
                DPRFormFieldDefinition("l4d_length_segment", "L4d. Length of Segment", placeholder: "Auto-filled from linked line/track length when available"),
                DPRFormFieldDefinition("l5_associated", "L5. Associated Resources", multiline: true),
                DPRFormFieldDefinition("l6_setting", "L6. Setting", multiline: true),
                DPRFormFieldDefinition("l7_integrity", "L7. Integrity Considerations", multiline: true),
                DPRFormFieldDefinition("l8_description", "L8. Photo / Map / Drawing Description", multiline: true),
                DPRFormFieldDefinition("l9_remarks", "L9. Remarks", multiline: true),
                DPRFormFieldDefinition("l10_prepared_by", "L10. Form Prepared by", multiline: true),
                DPRFormFieldDefinition("l11_date", "L11. Date")
            ]
        case .photoI:
            return common + [
                DPRFormFieldDefinition("project_name", "Project Name"),
                DPRFormFieldDefinition("year", "Year"),
                DPRFormFieldDefinition("camera_format", "Camera Format"),
                DPRFormFieldDefinition("lens_size", "Lens Size"),
                DPRFormFieldDefinition("film_type_speed", "Film Type and Speed / Digital Settings"),
                DPRFormFieldDefinition("negatives_kept", "Negatives / Digital Files Kept At"),
                DPRFormFieldDefinition("photo_log", "Photograph Log: Month / Day / Time / Frame / Subject / View Toward / Accession #", multiline: true)
            ]
        case .locationMapJ:
            return common + [
                DPRFormFieldDefinition("map_name", "Map Name"),
                DPRFormFieldDefinition("scale", "Scale"),
                DPRFormFieldDefinition("date_of_map", "Date of Map"),
                DPRFormFieldDefinition("map_notes", "Location Map Notes", multiline: true)
            ]
        case .sketchMapK:
            return common + [
                DPRFormFieldDefinition("drawn_by", "Drawn by"),
                DPRFormFieldDefinition("date_of_map", "Date of Map"),
                DPRFormFieldDefinition("sketch_notes", "Sketch Map Notes / North Arrow / Scale", multiline: true)
            ]
        case .continuationL:
            return common + [
                DPRFormFieldDefinition("continuation_type", "Continuation or Update"),
                DPRFormFieldDefinition("property_name", "Property Name"),
                DPRFormFieldDefinition("continuation_text", "Continuation Text", multiline: true)
            ]
        }
    }
}

struct DPRFormRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: DPRFormKind
    var linkedLayerID: UUID?
    var createdAt = Date()
    var updatedAt = Date()
    var values: [String: String] = [:]

    var resourceNameOrUntitled: String {
        let candidate = values["resource_name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? "Untitled Resource" : candidate
    }

    var linkedStatusText: String {
        linkedLayerID == nil ? "Standalone form" : "Attached to map feature"
    }
}

struct DPRFormEditorRequest: Identifiable {
    let id = UUID()
    let kind: DPRFormKind
    let linkedLayerID: UUID?
    let existingForm: DPRFormRecord?

    init(kind: DPRFormKind, linkedLayerID: UUID?) {
        self.kind = kind
        self.linkedLayerID = linkedLayerID
        self.existingForm = nil
    }

    init(existingForm: DPRFormRecord) {
        self.kind = existingForm.kind
        self.linkedLayerID = existingForm.linkedLayerID
        self.existingForm = existingForm
    }
}

final class DPRFormStore: ObservableObject {
    @Published private(set) var forms: [DPRFormRecord] = []

    private let fileURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = documents.appendingPathComponent("SavedDPR523Forms.json")
        load()
    }

    func forms(for layerID: UUID) -> [DPRFormRecord] {
        forms
            .filter { $0.linkedLayerID == layerID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func standaloneForms() -> [DPRFormRecord] {
        forms
            .filter { $0.linkedLayerID == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ form: DPRFormRecord) {
        var copy = form
        copy.updatedAt = Date()
        if let index = forms.firstIndex(where: { $0.id == form.id }) {
            forms[index] = copy
        } else {
            forms.append(copy)
        }
        save()
    }

    func delete(_ form: DPRFormRecord) {
        forms.removeAll { $0.id == form.id }
        save()
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            forms = try JSONDecoder().decode([DPRFormRecord].self, from: data)
        } catch {
            forms = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(forms)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Keep field recording responsive even if form persistence fails.
        }
    }
}

enum DPRFormAutofill {
    /// Mobile forms should not make the recorder re-type geometry that
    /// already exists on the map. This helper turns the linked point,
    /// line/track, or polygon into DPR-ready location and measurement
    /// text that can be applied to any DPR 523 form type.
    private struct FeatureMetrics {
        let coordinateForLocation: CLLocationCoordinate2D?
        let utmText: String
        let decimalDegreesText: String
        let locationNarrative: String
        let geometrySummary: String
        let lengthMeters: Double?
        let widthMeters: Double?
        let perimeterMeters: Double?
        let areaSquareMeters: Double?
        let lengthLabel: String?
        let widthLabel: String?
        let perimeterLabel: String?
        let areaLabel: String?
        let plssText: String
        let townshipText: String
        let rangeText: String
        let sectionText: String
        let principalMeridianText: String
        let countyText: String
        let countyStateText: String
        let quadNameText: String
        let quadDateText: String
        let quadText: String
    }

    static func values(
        kind: DPRFormKind,
        layer: MapLayer?,
        recorderName: String,
        coordinateFormat: CoordinateDisplayFormat,
        distanceUnits: DistanceUnits,
        allLayers: [MapLayer] = [],
        elevationProvider: ((CLLocationCoordinate2D) -> Double?)? = nil
    ) -> [String: String] {
        var values: [String: String] = [:]
        let today = DateFormatter.dprShortDate.string(from: Date())
        let metrics = layer.map { featureMetrics(for: $0, units: distanceUnits, allLayers: allLayers) }

        values["date_recorded"] = today
        values["p9_date_recorded"] = today
        values["l11_date"] = today

        if let layer = layer {
            values["resource_name"] = layer.name
            values["property_name"] = layer.name
            values["map_name"] = layer.group.isEmpty ? "Current field map" : layer.group
            values["linked_feature_id"] = layer.id.uuidString
            values["linked_feature_name"] = layer.name
            values["linked_feature_type"] = layer.kind.displayName
            values["autofill_source"] = "Auto-filled from linked app map feature geometry and GPS/map coordinates."

            if !layer.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values["p3a_description"] = layer.notes
                values["a14_remarks"] = layer.notes
                values["l9_remarks"] = layer.notes
                values["continuation_text"] = layer.notes
            }

            if let metrics = metrics {
                values["utm"] = metrics.utmText
                values["p2d_utm"] = metrics.utmText
                values["decimal_degrees"] = metrics.decimalDegreesText
                values["other_location"] = metrics.locationNarrative
                values["p2e_other_location"] = metrics.locationNarrative
                values["l2b_location"] = metrics.locationNarrative
                values["location_summary"] = metrics.locationNarrative
                values["geometry_summary"] = metrics.geometrySummary
                if !metrics.countyText.isEmpty {
                    values["county"] = metrics.countyText
                    values["county_name"] = metrics.countyText
                    values["p2_county"] = metrics.countyText
                }
                if !metrics.quadText.isEmpty {
                    values["quad"] = metrics.quadText
                    values["usgs_quad"] = metrics.quadText
                    values["usgs_75_quad"] = metrics.quadText
                    values["quad_date"] = metrics.quadDateText
                    // DPR 523J/K map fields can use the quad name/date when a downloaded USGS quad footprint is present.
                    if !metrics.quadNameText.isEmpty { values["map_name"] = metrics.quadNameText }
                    if !metrics.quadDateText.isEmpty { values["date_of_map"] = metrics.quadDateText }
                }
                if !metrics.plssText.isEmpty {
                    values["plss"] = metrics.plssText
                    values["township_range_section"] = metrics.plssText
                    values["p2b_township_range_section"] = metrics.plssText
                    values["legal_description"] = metrics.plssText
                    values["p2b_legal_description"] = metrics.plssText
                    values["other_location"] = [values["other_location"], "PLSS: \(metrics.plssText)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                    if !metrics.townshipText.isEmpty { values["township"] = metrics.townshipText }
                    if !metrics.rangeText.isEmpty { values["range"] = metrics.rangeText }
                    if !metrics.sectionText.isEmpty { values["section"] = metrics.sectionText }
                    if !metrics.principalMeridianText.isEmpty { values["principal_meridian"] = metrics.principalMeridianText }
                }

                if let lengthLabel = metrics.lengthLabel, let lengthMeters = metrics.lengthMeters {
                    values["length"] = lengthLabel
                    values["feature_length"] = lengthLabel
                    values["length_m"] = String(format: "%.2f", lengthMeters)
                    values["l4d_length_segment"] = lengthLabel
                    values["a1_length"] = lengthLabel
                }
                if let widthLabel = metrics.widthLabel, let widthMeters = metrics.widthMeters {
                    values["width"] = widthLabel
                    values["feature_width"] = widthLabel
                    values["width_m"] = String(format: "%.2f", widthMeters)
                    values["a1_width"] = widthLabel
                }
                if let perimeterLabel = metrics.perimeterLabel, let perimeterMeters = metrics.perimeterMeters {
                    values["perimeter"] = perimeterLabel
                    values["perimeter_m"] = String(format: "%.2f", perimeterMeters)
                }
                if let areaLabel = metrics.areaLabel, let areaSquareMeters = metrics.areaSquareMeters {
                    values["area"] = areaLabel
                    values["area_sq_m"] = String(format: "%.2f", areaSquareMeters)
                }

                values["a1_dimensions"] = archaeologicalDimensionsText(for: layer, metrics: metrics, units: distanceUnits)
                values["l4_dimensions"] = linearDimensionsText(for: layer, metrics: metrics, units: distanceUnits)
            } else {
                let summary = layer.geometrySummary(units: distanceUnits)
                values["other_location"] = summary
                values["l4_dimensions"] = summary
                values["a1_dimensions"] = summary
            }

            var elevationText: String? = nil
            if let stamped = layer.fields.first(where: { $0.key.lowercased() == "elevation_m" })?.value,
               !stamped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                elevationText = stamped.contains("m") ? stamped : "\(stamped) m"
            } else if let provider = elevationProvider,
                      let coordinate = metrics?.coordinateForLocation,
                      let elevationMeters = provider(coordinate) {
                // No stamped elevation (e.g. a line or polygon): sample the
                // loaded elevation grid at the feature's representative point.
                elevationText = String(format: "%.1f m", elevationMeters)
            }

            if let elevation = elevationText {
                values["a9_elevation"] = elevation
                values["elevation"] = elevation
                values["other_location"] = [values["other_location"], "Elevation: \(elevation)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                values["location_summary"] = [values["location_summary"], "Elevation: \(elevation)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            }

            if let accuracy = layer.fields.first(where: { $0.key.lowercased() == "gps_accuracy_m" })?.value,
               !accuracy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values["gps_accuracy_m"] = accuracy
                values["location_accuracy"] = accuracy.contains("m") ? accuracy : "±\(accuracy) m"
            }

            if !layer.photoFilenames.isEmpty {
                values["p5b_photo_description"] = "\(layer.photoFilenames.count) attached field photo(s)."
                values["a16_photographs"] = layer.photoFilenames.joined(separator: ", ")
                values["photo_log"] = layer.photoFilenames.enumerated().map { index, name in
                    "Photo \(index + 1): \(name)"
                }.joined(separator: "\n")
            }

            switch layer.kind {
            case .point:
                values["p4_resources_present"] = "Site / Object / Isolate / Point observation"
                values["l2a_portion"] = "Point Observation"
            case .measure, .track:
                values["l2a_portion"] = "Segment"
                values["p4_resources_present"] = "Structure / Site / Linear feature"
            case .polygon:
                values["p4_resources_present"] = "Site / District / Boundary"
                values["d4_boundary"] = metrics?.geometrySummary ?? layer.geometrySummary(units: distanceUnits)
            }
        }

        let recorder = recorderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recorder.isEmpty {
            values["recorded_by"] = recorder
            values["p8_recorded_by"] = recorder
            values["a17_prepared_by"] = recorder
            values["l10_prepared_by"] = recorder
            values["drawn_by"] = recorder
        }
        values["attachments"] = attachmentSuggestion(kind: kind, layer: layer)

        if let metrics = metrics {
            applyLabelBasedAutofill(kind: kind, metrics: metrics, to: &values)
        }
        return values
    }

    /// If a future DPR field definition contains words such as UTM or
    /// Length, fill it even if the field key was not explicitly listed
    /// above. Existing user-entered values are not overwritten here.
    private static func applyLabelBasedAutofill(
        kind: DPRFormKind,
        metrics: FeatureMetrics,
        to values: inout [String: String]
    ) {
        for field in kind.fields {
            let key = field.key.lowercased()
            let label = field.label.lowercased()
            let current = values[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard current.isEmpty else { continue }

            if key.contains("county") || label.contains("county") {
                if !metrics.countyText.isEmpty { values[field.key] = metrics.countyText }
            } else if key.contains("quad") || label.contains("quad") || label.contains("7.5") || label.contains("usgs") {
                if !metrics.quadText.isEmpty { values[field.key] = metrics.quadText }
            } else if (key.contains("date") || label.contains("date")) && label.contains("map") {
                if !metrics.quadDateText.isEmpty { values[field.key] = metrics.quadDateText }
            } else if key.contains("map_name") || label == "map name" {
                if !metrics.quadNameText.isEmpty { values[field.key] = metrics.quadNameText }
            } else if key.contains("plss") || label.contains("plss") || key.contains("legal") || label.contains("legal") {
                if !metrics.plssText.isEmpty { values[field.key] = metrics.plssText }
            } else if key.contains("township") || label.contains("township") {
                if !metrics.townshipText.isEmpty { values[field.key] = metrics.townshipText }
            } else if key == "range" || key.contains("range") || label == "range" || label.contains("range") {
                if !metrics.rangeText.isEmpty { values[field.key] = metrics.rangeText }
            } else if key.contains("section") || label.contains("section") {
                if !metrics.sectionText.isEmpty { values[field.key] = metrics.sectionText }
            } else if key.contains("meridian") || label.contains("meridian") {
                if !metrics.principalMeridianText.isEmpty { values[field.key] = metrics.principalMeridianText }
            } else if key.contains("utm") || label.contains("utm") {
                values[field.key] = metrics.utmText
            } else if key.contains("decimal") || label.contains("decimal") || label.contains("latitude") || label.contains("longitude") {
                values[field.key] = metrics.decimalDegreesText
            } else if key.contains("elevation") || label.contains("elevation") {
                // Elevation is applied in the explicit values map when the linked feature has elevation_m.
            } else if key.contains("length") || label.contains("length") {
                if let lengthLabel = metrics.lengthLabel {
                    values[field.key] = lengthLabel
                }
            } else if key.contains("width") || label.contains("width") {
                if let widthLabel = metrics.widthLabel {
                    values[field.key] = widthLabel
                }
            } else if key.contains("perimeter") || label.contains("perimeter") {
                if let perimeterLabel = metrics.perimeterLabel {
                    values[field.key] = perimeterLabel
                }
            } else if key.contains("area") || label.contains("area") {
                if let areaLabel = metrics.areaLabel {
                    values[field.key] = areaLabel
                }
            }
        }
    }

    private static func featureMetrics(for layer: MapLayer, units: DistanceUnits, allLayers: [MapLayer]) -> FeatureMetrics {
        let coordinates = layer.clCoordinates
        let center = preferredLocationCoordinate(for: layer)
        let geometrySummary = layer.geometrySummary(units: units)
        let utmText = utmSummary(for: layer, center: center)
        let decimalText = decimalSummary(for: layer, center: center)
        let plssRecord = PLSSLookup.lookup(for: center, layers: allLayers)
        let countyRecord = CountyLookup.lookup(for: center, layers: allLayers)
        let quadRecord = USGSQuadLookup.lookup(for: center, layers: allLayers)

        var lengthMeters: Double?
        var widthMeters: Double?
        var perimeterMeters: Double?
        var areaSquareMeters: Double?

        switch layer.kind {
        case .measure, .track:
            lengthMeters = MeasurementMath.totalDistanceMeters(for: coordinates)
        case .polygon:
            let bbox = boundingDimensionsMeters(for: coordinates)
            lengthMeters = bbox.length
            widthMeters = bbox.width
            perimeterMeters = MeasurementMath.totalDistanceMeters(for: coordinates + Array(coordinates.prefix(1)))
            areaSquareMeters = MeasurementMath.areaSquareMeters(for: coordinates)
        case .point:
            break
        }

        let lengthLabel = lengthMeters.map { UnitFormat.distance($0, units: units) }
        let widthLabel = widthMeters.map { UnitFormat.distance($0, units: units) }
        let perimeterLabel = perimeterMeters.map { UnitFormat.distance($0, units: units) }
        let areaLabel = areaSquareMeters.map { UnitFormat.area($0, units: units) }

        var narrativeParts: [String] = []
        if !utmText.isEmpty { narrativeParts.append("UTM: \(utmText)") }
        if !decimalText.isEmpty { narrativeParts.append("Decimal degrees: \(decimalText)") }
        if let countyText = countyRecord?.summary, !countyText.isEmpty { narrativeParts.append("County: \(countyText)") }
        if let quadText = quadRecord?.summary, !quadText.isEmpty { narrativeParts.append("USGS 7.5' Quad: \(quadText)") }
        if let plssText = plssRecord?.summary, !plssText.isEmpty { narrativeParts.append("PLSS: \(plssText)") }
        narrativeParts.append("Geometry: \(geometrySummary)")
        if let lengthLabel = lengthLabel {
            switch layer.kind {
            case .polygon:
                narrativeParts.append("Approx. maximum dimension: \(lengthLabel)")
            default:
                narrativeParts.append("Length: \(lengthLabel)")
            }
        }
        if let widthLabel = widthLabel { narrativeParts.append("Approx. width: \(widthLabel)") }
        if let perimeterLabel = perimeterLabel { narrativeParts.append("Perimeter: \(perimeterLabel)") }
        if let areaLabel = areaLabel { narrativeParts.append("Area: \(areaLabel)") }

        return FeatureMetrics(
            coordinateForLocation: center,
            utmText: utmText,
            decimalDegreesText: decimalText,
            locationNarrative: narrativeParts.joined(separator: "\n"),
            geometrySummary: geometrySummary,
            lengthMeters: lengthMeters,
            widthMeters: widthMeters,
            perimeterMeters: perimeterMeters,
            areaSquareMeters: areaSquareMeters,
            lengthLabel: lengthLabel,
            widthLabel: widthLabel,
            perimeterLabel: perimeterLabel,
            areaLabel: areaLabel,
            plssText: plssRecord?.summary ?? "",
            townshipText: plssRecord?.township ?? "",
            rangeText: plssRecord?.range ?? "",
            sectionText: plssRecord?.section ?? "",
            principalMeridianText: plssRecord?.principalMeridian ?? "",
            countyText: countyRecord?.county ?? "",
            countyStateText: countyRecord?.state ?? "",
            quadNameText: quadRecord?.name ?? "",
            quadDateText: quadRecord?.dateText ?? "",
            quadText: quadRecord?.summary ?? ""
        )
    }

    private static func preferredLocationCoordinate(for layer: MapLayer) -> CLLocationCoordinate2D? {
        switch layer.kind {
        case .point:
            return layer.clCoordinates.first
        case .measure, .track, .polygon:
            return MeasurementMath.centroid(for: layer.clCoordinates) ?? layer.clCoordinates.first
        }
    }

    private static func utmSummary(for layer: MapLayer, center: CLLocationCoordinate2D?) -> String {
        let coordinates = layer.clCoordinates
        guard !coordinates.isEmpty else { return "" }
        switch layer.kind {
        case .point:
            return CoordinateFormatter.utmString(for: coordinates[0])
        case .measure, .track:
            let start = coordinates.first.map { CoordinateFormatter.utmString(for: $0) } ?? ""
            let end = coordinates.last.map { CoordinateFormatter.utmString(for: $0) } ?? ""
            let centerText = center.map { CoordinateFormatter.utmString(for: $0) } ?? ""
            return "Start: \(start)\nEnd: \(end)\nCenter: \(centerText)"
        case .polygon:
            let centerText = center.map { CoordinateFormatter.utmString(for: $0) } ?? ""
            let firstVertex = coordinates.first.map { CoordinateFormatter.utmString(for: $0) } ?? ""
            return "Centroid: \(centerText)\nFirst vertex: \(firstVertex)"
        }
    }

    private static func decimalSummary(for layer: MapLayer, center: CLLocationCoordinate2D?) -> String {
        let coordinates = layer.clCoordinates
        guard !coordinates.isEmpty else { return "" }
        func decimal(_ coordinate: CLLocationCoordinate2D) -> String {
            CoordinateFormatter.string(for: coordinate, format: .decimalDegrees)
        }
        switch layer.kind {
        case .point:
            return decimal(coordinates[0])
        case .measure, .track:
            let start = coordinates.first.map(decimal) ?? ""
            let end = coordinates.last.map(decimal) ?? ""
            let centerText = center.map(decimal) ?? ""
            return "Start: \(start)\nEnd: \(end)\nCenter: \(centerText)"
        case .polygon:
            let centerText = center.map(decimal) ?? ""
            let firstVertex = coordinates.first.map(decimal) ?? ""
            return "Centroid: \(centerText)\nFirst vertex: \(firstVertex)"
        }
    }

    private static func boundingDimensionsMeters(for coordinates: [CLLocationCoordinate2D]) -> (length: Double, width: Double) {
        guard coordinates.count >= 2, let origin = coordinates.first else { return (0, 0) }
        let originLatitudeRadians = origin.latitude * .pi / 180
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = max(1.0, 111_320.0 * cos(originLatitudeRadians))
        let projected = coordinates.map { coordinate -> (x: Double, y: Double) in
            let x = (coordinate.longitude - origin.longitude) * metersPerDegreeLongitude
            let y = (coordinate.latitude - origin.latitude) * metersPerDegreeLatitude
            return (x, y)
        }
        let xs = projected.map { $0.x }
        let ys = projected.map { $0.y }
        let spanX = (xs.max() ?? 0) - (xs.min() ?? 0)
        let spanY = (ys.max() ?? 0) - (ys.min() ?? 0)
        return (max(spanX, spanY), min(spanX, spanY))
    }

    private static func archaeologicalDimensionsText(for layer: MapLayer, metrics: FeatureMetrics, units: DistanceUnits) -> String {
        switch layer.kind {
        case .point:
            return "Point observation. Location auto-filled from linked point."
        case .measure, .track:
            return "Linear resource or observation. Length: \(metrics.lengthLabel ?? layer.geometrySummary(units: units)). Method: mapped/GPS line from app. Reliability: field GPS/map-derived."
        case .polygon:
            var parts = ["Mapped site/boundary polygon from app geometry."]
            if let length = metrics.lengthLabel { parts.append("Length: \(length).") }
            if let width = metrics.widthLabel { parts.append("Width: \(width).") }
            if let area = metrics.areaLabel { parts.append("Area: \(area).") }
            if let perimeter = metrics.perimeterLabel { parts.append("Perimeter: \(perimeter).") }
            parts.append("Method: mapped/GPS polygon from app.")
            return parts.joined(separator: " ")
        }
    }

    private static func linearDimensionsText(for layer: MapLayer, metrics: FeatureMetrics, units: DistanceUnits) -> String {
        switch layer.kind {
        case .measure, .track:
            return "Length of segment: \(metrics.lengthLabel ?? layer.geometrySummary(units: units)). Top width: field verify. Bottom width: field verify. Height/depth: field verify."
        case .polygon:
            var parts = ["Mapped polygon/boundary; not a single linear segment."]
            if let length = metrics.lengthLabel { parts.append("Approx. maximum dimension: \(length).") }
            if let perimeter = metrics.perimeterLabel { parts.append("Perimeter: \(perimeter).") }
            return parts.joined(separator: " ")
        case .point:
            return "Point observation. No segment length available from point geometry."
        }
    }

    private static func attachmentSuggestion(kind: DPRFormKind, layer: MapLayer?) -> String {
        var parts: [String] = []
        if layer != nil { parts.append("Location Map") }
        switch kind {
        case .archaeologicalC:
            parts.append("Archaeological Record")
            parts.append("Photograph Record")
            parts.append("Sketch Map")
        case .linearE:
            parts.append("Linear Feature Record")
            parts.append("Sketch Map")
        case .buildingB:
            parts.append("Building, Structure, and Object Record")
            parts.append("Sketch Map")
        case .districtD:
            parts.append("District Record")
            parts.append("Location Map")
        case .photoI:
            parts.append("Photograph Record")
        case .locationMapJ:
            parts.append("Location Map")
        case .sketchMapK:
            parts.append("Sketch Map")
        case .continuationL:
            parts.append("Continuation Sheet")
        case .primaryA:
            break
        }
        return parts.joined(separator: "; ")
    }
}


struct PLSSLookupRecord {
    let township: String
    let range: String
    let section: String
    let principalMeridian: String
    let plssID: String

    var summary: String {
        var parts: [String] = []
        if !principalMeridian.isEmpty { parts.append(principalMeridian) }
        if !township.isEmpty { parts.append(prefixed(township, prefix: "T")) }
        if !range.isEmpty { parts.append(prefixed(range, prefix: "R")) }
        if !section.isEmpty { parts.append(section.uppercased().hasPrefix("SEC") ? section : "Sec \(section)") }
        if parts.isEmpty, !plssID.isEmpty { parts.append("PLSSID \(plssID)") }
        if !plssID.isEmpty, !parts.contains("PLSSID \(plssID)") { parts.append("PLSSID \(plssID)") }
        return parts.joined(separator: "; ")
    }

    private func prefixed(_ value: String, prefix: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.uppercased().hasPrefix(prefix.uppercased()) ? trimmed : "\(prefix)\(trimmed)"
    }
}

enum PLSSLookup {
    static func lookup(for coordinate: CLLocationCoordinate2D?, layers: [MapLayer]) -> PLSSLookupRecord? {
        guard let coordinate = coordinate else { return nil }
        let plssLayers = layers.filter { layer in
            let text = "\(layer.name) \(layer.group) \(layer.fields.map { $0.key + " " + $0.value }.joined(separator: " "))".lowercased()
            return text.contains("plss") || text.contains("township") || text.contains("frstdiv") || text.contains("section")
        }
        guard !plssLayers.isEmpty else { return nil }

        let sectionLayer = plssLayers.first { layer in
            layer.kind == .polygon && isSectionLayer(layer) && contains(coordinate, in: layer)
        }
        let townshipLayer = plssLayers.first { layer in
            layer.kind == .polygon && isTownshipLayer(layer) && contains(coordinate, in: layer)
        }

        guard sectionLayer != nil || townshipLayer != nil else { return nil }

        let township = townshipText(from: townshipLayer) ?? townshipText(from: sectionLayer) ?? ""
        let range = rangeText(from: townshipLayer) ?? rangeText(from: sectionLayer) ?? ""
        let section = sectionText(from: sectionLayer) ?? ""
        let meridian = value(from: townshipLayer, keys: ["PRINMER", "principal_meridian", "Principal Meridian"]) ?? ""
        let plssID = value(from: sectionLayer, keys: ["PLSSID"]) ?? value(from: townshipLayer, keys: ["PLSSID"]) ?? ""

        return PLSSLookupRecord(
            township: township,
            range: range,
            section: section,
            principalMeridian: meridian,
            plssID: plssID
        )
    }

    private static func isTownshipLayer(_ layer: MapLayer) -> Bool {
        let text = "\(layer.name) \(layer.group) \(layer.fields.map { $0.key }.joined(separator: " "))".lowercased()
        return text.contains("township") || text.contains("twnshp") || text.contains("plss: township")
    }

    private static func isSectionLayer(_ layer: MapLayer) -> Bool {
        let text = "\(layer.name) \(layer.group) \(layer.fields.map { $0.key }.joined(separator: " "))".lowercased()
        return text.contains("section") || text.contains("frstdiv") || text.contains("plss: section")
    }

    private static func townshipText(from layer: MapLayer?) -> String? {
        guard let layer = layer else { return nil }
        if let label = value(from: layer, keys: ["TWNSHPLAB", "township", "Township"]), !label.isEmpty { return cleanPLSSLabel(label) }
        let number = value(from: layer, keys: ["TWNSHPNO"]) ?? ""
        let fraction = value(from: layer, keys: ["TWNSHPFRAC"]) ?? ""
        let direction = value(from: layer, keys: ["TWNSHPDIR"]) ?? ""
        let text = cleanPLSSLabel(number + fraction + direction)
        return text.isEmpty ? nil : text
    }

    private static func rangeText(from layer: MapLayer?) -> String? {
        guard let layer = layer else { return nil }
        if let label = value(from: layer, keys: ["RANGELAB", "range", "Range"]), !label.isEmpty { return cleanPLSSLabel(label) }
        let number = value(from: layer, keys: ["RANGENO"]) ?? ""
        let fraction = value(from: layer, keys: ["RANGEFRAC"]) ?? ""
        let direction = value(from: layer, keys: ["RANGEDIR"]) ?? ""
        let text = cleanPLSSLabel(number + fraction + direction)
        return text.isEmpty ? nil : text
    }

    private static func sectionText(from layer: MapLayer?) -> String? {
        guard let layer = layer else { return nil }
        if let label = value(from: layer, keys: ["FRSTDIVLAB", "FRSTDIVNO", "section", "Section"]), !label.isEmpty {
            return cleanPLSSLabel(label)
        }
        return nil
    }

    private static func value(from layer: MapLayer?, keys: [String]) -> String? {
        guard let layer = layer else { return nil }
        for key in keys {
            if let field = layer.fields.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func cleanPLSSLabel(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    private static func contains(_ coordinate: CLLocationCoordinate2D, in layer: MapLayer) -> Bool {
        let polygon = layer.clCoordinates
        guard polygon.count >= 3 else { return false }
        let x = coordinate.longitude
        let y = coordinate.latitude
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let xi = polygon[i].longitude
            let yi = polygon[i].latitude
            let xj = polygon[j].longitude
            let yj = polygon[j].latitude
            let intersects = ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / max(0.000000000001, (yj - yi)) + xi)
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }
}


struct CountyLookupRecord {
    let county: String
    let state: String
    let geoid: String

    var summary: String {
        [county, state].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum CountyLookup {
    static func lookup(for coordinate: CLLocationCoordinate2D?, layers: [MapLayer]) -> CountyLookupRecord? {
        guard let coordinate = coordinate else { return nil }
        let countyLayers = layers.filter { layer in
            let text = "\(layer.name) \(layer.group) \(layer.fields.map { $0.key + " " + $0.value }.joined(separator: " "))".lowercased()
            return text.contains("dpr autofill: counties") || text.contains("county") || text.contains("namelsad") || text.contains("countyfp")
        }
        guard let layer = countyLayers.first(where: { $0.kind == .polygon && MapLayerPolygonLookup.contains(coordinate, in: $0) }) else { return nil }

        let rawCounty = value(from: layer, keys: ["NAMELSAD", "NAME", "COUNTY", "COUNTY_NAME", "County", "county"]) ?? layer.name
        let state = value(from: layer, keys: ["STATE_NAME", "STATE", "STATEFP", "STATE_ALPHA", "state"]) ?? ""
        let geoid = value(from: layer, keys: ["GEOID", "GEOIDFQ", "COUNTYFP", "COUNTYNS"]) ?? ""
        return CountyLookupRecord(county: cleanCounty(rawCounty), state: state, geoid: geoid)
    }

    private static func value(from layer: MapLayer, keys: [String]) -> String? {
        for key in keys {
            if let field = layer.fields.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func cleanCounty(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " County", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: " Parish", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: " Borough", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: " Census Area", with: "", options: [.caseInsensitive])
    }
}

struct USGSQuadLookupRecord {
    let name: String
    let dateText: String
    let state: String
    let counties: String

    var summary: String {
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        if !dateText.isEmpty { parts.append(dateText) }
        return parts.joined(separator: " / ")
    }
}

enum USGSQuadLookup {
    static func lookup(for coordinate: CLLocationCoordinate2D?, layers: [MapLayer]) -> USGSQuadLookupRecord? {
        guard let coordinate = coordinate else { return nil }
        let quadLayers = layers.filter { layer in
            let text = "\(layer.name) \(layer.group) \(layer.fields.map { $0.key + " " + $0.value }.joined(separator: " "))".lowercased()
            return text.contains("usgs 7.5") || text.contains("quad") || text.contains("cell_name") || text.contains("pub_yr") || text.contains("us topo")
        }
        guard let layer = quadLayers.first(where: { $0.kind == .polygon && MapLayerPolygonLookup.contains(coordinate, in: $0) }) else { return nil }

        let name = value(from: layer, keys: ["cell_name", "CELL_NAME", "Cell Name", "QUAD_NAME", "quad_name", "name", "NAME"]) ?? layer.name
        let pubYear = value(from: layer, keys: ["pub_yr", "PUB_YR", "PUB_YEAR", "publication_year"])
        let fileDate = value(from: layer, keys: ["file_name_date", "FILE_NAME_DATE", "date", "DATE"])
        let suffix = value(from: layer, keys: ["product_name_suffix", "PRODUCT_NAME_SUFFIX"])
        let dateText = [pubYear, yearFromArcGISDate(fileDate), yearFromProductSuffix(suffix), suffix]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let state = value(from: layer, keys: ["primary_state", "PRIMARY_STATE", "STATE", "state"]) ?? ""
        let counties = value(from: layer, keys: ["counties", "COUNTIES", "COUNTY", "county"]) ?? ""
        return USGSQuadLookupRecord(name: name, dateText: dateText, state: state, counties: counties)
    }

    private static func value(from layer: MapLayer, keys: [String]) -> String? {
        for key in keys {
            if let field = layer.fields.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func yearFromArcGISDate(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let number = Double(text), number > 1_000_000_000_000 {
            let date = Date(timeIntervalSince1970: number / 1000.0)
            return Calendar.current.component(.year, from: date).description
        }
        let yearPattern = #"(19|20)\d{2}"#
        return firstMatch(in: text, pattern: yearPattern)
    }

    private static func yearFromProductSuffix(_ text: String?) -> String? {
        guard let text = text else { return nil }
        return firstMatch(in: text, pattern: #"(19|20)\d{2}"#)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

enum MapLayerPolygonLookup {
    static func contains(_ coordinate: CLLocationCoordinate2D, in layer: MapLayer) -> Bool {
        let polygon = layer.clCoordinates
        guard polygon.count >= 3 else { return false }
        let x = coordinate.longitude
        let y = coordinate.latitude
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let xi = polygon[i].longitude
            let yi = polygon[i].latitude
            let xj = polygon[j].longitude
            let yj = polygon[j].latitude
            let intersects = ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / max(0.000000000001, (yj - yi)) + xi)
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }
}

extension DateFormatter {
    static let dprShortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    static let dprFileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct DPRFormsListView: View {
    @ObservedObject var store: DPRFormStore
    let layers: [MapLayer]
    let contextLayerID: UUID?
    let onNew: (DPRFormKind, UUID?) -> Void
    let onEdit: (DPRFormRecord) -> Void
    let onExport: (DPRFormRecord, DPRFormExportFormat) -> Void
    let onExportPacket: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var contextLayer: MapLayer? {
        contextLayerID.flatMap { id in layers.first(where: { $0.id == id }) }
    }

    private var displayedForms: [DPRFormRecord] {
        let base: [DPRFormRecord]
        if let contextLayerID = contextLayerID {
            base = store.forms(for: contextLayerID)
        } else {
            base = store.forms.sorted { $0.updatedAt > $1.updatedAt }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { form in
            form.kind.shortCode.localizedCaseInsensitiveContains(query)
            || form.kind.title.localizedCaseInsensitiveContains(query)
            || form.resourceNameOrUntitled.localizedCaseInsensitiveContains(query)
            || form.values.values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if let contextLayer = contextLayer {
                        Label("Attached to: \(contextLayer.name)", systemImage: "mappin.and.ellipse")
                        Button {
                            onExportPacket(contextLayer.id)
                        } label: {
                            Label("Export Feature Form Packet as PDF", systemImage: "doc.richtext")
                        }
                        .disabled(store.forms(for: contextLayer.id).isEmpty)
                    } else {
                        Label("Standalone and feature-attached DPR forms", systemImage: "doc.text.fill")
                    }
                } footer: {
                    Text("Forms can be filled without GPS, or attached to a point, line, track, or polygon. Export individual forms as filled PDFs or Word-compatible documents.")
                }

                Section(header: Text("New DPR Form")) {
                    ForEach(DPRFormKind.allCases) { kind in
                        Button {
                            onNew(kind, contextLayerID)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(kind.shortCode) — \(kind.title)")
                                Text(kind.recommendedGeometry)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(header: Text("Saved Forms")) {
                    if displayedForms.isEmpty {
                        Text("No DPR forms saved for this view yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(displayedForms) { form in
                            DPRFormRow(
                                form: form,
                                linkedLayerName: form.linkedLayerID.flatMap { id in layers.first(where: { $0.id == id })?.name },
                                onEdit: { onEdit(form) },
                                onExportPDF: { onExport(form, .pdf) },
                                onExportWord: { onExport(form, .word) },
                                onDelete: { store.delete(form) }
                            )
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search DPR forms")
            .navigationTitle(contextLayer == nil ? "DPR 523 Forms" : "Feature DPR Forms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct DPRFormRow: View {
    let form: DPRFormRecord
    let linkedLayerName: String?
    let onEdit: () -> Void
    let onExportPDF: () -> Void
    let onExportWord: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(form.kind.shortCode) — \(form.resourceNameOrUntitled)")
                        .font(.headline)
                    Text(linkedLayerName.map { "Attached to \($0)" } ?? "Standalone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Updated \(form.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Edit") { onEdit() }
                    Button("Export Filled PDF") { onExportPDF() }
                    Button("Export Word-compatible Document") { onExportWord() }
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }
            HStack(spacing: 8) {
                Button("Edit") { onEdit() }
                    .buttonStyle(.borderedProminent)
                Button("PDF") { onExportPDF() }
                    .buttonStyle(.bordered)
                Button("Word") { onExportWord() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Delete this DPR form?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Form", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct DPRFormEditorView: View {
    let request: DPRFormEditorRequest
    let linkedLayer: MapLayer?
    @ObservedObject var store: DPRFormStore
    let allLayers: [MapLayer]
    let recorderName: String
    let coordinateFormat: CoordinateDisplayFormat
    let distanceUnits: DistanceUnits
    let elevationProvider: ((CLLocationCoordinate2D) -> Double?)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: DPRFormKind
    @State private var record: DPRFormRecord

    init(
        request: DPRFormEditorRequest,
        linkedLayer: MapLayer?,
        store: DPRFormStore,
        allLayers: [MapLayer],
        recorderName: String,
        coordinateFormat: CoordinateDisplayFormat,
        distanceUnits: DistanceUnits,
        elevationProvider: ((CLLocationCoordinate2D) -> Double?)? = nil
    ) {
        self.request = request
        self.linkedLayer = linkedLayer
        self.store = store
        self.allLayers = allLayers
        self.recorderName = recorderName
        self.coordinateFormat = coordinateFormat
        self.distanceUnits = distanceUnits
        self.elevationProvider = elevationProvider
        let initialKind = request.existingForm?.kind ?? request.kind
        let initialRecord = request.existingForm ?? DPRFormRecord(
            kind: initialKind,
            linkedLayerID: request.linkedLayerID,
            values: DPRFormAutofill.values(
                kind: initialKind,
                layer: linkedLayer,
                recorderName: recorderName,
                coordinateFormat: coordinateFormat,
                distanceUnits: distanceUnits,
                allLayers: allLayers,
                elevationProvider: elevationProvider
            )
        )
        _selectedKind = State(initialValue: initialKind)
        _record = State(initialValue: initialRecord)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Form Type", selection: $selectedKind) {
                        ForEach(DPRFormKind.allCases) { kind in
                            Text("\(kind.shortCode) — \(kind.title)").tag(kind)
                        }
                    }
                    .onChange(of: selectedKind) { newKind in
                        record.kind = newKind
                        let autofill = DPRFormAutofill.values(
                            kind: newKind,
                            layer: linkedLayer,
                            recorderName: recorderName,
                            coordinateFormat: coordinateFormat,
                            distanceUnits: distanceUnits,
                            allLayers: allLayers,
                            elevationProvider: elevationProvider
                        )
                        for (key, value) in autofill where (record.values[key] ?? "").isEmpty {
                            record.values[key] = value
                        }
                    }

                    if let linkedLayer = linkedLayer {
                        Label("Attached to \(linkedLayer.name)", systemImage: "mappin.and.ellipse")
                        Button {
                            applyLinkedFeatureAutofill(overwriteExisting: false)
                        } label: {
                            Label("Auto-fill Blank UTM / Length / Geometry Fields", systemImage: "wand.and.stars")
                        }
                        Button {
                            applyLinkedFeatureAutofill(overwriteExisting: true)
                        } label: {
                            Label("Recalculate Map-Derived Fields", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } else {
                        Label("Standalone form — no map feature required", systemImage: "doc.text")
                    }
                } footer: {
                    Text(linkedLayer == nil ? selectedKind.recommendedGeometry : "Any DPR form can be attached to this point, line, track, or polygon. UTM, decimal degrees, elevation, length, width, perimeter, area, county, USGS 7.5-minute quad/date, and PLSS township/range/section fields are filled from the linked map feature plus downloaded offline DPR autofill layers when those fields exist in the selected DPR form.")
                }

                Section(header: Text("Resource")) {
                    fieldEditor(DPRFormFieldDefinition("resource_name", "Resource Name or Number"))
                    fieldEditor(DPRFormFieldDefinition("primary_number", "Primary #"))
                    fieldEditor(DPRFormFieldDefinition("trinomial", "Trinomial"))
                    fieldEditor(DPRFormFieldDefinition("recorded_by", "Recorded by"))
                    fieldEditor(DPRFormFieldDefinition("date_recorded", "Date Recorded"))
                }

                Section(selectedKind.shortCode) {
                    ForEach(selectedKind.fields.filter { !["resource_name", "primary_number", "trinomial", "recorded_by", "date_recorded"].contains($0.key) }) { field in
                        fieldEditor(field)
                    }
                }
            }
            .navigationTitle(selectedKind.shortCode)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        record.kind = selectedKind
                        store.upsert(record)
                        dismiss()
                    }
                    .disabled(record.resourceNameOrUntitled == "Untitled Resource" && (record.values["resource_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func applyLinkedFeatureAutofill(overwriteExisting: Bool) {
        guard linkedLayer != nil else { return }
        let autofill = DPRFormAutofill.values(
            kind: selectedKind,
            layer: linkedLayer,
            recorderName: recorderName,
            coordinateFormat: coordinateFormat,
            distanceUnits: distanceUnits,
            allLayers: allLayers,
            elevationProvider: elevationProvider
        )
        for (key, value) in autofill {
            let current = record.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if overwriteExisting || current.isEmpty {
                record.values[key] = value
            }
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: DPRFormFieldDefinition) -> some View {
        let binding = Binding<String>(
            get: { record.values[field.key] ?? "" },
            set: { record.values[field.key] = $0 }
        )
        if field.multiline {
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: binding)
                    .frame(minHeight: 92)
            }
        } else {
            TextField(field.label, text: binding, axis: .vertical)
        }
    }
}

enum DPRFormDocumentExporter {
    static func exportPDF(form: DPRFormRecord, linkedLayer: MapLayer?) throws -> URL {
        try exportPDFPacket(forms: [form], linkedLayer: linkedLayer)
    }

    static func exportPDFPacket(forms: [DPRFormRecord], linkedLayer: MapLayer?) throws -> URL {
        let first = forms.first
        let stem = safeFileStem("DPR523-\(first?.resourceNameOrUntitled ?? "Packet")-\(DateFormatter.dprFileStamp.string(from: Date()))")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        try renderer.writePDF(to: url) { context in
            for form in forms {
                context.beginPage()
                draw(form: form, linkedLayer: linkedLayer, in: pageRect, context: context)
            }
        }
        return url
    }

    static func exportWordCompatibleDocument(form: DPRFormRecord, linkedLayer: MapLayer?) throws -> URL {
        let stem = safeFileStem("\(form.kind.shortCode)-\(form.resourceNameOrUntitled)-\(DateFormatter.dprFileStamp.string(from: Date()))")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).doc")
        let rows = exportRows(form: form, linkedLayer: linkedLayer)
        let htmlRows = rows.map { row in
            "<tr><td><b>\(htmlEscape(row.0))</b></td><td>\(htmlEscape(row.1).replacingOccurrences(of: "\n", with: "<br/>") )</td></tr>"
        }.joined(separator: "\n")
        let html = """
        <html><head><meta charset="utf-8"><title>\(htmlEscape(form.kind.shortCode))</title>
        <style>body{font-family:Arial,Helvetica,sans-serif;font-size:11pt;} table{border-collapse:collapse;width:100%;} td{border:1px solid #999;padding:6px;vertical-align:top;} h1{font-size:18pt;} h2{font-size:13pt;}</style>
        </head><body>
        <h1>State of California Department of Parks and Recreation</h1>
        <h2>\(htmlEscape(form.kind.shortCode)) — \(htmlEscape(form.kind.title))</h2>
        <p><b>Exported:</b> \(htmlEscape(Date().formatted(date: .abbreviated, time: .shortened)))</p>
        <table>\(htmlRows)</table>
        </body></html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func draw(form: DPRFormRecord, linkedLayer: MapLayer?, in pageRect: CGRect, context: UIGraphicsPDFRendererContext) {
        var y: CGFloat = 34
        let left: CGFloat = 38
        let width = pageRect.width - 76
        let titleFont = UIFont.boldSystemFont(ofSize: 15)
        let subtitleFont = UIFont.boldSystemFont(ofSize: 12)
        let bodyFont = UIFont.systemFont(ofSize: 10)
        let smallFont = UIFont.systemFont(ofSize: 8)

        func drawText(_ text: String, font: UIFont, rect: CGRect, color: UIColor = .black) {
            (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color])
        }

        func beginContinuationPage() {
            context.beginPage()
            y = 34
            drawText("DPR 523 Continuation", font: titleFont, rect: CGRect(x: left, y: y, width: width, height: 20))
            y += 24
        }

        drawText("State of California — Department of Parks and Recreation", font: smallFont, rect: CGRect(x: left, y: y, width: width, height: 14))
        y += 16
        drawText("\(form.kind.shortCode)  \(form.kind.title)", font: titleFont, rect: CGRect(x: left, y: y, width: width, height: 22))
        y += 24
        drawText("Resource: \(form.resourceNameOrUntitled)", font: subtitleFont, rect: CGRect(x: left, y: y, width: width, height: 18))
        y += 20
        if let linkedLayer = linkedLayer {
            drawText("Linked feature: \(linkedLayer.name) — \(linkedLayer.geometrySummary(units: .metric))", font: smallFont, rect: CGRect(x: left, y: y, width: width, height: 14), color: .darkGray)
            y += 16
        }
        y += 6

        for row in exportRows(form: form, linkedLayer: linkedLayer) {
            let label = row.0
            let value = row.1.isEmpty ? " " : row.1
            let valueRect = CGRect(x: left + 145, y: y + 4, width: width - 153, height: 1000)
            let valueHeight = max(22, min(150, (value as NSString).boundingRect(
                with: CGSize(width: valueRect.width, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: bodyFont],
                context: nil
            ).height + 10))
            let rowHeight = valueHeight + 8
            if y + rowHeight > pageRect.height - 42 {
                beginContinuationPage()
            }
            let rowRect = CGRect(x: left, y: y, width: width, height: rowHeight)
            UIColor.black.setStroke()
            UIBezierPath(rect: rowRect).stroke()
            drawText(label, font: subtitleFont, rect: CGRect(x: left + 5, y: y + 5, width: 135, height: rowHeight - 10))
            drawText(value, font: bodyFont, rect: CGRect(x: left + 145, y: y + 5, width: width - 153, height: rowHeight - 10))
            y += rowHeight
        }
    }

    private static func exportRows(form: DPRFormRecord, linkedLayer: MapLayer?) -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("Form", "\(form.kind.shortCode) — \(form.kind.title)"))
        rows.append(("Linked Status", linkedLayer?.name ?? "Standalone"))
        rows.append(("Created", form.createdAt.formatted(date: .abbreviated, time: .shortened)))
        rows.append(("Updated", form.updatedAt.formatted(date: .abbreviated, time: .shortened)))
        for field in form.kind.fields {
            rows.append((field.label, form.values[field.key] ?? ""))
        }
        return rows
    }

    private static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func safeFileStem(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = text.map { character -> Character in
            String(character).rangeOfCharacter(from: allowed) == nil ? "-" : character
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "DPR523" : collapsed
    }
}

// MARK: - Field recorder UI models and views

enum FieldRecordCoordinateSource: String, CaseIterable, Identifiable {
    case gps
    case crosshair

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gps: return "GPS"
        case .crosshair: return "Crosshair"
        }
    }
}

enum FieldQuickTemplate: String, CaseIterable, Identifiable {
    case mayaMound
    case lithicScatter
    case ceramicScatter
    case wallLine
    case trailRoad
    case lootingPit
    case disturbance
    case photoPoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mayaMound: return "Maya Mound"
        case .lithicScatter: return "Lithic Scatter"
        case .ceramicScatter: return "Ceramic Scatter"
        case .wallLine: return "Wall / Alignment"
        case .trailRoad: return "Trail / Road"
        case .lootingPit: return "Looting Pit"
        case .disturbance: return "Disturbance"
        case .photoPoint: return "Photo Point"
        }
    }

    var subtitle: String {
        switch self {
        case .mayaMound: return "Mound, platform, rise"
        case .lithicScatter: return "Stone artifacts"
        case .ceramicScatter: return "Ceramics / sherds"
        case .wallLine: return "Linear stone/earth feature"
        case .trailRoad: return "Path, sacbe, modern road"
        case .lootingPit: return "Looting or pit feature"
        case .disturbance: return "Modern or natural impact"
        case .photoPoint: return "Photo documentation"
        }
    }

    var systemImage: String {
        switch self {
        case .mayaMound: return "mountain.2.fill"
        case .lithicScatter: return "circle.grid.3x3.fill"
        case .ceramicScatter: return "square.grid.3x3.fill"
        case .wallLine: return "line.diagonal"
        case .trailRoad: return "figure.walk"
        case .lootingPit: return "exclamationmark.triangle.fill"
        case .disturbance: return "wrench.and.screwdriver.fill"
        case .photoPoint: return "camera.fill"
        }
    }

    var color: LayerColor {
        switch self {
        case .mayaMound: return .orange
        case .lithicScatter: return .blue
        case .ceramicScatter: return .brown
        case .wallLine: return .yellow
        case .trailRoad: return .green
        case .lootingPit: return .red
        case .disturbance: return .pink
        case .photoPoint: return .purple
        }
    }

    var defaultNote: String {
        switch self {
        case .mayaMound: return "Field recorder template: possible mound/platform."
        case .lithicScatter: return "Field recorder template: lithic scatter."
        case .ceramicScatter: return "Field recorder template: ceramic scatter."
        case .wallLine: return "Field recorder template: wall, alignment, or linear feature."
        case .trailRoad: return "Field recorder template: trail, road, sacbe, or access route."
        case .lootingPit: return "Field recorder template: possible looting pit or disturbance."
        case .disturbance: return "Field recorder template: modern/natural disturbance."
        case .photoPoint: return "Field recorder template: photo documentation point."
        }
    }

    var defaultFields: [FeatureField] {
        [
            FeatureField(key: "feature_type", value: title),
            FeatureField(key: "condition", value: ""),
            FeatureField(key: "confidence", value: ""),
            FeatureField(key: "visibility", value: ""),
            FeatureField(key: "needs_review", value: "yes")
        ]
    }
}

enum FieldDataCheckSeverity: String {
    case warning
    case notice

    var systemImage: String {
        switch self {
        case .warning: return "exclamationmark.triangle.fill"
        case .notice: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .warning: return .orange
        case .notice: return .secondary
        }
    }
}

struct FieldDataCheckIssue: Identifiable {
    let id = UUID()
    let layerID: UUID?
    let layerName: String
    let message: String
    let severity: FieldDataCheckSeverity

    static func issues(for layers: [MapLayer]) -> [FieldDataCheckIssue] {
        var out: [FieldDataCheckIssue] = []
        let created = layers.filter { !$0.isImported }

        if created.isEmpty && layers.count != 1 {
            out.append(FieldDataCheckIssue(layerID: nil, layerName: "Survey", message: "No new field features have been recorded yet.", severity: .notice))
        }

        for layer in created {
            if layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || layer.name == layer.kind.displayName {
                out.append(FieldDataCheckIssue(layerID: layer.id, layerName: layer.name, message: "Feature name may need a more specific label.", severity: .notice))
            }
            if layer.photoFilenames.isEmpty && (layer.kind == .point || layer.kind == .polygon) {
                out.append(FieldDataCheckIssue(layerID: layer.id, layerName: layer.name, message: "No photo attached.", severity: .notice))
            }
            if layer.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(FieldDataCheckIssue(layerID: layer.id, layerName: layer.name, message: "Notes are empty.", severity: .notice))
            }
            if layer.fields.contains(where: { $0.key == "review_status" && $0.value == "needs_review" }) ||
                layer.fields.contains(where: { $0.key == "needs_review" && $0.value.lowercased() == "yes" }) {
                out.append(FieldDataCheckIssue(layerID: layer.id, layerName: layer.name, message: "Marked as needing review.", severity: .warning))
            }
            if layer.kind == .measure || layer.kind == .track {
                if layer.clCoordinates.count < 2 {
                    out.append(FieldDataCheckIssue(layerID: layer.id, layerName: layer.name, message: "Line/track has fewer than two vertices.", severity: .warning))
                }
            }
            if layer.kind == .polygon {
                if layer.clCoordinates.count < 3 {
                    out.append(FieldDataCheckIssue(layerID: layer.id, layerName: layer.name, message: "Polygon has fewer than three vertices.", severity: .warning))
                }
            }
            if let accuracyField = layer.fields.first(where: { $0.key == "gps_accuracy_m" }),
               let accuracy = Double(accuracyField.value), accuracy > 10 {
                out.append(FieldDataCheckIssue(layerID: layer.id, layerName: layer.name, message: String(format: "GPS accuracy is %.1f m.", accuracy), severity: .warning))
            }
        }

        return out
    }
}

enum TransectMissionStatus: String, CaseIterable, Identifiable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case complete = "complete"
    case skipped = "skipped"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .complete: return "Complete"
        case .skipped: return "Skipped"
        }
    }

    var color: Color {
        switch self {
        case .notStarted: return .secondary
        case .inProgress: return .orange
        case .complete: return .green
        case .skipped: return .red
        }
    }

    static func from(_ layer: MapLayer) -> TransectMissionStatus {
        let raw = layer.fields.first { $0.key == "mission_status" }?.value ?? ""
        return TransectMissionStatus(rawValue: raw) ?? .notStarted
    }
}

enum CrewPackageExportScope: String, CaseIterable, Identifiable {
    case visibleLayers
    case createdToday
    case transectArrays
    case allCreated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visibleLayers: return "Visible Layers"
        case .createdToday: return "Today’s Created Features"
        case .transectArrays: return "Transect Arrays"
        case .allCreated: return "All Created Field Data"
        }
    }

    var subtitle: String {
        switch self {
        case .visibleLayers: return "Everything currently turned on"
        case .createdToday: return "New features from this device today"
        case .transectArrays: return "Crew walking lines only"
        case .allCreated: return "All non-imported survey layers"
        }
    }
}

struct FieldRecorderMiniStatus: View {
    let title: String
    let value: String
    let systemImage: String
    let isWarning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isWarning ? Color.brandAmber : .white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.10)))
        .foregroundStyle(.white)
    }
}

struct FieldRecorderDeckButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(subtitle)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(0.82)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(prominent ? Color.brandAmber : Color.white.opacity(0.12))
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct FieldDashboardView: View {
    let layers: [MapLayer]
    let recorderName: String
    let mapLoaded: Bool
    let mapName: String
    let gpsStatus: String
    let currentCoordinate: CLLocationCoordinate2D?
    let isRecordingTrack: Bool
    let dataIssueCount: Int
    let onStartSurvey: () -> Void
    let onRecordFeature: () -> Void
    let onOpenLayers: () -> Void
    let onDataCheck: () -> Void
    let onCrewPackage: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("coordinateDisplayFormat") private var coordinateFormatRaw = CoordinateDisplayFormat.decimalDegrees.rawValue

    private var coordinateFormat: CoordinateDisplayFormat {
        CoordinateDisplayFormat(rawValue: coordinateFormatRaw) ?? .decimalDegrees
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Today’s Survey")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        Text(recorderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recorder not set" : "Recorder: \(recorderName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(
                        LinearGradient(colors: [Color.brandSlate, Color.brandAmber.opacity(0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    )

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        FieldDashboardStatCard(title: "Map", value: mapLoaded ? "Ready" : "None", detail: mapLoaded ? mapName : "Import or create offline map", systemImage: "map.fill")
                        FieldDashboardStatCard(title: "GPS", value: gpsStatus, detail: currentCoordinate.map { CoordinateFormatter.string(for: $0, format: coordinateFormat) } ?? "Waiting for fix", systemImage: "location.fill")
                        FieldDashboardStatCard(title: "Features", value: "\(layers.filter { !$0.isImported }.count)", detail: "Created on this device", systemImage: "mappin.and.ellipse")
                        FieldDashboardStatCard(title: "Data Check", value: dataIssueCount == 0 ? "Good" : "\(dataIssueCount)", detail: dataIssueCount == 0 ? "No review flags" : "Items need review", systemImage: "checkmark.shield.fill")
                    }

                    VStack(spacing: 10) {
                        FieldDashboardActionButton(title: isRecordingTrack ? "Continue Recording" : "Start / Resume Survey", subtitle: "Return to the live field map", systemImage: "arrow.forward.circle.fill", tint: Color.brandAmber) {
                            dismiss()
                            onStartSurvey()
                        }
                        FieldDashboardActionButton(title: "Record Feature", subtitle: "Point, line, polygon, track, 3D", systemImage: "plus.viewfinder", tint: .green) {
                            dismiss()
                            onRecordFeature()
                        }
                        FieldDashboardActionButton(title: "Review Layers", subtitle: "Sort, search, edit, group, delete", systemImage: "square.3.layers.3d", tint: .purple) {
                            dismiss()
                            onOpenLayers()
                        }
                        FieldDashboardActionButton(title: "Run Data Check", subtitle: "Missing notes/photos, GPS accuracy, review flags", systemImage: "checkmark.shield", tint: .orange) {
                            dismiss()
                            onDataCheck()
                        }
                        FieldDashboardActionButton(title: "Crew Package / Export", subtitle: "Share transects or today’s features", systemImage: "shippingbox.fill", tint: .blue) {
                            dismiss()
                            onCrewPackage()
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Field Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct FieldDashboardStatCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.brandAmber)
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.heavy))
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
    }
}

struct FieldDashboardActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: 34)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}

struct FieldRecorderActionView: View {
    let gpsAvailable: Bool
    let crosshairAvailable: Bool
    let isRecordingTrack: Bool
    let gpsActionSuffix: String
    let onRecordPoint: (FieldRecordCoordinateSource) -> Void
    let onStartLine: () -> Void
    let onStartPolygon: () -> Void
    let onToggleTrack: () -> Void
    let onLiDARScan: () -> Void
    let onOpenForms: () -> Void
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                            onRecordPoint(.gps)
                        } label: {
                            Label("Point @ GPS\(gpsActionSuffix)", systemImage: "location.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!gpsAvailable)

                        Button {
                            dismiss()
                            onRecordPoint(.crosshair)
                        } label: {
                            Label("Point @ Crosshair", systemImage: "plus.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!crosshairAvailable)
                    }
                } header: {
                    Text("Points")
                } footer: {
                    Text("Record a generic point, then attach any DPR 523 form from Feature Info or the Forms screen. Location fields can be auto-filled from GPS/map geometry.")
                }

                Section(header: Text("Lines, polygons, tracks")) {
                    Button {
                        dismiss()
                        onStartLine()
                    } label: {
                        Label("Start Line @ Crosshair", systemImage: "line.diagonal")
                    }
                    .disabled(!crosshairAvailable)

                    Button {
                        dismiss()
                        onStartPolygon()
                    } label: {
                        Label("Start Polygon @ Crosshair", systemImage: "skew")
                    }
                    .disabled(!crosshairAvailable)

                    Button {
                        dismiss()
                        onToggleTrack()
                    } label: {
                        Label(isRecordingTrack ? "Stop and Save Track" : "Start GPS Track", systemImage: isRecordingTrack ? "stop.circle.fill" : "figure.walk")
                    }
                }

                Section(header: Text("DPR 523 forms")) {
                    Button {
                        dismiss()
                        onOpenForms()
                    } label: {
                        Label("Open Standalone / Attached DPR Forms", systemImage: "doc.text.fill")
                    }
                }

                Section(header: Text("3D documentation")) {
                    Button {
                        dismiss()
                        onLiDARScan()
                    } label: {
                        Label(LiDARScanCoordinator.isSupported ? "LiDAR Scan @ Crosshair" : "Photo 3D Model @ Crosshair", systemImage: LiDARScanCoordinator.isSupported ? "cube.transparent" : "camera.viewfinder")
                    }
                    .disabled(!crosshairAvailable || (!LiDARScanCoordinator.isSupported && !Photo3DModelScanCoordinator.isSupported))
                }
            }
            .navigationTitle("Record Feature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                        onClose()
                    }
                }
            }
        }
    }
}

struct FieldDataCheckView: View {
    let layers: [MapLayer]
    @Environment(\.dismiss) private var dismiss

    private var issues: [FieldDataCheckIssue] { FieldDataCheckIssue.issues(for: layers) }
    private var createdCount: Int { layers.filter { !$0.isImported }.count }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: issues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(issues.isEmpty ? Color.green : Color.brandAmber)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issues.isEmpty ? "Data looks ready" : "\(issues.count) item\(issues.count == 1 ? "" : "s") need review")
                                .font(.headline)
                            Text("\(createdCount) created field feature\(createdCount == 1 ? "" : "s") checked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if issues.isEmpty {
                    Section {
                        Text("No obvious issues were found. This check looks for empty notes, missing photos, review flags, short geometries, and high GPS accuracy values when recorded.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section(header: Text("Review Items")) {
                        ForEach(issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(issue.message, systemImage: issue.severity.systemImage)
                                    .foregroundStyle(issue.severity.color)
                                Text(issue.layerName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Data Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct TransectMissionView: View {
    let layers: [MapLayer]
    let onWalk: (MapLayer) -> Void
    let onSetStatus: (UUID, TransectMissionStatus) -> Void
    let onExportGroup: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var missionGroups: [(name: String, layers: [MapLayer])] {
        let arrayLayers = layers.filter { $0.isTransectArrayMember || $0.group.hasPrefix("Transect Array -") }
        let grouped = Dictionary(grouping: arrayLayers) { layer in
            layer.group.isEmpty ? "Transect Array" : layer.group
        }
        return grouped
            .map { key, value in
                (name: key, layers: value.sorted { lhs, rhs in
                    let li = Int(lhs.fields.first { $0.key == "transect_index" }?.value ?? "") ?? Int.max
                    let ri = Int(rhs.fields.first { $0.key == "transect_index" }?.value ?? "") ?? Int.max
                    if li != ri { return li < ri }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationView {
            List {
                if missionGroups.isEmpty {
                    Section {
                        Text("No transect arrays are saved yet. Tap a drawn line or track, then choose Create Transect Array from This Line.")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(missionGroups, id: \.name) { groupEntry in
                    Section {
                        ForEach(groupEntry.layers) { layer in
                            TransectMissionRow(layer: layer) { action in
                                switch action {
                                case .walk:
                                    dismiss()
                                    onWalk(layer)
                                case .inProgress:
                                    onSetStatus(layer.id, .inProgress)
                                case .complete:
                                    onSetStatus(layer.id, .complete)
                                case .skipped:
                                    onSetStatus(layer.id, .skipped)
                                }
                            }
                        }

                        Button {
                            onExportGroup(groupEntry.name)
                        } label: {
                            Label("Export This Array as KML", systemImage: "square.and.arrow.up")
                        }
                    } header: {
                        Text(groupEntry.name)
                    } footer: {
                        let complete = groupEntry.layers.filter { TransectMissionStatus.from($0) == .complete }.count
                        Text("\(complete) of \(groupEntry.layers.count) transects marked complete.")
                    }
                }
            }
            .navigationTitle("Transect Mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

enum TransectMissionRowAction {
    case walk
    case inProgress
    case complete
    case skipped
}

struct TransectMissionRow: View {
    let layer: MapLayer
    let onAction: (TransectMissionRowAction) -> Void

    private var status: TransectMissionStatus { TransectMissionStatus.from(layer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.transectArrayLabel ?? layer.name)
                        .font(.headline)
                    Text(layer.geometrySummary(units: .metric))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(status.title)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(status.color.opacity(0.16)))
                    .foregroundStyle(status.color)
            }

            HStack {
                Button("Walk") { onAction(.walk) }
                    .buttonStyle(.borderedProminent)
                Button("Started") { onAction(.inProgress) }
                    .buttonStyle(.bordered)
                Button("Complete") { onAction(.complete) }
                    .buttonStyle(.bordered)
                Button("Skip") { onAction(.skipped) }
                    .buttonStyle(.bordered)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}

struct CrewPackageExportView: View {
    let layers: [MapLayer]
    let onExport: (CrewPackageExportScope, LayerExportFormat) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope: CrewPackageExportScope = .transectArrays
    @State private var format: LayerExportFormat = .kml

    private var estimatedLayerCount: Int {
        switch scope {
        case .visibleLayers: return layers.filter { $0.isVisible }.count
        case .createdToday: return layers.filter { Calendar.current.isDateInToday($0.createdAt) && !$0.isImported }.count
        case .transectArrays: return layers.filter { $0.isTransectArrayMember || $0.group.hasPrefix("Transect Array -") }.count
        case .allCreated: return layers.filter { !$0.isImported }.count
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Package", selection: $scope) {
                        ForEach(CrewPackageExportScope.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }

                    Picker("Format", selection: $format) {
                        ForEach(LayerExportFormat.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }

                    LabeledContent("Layers", value: "\(estimatedLayerCount)")
                } header: {
                    Text("Crew Package")
                } footer: {
                    Text(scope.subtitle + ". KML is best for sharing planned transect lines to another phone; GeoJSON is best for GIS editing.")
                }

                Section {
                    Button {
                        dismiss()
                        onExport(scope, format)
                    } label: {
                        Label("Export Crew Package", systemImage: "square.and.arrow.up")
                    }
                    .disabled(estimatedLayerCount == 0)
                }
            }
            .navigationTitle("Crew Package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct FieldFeatureSummaryCard: View {
    let layer: MapLayer
    let units: DistanceUnits

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: layer.kind.systemImage)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(layer.effectiveColor.color)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(layer.name)
                        .font(.title3.weight(.heavy))
                    Text("\(layer.kind.displayName) • \(Self.dateFormatter.string(from: layer.createdAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(layer.geometrySummary(units: units))
                .font(.callout.monospacedDigit().weight(.semibold))

            HStack(spacing: 8) {
                FieldFeatureBadge(text: "Photos \(layer.photoFilenames.count)", systemImage: "photo")
                if !layer.group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    FieldFeatureBadge(text: layer.group, systemImage: "folder")
                }
                if layer.isTransectArrayMember {
                    FieldFeatureBadge(text: "Transect", systemImage: "figure.walk")
                }
            }
        }
        .padding(.vertical, 6)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

struct FieldFeatureBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
            .foregroundStyle(.secondary)
    }
}

struct FeatureInfoPillButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Feature info

/// Read-only feature detail view shown when a saved feature is tapped on the map.
/// Editing is a deliberate second step so accidental taps do not immediately
/// put the feature into edit mode.
struct FeatureInfoView: View {
    let layer: MapLayer
    let onClose: () -> Void
    let onEditAttributes: (UUID) -> Void
    let onEditGeometry: (UUID) -> Void
    let onLiDARScan: ((UUID) -> Void)?
    let onViewLiDARScan: ((UUID) -> Void)?
    let onShareLiDARScan: ((UUID) -> Void)?
    let onBufferLayer: ((UUID) -> Void)?
    let onCreateTransectArray: ((UUID) -> Void)?
    let onExportTransectArray: ((UUID) -> Void)?
    let onExportLayer: ((UUID, LayerExportFormat) -> Void)?
    let dprFormCount: Int
    let onOpenDPRForms: ((UUID) -> Void)?
    let onExportDPRPacket: ((UUID) -> Void)?
    let onDelete: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("distanceUnits") private var infoUnitsRaw = DistanceUnits.metric.rawValue
    @AppStorage("coordinateDisplayFormat") private var coordinateFormatRaw = CoordinateDisplayFormat.decimalDegrees.rawValue
    @State private var viewingPhoto: IdentifiedPhoto?
    @State private var didChooseAction = false
    @State private var confirmingDeleteFeature = false

    init(
        layer: MapLayer,
        onClose: @escaping () -> Void,
        onEditAttributes: @escaping (UUID) -> Void,
        onEditGeometry: @escaping (UUID) -> Void,
        onLiDARScan: ((UUID) -> Void)? = nil,
        onViewLiDARScan: ((UUID) -> Void)? = nil,
        onShareLiDARScan: ((UUID) -> Void)? = nil,
        onBufferLayer: ((UUID) -> Void)? = nil,
        onCreateTransectArray: ((UUID) -> Void)? = nil,
        onExportTransectArray: ((UUID) -> Void)? = nil,
        onExportLayer: ((UUID, LayerExportFormat) -> Void)? = nil,
        dprFormCount: Int = 0,
        onOpenDPRForms: ((UUID) -> Void)? = nil,
        onExportDPRPacket: ((UUID) -> Void)? = nil,
        onDelete: ((UUID) -> Void)? = nil
    ) {
        self.layer = layer
        self.onClose = onClose
        self.onEditAttributes = onEditAttributes
        self.onEditGeometry = onEditGeometry
        self.onLiDARScan = onLiDARScan
        self.onViewLiDARScan = onViewLiDARScan
        self.onShareLiDARScan = onShareLiDARScan
        self.onBufferLayer = onBufferLayer
        self.onCreateTransectArray = onCreateTransectArray
        self.onExportTransectArray = onExportTransectArray
        self.onExportLayer = onExportLayer
        self.dprFormCount = dprFormCount
        self.onOpenDPRForms = onOpenDPRForms
        self.onExportDPRPacket = onExportDPRPacket
        self.onDelete = onDelete
    }

    private struct IdentifiedPhoto: Identifiable { let id: String }

    private var distanceUnits: DistanceUnits {
        DistanceUnits(rawValue: infoUnitsRaw) ?? .metric
    }

    private var coordinateFormat: CoordinateDisplayFormat {
        CoordinateDisplayFormat(rawValue: coordinateFormatRaw) ?? .decimalDegrees
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    FieldFeatureSummaryCard(layer: layer, units: distanceUnits)
                }

                if !FieldDataCheckIssue.issues(for: [layer]).isEmpty {
                    Section(header: Text("Data Check")) {
                        ForEach(FieldDataCheckIssue.issues(for: [layer])) { issue in
                            Label(issue.message, systemImage: issue.severity.systemImage)
                                .foregroundStyle(issue.severity.color)
                        }
                    }
                }

                Section(header: Text("Feature")) {
                    LabeledContent("Name", value: layer.name)
                    LabeledContent("Type", value: layer.kind.displayName)
                    LabeledContent("Geometry", value: layer.geometrySummary(units: distanceUnits))
                    if !layer.group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent("Group", value: layer.group)
                    }
                    LabeledContent("Visible", value: layer.isVisible ? "Yes" : "No")
                    LabeledContent("Created", value: Self.dateFormatter.string(from: layer.createdAt))
                }

                Section(header: Text("Measurements")) {
                    ForEach(measurementRows, id: \.0) { row in
                        LabeledContent(row.0, value: row.1)
                    }
                }

                if !coordinateRows.isEmpty {
                    Section(header: Text("Coordinates")) {
                        ForEach(coordinateRows, id: \.0) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.0)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(row.1)
                                    .font(.footnote.monospacedDigit())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !layer.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(header: Text("Notes")) {
                        Text(layer.notes)
                            .textSelection(.enabled)
                    }
                }

                Section(header: Text("Attributes")) {
                    if layer.fields.isEmpty {
                        Text("No attributes recorded")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(layer.fields) { field in
                            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
                            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                            LabeledContent(key.isEmpty ? "Attribute" : key, value: value.isEmpty ? "—" : value)
                        }
                    }
                }

                if !layer.photoFilenames.isEmpty {
                    Section(header: Text("Photos")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(layer.photoFilenames, id: \.self) { filename in
                                    photoThumbnail(filename)
                                        .onTapGesture {
                                            viewingPhoto = IdentifiedPhoto(id: filename)
                                        }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(header: Text("Quick Actions")) {
                    HStack(spacing: 10) {
                        FeatureInfoPillButton(title: "Edit", systemImage: "square.and.pencil", tint: .blue) {
                            didChooseAction = true
                            dismiss()
                            onEditAttributes(layer.id)
                        }

                        if layer.kind == .track || layer.kind == .measure {
                            FeatureInfoPillButton(title: "Buffer", systemImage: "square.dashed", tint: .orange) {
                                didChooseAction = true
                                dismiss()
                                onBufferLayer?(layer.id)
                            }
                        }

                        FeatureInfoPillButton(title: "Export", systemImage: "square.and.arrow.up", tint: .green) {
                            didChooseAction = true
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onExportLayer?(layer.id, .kml)
                            }
                        }
                    }
                }

                Section(header: Text("DPR 523 Forms")) {
                    HStack {
                        Label("\(dprFormCount) attached form\(dprFormCount == 1 ? "" : "s")", systemImage: "doc.text.fill")
                        Spacer()
                    }

                    if let onOpenDPRForms = onOpenDPRForms {
                        Button {
                            didChooseAction = true
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onOpenDPRForms(layer.id)
                            }
                        } label: {
                            Label(dprFormCount == 0 ? "Create / Attach DPR Form…" : "View / Add DPR Forms…", systemImage: "doc.badge.plus")
                        }
                    }

                    if let onExportDPRPacket = onExportDPRPacket {
                        Button {
                            didChooseAction = true
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onExportDPRPacket(layer.id)
                            }
                        } label: {
                            Label("Export DPR Form Packet as PDF", systemImage: "doc.richtext")
                        }
                        .disabled(dprFormCount == 0)
                    }
                }

                Section(header: Text("Actions")) {
                    Button {
                        didChooseAction = true
                        dismiss()
                        onEditAttributes(layer.id)
                    } label: {
                        Label("Edit Attributes / Photos", systemImage: "square.and.pencil")
                    }

                    Button {
                        didChooseAction = true
                        dismiss()
                        onEditGeometry(layer.id)
                    } label: {
                        Label("Edit Geometry / Vertices", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    .disabled(layer.coordinates.isEmpty)

                    if layer.kind == .measure || layer.kind == .track {
                        if let onBufferLayer = onBufferLayer {
                            Button {
                                didChooseAction = true
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    onBufferLayer(layer.id)
                                }
                            } label: {
                                Label("Buffer Line / Track…", systemImage: "rectangle.dashed")
                            }
                        }

                        if let onCreateTransectArray = onCreateTransectArray {
                            Button {
                                didChooseAction = true
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    onCreateTransectArray(layer.id)
                                }
                            } label: {
                                Label("Create Transect Array from This Line…", systemImage: "rectangle.split.3x1")
                            }
                        }
                    }

                    if let onExportTransectArray = onExportTransectArray,
                       layer.isTransectArrayMember {
                        Button {
                            didChooseAction = true
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onExportTransectArray(layer.id)
                            }
                        } label: {
                            Label("Export Full Transect Array KML", systemImage: "rectangle.split.3x1.and.arrow.up")
                        }
                    }

                    if let onExportLayer = onExportLayer {
                        Button {
                            didChooseAction = true
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onExportLayer(layer.id, .kml)
                            }
                        } label: {
                            Label("Export This Feature as KML", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            didChooseAction = true
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onExportLayer(layer.id, .geojson)
                            }
                        } label: {
                            Label("Export This Feature as GeoJSON", systemImage: "curlybraces")
                        }
                    }

                    if layer.hasLiDARScanFiles {
                        if let onViewLiDARScan = onViewLiDARScan, layer.lidarPLYFilename != nil {
                            Button {
                                didChooseAction = true
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    onViewLiDARScan(layer.id)
                                }
                            } label: {
                                Label("View 3D Point Cloud", systemImage: "view.3d")
                            }
                        }

                        if let onShareLiDARScan = onShareLiDARScan {
                            Button {
                                didChooseAction = true
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    onShareLiDARScan(layer.id)
                                }
                            } label: {
                                Label("Export / Open 3D Files…", systemImage: "square.and.arrow.up")
                            }
                        }
                    }

                    if layer.kind == .point, let onLiDARScan = onLiDARScan {
                        Button {
                            didChooseAction = true
                            dismiss()
                            onLiDARScan(layer.id)
                        } label: {
                            Label(LiDARScanCoordinator.isSupported ? "Scan LiDAR at This Point…" : "Capture Photo 3D Model at This Point…", systemImage: LiDARScanCoordinator.isSupported ? "cube.transparent" : "camera.viewfinder")
                        }
                        .disabled(!LiDARScanCoordinator.isSupported && !Photo3DModelScanCoordinator.isSupported)
                    }
                }

                if onDelete != nil {
                    Section(header: Text("Feature Management")) {
                        HStack(spacing: 12) {
                            Button {
                                didChooseAction = true
                                dismiss()
                                onEditAttributes(layer.id)
                            } label: {
                                Label("Edit", systemImage: "square.and.pencil")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(role: .destructive) {
                                confirmingDeleteFeature = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Feature Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        didChooseAction = true
                        dismiss()
                        onClose()
                    }
                }
            }
            .confirmationDialog(
                "Delete \(layer.name)? This cannot be undone.",
                isPresented: $confirmingDeleteFeature,
                titleVisibility: .visible
            ) {
                Button("Delete Feature", role: .destructive) {
                    didChooseAction = true
                    dismiss()
                    onDelete?(layer.id)
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $viewingPhoto) { photo in
                PhotoViewer(filename: photo.id)
            }
            .onDisappear {
                if !didChooseAction {
                    onClose()
                }
            }
        }
    }

    private var measurementRows: [(String, String)] {
        switch layer.kind {
        case .point:
            return [("Point", "1 coordinate")]
        case .track, .measure:
            let distance = MeasurementMath.totalDistanceMeters(for: layer.clCoordinates)
            var rows: [(String, String)] = [
                ("Vertices", "\(layer.coordinates.count)"),
                ("Distance", UnitFormat.distance(distance, units: distanceUnits))
            ]
            if let bearing = MeasurementMath.finalSegmentBearingDegrees(for: layer.clCoordinates) {
                rows.append(("Final Segment Bearing", String(format: "%.1f deg", bearing)))
            }
            if layer.clCoordinates.count >= 2,
               let first = layer.clCoordinates.first,
               let last = layer.clCoordinates.last {
                rows.append(("Start-End Bearing", String(format: "%.1f deg", MeasurementMath.bearingDegrees(from: first, to: last))))
            }
            return rows
        case .polygon:
            let area = MeasurementMath.areaSquareMeters(for: layer.clCoordinates)
            let perimeter = MeasurementMath.totalDistanceMeters(for: layer.clCoordinates + Array(layer.clCoordinates.prefix(1)))
            return [
                ("Vertices", "\(layer.coordinates.count)"),
                ("Area", UnitFormat.area(area, units: distanceUnits)),
                ("Perimeter", UnitFormat.distance(perimeter, units: distanceUnits))
            ]
        }
    }

    private var coordinateRows: [(String, String)] {
        let coordinates = layer.clCoordinates
        guard !coordinates.isEmpty else { return [] }

        func line(_ coordinate: CLLocationCoordinate2D) -> String {
            CoordinateFormatter.string(for: coordinate, format: coordinateFormat)
                + "\n" + CoordinateFormatter.utmString(for: coordinate)
        }

        switch layer.kind {
        case .point:
            return [("Point", line(coordinates[0]))]
        case .track, .measure:
            var rows: [(String, String)] = []
            if let first = coordinates.first { rows.append(("Start", line(first))) }
            if let last = coordinates.last { rows.append(("End", line(last))) }
            return rows
        case .polygon:
            guard let centroid = MeasurementMath.centroid(for: coordinates) else { return [] }
            return [("Approximate Center", line(centroid))]
        }
    }

    private func photoThumbnail(_ filename: String) -> some View {
        Group {
            if let image = PhotoStore.loadImage(filename) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 96, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}


// MARK: - Feature line/track tools

struct FeatureBufferRequest: Identifiable {
    let id = UUID()
    let layer: MapLayer
}

enum FeatureBufferExportMode: String, CaseIterable, Identifiable {
    case none
    case sourceKML
    case bufferKML
    case sourceAndBufferKML

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Save buffer only"
        case .sourceKML: return "Export source line/track KML"
        case .bufferKML: return "Export buffer KML"
        case .sourceAndBufferKML: return "Export source + buffer KML"
        }
    }
}

struct FeatureBufferView: View {
    @Environment(\.dismiss) private var dismiss
    let request: FeatureBufferRequest
    let onCreate: (Double, FeatureBufferExportMode) -> Void

    @AppStorage("distanceUnits") private var distanceUnitsRaw = DistanceUnits.metric.rawValue
    @State private var widthText = "15"
    @State private var exportMode: FeatureBufferExportMode = .none
    @State private var message = "Buffer width is the total corridor width around the selected line or track."

    private var units: DistanceUnits {
        DistanceUnits(rawValue: distanceUnitsRaw) ?? .metric
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Selected Feature")) {
                    LabeledContent("Name", value: request.layer.name)
                    LabeledContent("Type", value: request.layer.kind.displayName)
                    LabeledContent("Length", value: UnitFormat.distance(MeasurementMath.totalDistanceMeters(for: request.layer.clCoordinates), units: units))
                }

                Section(header: Text("Buffer")) {
                    TextField("Buffer width (\(units.shortDistanceLabel))", text: $widthText)
                        .keyboardType(.decimalPad)

                    Picker("Preset width", selection: $widthText) {
                        Text("5 \(units.shortDistanceLabel)").tag(presetText(5))
                        Text("10 \(units.shortDistanceLabel)").tag(presetText(10))
                        Text("15 \(units.shortDistanceLabel)").tag(presetText(15))
                        Text("20 \(units.shortDistanceLabel)").tag(presetText(20))
                        Text("30 \(units.shortDistanceLabel)").tag(presetText(30))
                    }
                }

                Section(header: Text("Export After Saving")) {
                    Picker("Export", selection: $exportMode) {
                        ForEach(FeatureBufferExportMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Buffer Line / Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { create() }
                }
            }
        }
    }

    private func presetText(_ value: Double) -> String {
        if value.rounded() == value { return String(format: "%.0f", value) }
        return String(value)
    }

    private func create() {
        guard let input = Double(widthText.replacingOccurrences(of: ",", with: ".")), input > 0 else {
            message = "Enter a positive buffer width."
            return
        }
        let widthMeters = UnitFormat.metersFromInput(input, units: units)
        guard widthMeters <= 5_000 else {
            message = "Buffer width is too large. Use a smaller corridor width."
            return
        }
        onCreate(widthMeters, exportMode)
        dismiss()
    }
}

struct TransectArrayFromLayerRequest: Identifiable {
    let id = UUID()
    let layer: MapLayer
}

enum TransectArraySide: String, CaseIterable, Identifiable {
    case right
    case left
    case centered

    var id: String { rawValue }

    var title: String {
        switch self {
        case .right: return "Right of line"
        case .left: return "Left of line"
        case .centered: return "Centered on line"
        }
    }
}

enum TransectArrayLabelMode: String, CaseIterable, Identifiable {
    case numbers
    case letters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .numbers: return "1, 2, 3"
        case .letters: return "A, B, C"
        }
    }

    func label(for zeroBasedIndex: Int) -> String {
        switch self {
        case .numbers:
            return "\(zeroBasedIndex + 1)"
        case .letters:
            return Self.letterLabel(for: zeroBasedIndex)
        }
    }

    private static func letterLabel(for zeroBasedIndex: Int) -> String {
        var number = max(0, zeroBasedIndex)
        var result = ""
        repeat {
            let remainder = number % 26
            let scalar = UnicodeScalar(65 + remainder)!
            result = String(Character(scalar)) + result
            number = number / 26 - 1
        } while number >= 0
        return result
    }
}

struct TransectArrayFromLayerView: View {
    @Environment(\.dismiss) private var dismiss
    let request: TransectArrayFromLayerRequest
    let onCreate: ([MapLayer], Bool) -> Void

    @AppStorage("distanceUnits") private var distanceUnitsRaw = DistanceUnits.metric.rawValue
    @State private var spacingText = "15"
    @State private var countText = "10"
    @State private var side: TransectArraySide = .right
    @State private var labelMode: TransectArrayLabelMode = .numbers
    @State private var exportKML = false
    @State private var message = "Transects will be saved as visible map layers first. Turn on KML export only when you want to share the array to other phones."

    private var units: DistanceUnits {
        DistanceUnits(rawValue: distanceUnitsRaw) ?? .metric
    }

    private var baseCoordinates: [CLLocationCoordinate2D] {
        request.layer.clCoordinates
    }

    private var baseLengthMeters: Double {
        guard let first = baseCoordinates.first, let last = baseCoordinates.last else { return 0 }
        return MeasurementMath.totalDistanceMeters(for: [first, last])
    }

    private var baseBearing: Double? {
        guard let first = baseCoordinates.first, let last = baseCoordinates.last else { return nil }
        return MeasurementMath.bearingDegrees(from: first, to: last)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Source Line")) {
                    LabeledContent("Name", value: request.layer.name)
                    LabeledContent("Bearing", value: baseBearing.map { String(format: "%.1f°", $0) } ?? "—")
                    LabeledContent("Length", value: UnitFormat.distance(baseLengthMeters, units: units))
                }

                Section(header: Text("Transect Array")) {
                    TextField("Spacing (\(units.shortDistanceLabel))", text: $spacingText)
                        .keyboardType(.decimalPad)
                    TextField("Number of transects", text: $countText)
                        .keyboardType(.numberPad)
                    Picker("Array side", selection: $side) {
                        ForEach(TransectArraySide.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Picker("Labels", selection: $labelMode) {
                        ForEach(TransectArrayLabelMode.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("Also export KML for sharing", isOn: $exportKML)
                    Text("All generated transects are added to the map and saved in their own layer group. KML export is optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Create Transect Array")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { create() }
                }
            }
        }
    }

    private func create() {
        guard baseCoordinates.count >= 2,
              let first = baseCoordinates.first,
              let last = baseCoordinates.last,
              let bearing = baseBearing else {
            message = "The selected layer needs at least two vertices."
            return
        }
        guard let spacingInput = Double(spacingText.replacingOccurrences(of: ",", with: ".")), spacingInput > 0 else {
            message = "Enter a positive spacing value."
            return
        }
        let spacingMeters = UnitFormat.metersFromInput(spacingInput, units: units)
        guard spacingMeters <= 5_000 else {
            message = "Spacing is too wide. Use a smaller interval."
            return
        }
        guard let count = Int(countText), count >= 1, count <= 300 else {
            message = "Number of transects must be 1 to 300."
            return
        }

        let groupName = "Transect Array - \(request.layer.name)"
        var newLayers: [MapLayer] = []

        for index in 0..<count {
            let offsetMeters = offsetForIndex(index, count: count, spacingMeters: spacingMeters)
            let offsetBearing = offsetMeters >= 0
                ? MeasurementMath.normalizedBearing360(bearing + 90)
                : MeasurementMath.normalizedBearing360(bearing - 90)
            let distance = abs(offsetMeters)
            let start = MeasurementMath.destination(from: first, bearingDegrees: offsetBearing, distanceMeters: distance)
            let end = MeasurementMath.destination(from: last, bearingDegrees: offsetBearing, distanceMeters: distance)
            let label = labelMode.label(for: index)

            var fields: [FeatureField] = [
                FeatureField(key: "transect_label", value: label),
                FeatureField(key: "transect_index", value: "\(index + 1)"),
                FeatureField(key: "transect_count", value: "\(count)"),
                FeatureField(key: "transect_spacing_m", value: String(format: "%.1f", spacingMeters)),
                FeatureField(key: "transect_offset_m", value: String(format: "%.1f", offsetMeters)),
                FeatureField(key: "bearing_deg", value: String(format: "%.1f", bearing)),
                FeatureField(key: "array_side", value: side.title),
                FeatureField(key: "array_source_layer", value: request.layer.name),
                FeatureField(key: "array_source_id", value: request.layer.id.uuidString),
                FeatureField(key: "array_group", value: groupName),
                FeatureField(key: "share_note", value: "Tap any transect in this array and choose Export Full Transect Array KML to share all transects.")
            ]

            let layer = MapLayer(
                name: "\(request.layer.name) Transect \(label)",
                kind: .measure,
                coordinates: [LayerCoordinate(start), LayerCoordinate(end)],
                notes: "Transect \(label) generated parallel to \(request.layer.name).",
                fields: fields,
                color: .orange,
                group: groupName
            )
            newLayers.append(layer)
        }

        onCreate(newLayers, exportKML)
        dismiss()
    }

    private func offsetForIndex(_ index: Int, count: Int, spacingMeters: Double) -> Double {
        switch side {
        case .right:
            return Double(index) * spacingMeters
        case .left:
            return -Double(index) * spacingMeters
        case .centered:
            let center = (Double(count) - 1.0) / 2.0
            return (Double(index) - center) * spacingMeters
        }
    }
}

// MARK: - Attribute editor

/// Edit name, color, notes, attributes, and photos for a feature.
/// Used when creating a new feature and when editing a saved one.
/// Pass onDelete to show a Delete Feature button.
struct AttributeEditorView: View {
    @State var layer: MapLayer
    @ObservedObject var templateStore: TemplateStore
    /// Existing group names, offered as quick picks.
    var existingGroups: [String] = []
    let title: String
    let onSave: (MapLayer) -> Void
    let onCancel: () -> Void
    var onDelete: ((UUID) -> Void)? = nil

    @AppStorage("distanceUnits") private var editorUnitsRaw = DistanceUnits.metric.rawValue
    @State private var initialPhotoFilenames: Set<String> = []
    @State private var pendingPhotoDeletions: Set<String> = []
    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var viewingPhoto: IdentifiedPhoto?
    @State private var confirmingDelete = false
    @State private var showingTemplateManager = false
    @State private var showingNewChoiceAlert = false
    @State private var newChoiceFieldKey = ""
    @State private var newChoiceText = ""

    private struct IdentifiedPhoto: Identifiable { let id: String }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Feature")) {
                    TextField("Name", text: $layer.name)
                    HStack {
                        TextField("Group (optional)", text: $layer.group)
                            .textInputAutocapitalization(.words)
                        if !existingGroups.isEmpty {
                            Menu {
                                ForEach(existingGroups, id: \.self) { groupName in
                                    Button(groupName) {
                                        layer.group = groupName
                                    }
                                }
                                if !layer.group.isEmpty {
                                    Divider()
                                    Button("No Group") { layer.group = "" }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                        }
                    }
                    LabeledContent("Type", value: layer.kind.displayName)
                    LabeledContent("Geometry", value: layer.geometrySummary(units: DistanceUnits(rawValue: editorUnitsRaw) ?? .metric))
                }

                Section {
                    Menu {
                        if templateStore.templates.isEmpty {
                            Text("No templates yet")
                        }
                        ForEach(templateStore.templates) { template in
                            Button(template.name) {
                                applyTemplate(template)
                            }
                        }
                        Divider()
                        Button {
                            showingTemplateManager = true
                        } label: {
                            Label("Manage Templates…", systemImage: "gearshape")
                        }
                    } label: {
                        Label("Apply Template", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("Template")
                } footer: {
                    Text("Templates add a standard set of fields with drop-down domains. Create them on the go from Manage Templates.")
                }

                Section(layer.kind == .polygon ? "Outline Color" : "Color") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(LayerColor.allCases) { option in
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Circle().stroke(
                                            Color.primary.opacity(layer.effectiveColor == option ? 0.9 : 0.15),
                                            lineWidth: layer.effectiveColor == option ? 3 : 1
                                        )
                                    )
                                    .onTapGesture {
                                        layer.color = option
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if layer.kind == .polygon {
                    Section(header: Text("Polygon Fill")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                // First swatch: match the outline color.
                                ZStack {
                                    Circle()
                                        .strokeBorder(layer.effectiveColor.color, lineWidth: 3)
                                        .frame(width: 34, height: 34)
                                    Text("=")
                                        .font(.headline)
                                        .foregroundStyle(layer.effectiveColor.color)
                                }
                                .overlay(
                                    Circle().stroke(
                                        Color.primary.opacity(layer.fillColor == nil ? 0.9 : 0.0),
                                        lineWidth: 3
                                    )
                                )
                                .onTapGesture {
                                    layer.fillColor = nil
                                }

                                ForEach(LayerColor.allCases) { option in
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 34, height: 34)
                                        .overlay(
                                            Circle().stroke(
                                                Color.primary.opacity(layer.fillColor == option ? 0.9 : 0.15),
                                                lineWidth: layer.fillColor == option ? 3 : 1
                                            )
                                        )
                                        .onTapGesture {
                                            layer.fillColor = option
                                        }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Picker("Fill Style", selection: $layer.fillStyle) {
                            ForEach(PolygonFillStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)

                        if layer.fillStyle != PolygonFillStyle.none {
                            HStack {
                                Text("Opacity")
                                Slider(value: $layer.fillOpacity, in: 0.05...0.85)
                                Text("\(Int(layer.fillOpacity * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }

                Section(header: Text("Notes")) {
                    TextEditor(text: $layer.notes)
                        .frame(minHeight: 80)
                }

                Section {
                    ForEach($layer.fields) { $field in
                        fieldRow($field)
                    }
                    .onDelete { offsets in
                        layer.fields.remove(atOffsets: offsets)
                    }

                    Button {
                        layer.fields.append(FeatureField())
                    } label: {
                        Label("Add Attribute", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Attributes")
                } footer: {
                    Text("Attributes become columns in the GIS attribute table when you export GeoJSON. Use short field names like site_id, material, condition.")
                }

                Section {
                    if !layer.photoFilenames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(layer.photoFilenames, id: \.self) { name in
                                    ZStack(alignment: .topTrailing) {
                                        photoThumbnail(name)
                                            .onTapGesture {
                                                viewingPhoto = IdentifiedPhoto(id: name)
                                            }
                                        Button {
                                            removePhoto(name)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                        .padding(4)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Button {
                        showingCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                    Button {
                        showingLibrary = true
                    } label: {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                    }
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Photos are saved in the app's Documents/LayerPhotos folder and referenced by filename in GeoJSON and KML exports.")
                }

                if onDelete != nil {
                    Section {
                        Button("Delete Feature", role: .destructive) {
                            confirmingDelete = true
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelEditing()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEditing()
                    }
                }
            }
            .onAppear {
                initialPhotoFilenames = Set(layer.photoFilenames)
            }
            .sheet(isPresented: $showingCamera) {
                ImagePicker(sourceType: .camera) { image in
                    addPhoto(image)
                }
            }
            .sheet(isPresented: $showingLibrary) {
                ImagePicker(sourceType: .photoLibrary) { image in
                    addPhoto(image)
                }
            }
            .sheet(item: $viewingPhoto) { photo in
                PhotoViewer(filename: photo.id)
            }
            .sheet(isPresented: $showingTemplateManager) {
                TemplateManagerView(store: templateStore)
            }
            .alert("New option for \(newChoiceFieldKey)", isPresented: $showingNewChoiceAlert) {
                TextField("New option", text: $newChoiceText)
                Button("Add") {
                    let value = newChoiceText.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { return }
                    templateStore.addChoice(value, forFieldNamed: newChoiceFieldKey)
                    if let index = layer.fields.firstIndex(where: { $0.key == newChoiceFieldKey }) {
                        layer.fields[index].value = value
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete this feature and its photos? This cannot be undone.",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Feature", role: .destructive) {
                    onDelete?(layer.id)
                }
            }
        }
    }

    /// Add the template's fields (without overwriting any already present).
    private func applyTemplate(_ template: AttributeTemplate) {
        for templateField in template.fields {
            let key = templateField.name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  !layer.fields.contains(where: { $0.key == key }) else { continue }
            layer.fields.append(FeatureField(key: key, value: ""))
        }
    }

    /// Render a field row: drop-down menu for domain fields, numeric
    /// keyboard for number fields, free text otherwise.
    @ViewBuilder
    private func fieldRow(_ field: Binding<FeatureField>) -> some View {
        let key = field.wrappedValue.key

        if let options = templateStore.choices(forFieldNamed: key) {
            HStack {
                Text(key)
                    .frame(maxWidth: 140, alignment: .leading)
                Spacer()
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            field.wrappedValue.value = option
                        }
                    }
                    Divider()
                    Button {
                        newChoiceFieldKey = key
                        newChoiceText = ""
                        showingNewChoiceAlert = true
                    } label: {
                        Label("Add Option…", systemImage: "plus")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(field.wrappedValue.value.isEmpty ? "Select" : field.wrappedValue.value)
                            .foregroundStyle(field.wrappedValue.value.isEmpty ? Color.secondary : Color.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if templateStore.fieldKind(forFieldNamed: key) == .number {
            HStack {
                Text(key)
                    .frame(maxWidth: 140, alignment: .leading)
                Divider()
                TextField("Number", text: field.value)
                    .keyboardType(.decimalPad)
            }
        } else {
            HStack {
                TextField("Field name", text: field.key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 140)
                Divider()
                TextField("Value", text: field.value)
            }
        }
    }

    private func photoThumbnail(_ name: String) -> some View {
        Group {
            if let image = PhotoStore.loadImage(name) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func addPhoto(_ image: UIImage) {
        if let name = PhotoStore.save(image) {
            layer.photoFilenames.append(name)
        }
    }

    private func removePhoto(_ name: String) {
        layer.photoFilenames.removeAll { $0 == name }
        if initialPhotoFilenames.contains(name) {
            // Pre-existing photo: only delete the file if Save is tapped,
            // so Cancel leaves the saved feature untouched.
            pendingPhotoDeletions.insert(name)
        } else {
            PhotoStore.delete([name])
        }
    }

    private func cancelEditing() {
        // Discard photo files added during this editing session.
        let added = layer.photoFilenames.filter { !initialPhotoFilenames.contains($0) }
        PhotoStore.delete(added)
        onCancel()
    }

    private func saveEditing() {
        PhotoStore.delete(Array(pendingPhotoDeletions))
        var cleaned = layer
        cleaned.fields.removeAll { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        if cleaned.name.trimmingCharacters(in: .whitespaces).isEmpty {
            cleaned.name = cleaned.kind.displayName
        }
        onSave(cleaned)
    }
}

// MARK: - Layer list

enum LayerSortMode: String, CaseIterable, Identifiable {
    case dateNewest
    case dateOldest
    case nameAscending
    case nameDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateNewest: return "Newest"
        case .dateOldest: return "Oldest"
        case .nameAscending: return "Name A-Z"
        case .nameDescending: return "Name Z-A"
        }
    }

    func sorted(_ layers: [MapLayer]) -> [MapLayer] {
        switch self {
        case .dateNewest:
            return layers.sorted { $0.createdAt > $1.createdAt }
        case .dateOldest:
            return layers.sorted { $0.createdAt < $1.createdAt }
        case .nameAscending:
            return layers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return layers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }
}

/// Browse saved layers: tap to edit attributes, swipe to delete,
/// tap the eye to show or hide a layer on the map.
struct LayerListView: View {
    @ObservedObject var store: LayerStore
    @ObservedObject var templateStore: TemplateStore
    /// Called when the user chooses Walk (lines/tracks) or Go To
    /// (points) on a row; ContentView turns it into a transect.
    var onWalkLayer: ((MapLayer) -> Void)? = nil
    /// Called when the user chooses Buffer to Polygon on a line/track.
    var onBufferLayer: ((MapLayer) -> Void)? = nil

    @AppStorage("distanceUnits") private var listUnitsRaw = DistanceUnits.metric.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var editingLayer: MapLayer?
    @State private var confirmingClearAll = false
    @State private var confirmingDeleteSelected = false
    @State private var searchText = ""
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingNewGroupAlert = false
    @State private var newGroupName = ""
    @State private var newGroupTargetID: UUID?
    @State private var showingBulkGroupAlert = false
    @State private var bulkGroupName = ""
    @AppStorage("layerListSortMode") private var layerSortModeRaw = LayerSortMode.dateNewest.rawValue

    private var layerSortMode: LayerSortMode {
        LayerSortMode(rawValue: layerSortModeRaw) ?? .dateNewest
    }

    private var filteredLayers: [MapLayer] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let matches: [MapLayer]
        if query.isEmpty {
            matches = store.layers
        } else {
            matches = store.layers.filter { layer in
                if layer.name.lowercased().contains(query) { return true }
                if layer.group.lowercased().contains(query) { return true }
                if layer.notes.lowercased().contains(query) { return true }
                return layer.fields.contains {
                    $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
                }
            }
        }
        return layerSortMode.sorted(matches)
    }

    private var filteredIDs: Set<UUID> {
        Set(filteredLayers.map { $0.id })
    }

    private var selectedCountText: String {
        "\(selectedIDs.count) selected"
    }

    /// Layers split into Created vs Imported, each subdivided by group
    /// (ungrouped last). Created sections come before imported ones so
    /// the user's own field data is always at the top of the list.
    private var groupedLayers: [(name: String, layers: [MapLayer])] {
        func subsections(_ layers: [MapLayer], categoryLabel: String) -> [(String, [MapLayer])] {
            guard !layers.isEmpty else { return [] }
            let grouped = Dictionary(grouping: layers) { $0.group }
            var out: [(String, [MapLayer])] = grouped
                .filter { !$0.key.isEmpty }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { ("\(categoryLabel) · \($0.key)", $0.value) }
            if let ungrouped = grouped[""], !ungrouped.isEmpty {
                out.append((categoryLabel, ungrouped))
            }
            return out
        }

        let created = filteredLayers.filter { !$0.isImported }
        let imported = filteredLayers.filter { $0.isImported }
        return subsections(created, categoryLabel: "Created")
            + subsections(imported, categoryLabel: "Imported")
    }

    var body: some View {
        NavigationView {
            Group {
                if store.layers.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.3.layers.3d.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No saved layers yet")
                            .foregroundStyle(.secondary)
                        Text("Save tracks, lines, polygons, and points from the Save menu, or use the + quick-add button.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        Section {
                            Picker("Sort", selection: $layerSortModeRaw) {
                                ForEach(LayerSortMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                        } header: {
                            Text("Sort Layers")
                        }

                        if selectionMode {
                            Section {
                                Text(selectedCountText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(groupedLayers, id: \.name) { groupEntry in
                            Section {
                                ForEach(groupEntry.layers) { layer in
                                    layerRow(layer)
                                }
                            } header: {
                                groupHeader(groupEntry.name, layers: groupEntry.layers)
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search name, group, notes, attributes")
                }
            }
            .navigationTitle(selectionMode ? "Select Layers" : "Saved Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selectionMode {
                        Button("Cancel") {
                            exitSelectionMode()
                        }
                    } else {
                        Button("Select") {
                            selectionMode = true
                            selectedIDs.removeAll()
                        }
                        .disabled(store.layers.isEmpty)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if selectionMode {
                        Button("All") {
                            selectAllFiltered()
                        }
                        .disabled(filteredLayers.isEmpty)

                        Button("None") {
                            selectedIDs.removeAll()
                        }
                        .disabled(selectedIDs.isEmpty)

                        Spacer()

                        Button("Group") {
                            bulkGroupName = ""
                            showingBulkGroupAlert = true
                        }
                        .disabled(selectedIDs.isEmpty)

                        Button("Delete", role: .destructive) {
                            confirmingDeleteSelected = true
                        }
                        .disabled(selectedIDs.isEmpty)
                    } else {
                        Button("Clear All", role: .destructive) {
                            confirmingClearAll = true
                        }
                        .disabled(store.layers.isEmpty)

                        Spacer()

                        Text("\(store.layers.count) layer\(store.layers.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .confirmationDialog(
                "Delete all saved layers? This cannot be undone.",
                isPresented: $confirmingClearAll,
                titleVisibility: .visible
            ) {
                Button("Delete All Layers", role: .destructive) {
                    store.clear()
                    exitSelectionMode()
                }
            }
            .confirmationDialog(
                "Delete \(selectedIDs.count) selected layer\(selectedIDs.count == 1 ? "" : "s")? This cannot be undone.",
                isPresented: $confirmingDeleteSelected,
                titleVisibility: .visible
            ) {
                Button("Delete Selected Layers", role: .destructive) {
                    store.remove(ids: selectedIDs)
                    exitSelectionMode()
                }
            }
            .alert("New Group", isPresented: $showingNewGroupAlert) {
                TextField("Group name", text: $newGroupName)
                Button("Add") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let id = newGroupTargetID {
                        store.setGroup(name, id: id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Group Selected Layers", isPresented: $showingBulkGroupAlert) {
                TextField("Group name", text: $bulkGroupName)
                Button("Apply") {
                    let name = bulkGroupName.trimmingCharacters(in: .whitespaces)
                    store.setGroup(name, ids: selectedIDs)
                    exitSelectionMode()
                }
                Button("Remove Group") {
                    store.setGroup("", ids: selectedIDs)
                    exitSelectionMode()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a group name for the selected layers, or remove them from their current groups.")
            }
            .sheet(item: $editingLayer) { layer in
                AttributeEditorView(
                    layer: layer,
                    templateStore: templateStore,
                    existingGroups: store.groupNames,
                    title: "Edit Feature",
                    onSave: { updated in
                        store.update(updated)
                        editingLayer = nil
                    },
                    onCancel: {
                        editingLayer = nil
                    },
                    onDelete: { featureID in
                        store.remove(id: featureID)
                        editingLayer = nil
                    }
                )
            }
            .onChange(of: searchText) { _ in
                selectedIDs = selectedIDs.intersection(filteredIDs)
            }
        }
    }

    private func layerRow(_ layer: MapLayer) -> some View {
        HStack(spacing: 12) {
            if selectionMode {
                Button {
                    toggleSelection(layer.id)
                } label: {
                    Image(systemName: selectedIDs.contains(layer.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedIDs.contains(layer.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(selectedIDs.contains(layer.id) ? "Deselect \(layer.name)" : "Select \(layer.name)")
            }

            Image(systemName: layer.kind.systemImage)
                .foregroundStyle(layer.effectiveColor.color)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(layer.geometrySummary(units: DistanceUnits(rawValue: listUnitsRaw) ?? .metric))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Recorded \(Self.layerDateFormatter.string(from: layer.createdAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !layer.notes.isEmpty || !layer.fields.isEmpty {
                    Text(attributePreview(for: layer))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            Spacer(minLength: 8)

            Button {
                store.toggleVisibility(layer)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selectionMode {
                toggleSelection(layer.id)
            } else {
                editingLayer = layer
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !selectionMode, let onWalkLayer = onWalkLayer {
                if layer.kind == .measure || layer.kind == .track {
                    Button {
                        onWalkLayer(layer)
                    } label: {
                        Label("Walk", systemImage: "figure.walk")
                    }
                    .tint(.orange)
                } else if layer.kind == .point {
                    Button {
                        onWalkLayer(layer)
                    } label: {
                        Label("Go To", systemImage: "location.north.line")
                    }
                    .tint(.blue)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !selectionMode {
                Button(role: .destructive) {
                    store.remove(id: layer.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if !selectionMode {
                Menu {
                    ForEach(store.groupNames, id: \.self) { groupName in
                        Button(groupName) {
                            store.setGroup(groupName, id: layer.id)
                        }
                    }
                    if !store.groupNames.isEmpty {
                        Divider()
                    }
                    Button {
                        newGroupTargetID = layer.id
                        newGroupName = ""
                        showingNewGroupAlert = true
                    } label: {
                        Label("New Group…", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("Add to Group", systemImage: "folder")
                }

                if !layer.group.isEmpty {
                    Button("Remove from \"\(layer.group)\"") {
                        store.setGroup("", id: layer.id)
                    }
                }

                if let onBufferLayer = onBufferLayer,
                   layer.kind == .measure || layer.kind == .track {
                    Button {
                        onBufferLayer(layer)
                    } label: {
                        Label("Buffer to Polygon", systemImage: "rectangle.dashed")
                    }
                }
            }
        }
    }

    private func groupHeader(_ name: String, layers: [MapLayer]) -> some View {
        let ids = Set(layers.map { $0.id })
        let allVisible = layers.allSatisfy { $0.isVisible }
        return HStack(spacing: 8) {
            if selectionMode {
                Button {
                    toggleGroupSelection(ids)
                } label: {
                    Image(systemName: groupSelectionIcon(for: ids))
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderless)
            }

            Text("\(name) (\(layers.count))")
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer()

            Button {
                store.setVisibility(!allVisible, ids: ids)
            } label: {
                Image(systemName: allVisible ? "eye" : "eye.slash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func toggleGroupSelection(_ ids: Set<UUID>) {
        let visibleIDs = ids.intersection(filteredIDs)
        if visibleIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(visibleIDs)
        } else {
            selectedIDs.formUnion(visibleIDs)
        }
    }

    private func groupSelectionIcon(for ids: Set<UUID>) -> String {
        let visibleIDs = ids.intersection(filteredIDs)
        guard !visibleIDs.isEmpty else { return "circle" }
        if visibleIDs.isSubset(of: selectedIDs) {
            return "checkmark.circle.fill"
        }
        if !visibleIDs.isDisjoint(with: selectedIDs) {
            return "minus.circle.fill"
        }
        return "circle"
    }

    private func selectAllFiltered() {
        selectedIDs.formUnion(filteredIDs)
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedIDs.removeAll()
    }

    private static let layerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func attributePreview(for layer: MapLayer) -> String {
        var parts: [String] = []
        if !layer.notes.isEmpty {
            parts.append(layer.notes)
        }
        parts.append(contentsOf: layer.fields.map { "\($0.key)=\($0.value)" })
        return parts.joined(separator: " | ")
    }
}

// MARK: - Selective layer export

enum LayerExportFormat: String, CaseIterable, Identifiable {
    case geojson
    case kml

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geojson: return "GeoJSON (GIS)"
        case .kml: return "KML"
        }
    }
}

/// Pick which layers or whole groups to export, and the format.
struct LayerExportPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let layers: [MapLayer]
    let onExport: ([MapLayer], LayerExportFormat) -> Void

    @State private var selectedIDs: Set<UUID> = []
    @State private var format: LayerExportFormat = .geojson

    private var groupedLayers: [(name: String, layers: [MapLayer])] {
        func subsections(_ items: [MapLayer], categoryLabel: String) -> [(String, [MapLayer])] {
            guard !items.isEmpty else { return [] }
            let grouped = Dictionary(grouping: items) { $0.group }
            var out: [(String, [MapLayer])] = grouped
                .filter { !$0.key.isEmpty }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { ("\(categoryLabel) · \($0.key)", $0.value) }
            if let ungrouped = grouped[""], !ungrouped.isEmpty {
                out.append((categoryLabel, ungrouped))
            }
            return out
        }
        let created = layers.filter { !$0.isImported }
        let imported = layers.filter { $0.isImported }
        return subsections(created, categoryLabel: "Created")
            + subsections(imported, categoryLabel: "Imported")
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(LayerExportFormat.allCases) { exportFormat in
                            Text(exportFormat.title).tag(exportFormat)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                ForEach(groupedLayers, id: \.name) { groupEntry in
                    Section {
                        ForEach(groupEntry.layers) { layer in
                            Button {
                                toggle(layer.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedIDs.contains(layer.id)
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIDs.contains(layer.id)
                                            ? Color.accentColor : Color.secondary)
                                    Image(systemName: layer.kind.systemImage)
                                        .foregroundStyle(layer.effectiveColor.color)
                                        .frame(width: 22)
                                    Text(layer.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        groupHeader(groupEntry.name, layers: groupEntry.layers)
                    }
                }
            }
            .navigationTitle("Export Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export (\(selectedIDs.count))") {
                        let chosen = layers.filter { selectedIDs.contains($0.id) }
                        onExport(chosen, format)
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .onAppear {
                if selectedIDs.isEmpty {
                    selectedIDs = Set(layers.map { $0.id })
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func groupHeader(_ name: String, layers groupLayers: [MapLayer]) -> some View {
        let ids = Set(groupLayers.map { $0.id })
        let allSelected = ids.isSubset(of: selectedIDs)
        return HStack {
            Text("\(name) (\(groupLayers.count))")
            Spacer()
            Button(allSelected ? "Deselect Group" : "Select Group") {
                if allSelected {
                    selectedIDs.subtract(ids)
                } else {
                    selectedIDs.formUnion(ids)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Bearing line entry

/// Project a survey line from a start point along a compass bearing.
/// Defaults to the current GPS position; coordinates can be overridden.
/// Supports chaining segments into a traverse and converting magnetic
/// hand-compass bearings to true north via a saved declination.
struct BearingLineView: View {
    @Environment(\.dismiss) private var dismiss

    let currentCoordinate: CLLocationCoordinate2D?
    let lastLineEnd: CLLocationCoordinate2D?
    /// Called with (start, TRUE bearing in degrees, distance in meters).
    let onSave: (CLLocationCoordinate2D, Double, Double) -> Void

    @State private var startLatitude = ""
    @State private var startLongitude = ""
    @State private var bearingText = ""
    @State private var distanceText = "100"
    @State private var continuingFromLastEnd = false
    @AppStorage("distanceUnits") private var distanceUnitsRaw = DistanceUnits.metric.rawValue
    @AppStorage("bearingIsMagnetic") private var bearingIsMagnetic = false
    @AppStorage("magneticDeclinationDegrees") private var declinationText = ""
    @State private var message = "Enter a bearing in degrees and a distance in meters. The line draws on the map and the status bar shows how far left or right of it you are while walking."

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Start Point")) {
                    TextField("Latitude", text: $startLatitude)
                        .keyboardType(.numbersAndPunctuation)
                        .onChange(of: startLatitude) { _ in continuingFromLastEnd = false }
                    TextField("Longitude", text: $startLongitude)
                        .keyboardType(.numbersAndPunctuation)
                        .onChange(of: startLongitude) { _ in continuingFromLastEnd = false }
                    Button("Use Current GPS") {
                        fillFromGPS()
                    }
                    .disabled(currentCoordinate == nil)
                    Button {
                        fillFromLastEnd()
                    } label: {
                        Label(
                            continuingFromLastEnd ? "Continuing from End of Last Line" : "Continue from End of Last Line",
                            systemImage: continuingFromLastEnd ? "checkmark.circle.fill" : "arrow.turn.down.right"
                        )
                    }
                    .disabled(lastLineEnd == nil)
                }

                Section(header: Text("Line")) {
                    TextField(bearingIsMagnetic ? "Magnetic bearing (degrees, 0-360)" : "True bearing (degrees, 0-360)", text: $bearingText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Distance (\(bearingUnits.shortDistanceLabel))", text: $distanceText)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section {
                    Toggle("Bearing is from a magnetic compass", isOn: $bearingIsMagnetic)
                    if bearingIsMagnetic {
                        TextField("Declination (degrees, east positive)", text: $declinationText)
                            .keyboardType(.numbersAndPunctuation)
                    }
                } header: {
                    Text("Compass")
                } footer: {
                    Text("Turn this on if you read the bearing off a hand compass. Enter your local magnetic declination (east positive, e.g. 13 for 13 deg E) and the app converts to true north before drawing. The declination is remembered between uses.")
                }

                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Bearing Line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Line") {
                        saveLine()
                    }
                }
            }
            .onAppear {
                fillFromGPS()
            }
        }
    }

    private var bearingUnits: DistanceUnits {
        DistanceUnits(rawValue: distanceUnitsRaw) ?? .metric
    }

    private func fillFromGPS() {
        guard let coordinate = currentCoordinate else { return }
        startLatitude = String(format: "%.6f", coordinate.latitude)
        startLongitude = String(format: "%.6f", coordinate.longitude)
        continuingFromLastEnd = false
    }

    private func fillFromLastEnd() {
        guard let coordinate = lastLineEnd else { return }
        startLatitude = String(format: "%.7f", coordinate.latitude)
        startLongitude = String(format: "%.7f", coordinate.longitude)
        continuingFromLastEnd = true
        message = "Next segment will chain onto the end of the existing bearing line, building a traverse."
    }

    private func saveLine() {
        let start: CLLocationCoordinate2D

        if continuingFromLastEnd, let lastEnd = lastLineEnd {
            // Use the exact stored endpoint so the chain check matches
            // without rounding loss from the text fields.
            start = lastEnd
        } else {
            guard let latitude = Double(startLatitude),
                  let longitude = Double(startLongitude),
                  latitude >= -90, latitude <= 90,
                  longitude >= -180, longitude <= 180 else {
                message = "Check the start coordinates. Latitude must be -90 to 90 and longitude -180 to 180."
                return
            }
            start = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        guard let bearing = Double(bearingText), bearing >= 0, bearing <= 360 else {
            message = "Bearing must be a number from 0 to 360 degrees."
            return
        }

        guard let distanceInput = Double(distanceText), distanceInput > 0 else {
            message = "Distance must be a positive number of \(bearingUnits.shortDistanceLabel)."
            return
        }
        let distance = UnitFormat.metersFromInput(distanceInput, units: bearingUnits)
        guard distance <= 100_000 else {
            message = "Distance is too long."
            return
        }

        var trueBearing = bearing
        if bearingIsMagnetic {
            guard let declination = Double(declinationText), abs(declination) <= 90 else {
                message = "Enter your magnetic declination in degrees (east positive), or turn off the magnetic compass toggle."
                return
            }
            trueBearing = MeasurementMath.normalizedBearing360(bearing + declination)
        }

        onSave(start, trueBearing, distance)
        dismiss()
    }
}

/// North arrow + heading badge. The arrow always points to map-north
/// on screen (it rotates with the map), so it doubles as a compass
/// rose. Tapping it cycles: free pan -> follow GPS (north-up) ->
/// rotate-to-heading -> back to free pan (north-up).
struct BearingBadge: View {
    let degrees: CLLocationDirection?
    let mode: MapFollowMode
    /// The map's current on-screen rotation; the north arrow matches it.
    let mapRotationDegrees: Double

    private var headingText: String {
        if let degrees = degrees {
            return "\(Int(degrees.rounded()))°"
        }
        return "--°"
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 32, height: 32)
                VStack(spacing: -2) {
                    Text("N")
                        .font(.system(size: 9, weight: .heavy))
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(mode == .free ? Color.primary : Color.blue)
                .rotationEffect(.degrees(mapRotationDegrees))
                .animation(.linear(duration: 0.3), value: mapRotationDegrees)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 0) {
                Text(headingText)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minWidth: 46, alignment: .leading)

                Text(modeCaption)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .frame(minWidth: 46, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 108, minHeight: 44, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .background(mode == .free ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(Color.blue.opacity(0.22)))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .accessibilityLabel("Heading \(headingText), \(modeCaption.lowercased()) mode")
    }

    private var modeCaption: String {
        switch mode {
        case .free: return "FREE"
        case .centered: return "FOLLOW"
        case .oriented: return "HEADING"
        }
    }
}

struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var westLongitude = ""
    @State private var eastLongitude = ""
    @State private var southLatitude = ""
    @State private var northLatitude = ""
    @State private var message = "Enter the outer map extent from your GIS export. Longitudes west of Greenwich are negative."

    let onSave: (GeoReference) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Longitude")) {
                    TextField("West / left longitude, example -124.1000", text: $westLongitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("East / right longitude, example -124.0000", text: $eastLongitude)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section(header: Text("Latitude")) {
                    TextField("South / bottom latitude, example 40.9000", text: $southLatitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("North / top latitude, example 41.0000", text: $northLatitude)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Calibrate Map")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCalibration()
                    }
                }
            }
        }
    }

    private func saveCalibration() {
        guard let west = Double(westLongitude),
              let east = Double(eastLongitude),
              let south = Double(southLatitude),
              let north = Double(northLatitude),
              west != east,
              south != north else {
            message = "Check the numbers. West/east and south/north cannot be the same."
            return
        }

        let minLongitude = min(west, east)
        let maxLongitude = max(west, east)
        let minLatitude = min(south, north)
        let maxLatitude = max(south, north)

        onSave(GeoReference.fromExtent(
            minLatitude: minLatitude,
            maxLatitude: maxLatitude,
            minLongitude: minLongitude,
            maxLongitude: maxLongitude
        ))
    }
}

// MARK: - Location and compass

final class FieldLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var currentLocation: CLLocation?
    @Published var track: [CLLocation] = []
    @Published var isRecording = false

    /// Fixes worse than this (meters) are not added to the recorded track.
    var recordingAccuracyLimit: CLLocationAccuracy = 25

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 1.0
        manager.activityType = .fitness
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        manager.allowsBackgroundLocationUpdates = backgroundModes?.contains("location") == true
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startRecording() {
        // Each press of Start begins a fresh segment. Stopped tracks are
        // saved as layers by ContentView, so this live array should never
        // bridge two separate walks with a straight connector.
        track.removeAll()
        if let currentLocation = currentLocation,
           currentLocation.horizontalAccuracy >= 0,
           currentLocation.horizontalAccuracy <= recordingAccuracyLimit {
            track.append(currentLocation)
        }
        isRecording = true
        manager.startUpdatingLocation()
    }

    func stopRecording() {
        isRecording = false
    }

    func clearTrack() {
        track.removeAll()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }
        currentLocation = newest

        guard isRecording else { return }
        guard newest.horizontalAccuracy >= 0, newest.horizontalAccuracy <= recordingAccuracyLimit else { return }

        // User-configurable cadence (Survey Settings): record a point
        // every N meters or every N seconds.
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "trackFilterMode") ?? "distance"
        if mode == "time" {
            let storedInterval = defaults.double(forKey: "trackFilterInterval")
            let interval = storedInterval > 0 ? storedInterval : 1.0
            if let last = track.last,
               newest.timestamp.timeIntervalSince(last.timestamp) < interval {
                return
            }
        } else {
            let storedDistance = defaults.double(forKey: "trackFilterDistance")
            let spacing = storedDistance > 0 ? storedDistance : 1.0
            if let last = track.last, newest.distance(from: last) < spacing {
                return
            }
        }
        track.append(newest)
    }
}

final class CompassManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var trueHeadingDegrees: CLLocationDirection?

    /// Low-pass filtered heading, unwrapped to a continuous value so the
    /// map rotates the short way across the 0/360 boundary instead of
    /// spinning nearly a full turn. Use this for map rotation; use
    /// trueHeadingDegrees for display.
    @Published var continuousHeadingDegrees: Double?

    private var filteredSin = 0.0
    private var filteredCos = 1.0
    private var hasFilteredSample = false
    private var unwrappedHeading: Double?

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 2
        manager.startUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let raw = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        trueHeadingDegrees = raw

        // Low-pass filter on the unit circle to damp compass jitter,
        // which otherwise shakes the whole map in oriented mode.
        let radians = raw * .pi / 180
        if hasFilteredSample {
            let alpha = 0.15
            filteredSin += alpha * (sin(radians) - filteredSin)
            filteredCos += alpha * (cos(radians) - filteredCos)
        } else {
            filteredSin = sin(radians)
            filteredCos = cos(radians)
            hasFilteredSample = true
        }

        var smoothed = atan2(filteredSin, filteredCos) * 180 / .pi
        if smoothed < 0 { smoothed += 360 }

        if let current = unwrappedHeading {
            // Unwrap: 359 -> 1 becomes a +2 degree change, not -358.
            let delta = MeasurementMath.normalizedAngle180(
                smoothed - MeasurementMath.normalizedBearing360(current)
            )
            let next = current + delta
            // Only publish meaningful changes; sub-degree churn restarts
            // the rotation animation and makes the map quiver.
            if abs(next - current) >= 1.0 {
                unwrappedHeading = next
                continuousHeadingDegrees = next
            }
        } else {
            unwrappedHeading = smoothed
            continuousHeadingDegrees = smoothed
        }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}

// MARK: - Survey settings

struct MeasurementUnitsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var distanceUnitsRaw: String

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Distance / Area Units", selection: $distanceUnitsRaw) {
                        ForEach(DistanceUnits.allCases) { units in
                            Text(units.title).tag(units.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("This changes quick measurements, line lengths, polygon areas, GPS accuracy, track distance, and exported measurement attributes shown by the app.")
                }
            }
            .navigationTitle("Measurement Units")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SurveySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("recorderName") private var recorderName = ""
    @AppStorage("coordinateDisplayFormat") private var coordinateFormatRaw = CoordinateDisplayFormat.decimalDegrees.rawValue
    @AppStorage("gpsAveragingEnabled") private var gpsAveragingEnabled = false
    @AppStorage("gpsAveragingTargetFixes") private var gpsAveragingTargetFixes = 30
    @AppStorage("distanceUnits") private var distanceUnitsRaw = DistanceUnits.metric.rawValue
    @AppStorage("trackFilterMode") private var trackFilterMode = "distance"
    @AppStorage("trackFilterDistance") private var trackFilterDistance = 1.0
    @AppStorage("trackFilterInterval") private var trackFilterInterval = 1.0

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Recorder name or initials", text: $recorderName)
                } header: {
                    Text("Recorder")
                } footer: {
                    Text("Automatically added to every saved feature as a recorded_by attribute.")
                }

                Section(header: Text("Coordinate Display")) {
                    Picker("Format", selection: $coordinateFormatRaw) {
                        ForEach(CoordinateDisplayFormat.allCases) { format in
                            Text(format.title).tag(format.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(header: Text("Distance Units")) {
                    Picker("Units", selection: $distanceUnitsRaw) {
                        ForEach(DistanceUnits.allCases) { units in
                            Text(units.title).tag(units.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Picker("Record track points", selection: $trackFilterMode) {
                        Text("By distance").tag("distance")
                        Text("By time").tag("time")
                    }
                    .pickerStyle(.segmented)

                    if trackFilterMode == "time" {
                        Picker("Every", selection: $trackFilterInterval) {
                            Text("1 second").tag(1.0)
                            Text("2 seconds").tag(2.0)
                            Text("5 seconds").tag(5.0)
                            Text("10 seconds").tag(10.0)
                        }
                    } else {
                        Picker("Every", selection: $trackFilterDistance) {
                            Text("1 m / 3 ft").tag(1.0)
                            Text("2 m / 7 ft").tag(2.0)
                            Text("5 m / 16 ft").tag(5.0)
                            Text("10 m / 33 ft").tag(10.0)
                        }
                    }
                } header: {
                    Text("Track Recording")
                } footer: {
                    Text("How often the GPS track records a point. Distance mode also sets the vertex spacing for walk-to-draw lines and polygons. Fixes worse than +/- 25 m are always skipped.")
                }

                Section {
                    Toggle("Average GPS for points", isOn: $gpsAveragingEnabled)
                    Stepper("Target fixes: \(gpsAveragingTargetFixes)", value: $gpsAveragingTargetFixes, in: 10...120, step: 10)
                } header: {
                    Text("GPS Averaging")
                } footer: {
                    Text("When on, GPS point drops and Add @ GPS collect and average multiple fixes for a better position. The fix count, spread, and accuracy are saved with the feature.")
                }
            }
            .navigationTitle("Survey Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - GPS point averaging

struct GPSAverageResult {
    let coordinate: CLLocationCoordinate2D
    let fixCount: Int
    let rmsMeters: Double
    let meanAccuracy: Double
}

struct GPSAveragingRequest: Identifiable {
    let id = UUID()
    let onComplete: (GPSAverageResult) -> Void
}

/// Hold-still averaging session: collects GPS fixes and reports the mean
/// position, RMS spread, and mean reported accuracy.
struct GPSAveragingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("distanceUnits") private var averagingUnitsRaw = DistanceUnits.metric.rawValue
    @ObservedObject var location: FieldLocationManager
    let coordinateFormat: CoordinateDisplayFormat
    let targetFixes: Int
    let onComplete: (GPSAverageResult) -> Void

    @State private var fixes: [CLLocation] = []
    @State private var lastTimestamp = Date.distantPast

    private var meanCoordinate: CLLocationCoordinate2D? {
        guard !fixes.isEmpty else { return nil }
        let lat = fixes.map { $0.coordinate.latitude }.reduce(0, +) / Double(fixes.count)
        let lon = fixes.map { $0.coordinate.longitude }.reduce(0, +) / Double(fixes.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private var rmsMeters: Double {
        guard let mean = meanCoordinate, fixes.count > 1 else { return 0 }
        let meanLocation = CLLocation(latitude: mean.latitude, longitude: mean.longitude)
        let sumSquares = fixes.reduce(0.0) { total, fix in
            let d = fix.distance(from: meanLocation)
            return total + d * d
        }
        return sqrt(sumSquares / Double(fixes.count))
    }

    private var meanAccuracy: Double {
        guard !fixes.isEmpty else { return 0 }
        return fixes.map { $0.horizontalAccuracy }.reduce(0, +) / Double(fixes.count)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Text("\(fixes.count)")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("of \(targetFixes) fixes")
                    .foregroundStyle(.secondary)

                ProgressView(value: min(1.0, Double(fixes.count) / Double(max(1, targetFixes))))
                    .padding(.horizontal, 32)

                if let mean = meanCoordinate {
                    Text(CoordinateFormatter.string(for: mean, format: coordinateFormat))
                        .font(.callout.monospacedDigit().bold())
                    Text("Spread (RMS): " + UnitFormat.distance(rmsMeters, units: DistanceUnits(rawValue: averagingUnitsRaw) ?? .metric)
                        + "  |  Mean accuracy: " + UnitFormat.accuracy(meanAccuracy, units: DistanceUnits(rawValue: averagingUnitsRaw) ?? .metric))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Hold still over the point. Collecting GPS fixes…")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    finish()
                } label: {
                    Text("Use Average (\(fixes.count) fixes)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(fixes.count < 5)
                .padding(.horizontal)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)
            .navigationTitle("GPS Averaging")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onReceive(location.$currentLocation) { newLocation in
                guard let newLocation = newLocation,
                      newLocation.timestamp > lastTimestamp,
                      newLocation.horizontalAccuracy >= 0,
                      newLocation.horizontalAccuracy <= 30,
                      fixes.count < 200 else { return }
                lastTimestamp = newLocation.timestamp
                fixes.append(newLocation)
            }
        }
    }

    private func finish() {
        guard let mean = meanCoordinate else { return }
        onComplete(GPSAverageResult(
            coordinate: mean,
            fixCount: fixes.count,
            rmsMeters: rmsMeters,
            meanAccuracy: meanAccuracy
        ))
        dismiss()
    }
}

// MARK: - Template manager

struct TemplateManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TemplateStore
    @State private var editingTemplate: AttributeTemplate?
    @State private var sharePackage: LiDARSharePackage?
    @State private var showingTemplateImporter = false
    @State private var importResultMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if store.templates.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No templates yet")
                            .foregroundStyle(.secondary)
                        Text("Templates define attribute fields and drop-down domains for fast, consistent recording. Tap + to create one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    List {
                        ForEach(store.templates) { template in
                            Button {
                                editingTemplate = template
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .foregroundStyle(.primary)
                                    Text("\(template.fields.count) fields")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    shareTemplates([template], baseName: template.name)
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                        }
                        .onDelete { offsets in
                            store.templates.remove(atOffsets: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Attribute Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        editingTemplate = AttributeTemplate()
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        shareTemplates(store.templates, baseName: "Survey-Field-Standard")
                    } label: {
                        Label("Share All", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.templates.isEmpty)

                    Spacer()

                    Button {
                        showingTemplateImporter = true
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(item: $editingTemplate) { template in
                TemplateEditorView(
                    template: template,
                    onSave: { updated in
                        if let index = store.templates.firstIndex(where: { $0.id == updated.id }) {
                            store.templates[index] = updated
                        } else {
                            store.templates.append(updated)
                        }
                        editingTemplate = nil
                    },
                    onCancel: { editingTemplate = nil }
                )
            }
            .sheet(item: $sharePackage) { package in
                ShareSheet(activityItems: package.urls)
            }
            .fileImporter(
                isPresented: $showingTemplateImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                importTemplates(result)
            }
            .alert(
                "Template Import",
                isPresented: Binding(
                    get: { importResultMessage != nil },
                    set: { if !$0 { importResultMessage = nil } }
                )
            ) {
                Button("OK") { importResultMessage = nil }
            } message: {
                Text(importResultMessage ?? "")
            }
        }
    }

    /// Write templates to a temp JSON file and open the share sheet, so
    /// a field standard can be AirDropped or emailed to the whole crew.
    private func shareTemplates(_ templates: [AttributeTemplate], baseName: String) {
        guard let data = store.exportData(for: templates) else { return }
        let safeName = baseName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName.isEmpty ? "Templates" : safeName)-templates.json")
        do {
            try data.write(to: url, options: .atomic)
            sharePackage = LiDARSharePackage(name: baseName, urls: [url])
        } catch {
            importResultMessage = "Could not prepare the template file: \(error.localizedDescription)"
        }
    }

    private func importTemplates(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importResultMessage = "Import failed: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                importResultMessage = "Could not read that file."
                return
            }
            let count = store.importTemplates(from: data)
            importResultMessage = count > 0
                ? "Imported \(count) template\(count == 1 ? "" : "s"). Duplicate names were kept separate with a numeric suffix."
                : "No templates were found in that file. Share templates from Manage Templates on another device to create one."
        }
    }
}

struct TemplateEditorView: View {
    @State var template: AttributeTemplate
    let onSave: (AttributeTemplate) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Template")) {
                    TextField("Template name (e.g. Artifact, Shovel Test)", text: $template.name)
                }

                Section {
                    ForEach($template.fields) { $field in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Field name (e.g. material)", text: $field.name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Picker("Type", selection: $field.kind) {
                                ForEach(TemplateFieldKind.allCases) { kind in
                                    Text(kind.title).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                            if field.kind == .choice {
                                TextField("Options, comma separated", text: choicesBinding($field))
                                    .textInputAutocapitalization(.never)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        template.fields.remove(atOffsets: offsets)
                    }

                    Button {
                        template.fields.append(TemplateField())
                    } label: {
                        Label("Add Field", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Fields")
                } footer: {
                    Text("Drop-down fields become tap-to-select menus on the attribute form, with consistent values for GIS. You can add more options on the fly while collecting.")
                }
            }
            .navigationTitle("Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var cleaned = template
                        cleaned.fields.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                        if cleaned.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            cleaned.name = "Template"
                        }
                        onSave(cleaned)
                    }
                }
            }
        }
    }

    private func choicesBinding(_ field: Binding<TemplateField>) -> Binding<String> {
        Binding(
            get: { field.wrappedValue.choices.joined(separator: ", ") },
            set: { newValue in
                field.wrappedValue.choices = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

// MARK: - Transect array generator

/// Generate a set of parallel transect lines: origin, bearing, length,
/// spacing, and count. Lines step perpendicular to the bearing.
struct TransectArrayView: View {
    @Environment(\.dismiss) private var dismiss
    let currentCoordinate: CLLocationCoordinate2D?
    let crosshairProvider: () -> CLLocationCoordinate2D?
    let onCreate: ([[CLLocationCoordinate2D]], Double) -> Void

    @State private var originLatitude = ""
    @State private var originLongitude = ""
    @State private var bearingText = ""
    @State private var lengthText = "200"
    @State private var spacingText = "15"
    @State private var countText = "10"
    @State private var offsetRight = true
    @AppStorage("distanceUnits") private var distanceUnitsRaw = DistanceUnits.metric.rawValue

    private var arrayUnits: DistanceUnits {
        DistanceUnits(rawValue: distanceUnitsRaw) ?? .metric
    }

    @State private var message = "Lines step sideways from the origin, perpendicular to the bearing. Spacing is your survey interval; the walked-coverage shading uses it as the swath width."

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Origin (first transect start)")) {
                    TextField("Latitude", text: $originLatitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $originLongitude)
                        .keyboardType(.numbersAndPunctuation)
                    Button("Use Current GPS") { fillFromGPS() }
                        .disabled(currentCoordinate == nil)
                    Button("Use Map Center") { fillFromCrosshair() }
                }

                Section(header: Text("Array")) {
                    TextField("Walk bearing (degrees true)", text: $bearingText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Transect length (\(arrayUnits.shortDistanceLabel))", text: $lengthText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Spacing between transects (\(arrayUnits.shortDistanceLabel))", text: $spacingText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Number of transects", text: $countText)
                        .keyboardType(.numberPad)
                    Picker("Array steps", selection: $offsetRight) {
                        Text("Right of bearing").tag(true)
                        Text("Left of bearing").tag(false)
                    }
                }

                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transect Array")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { create() }
                }
            }
            .onAppear { fillFromGPS() }
        }
    }

    private func fillFromGPS() {
        guard let coordinate = currentCoordinate else { return }
        originLatitude = String(format: "%.6f", coordinate.latitude)
        originLongitude = String(format: "%.6f", coordinate.longitude)
    }

    private func fillFromCrosshair() {
        guard let coordinate = crosshairProvider() else {
            message = "Map center is outside the map extent."
            return
        }
        originLatitude = String(format: "%.6f", coordinate.latitude)
        originLongitude = String(format: "%.6f", coordinate.longitude)
    }

    private func create() {
        guard let latitude = Double(originLatitude), let longitude = Double(originLongitude),
              latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else {
            message = "Check the origin coordinates."
            return
        }
        guard let bearing = Double(bearingText), bearing >= 0, bearing <= 360 else {
            message = "Bearing must be 0 to 360 degrees."
            return
        }
        guard let lengthInput = Double(lengthText), lengthInput > 0 else {
            message = "Length must be a positive number of \(arrayUnits.shortDistanceLabel)."
            return
        }
        let length = UnitFormat.metersFromInput(lengthInput, units: arrayUnits)
        guard length <= 100_000 else {
            message = "Length is too long."
            return
        }
        guard let spacingInput = Double(spacingText), spacingInput > 0 else {
            message = "Spacing must be a positive number of \(arrayUnits.shortDistanceLabel)."
            return
        }
        let spacing = UnitFormat.metersFromInput(spacingInput, units: arrayUnits)
        guard spacing <= 1000 else {
            message = "Spacing is too wide."
            return
        }
        guard let count = Int(countText), count >= 1, count <= 200 else {
            message = "Number of transects must be 1 to 200."
            return
        }

        let origin = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let perpendicular = MeasurementMath.normalizedBearing360(bearing + (offsetRight ? 90 : -90))

        var lines: [[CLLocationCoordinate2D]] = []
        for index in 0..<count {
            let start = MeasurementMath.destination(
                from: origin,
                bearingDegrees: perpendicular,
                distanceMeters: Double(index) * spacing
            )
            let end = MeasurementMath.destination(
                from: start,
                bearingDegrees: bearing,
                distanceMeters: length
            )
            lines.append([start, end])
        }

        onCreate(lines, spacing)
        dismiss()
    }
}

// MARK: - Tiled PDF map view (full-resolution zoom)

/// Lets SwiftUI ask the underlying map view questions, such as the
/// geographic coordinate under the screen-center crosshair.
final class MapProxy: ObservableObject {
    weak var container: GeoPDFContainerView?

    func centerCoordinate() -> CLLocationCoordinate2D? {
        container?.coordinateAtViewCenter()
    }

    /// Immediately recenters the current map on a coordinate. This is used
    /// by the compass/center button so the blue GPS dot snaps under the
    /// crosshair even if CoreLocation has not emitted a new fix yet.
    func centerOnCoordinate(_ coordinate: CLLocationCoordinate2D, georef: GeoReference) {
        container?.centerOnUser(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            georef: georef
        )
    }

    func visibleExtent() -> GeoExtent? {
        container?.visibleExtent()
    }
}

/// Decorative topo-contour art for the welcome screen: nested wobbling
/// contour rings in amber over the dark background, with the app's blue
/// GPS dot resting on one of the ridgelines.
struct ContourArtView: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.50, y: size.height * 0.44)
            let unit = min(size.width, size.height)
            let amber = Color(red: 0.97, green: 0.66, blue: 0.26)

            for ring in 0..<16 {
                let baseRadius = CGFloat(ring + 2) * unit * 0.052
                var path = Path()
                let steps = 220

                for step in 0...steps {
                    let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
                    // Deterministic per-ring wobble so the rings read as
                    // organic contour lines rather than circles.
                    let wobble =
                        sin(angle * 3 + CGFloat(ring) * 0.9) * unit * 0.020 +
                        sin(angle * 7 + CGFloat(ring) * 1.7) * unit * 0.010 +
                        sin(angle * 13 + CGFloat(ring) * 0.4) * unit * 0.004
                    let radius = baseRadius + wobble
                    let point = CGPoint(
                        x: center.x + cos(angle) * radius * 1.18,
                        y: center.y + sin(angle) * radius
                    )
                    if step == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                path.closeSubpath()

                let isIndex = ring % 3 == 0
                let fade = max(0.15, 1.0 - Double(ring) * 0.05)
                context.stroke(
                    path,
                    with: .color(amber.opacity((isIndex ? 0.8 : 0.35) * fade)),
                    lineWidth: isIndex ? 2.6 : 1.2
                )
            }

            // Blue GPS dot with white ring, offset onto a ridgeline.
            let dotCenter = CGPoint(x: center.x + unit * 0.20, y: center.y - unit * 0.13)
            let dotRadius = unit * 0.026
            let haloRect = CGRect(
                x: dotCenter.x - dotRadius * 2.2, y: dotCenter.y - dotRadius * 2.2,
                width: dotRadius * 4.4, height: dotRadius * 4.4
            )
            context.fill(Path(ellipseIn: haloRect), with: .color(Color.blue.opacity(0.25)))
            let dotRect = CGRect(
                x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(Color(red: 0.04, green: 0.48, blue: 1.0)))
            context.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 3)
        }
        .allowsHitTesting(false)
    }
}

/// Screen-center crosshair shown while a collection tool is active.
struct CrosshairView: View {
    /// Subtle styling when no collection tool is active.
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.65), lineWidth: 3)
                .frame(width: 28, height: 28)
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: 28, height: 28)

            Group {
                Rectangle().frame(width: 2, height: 14).offset(y: -21)
                Rectangle().frame(width: 2, height: 14).offset(y: 21)
                Rectangle().frame(width: 14, height: 2).offset(x: -21)
                Rectangle().frame(width: 14, height: 2).offset(x: 21)
            }
            .foregroundStyle(Color.black.opacity(0.75))
            .shadow(color: .white.opacity(0.9), radius: 1)

            Circle()
                .fill(Color.red)
                .frame(width: 5, height: 5)
        }
        .opacity(dimmed ? 0.4 : 1.0)
    }
}

struct GeoPDFView: UIViewRepresentable {
    let document: PDFDocument
    let georef: GeoReference?
    let locations: [CLLocation]
    let currentLocation: CLLocation?
    let headingDegrees: CLLocationDirection?
    let mapTool: MapTool
    let measurePoints: [CLLocationCoordinate2D]
    let polygonPoints: [CLLocationCoordinate2D]
    let bearingLine: [CLLocationCoordinate2D]
    let previewCoordinate: CLLocationCoordinate2D?
    let distanceUnits: DistanceUnits
    let savedLayers: [MapLayer]
    let selectedLayerID: UUID?
    let selectedVertexIndex: Int?
    let transectArrayLines: [[CLLocationCoordinate2D]]
    let activeTransectIndex: Int
    let coverageSwathMeters: Double
    let bufferSavedLinesWidthMeters: Double
    let terrainOverlay: TerrainRasterOverlay?
    let terrainOverlayOpacity: Double
    let currentMapOpacity: Double
    let currentMapBlendMode: SurveyLayerBlendMode
    let followMode: MapFollowMode
    let viewportSize: CGSize
    let onCenterCoordinateChanged: (CLLocationCoordinate2D?) -> Void
    let onMapTap: (CLLocationCoordinate2D) -> Void
    let onFeatureTap: (UUID) -> Void
    let onVertexTap: (UUID, Int) -> Void
    let onUserPan: () -> Void
    let onUserRotate: (Double) -> Void
    let proxy: MapProxy

    func makeCoordinator() -> Coordinator {
        Coordinator(onMapTap: onMapTap, onFeatureTap: onFeatureTap, onVertexTap: onVertexTap)
    }

    func makeUIView(context: Context) -> GeoPDFContainerView {
        let view = GeoPDFContainerView()
        view.tapHandler = context.coordinator
        return view
    }

    func updateUIView(_ uiView: GeoPDFContainerView, context: Context) {
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onFeatureTap = onFeatureTap
        context.coordinator.onVertexTap = onVertexTap
        uiView.setDocument(document)
        uiView.setMapLayerDisplay(opacity: currentMapOpacity, blendMode: currentMapBlendMode)
        uiView.overlay.georef = georef
        uiView.overlay.locations = locations
        uiView.overlay.currentLocation = currentLocation
        uiView.overlay.headingDegrees = headingDegrees
        uiView.overlay.mapTool = mapTool
        uiView.overlay.measurePoints = measurePoints
        uiView.overlay.polygonPoints = polygonPoints
        uiView.overlay.bearingLine = bearingLine
        uiView.overlay.previewCoordinate = previewCoordinate
        uiView.overlay.distanceUnits = distanceUnits
        uiView.overlay.savedLayers = savedLayers
        uiView.overlay.selectedLayerID = selectedLayerID
        uiView.overlay.selectedVertexIndex = selectedVertexIndex
        uiView.overlay.transectArrayLines = transectArrayLines
        uiView.overlay.activeTransectIndex = activeTransectIndex
        uiView.overlay.coverageSwathMeters = coverageSwathMeters
        uiView.overlay.bufferSavedLinesWidthMeters = bufferSavedLinesWidthMeters
        uiView.overlay.terrainOverlay = terrainOverlay
        uiView.overlay.terrainOverlayOpacity = terrainOverlayOpacity
        uiView.onUserPan = onUserPan
        uiView.visibleScreenSize = viewportSize
        uiView.onCenterCoordinateChanged = onCenterCoordinateChanged
        uiView.onUserRotate = onUserRotate
        proxy.container = uiView
        uiView.overlay.setNeedsDisplay()

        if followMode != .free, let georef = georef, let location = currentLocation {
            uiView.centerOnUser(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                georef: georef
            )
        }
    }

    final class Coordinator: NSObject, TrackOverlayTapHandler {
        var onMapTap: (CLLocationCoordinate2D) -> Void
        var onFeatureTap: (UUID) -> Void
        var onVertexTap: (UUID, Int) -> Void

        init(
            onMapTap: @escaping (CLLocationCoordinate2D) -> Void,
            onFeatureTap: @escaping (UUID) -> Void,
            onVertexTap: @escaping (UUID, Int) -> Void
        ) {
            self.onMapTap = onMapTap
            self.onFeatureTap = onFeatureTap
            self.onVertexTap = onVertexTap
        }

        func didTapMap(at coordinate: CLLocationCoordinate2D) {
            onMapTap(coordinate)
        }

        func didTapFeature(id: UUID) {
            onFeatureTap(id)
        }

        func didTapVertex(layerID: UUID, vertexIndex: Int) {
            onVertexTap(layerID, vertexIndex)
        }
    }
}

/// Renders the PDF page through a CATiledLayer: each tile is drawn
/// directly from the page data at the current zoom, so vector content
/// and embedded rasters stay sharp at deep zoom levels instead of
/// going soft like PDFKit's cached page images.
final class TiledPDFContentView: UIView {
    private let cgPage: CGPDFPage
    /// CGPDFPage drawing is not safe to run concurrently on the same
    /// document; CATiledLayer draws tiles on background threads.
    private static let drawLock = NSLock()

    override class var layerClass: AnyClass { CATiledLayer.self }

    init(cgPage: CGPDFPage, size: CGSize) {
        self.cgPage = cgPage
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = .white
        isOpaque = true

        if let tiled = layer as? CATiledLayer {
            let screenScale = UIScreen.main.scale
            tiled.tileSize = CGSize(width: 512 * screenScale, height: 512 * screenScale)
            tiled.levelsOfDetail = 4
            // Each bias level doubles the sharp zoom range; 7 covers ~128x.
            tiled.levelsOfDetailBias = 7
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)

        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        let transform = cgPage.getDrawingTransform(
            .mediaBox,
            rect: CGRect(origin: .zero, size: bounds.size),
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)

        Self.drawLock.lock()
        context.drawPDFPage(cgPage)
        Self.drawLock.unlock()

        context.restoreGState()
    }
}

final class GeoPDFContainerView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()
    let overlay = TrackOverlayView()

    weak var tapHandler: TrackOverlayTapHandler?
    /// Called when the user manually pans the map (breaks GPS-follow mode).
    var onUserPan: (() -> Void)?
    /// Called with a degree delta when the user twists with two fingers.
    var onUserRotate: ((Double) -> Void)?

    private var contentView: TiledPDFContentView?
    private var currentMapOpacity: CGFloat = 1.0
    private var currentMapBlendMode: SurveyLayerBlendMode = .normal
    private var currentDocument: PDFDocument?
    private(set) var pageBounds: CGRect = .zero
    private var needsInitialFit = true

    private let toolTapGesture = UITapGestureRecognizer()
    private let doubleTapGesture = UITapGestureRecognizer()
    private let rotationGesture = UIRotationGestureRecognizer()
    private var lastRotationRadians: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = UIColor(white: 0.92, alpha: 1)
        addSubview(scrollView)

        addSubview(overlay)
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.pagePointToOverlay = { [weak self] pagePoint in
            self?.overlayPoint(forPagePoint: pagePoint)
        }

        // Our own double-tap zoom (PDFKit used to provide this).
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.addTarget(self, action: #selector(handleDoubleTap(_:)))
        scrollView.addGestureRecognizer(doubleTapGesture)

        // Pass-through single tap: drawing-tool points, or feature
        // selection when no tool is active.
        toolTapGesture.addTarget(self, action: #selector(handleToolTap(_:)))
        toolTapGesture.cancelsTouchesInView = false
        toolTapGesture.delegate = self
        toolTapGesture.require(toFail: doubleTapGesture)
        addGestureRecognizer(toolTapGesture)

        // Two-finger twist rotates the map freely.
        rotationGesture.addTarget(self, action: #selector(handleRotation(_:)))
        rotationGesture.cancelsTouchesInView = false
        rotationGesture.delegate = self
        addGestureRecognizer(rotationGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMapLayerDisplay(opacity: Double, blendMode: SurveyLayerBlendMode) {
        currentMapOpacity = CGFloat(min(max(opacity, 0.0), 1.0))
        currentMapBlendMode = blendMode
        contentView?.alpha = currentMapOpacity
        contentView?.layer.compositingFilter = blendMode.coreAnimationCompositingFilter
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func setDocument(_ document: PDFDocument) {
        guard document !== currentDocument else { return }
        currentDocument = document
        contentView?.removeFromSuperview()
        contentView = nil
        pageBounds = .zero

        guard let page = document.page(at: 0), let cgPage = page.pageRef else { return }
        pageBounds = cgPage.getBoxRect(.mediaBox)
        overlay.pageBounds = pageBounds

        let content = TiledPDFContentView(cgPage: cgPage, size: pageBounds.size)
        content.alpha = currentMapOpacity
        content.layer.compositingFilter = currentMapBlendMode.coreAnimationCompositingFilter
        scrollView.addSubview(content)
        scrollView.contentSize = pageBounds.size
        contentView = content
        needsInitialFit = true
        setNeedsLayout()
    }

    /// The real visible screen size. This view is oversized to the
    /// screen diagonal so rotation never shows blank corners, which
    /// means panning limits must be computed against the screen, not
    /// against our own (larger) bounds.
    var visibleScreenSize: CGSize = .zero {
        didSet {
            if visibleScreenSize != oldValue { setNeedsLayout() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        overlay.frame = bounds
        configureZoomScales()
        centerContentIfSmall()
        overlay.setNeedsDisplay()
        reportCenterCoordinate()
    }

    private func configureZoomScales() {
        guard contentView != nil, pageBounds.width > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / pageBounds.width, bounds.height / pageBounds.height)
        scrollView.minimumZoomScale = fit * 0.5
        // Tiles re-render per zoom level, so deep zoom stays sharp.
        scrollView.maximumZoomScale = max(fit * 120, 30)
        if needsInitialFit {
            needsInitialFit = false
            scrollView.zoomScale = fit
        }
    }

    /// Gives the scroll view enough margin to place any map coordinate
    /// directly under the crosshair. The map view is intentionally larger
    /// than the phone screen (diagonal-sized) so rotation never exposes
    /// blank corners. On landscape/odd-page PDFs, the PDF page can be
    /// smaller than that oversized view in one direction; without these
    /// centering margins the scroll view clamps too early and the blue GPS
    /// dot stops off to the side of the crosshair.
    private func centerContentIfSmall() {
        let visible = visibleScreenSize == .zero ? bounds.size : visibleScreenSize
        let slackX = max(0, (bounds.width - visible.width) / 2)
        let slackY = max(0, (bounds.height - visible.height) / 2)
        let dx = max(0, (bounds.width - scrollView.contentSize.width) / 2)
        let dy = max(0, (bounds.height - scrollView.contentSize.height) / 2)

        // Half-bounds padding is what allows an edge/near-edge point on
        // any page aspect ratio to sit at the exact screen-center pivot.
        // Keep the older dx+slack value when it is larger so small maps
        // still open centered.
        let centerPadX = max(dx + slackX, bounds.width / 2)
        let centerPadY = max(dy + slackY, bounds.height / 2)

        scrollView.contentInset = UIEdgeInsets(
            top: centerPadY,
            left: centerPadX,
            bottom: centerPadY,
            right: centerPadX
        )
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContentIfSmall()
        overlay.setNeedsDisplay()
        reportCenterCoordinate()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        overlay.setNeedsDisplay()
        if scrollView.isDragging && !scrollView.isZooming {
            onUserPan?()
        }
        reportCenterCoordinate()
    }

    /// Throttled live readout of the coordinate under the crosshair.
    var onCenterCoordinateChanged: ((CLLocationCoordinate2D?) -> Void)?
    private var lastCenterReport: CFTimeInterval = 0

    func reportCenterCoordinate() {
        let now = CACurrentMediaTime()
        guard now - lastCenterReport > 0.1 else { return }
        lastCenterReport = now
        onCenterCoordinateChanged?(coordinateAtViewCenter())
    }

    // MARK: Coordinate conversion (PDF page space <-> overlay space)

    /// Page coordinates are PDF points with the origin at the bottom-left
    /// of the media box (y up); the content view is the same size with
    /// y down. UIKit's convert handles the zoom and scroll from there.
    func overlayPoint(forPagePoint pagePoint: CGPoint) -> CGPoint? {
        guard let contentView = contentView, pageBounds.height > 0 else { return nil }
        let contentPoint = CGPoint(
            x: pagePoint.x - pageBounds.minX,
            y: pageBounds.maxY - pagePoint.y
        )
        return contentView.convert(contentPoint, to: overlay)
    }

    func pagePoint(forOverlayPoint overlayPoint: CGPoint) -> CGPoint? {
        guard let contentView = contentView, pageBounds.height > 0 else { return nil }
        let contentPoint = overlay.convert(overlayPoint, to: contentView)
        return CGPoint(
            x: contentPoint.x + pageBounds.minX,
            y: pageBounds.maxY - contentPoint.y
        )
    }

    /// The geographic coordinate under the visual center of this view,
    /// which is where the crosshair is drawn (the view is centered on
    /// the screen, and rotation pivots around this same point).
    func coordinateAtViewCenter() -> CLLocationCoordinate2D? {
        guard let georef = overlay.georef else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let pagePoint = pagePoint(forOverlayPoint: center) else { return nil }
        let normalized = georef.normalizedPoint(forPagePoint: pagePoint, pageBounds: pageBounds)
        return georef.coordinate(forNormalizedPoint: normalized)
    }

    /// The geographic extent currently visible on screen, by projecting
    /// the four view corners back through the georeference. Used to
    /// re-render terrain at the zoomed-in area for sharper local shadows.
    func visibleExtent() -> GeoExtent? {
        guard let georef = overlay.georef else { return nil }
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY)
        ]
        var coords: [CLLocationCoordinate2D] = []
        for corner in corners {
            guard let pagePoint = pagePoint(forOverlayPoint: corner) else { continue }
            let normalized = georef.normalizedPoint(forPagePoint: pagePoint, pageBounds: pageBounds)
            if let coordinate = georef.coordinate(forNormalizedPoint: normalized) {
                coords.append(coordinate)
            }
        }
        guard coords.count == 4,
              let minLat = coords.map(\.latitude).min(),
              let maxLat = coords.map(\.latitude).max(),
              let minLon = coords.map(\.longitude).min(),
              let maxLon = coords.map(\.longitude).max() else { return nil }
        let extent = GeoExtent(minLatitude: minLat, maxLatitude: maxLat,
                               minLongitude: minLon, maxLongitude: maxLon)
        return extent.isValid ? extent : nil
    }

    /// Keep the user's GPS position pinned to the middle of the screen
    /// with small continuous offset nudges. This version recenters by
    /// measuring where the blue dot is actually drawing on the overlay and
    /// shifting the scroll offset by that screen-space error. That is more
    /// reliable than recomputing the absolute offset from page size alone,
    /// especially for GeoPDFs with odd page layouts, title blocks, margins,
    /// or landscape/portrait aspect changes.
    func centerOnUser(latitude: Double, longitude: Double, georef: GeoReference) {
        guard contentView != nil,
              let pagePoint = georef.pagePoint(latitude: latitude, longitude: longitude, pageBounds: pageBounds) else { return }

        centerOnPagePoint(pagePoint, allowSecondPass: true)
    }

    private func centerOnPagePoint(_ pagePoint: CGPoint, allowSecondPass: Bool) {
        guard contentView != nil else { return }

        layoutIfNeeded()
        centerContentIfSmall()

        let targetCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let currentPoint = overlayPoint(forPagePoint: pagePoint) else { return }

        var target = scrollView.contentOffset
        target.x += currentPoint.x - targetCenter.x
        target.y += currentPoint.y - targetCenter.y
        target = clampedContentOffset(target)

        let current = scrollView.contentOffset
        if abs(target.x - current.x) > 0.25 || abs(target.y - current.y) > 0.25 {
            scrollView.setContentOffset(target, animated: false)
        }

        overlay.setNeedsDisplay()
        reportCenterCoordinate()

        // A second pass after UIScrollView applies the first offset catches
        // any inset/zoom/layout adjustment that happened in the same update
        // cycle. This is what makes the center button deterministic when
        // switching maps or page orientations.
        if allowSecondPass {
            DispatchQueue.main.async { [weak self] in
                self?.centerOnPagePoint(pagePoint, allowSecondPass: false)
            }
        }
    }

    private func clampedContentOffset(_ proposed: CGPoint) -> CGPoint {
        let inset = scrollView.contentInset
        let minX = -inset.left
        let maxX = max(minX, scrollView.contentSize.width - bounds.width + inset.right)
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - bounds.height + inset.bottom)
        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }

    // MARK: Gestures

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let contentView = contentView else { return }
        let targetZoom = min(scrollView.zoomScale * 2.5, scrollView.maximumZoomScale)
        let point = gesture.location(in: contentView)
        let size = CGSize(
            width: bounds.width / targetZoom,
            height: bounds.height / targetZoom
        )
        let rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        scrollView.zoom(to: rect, animated: true)
    }

    @objc private func handleToolTap(_ gesture: UITapGestureRecognizer) {
        let overlayPoint = gesture.location(in: overlay)

        if overlay.mapTool == .navigate {
            if let vertex = overlay.vertexHit(at: overlayPoint, tolerance: 26) {
                tapHandler?.didTapVertex(layerID: vertex.layerID, vertexIndex: vertex.vertexIndex)
                return
            }

            if overlay.selectedLayerID != nil, overlay.selectedVertexIndex != nil,
               let coordinate = coordinate(forOverlayPoint: overlayPoint) {
                // Vertex edit mode: after selecting a vertex, tap its new location.
                tapHandler?.didTapMap(at: coordinate)
                return
            }

            // No tool active: tap selects a saved feature and reveals its vertices.
            if let featureID = overlay.featureID(at: overlayPoint, tolerance: 24) {
                tapHandler?.didTapFeature(id: featureID)
            } else if let coordinate = coordinate(forOverlayPoint: overlayPoint) {
                tapHandler?.didTapMap(at: coordinate)
            }
            return
        }

        guard let coordinate = coordinate(forOverlayPoint: overlayPoint) else { return }
        tapHandler?.didTapMap(at: coordinate)
    }

    private func coordinate(forOverlayPoint overlayPoint: CGPoint) -> CLLocationCoordinate2D? {
        guard let georef = overlay.georef,
              let pagePoint = pagePoint(forOverlayPoint: overlayPoint) else { return nil }
        let normalized = georef.normalizedPoint(forPagePoint: pagePoint, pageBounds: pageBounds)
        return georef.coordinate(forNormalizedPoint: normalized)
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastRotationRadians = gesture.rotation
        case .changed:
            let deltaDegrees = Double(gesture.rotation - lastRotationRadians) * 180 / .pi
            lastRotationRadians = gesture.rotation
            onUserRotate?(deltaDegrees)
        default:
            break
        }
    }
}

protocol TrackOverlayTapHandler: AnyObject {
    func didTapMap(at coordinate: CLLocationCoordinate2D)
    func didTapFeature(id: UUID)
    func didTapVertex(layerID: UUID, vertexIndex: Int)
}

final class TrackOverlayView: UIView {
    var georef: GeoReference?
    var pageBounds: CGRect = .zero
    /// Conversion from PDF page coordinates to this view's coordinates,
    /// supplied by the container (accounts for zoom and scroll).
    var pagePointToOverlay: ((CGPoint) -> CGPoint?)?

    var locations: [CLLocation] = []
    var currentLocation: CLLocation?
    var headingDegrees: CLLocationDirection?
    var mapTool: MapTool = .navigate
    var measurePoints: [CLLocationCoordinate2D] = []
    var polygonPoints: [CLLocationCoordinate2D] = []
    var bearingLine: [CLLocationCoordinate2D] = []
    var previewCoordinate: CLLocationCoordinate2D?
    var distanceUnits: DistanceUnits = .metric
    var savedLayers: [MapLayer] = []
    var selectedLayerID: UUID?
    var selectedVertexIndex: Int?
    var transectArrayLines: [[CLLocationCoordinate2D]] = []
    var activeTransectIndex: Int = 0
    /// Width in meters of the walked-coverage swath (0 = off).
    var coverageSwathMeters: Double = 0
    /// Width in meters of the buffer drawn around saved lines/tracks (0 = off).
    var bufferSavedLinesWidthMeters: Double = 0
    /// Optional terrain raster (VAT/RVT/hillshade) drawn over the PDF map.
    var terrainOverlay: TerrainRasterOverlay?
    var terrainOverlayOpacity: Double = 0.45

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              georef != nil,
              pageBounds.width > 0 else { return }

        drawTerrainRasterOverlay(context: context)

        // Walked-coverage swath: the GPS track stroked at the survey
        // interval width, so gaps in coverage are visible at a glance.
        if coverageSwathMeters > 0, locations.count > 1, let ppm = pixelsPerMeter() {
            let coveragePoints = locations.compactMap { mapPoint(for: $0.coordinate) }
            if coveragePoints.count > 1 {
                let width = min(CGFloat(coverageSwathMeters) * ppm, 4000)
                context.saveGState()
                context.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.22).cgColor)
                context.setLineWidth(width)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.beginPath()
                context.move(to: coveragePoints[0])
                for point in coveragePoints.dropFirst() {
                    context.addLine(to: point)
                }
                context.strokePath()
                context.restoreGState()
            }
        }

        // Non-active transect array lines, thin and dashed; the active
        // one is drawn by the bearing-line block below.
        for (index, line) in transectArrayLines.enumerated() where index != activeTransectIndex {
            let points = line.compactMap { mapPoint(for: $0) }
            guard points.count > 1 else { continue }
            context.saveGState()
            context.setStrokeColor(UIColor.systemOrange.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [8, 7])
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
            context.restoreGState()
        }

        // Optional coverage-style buffer around every visible saved
        // line and track, at the same width as the walked-coverage
        // buffer, so planned corridors are visible before walking.
        if bufferSavedLinesWidthMeters > 0, let ppm = pixelsPerMeter() {
            let bufferWidth = min(CGFloat(bufferSavedLinesWidthMeters) * ppm, 4000)
            for layer in savedLayers where layer.isVisible && (layer.kind == .measure || layer.kind == .track) {
                let linePoints = layer.clCoordinates.compactMap { mapPoint(for: $0) }
                guard linePoints.count > 1 else { continue }
                context.saveGState()
                context.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.16).cgColor)
                context.setLineWidth(bufferWidth)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.beginPath()
                context.move(to: linePoints[0])
                for point in linePoints.dropFirst() {
                    context.addLine(to: point)
                }
                context.strokePath()
                context.restoreGState()
            }
        }

        for layer in savedLayers where layer.isVisible {
            let isSelected = layer.id == selectedLayerID
            if layer.kind == .point {
                drawPointLayer(layer, selected: isSelected, context: context)
            } else if layer.kind == .polygon {
                drawPolygonLayer(layer, selected: isSelected, context: context)
            } else {
                // White lines (OSM minor roads) get a dark casing so they
                // stay visible on light map backgrounds, matching how OSM
                // renders white roads with gray edges.
                if layer.effectiveColor == .white {
                    let casingPoints = layer.clCoordinates.compactMap { mapPoint(for: $0) }
                    if casingPoints.count > 1 {
                        context.saveGState()
                        context.setStrokeColor(UIColor.darkGray.withAlphaComponent(0.85).cgColor)
                        context.setLineWidth(6.5)
                        context.setLineJoin(.round)
                        context.setLineCap(.round)
                        context.beginPath()
                        context.move(to: casingPoints[0])
                        for point in casingPoints.dropFirst() {
                            context.addLine(to: point)
                        }
                        context.strokePath()
                        context.restoreGState()
                    }
                }
                drawToolLines(
                    coordinates: layer.clCoordinates,
                    closeShape: false,
                    color: layer.effectiveColor.uiColor.withAlphaComponent(0.9),
                    dashed: false,
                    drawVertices: isSelected,
                    selectedVertexIndex: isSelected ? selectedVertexIndex : nil,
                    context: context
                )
            }
        }

        let points = locations.compactMap { mapPoint(for: $0.coordinate) }

        if points.count > 1 {
            context.setStrokeColor(UIColor.systemRed.cgColor)
            context.setLineWidth(4)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }

        drawToolLines(
            coordinates: measurePoints,
            closeShape: false,
            color: UIColor.systemYellow,
            dashed: false,
            drawVertices: true,
            selectedVertexIndex: nil,
            context: context
        )
        drawMeasureRubberBandAndLabels(context: context)

        drawPolygonRubberBand(context: context)
        drawToolLines(
            coordinates: polygonPoints,
            closeShape: polygonPoints.count > 2 && !(mapTool == .polygon && previewCoordinate != nil),
            color: UIColor.systemGreen,
            dashed: false,
            drawVertices: true,
            selectedVertexIndex: nil,
            context: context
        )
        drawPolygonMeasurementLabel(context: context)

        drawToolLines(
            coordinates: bearingLine,
            closeShape: false,
            color: UIColor.systemOrange,
            dashed: true,
            drawVertices: false,
            selectedVertexIndex: nil,
            context: context
        )

        if let currentLocation = currentLocation,
           let point = mapPoint(for: currentLocation.coordinate) {
            drawUserDot(at: point, context: context)
            if let headingDegrees = headingDegrees {
                drawHeadingArrow(at: point, headingDegrees: headingDegrees, context: context)
            }
        }
    }

    private func drawTerrainRasterOverlay(context: CGContext) {
        guard let terrainOverlay = terrainOverlay,
              terrainOverlayOpacity > 0.01,
              let cgImage = terrainOverlay.image.cgImage,
              cgImage.width > 0, cgImage.height > 0 else { return }

        let extent = terrainOverlay.extent
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // Fast whole-overlay reject using the four projected corners.
        let cornerCoords = [
            CLLocationCoordinate2D(latitude: extent.maxLatitude, longitude: extent.minLongitude),
            CLLocationCoordinate2D(latitude: extent.maxLatitude, longitude: extent.maxLongitude),
            CLLocationCoordinate2D(latitude: extent.minLatitude, longitude: extent.minLongitude),
            CLLocationCoordinate2D(latitude: extent.minLatitude, longitude: extent.maxLongitude)
        ]
        let projectedCorners = cornerCoords.compactMap { mapPoint(for: $0) }
        guard projectedCorners.count == 4 else { return }
        let allX = projectedCorners.map(\.x), allY = projectedCorners.map(\.y)
        let bounding = CGRect(x: allX.min()!, y: allY.min()!,
                              width: allX.max()! - allX.min()!,
                              height: allY.max()! - allY.min()!)
        guard bounding.intersects(bounds.insetBy(dx: -40, dy: -40)) else { return }

        let blendMode: CGBlendMode = terrainOverlay.isColor ? .normal : .multiply

        context.saveGState()
        context.setAlpha(CGFloat(min(max(terrainOverlayOpacity, 0.02), 1.0)))
        context.setBlendMode(blendMode)
        context.interpolationQuality = .high

        // Draw the image in horizontal strips, re-projecting the corners
        // of each strip independently. Because every strip's parallelogram
        // is computed from the live georeference, the composite follows
        // the basemap's projection curve (UTM/State Plane/etc.) instead of
        // a single affine fit, removing the lidar-vs-basemap shear.
        let stripCount = max(1, min(48, Int(imageHeight / 24)))
        let latSpan = extent.maxLatitude - extent.minLatitude

        for strip in 0..<stripCount {
            let v0 = CGFloat(strip) / CGFloat(stripCount)
            let v1 = CGFloat(strip + 1) / CGFloat(stripCount)
            // Image row 0 is north (maxLatitude); v increases southward.
            let latTop = extent.maxLatitude - Double(v0) * latSpan
            let latBottom = extent.maxLatitude - Double(v1) * latSpan

            guard let sTL = mapPoint(for: CLLocationCoordinate2D(latitude: latTop, longitude: extent.minLongitude)),
                  let sTR = mapPoint(for: CLLocationCoordinate2D(latitude: latTop, longitude: extent.maxLongitude)),
                  let sBL = mapPoint(for: CLLocationCoordinate2D(latitude: latBottom, longitude: extent.minLongitude))
            else { continue }

            let basisX = CGVector(dx: sTR.x - sTL.x, dy: sTR.y - sTL.y)
            let basisY = CGVector(dx: sBL.x - sTL.x, dy: sBL.y - sTL.y)

            context.saveGState()
            // Build a coordinate space whose unit square (0,0)-(1,1),
            // top-left origin, maps onto this strip's screen
            // parallelogram. tx/ty place the strip's top-left; basisX is
            // the eastward edge, basisY the southward edge.
            let toScreen = CGAffineTransform(
                a: basisX.dx, b: basisX.dy,
                c: basisY.dx, d: basisY.dy,
                tx: sTL.x, ty: sTL.y
            )
            context.concatenate(toScreen)
            // Clip to this strip's unit square.
            context.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            // Flip Y: our space has y increasing downward (south), but
            // CGContext.draw places images bottom-up. After flipping, the
            // full image spans y in 0..stripCount with row 0 (north) on
            // top; shift up by `strip` so this strip fills 0..1.
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            let fullH = CGFloat(stripCount)
            context.draw(cgImage, in: CGRect(x: 0, y: CGFloat(strip) - fullH + 1, width: 1, height: fullH))
            context.restoreGState()
        }
        context.restoreGState()
    }

    func mapPoint(for coordinate: CLLocationCoordinate2D) -> CGPoint? {
        guard let georef = georef,
              pageBounds.width > 0,
              let convert = pagePointToOverlay,
              let pagePoint = georef.pagePoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                pageBounds: pageBounds
              ) else { return nil }
        return convert(pagePoint)
    }

    /// On-screen pixels per ground meter at the current zoom, derived
    /// from the georeference. Used to size the coverage swath.
    private func pixelsPerMeter() -> CGFloat? {
        guard let georef = georef,
              let c1 = georef.coordinate(forNormalizedPoint: CGPoint(x: 0.5, y: 0.5)),
              let c2 = georef.coordinate(forNormalizedPoint: CGPoint(x: 0.5, y: 0.55)),
              let p1 = mapPoint(for: c1),
              let p2 = mapPoint(for: c2) else { return nil }

        let meters = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
            .distance(from: CLLocation(latitude: c2.latitude, longitude: c2.longitude))
        guard meters > 0 else { return nil }

        let pixels = hypot(p2.x - p1.x, p2.y - p1.y)
        guard pixels > 0 else { return nil }
        return pixels / CGFloat(meters)
    }

    /// Hit-test the saved layers: nearest vertex or segment within
    /// tolerance (screen points). Returns the closest feature's id.
    func featureID(at point: CGPoint, tolerance: CGFloat) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?

        for layer in savedLayers where layer.isVisible {
            let points = layer.clCoordinates.compactMap { mapPoint(for: $0) }
            guard !points.isEmpty else { continue }

            var distance = points
                .map { hypot($0.x - point.x, $0.y - point.y) }
                .min() ?? .greatestFiniteMagnitude

            if points.count > 1 {
                for index in 0..<(points.count - 1) {
                    distance = min(distance, Self.distance(from: point, toSegment: points[index], points[index + 1]))
                }
                if layer.kind == .polygon, points.count > 2,
                   let last = points.last {
                    distance = min(distance, Self.distance(from: point, toSegment: last, points[0]))
                }
            }

            if distance <= tolerance, best == nil || distance < best!.distance {
                best = (layer.id, distance)
            }
        }

        return best?.id
    }


    /// Hit-test visible vertex handles for the selected feature only.
    func vertexHit(at point: CGPoint, tolerance: CGFloat) -> (layerID: UUID, vertexIndex: Int)? {
        guard let selectedLayerID = selectedLayerID,
              let layer = savedLayers.first(where: { $0.id == selectedLayerID && $0.isVisible }) else { return nil }

        let points = layer.clCoordinates.compactMap { mapPoint(for: $0) }
        guard !points.isEmpty else { return nil }

        var best: (index: Int, distance: CGFloat)?
        for (index, vertexPoint) in points.enumerated() {
            let distance = hypot(vertexPoint.x - point.x, vertexPoint.y - point.y)
            if distance <= tolerance, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }

        guard let index = best?.index else { return nil }
        return (selectedLayerID, index)
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abX = b.x - a.x
        let abY = b.y - a.y
        let lengthSquared = abX * abX + abY * abY
        guard lengthSquared > 0 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        let t = max(0, min(1, ((point.x - a.x) * abX + (point.y - a.y) * abY) / lengthSquared))
        let projX = a.x + t * abX
        let projY = a.y + t * abY
        return hypot(point.x - projX, point.y - projY)
    }

    private func drawPointLayer(_ layer: MapLayer, selected: Bool, context: CGContext) {
        let points = layer.clCoordinates.compactMap { mapPoint(for: $0) }
        guard let point = points.first else { return }
        let color = layer.effectiveColor.uiColor
        let radius: CGFloat = selected ? 8 : 5
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(selected ? 3 : 2)
        context.strokeEllipse(in: rect)
        if selected {
            drawVertexHandles(points: points, color: color, selectedIndex: selectedVertexIndex, context: context)
        }
    }

    /// Saved polygon with independent outline color, fill color,
    /// opacity, and solid/hatched/none fill style.
    private func drawPolygonLayer(_ layer: MapLayer, selected: Bool, context: CGContext) {
        let points = layer.clCoordinates.compactMap { mapPoint(for: $0) }
        guard points.count >= 2 else { return }

        let outline = layer.effectiveColor.uiColor.withAlphaComponent(0.9)
        let fill = layer.effectiveFillColor.uiColor
        let opacity = max(0, min(1, layer.fillOpacity))

        func addRing() {
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.closePath()
        }

        if points.count >= 3, layer.fillStyle != PolygonFillStyle.none, opacity > 0.01 {
            switch layer.fillStyle {
            case .solid:
                context.saveGState()
                addRing()
                context.setFillColor(fill.withAlphaComponent(opacity).cgColor)
                context.fillPath()
                context.restoreGState()
            case .hatch:
                context.saveGState()
                addRing()
                context.clip()
                // Faint base wash so the hatch reads as a fill.
                let bounds = points.reduce(CGRect(x: points[0].x, y: points[0].y, width: 0, height: 0)) {
                    $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0))
                }
                context.setFillColor(fill.withAlphaComponent(opacity * 0.25).cgColor)
                context.fill(bounds)
                context.setStrokeColor(fill.withAlphaComponent(min(1, opacity + 0.25)).cgColor)
                context.setLineWidth(1.6)
                let spacing: CGFloat = 12
                var offset = -bounds.height
                while offset < bounds.width {
                    context.move(to: CGPoint(x: bounds.minX + offset, y: bounds.maxY))
                    context.addLine(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.minY))
                    offset += spacing
                }
                context.strokePath()
                context.restoreGState()
            case .none:
                break
            }
        }

        // Outline. Vertices stay hidden until the feature is selected.
        context.saveGState()
        addRing()
        context.setStrokeColor(outline.cgColor)
        context.setLineWidth(selected ? 5 : 4)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()

        if selected {
            drawVertexHandles(points: points, color: outline, selectedIndex: selectedVertexIndex, context: context)
        }
    }

    private func drawToolLines(
        coordinates: [CLLocationCoordinate2D],
        closeShape: Bool,
        color: UIColor,
        dashed: Bool,
        drawVertices: Bool,
        selectedVertexIndex: Int?,
        context: CGContext
    ) {
        let points = coordinates.compactMap { mapPoint(for: $0) }

        if points.count > 1 {
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(4)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            if dashed {
                context.setLineDash(phase: 0, lengths: [10, 8])
            }
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            if closeShape {
                context.closePath()
                context.setFillColor(color.withAlphaComponent(0.2).cgColor)
                context.drawPath(using: .fillStroke)
            } else {
                context.strokePath()
            }
            context.restoreGState()
        }

        if drawVertices {
            drawVertexHandles(points: points, color: color, selectedIndex: selectedVertexIndex, context: context)
        }
    }


    /// Active distance measurement: rubber-band from the last placed
    /// vertex to the screen-center crosshair, with live segment and
    /// total labels drawn directly on the map.
    private func drawMeasureRubberBandAndLabels(context: CGContext) {
        guard mapTool == .measure else { return }

        // Label completed segments first, so every fixed line segment has
        // its own distance/bearing readout while the user is collecting.
        if measurePoints.count >= 2 {
            for index in 0..<(measurePoints.count - 1) {
                let start = measurePoints[index]
                let end = measurePoints[index + 1]
                guard let startPoint = mapPoint(for: start),
                      let endPoint = mapPoint(for: end) else { continue }
                let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                    .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
                let bearing = MeasurementMath.bearingDegrees(from: start, to: end)
                let labelPoint = offsetMidpoint(startPoint, endPoint, distance: 18)
                drawMeasurementLabel(
                    "\(UnitFormat.distance(distance, units: distanceUnits))  \(formatMapBearing(bearing))",
                    at: labelPoint,
                    context: context,
                    background: UIColor.black.withAlphaComponent(0.68)
                )
            }
        }

        guard let lastCoordinate = measurePoints.last,
              let previewCoordinate = previewCoordinate,
              let startPoint = mapPoint(for: lastCoordinate),
              let previewPoint = mapPoint(for: previewCoordinate) else { return }

        let previewDistance = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            .distance(from: CLLocation(latitude: previewCoordinate.latitude, longitude: previewCoordinate.longitude))
        guard previewDistance > 0.05 else { return }

        let previewBearing = MeasurementMath.bearingDegrees(from: lastCoordinate, to: previewCoordinate)
        let total = MeasurementMath.totalDistanceMeters(for: measurePoints + [previewCoordinate])

        context.saveGState()
        context.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(3)
        context.setLineDash(phase: 0, lengths: [9, 6])
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: startPoint)
        context.addLine(to: previewPoint)
        context.strokePath()
        context.restoreGState()

        // Small, unobtrusive live endpoint at the crosshair-derived point.
        let radius: CGFloat = 4
        context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.95).cgColor)
        context.fillEllipse(in: CGRect(
            x: previewPoint.x - radius,
            y: previewPoint.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        let label = measurePoints.count <= 1
            ? "\(UnitFormat.distance(previewDistance, units: distanceUnits))  \(formatMapBearing(previewBearing))"
            : "+\(UnitFormat.distance(previewDistance, units: distanceUnits))  \(formatMapBearing(previewBearing))  total \(UnitFormat.distance(total, units: distanceUnits))"
        drawMeasurementLabel(
            label,
            at: offsetMidpoint(startPoint, previewPoint, distance: -24),
            context: context,
            background: UIColor.systemYellow.withAlphaComponent(0.92),
            textColor: UIColor.black
        )
    }

    /// Active polygon/area measurement: rubber-band from the last
    /// polygon vertex to the crosshair and back to the first vertex,
    /// plus a live area label for the polygon that would be created if
    /// the crosshair point were accepted.
    private func drawPolygonRubberBand(context: CGContext) {
        guard mapTool == .polygon,
              let previewCoordinate = previewCoordinate,
              let lastCoordinate = polygonPoints.last,
              let lastPoint = mapPoint(for: lastCoordinate),
              let previewPoint = mapPoint(for: previewCoordinate) else { return }

        let previewCoordinates = polygonPoints + [previewCoordinate]
        let previewPoints = previewCoordinates.compactMap { mapPoint(for: $0) }

        if previewPoints.count >= 3 {
            context.saveGState()
            context.beginPath()
            context.move(to: previewPoints[0])
            for point in previewPoints.dropFirst() {
                context.addLine(to: point)
            }
            context.closePath()
            context.setFillColor(UIColor.systemGreen.withAlphaComponent(0.14).cgColor)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(3)
        context.setLineDash(phase: 0, lengths: [9, 6])
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: lastPoint)
        context.addLine(to: previewPoint)
        if polygonPoints.count >= 2,
           let first = polygonPoints.first,
           let firstPoint = mapPoint(for: first) {
            context.move(to: previewPoint)
            context.addLine(to: firstPoint)
        }
        context.strokePath()
        context.restoreGState()

        let radius: CGFloat = 4
        context.setFillColor(UIColor.systemGreen.withAlphaComponent(0.95).cgColor)
        context.fillEllipse(in: CGRect(
            x: previewPoint.x - radius,
            y: previewPoint.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    private func drawPolygonMeasurementLabel(context: CGContext) {
        guard mapTool == .polygon else { return }

        let coordinates: [CLLocationCoordinate2D]
        if let previewCoordinate = previewCoordinate, !polygonPoints.isEmpty {
            coordinates = polygonPoints + [previewCoordinate]
        } else {
            coordinates = polygonPoints
        }

        let points = coordinates.compactMap { mapPoint(for: $0) }
        guard points.count >= 2 else { return }

        if coordinates.count >= 3 {
            let area = MeasurementMath.areaSquareMeters(for: coordinates)
            let labelPoint = centroid(of: points)
            drawMeasurementLabel(
                "Area  \(UnitFormat.area(area, units: distanceUnits))",
                at: labelPoint,
                context: context,
                background: UIColor.systemGreen.withAlphaComponent(0.88),
                textColor: UIColor.white
            )
        } else if coordinates.count == 2 {
            let start = coordinates[0]
            let end = coordinates[1]
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            let bearing = MeasurementMath.bearingDegrees(from: start, to: end)
            drawMeasurementLabel(
                "\(UnitFormat.distance(distance, units: distanceUnits))  \(formatMapBearing(bearing))",
                at: offsetMidpoint(points[0], points[1], distance: 18),
                context: context,
                background: UIColor.systemGreen.withAlphaComponent(0.88),
                textColor: UIColor.white
            )
        }
    }

    private func offsetMidpoint(_ start: CGPoint, _ end: CGPoint, distance: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        return CGPoint(
            x: mid.x - (dy / length) * distance,
            y: mid.y + (dx / length) * distance
        )
    }

    private func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let total = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: total.x / CGFloat(points.count), y: total.y / CGFloat(points.count))
    }

    private func formatMapBearing(_ degrees: Double) -> String {
        String(format: "%.1f°", degrees)
    }

    private func drawMeasurementLabel(
        _ text: String,
        at point: CGPoint,
        context: CGContext,
        background: UIColor,
        textColor: UIColor = .white
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: textColor
        ]
        let size = text.size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 5)
        var rect = CGRect(
            x: point.x - size.width / 2 - padding.width,
            y: point.y - size.height / 2 - padding.height,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )

        // Keep labels inside the overlay so edge measurements remain readable.
        rect.origin.x = min(max(rect.origin.x, 6), max(6, bounds.width - rect.width - 6))
        rect.origin.y = min(max(rect.origin.y, 6), max(6, bounds.height - rect.height - 6))

        context.saveGState()
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 7)
        background.setFill()
        path.fill()
        UIColor.white.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
        context.restoreGState()

        text.draw(
            in: rect.insetBy(dx: padding.width, dy: padding.height),
            withAttributes: attributes
        )
    }

    private func drawVertexHandles(points: [CGPoint], color: UIColor, selectedIndex: Int?, context: CGContext) {
        for (index, point) in points.enumerated() {
            let selected = index == selectedIndex
            let radius: CGFloat = selected ? 8 : 4
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor((selected ? UIColor.white : color).cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor((selected ? color : UIColor.black.withAlphaComponent(0.55)).cgColor)
            context.setLineWidth(selected ? 3 : 1.5)
            context.strokeEllipse(in: rect)
        }
    }

    private func drawUserDot(at point: CGPoint, context: CGContext) {
        context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.2).cgColor)
        context.fillEllipse(in: CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48))
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(4)
        context.strokeEllipse(in: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))
    }

    private func drawHeadingArrow(at point: CGPoint, headingDegrees: CLLocationDirection, context: CGContext) {
        let length: CGFloat = 46
        let angle = CGFloat((headingDegrees - 90) * .pi / 180)
        let tip = CGPoint(x: point.x + cos(angle) * length, y: point.y + sin(angle) * length)

        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(5)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: point)
        context.addLine(to: tip)
        context.strokePath()
    }
}

// MARK: - Georeferencing

struct GeoReference {
    let coefficients: AffineCoefficients
    let inverseCoefficients: InverseAffineCoefficients?
    let viewportBox: CGRect?

    static func fromExtent(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double
    ) -> GeoReference {
        let longitudeRange = maxLongitude - minLongitude
        let latitudeRange = maxLatitude - minLatitude

        return GeoReference(coefficients: AffineCoefficients(
            ax: 1.0 / longitudeRange,
            bx: 0,
            cx: -minLongitude / longitudeRange,
            ay: 0,
            by: 1.0 / latitudeRange,
            cy: -minLatitude / latitudeRange
        ))
    }

    init(coefficients: AffineCoefficients, viewportBox: CGRect? = nil) {
        self.coefficients = coefficients
        self.inverseCoefficients = InverseAffineCoefficients(from: coefficients)
        self.viewportBox = viewportBox
    }

    func normalizedPoint(latitude: Double, longitude: Double) -> CGPoint? {
        let x = coefficients.ax * longitude + coefficients.bx * latitude + coefficients.cx
        let y = coefficients.ay * longitude + coefficients.by * latitude + coefficients.cy

        guard x.isFinite, y.isFinite else { return nil }
        guard x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        let x = coefficients.ax * longitude + coefficients.bx * latitude + coefficients.cx
        let y = coefficients.ay * longitude + coefficients.by * latitude + coefficients.cy

        guard x.isFinite, y.isFinite else { return false }
        return x >= 0 && x <= 1 && y >= 0 && y <= 1
    }

    var extentDescription: String {
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1)
        ].compactMap { coordinate(forNormalizedPoint: $0) }

        guard !corners.isEmpty else {
            return "unknown"
        }

        let latitudes = corners.map { $0.latitude }
        let longitudes = corners.map { $0.longitude }

        guard let minLatitude = latitudes.min(),
              let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(),
              let maxLongitude = longitudes.max() else {
            return "unknown"
        }

        return String(
            format: "lat %.5f to %.5f, lon %.5f to %.5f",
            minLatitude,
            maxLatitude,
            minLongitude,
            maxLongitude
        )
    }

    func pagePoint(latitude: Double, longitude: Double, pageBounds: CGRect) -> CGPoint? {
        guard let normalized = normalizedPoint(latitude: latitude, longitude: longitude) else {
            return nil
        }

        let box = viewportBox ?? pageBounds
        return CGPoint(
            x: box.minX + normalized.x * box.width,
            y: box.minY + normalized.y * box.height
        )
    }

    func normalizedPoint(forPagePoint pagePoint: CGPoint, pageBounds: CGRect) -> CGPoint {
        let box = viewportBox ?? pageBounds
        return CGPoint(
            x: (pagePoint.x - box.minX) / box.width,
            y: (pagePoint.y - box.minY) / box.height
        )
    }

    func coordinate(forNormalizedPoint point: CGPoint) -> CLLocationCoordinate2D? {
        guard let inverseCoefficients = inverseCoefficients else { return nil }

        let x = Double(point.x)
        let y = Double(point.y)
        let longitude = inverseCoefficients.longitudeA * x + inverseCoefficients.longitudeB * y + inverseCoefficients.longitudeC
        let latitude = inverseCoefficients.latitudeA * x + inverseCoefficients.latitudeB * y + inverseCoefficients.latitudeC

        guard latitude.isFinite, longitude.isFinite else { return nil }
        guard latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension GeoReference {
    /// Download extent derived from the GeoPDF corner transform. Used by
    /// online public-data downloads so the query matches the current map.
    var downloadExtent: GeoExtent? {
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1)
        ].compactMap { coordinate(forNormalizedPoint: $0) }

        guard !corners.isEmpty,
              let minLatitude = corners.map(\.latitude).min(),
              let maxLatitude = corners.map(\.latitude).max(),
              let minLongitude = corners.map(\.longitude).min(),
              let maxLongitude = corners.map(\.longitude).max() else { return nil }

        let extent = GeoExtent(
            minLatitude: minLatitude,
            maxLatitude: maxLatitude,
            minLongitude: minLongitude,
            maxLongitude: maxLongitude
        )
        return extent.isValid ? extent : nil
    }
}

struct AffineCoefficients {
    let ax: Double
    let bx: Double
    let cx: Double
    let ay: Double
    let by: Double
    let cy: Double
}

struct InverseAffineCoefficients {
    let longitudeA: Double
    let longitudeB: Double
    let longitudeC: Double
    let latitudeA: Double
    let latitudeB: Double
    let latitudeC: Double

    init?(from coefficients: AffineCoefficients) {
        let determinant = coefficients.ax * coefficients.by - coefficients.bx * coefficients.ay
        guard abs(determinant) > 0.0000000001 else { return nil }

        longitudeA = coefficients.by / determinant
        longitudeB = -coefficients.bx / determinant
        longitudeC = (coefficients.bx * coefficients.cy - coefficients.by * coefficients.cx) / determinant

        latitudeA = -coefficients.ay / determinant
        latitudeB = coefficients.ax / determinant
        latitudeC = (coefficients.ay * coefficients.cx - coefficients.ax * coefficients.cy) / determinant
    }
}

enum GeoPDFParser {
    static func parse(url: URL) -> GeoReference? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data: data)
    }

    static func parse(document: PDFDocument) -> GeoReference? {
        guard let data = document.dataRepresentation() else {
            return nil
        }
        return parse(data: data)
    }

    private static func parse(data: Data) -> GeoReference? {
        guard let text = searchableText(from: data),
              let candidate = bestGeoPDFCandidate(in: text) else {
            return nil
        }

        guard let coefficients = solveAffine(gpts: candidate.gpts, lpts: candidate.lpts) else {
            return nil
        }
        return GeoReference(coefficients: coefficients, viewportBox: candidate.viewportBox)
    }

    private static func solveAffine(gpts: [Double], lpts: [Double]) -> AffineCoefficients? {
        let pairCount = min(gpts.count / 2, lpts.count / 2)
        guard pairCount >= 3 else { return nil }

        if let coefficients = solveAffine(gpts: gpts, lpts: lpts, order: .latitudeLongitude) {
            return coefficients
        }
        return solveAffine(gpts: gpts, lpts: lpts, order: .longitudeLatitude)
    }

    private enum GPTSOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    private static func solveAffine(gpts: [Double], lpts: [Double], order: GPTSOrder) -> AffineCoefficients? {
        let pairCount = min(gpts.count / 2, lpts.count / 2)
        var controls: [(lat: Double, lon: Double, x: Double, y: Double)] = []

        for index in 0..<pairCount {
            let first = gpts[index * 2]
            let second = gpts[index * 2 + 1]
            let lat = order == .latitudeLongitude ? first : second
            let lon = order == .latitudeLongitude ? second : first
            let x = lpts[index * 2]
            let y = lpts[index * 2 + 1]

            guard lat >= -90, lat <= 90, lon >= -180, lon <= 180 else {
                return nil
            }

            controls.append((lat: lat, lon: lon, x: x, y: y))
        }

        guard let coefficients = solveAffine(using: Array(controls.prefix(3))) else {
            return nil
        }
        return coefficients
    }

    private static func searchableText(from data: Data) -> String? {
        var pieces: [String] = []

        if let raw = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .utf8) {
            pieces.append(raw)
            pieces.append(contentsOf: decompressedFlateStreams(in: raw))
        }

        let combined = pieces.joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    private static func decompressedFlateStreams(in text: String) -> [String] {
        var results: [String] = []
        let pattern = #"(?s)<<[^>]*?/FlateDecode[^>]*?>>\s*stream\s*\r?\n(.*?)\r?\nendstream"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let streamRange = Range(match.range(at: 1), in: text) else { continue }
            let streamText = String(text[streamRange])
            guard let streamData = streamText.data(using: .isoLatin1) else { continue }

            if let decompressed = inflate(streamData),
               let decompressedText = String(data: decompressed, encoding: .isoLatin1) ?? String(data: decompressed, encoding: .utf8) {
                results.append(decompressedText)
            }
        }

        return results
    }

    private static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        return data.withUnsafeBytes { sourceBuffer in
            guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }

            for multiplier in [20, 50, 100, 200] {
                let destinationSize = max(64 * 1024, data.count * multiplier)
                let destinationPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
                defer { destinationPointer.deallocate() }

                let decodedSize = compression_decode_buffer(
                    destinationPointer,
                    destinationSize,
                    sourcePointer,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )

                if decodedSize > 0 {
                    return Data(bytes: destinationPointer, count: decodedSize)
                }
            }

            return nil
        }
    }

    private static func bestGeoPDFCandidate(in text: String) -> (gpts: [Double], lpts: [Double], viewportBox: CGRect?)? {
        let bboxArrays = numberArrays(named: "BBox", in: text)
        let gptsArrays = numberArrays(named: "GPTS", in: text)
        let lptsArrays = numberArrays(named: "LPTS", in: text)

        guard !gptsArrays.isEmpty, !lptsArrays.isEmpty else { return nil }

        var bestCandidate: (gpts: [Double], lpts: [Double], viewportBox: CGRect?, distance: Int)?

        for gpts in gptsArrays {
            for lpts in lptsArrays {
                guard gpts.values.count >= 6, lpts.values.count >= 6 else { continue }
                let distance = abs(gpts.location - lpts.location)
                if bestCandidate == nil || distance < bestCandidate!.distance {
                    let viewportBox = closestViewportBox(before: gpts.location, in: bboxArrays)
                    bestCandidate = (gpts.values, lpts.values, viewportBox, distance)
                }
            }
        }

        guard let candidate = bestCandidate else { return nil }
        return (candidate.gpts, candidate.lpts, candidate.viewportBox)
    }

    private static func closestViewportBox(
        before location: Int,
        in bboxArrays: [(values: [Double], location: Int)]
    ) -> CGRect? {
        let candidate = bboxArrays
            .filter { $0.location < location && $0.values.count >= 4 }
            .max { $0.location < $1.location }

        guard let values = candidate?.values else { return nil }

        let minX = min(values[0], values[2])
        let maxX = max(values[0], values[2])
        let minY = min(values[1], values[3])
        let maxY = max(values[1], values[3])

        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX),
            height: CGFloat(maxY - minY)
        )
    }

    private static func numberArrays(named key: String, in text: String) -> [(values: [Double], location: Int)] {
        let pattern = #"/\#(key)\s*\[([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else {
                return nil
            }

            let values = text[range]
                .split { character in
                    character == " " || character == "\n" || character == "\r" || character == "\t"
                }
                .compactMap { Double($0) }

            return values.isEmpty ? nil : (values, match.range.location)
        }
    }

    private static func solveAffine(using controls: [(lat: Double, lon: Double, x: Double, y: Double)]) -> AffineCoefficients? {
        guard controls.count >= 3 else { return nil }

        let p1 = controls[0]
        let p2 = controls[1]
        let p3 = controls[2]

        let determinant =
            p1.lon * (p2.lat - p3.lat) +
            p2.lon * (p3.lat - p1.lat) +
            p3.lon * (p1.lat - p2.lat)

        guard abs(determinant) > 0.0000000001 else { return nil }

        func coefficients(for value: ((lat: Double, lon: Double, x: Double, y: Double)) -> Double) -> (a: Double, b: Double, c: Double) {
            let t1 = value(p1)
            let t2 = value(p2)
            let t3 = value(p3)

            let a = (t1 * (p2.lat - p3.lat) + t2 * (p3.lat - p1.lat) + t3 * (p1.lat - p2.lat)) / determinant
            let b = (p1.lon * (t2 - t3) + p2.lon * (t3 - t1) + p3.lon * (t1 - t2)) / determinant
            let c = (p1.lon * (p2.lat * t3 - p3.lat * t2) + p2.lon * (p3.lat * t1 - p1.lat * t3) + p3.lon * (p1.lat * t2 - p2.lat * t1)) / determinant
            return (a, b, c)
        }

        let x = coefficients(for: { $0.x })
        let y = coefficients(for: { $0.y })

        return AffineCoefficients(ax: x.a, bx: x.b, cx: x.c, ay: y.a, by: y.b, cy: y.c)
    }
}

// MARK: - Measurement math

enum MeasurementMath {
    private static let earthRadiusMeters = 6_371_000.0

    static func finalSegmentBearingDegrees(for coordinates: [CLLocationCoordinate2D]) -> Double? {
        guard coordinates.count >= 2,
              let start = coordinates.dropLast().last,
              let end = coordinates.last else {
            return nil
        }

        return bearingDegrees(from: start, to: end)
    }

    static func bearingDegrees(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180

        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        let bearing = atan2(y, x) * 180 / .pi
        return bearing >= 0 ? bearing : bearing + 360
    }

    /// Great-circle destination from a start point along a bearing.
    static func destination(
        from start: CLLocationCoordinate2D,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {
        let angularDistance = distanceMeters / earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(angularDistance) + cos(lat1) * sin(angularDistance) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angularDistance) * cos(lat1),
            cos(angularDistance) - sin(lat1) * sin(lat2)
        )

        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }

    /// Signed cross-track distance in meters from `point` to the great-circle
    /// line through `lineStart` and `lineEnd`. Positive means right of the line
    /// when facing along it.
    static func crossTrackDistanceMeters(
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D,
        point: CLLocationCoordinate2D
    ) -> Double {
        let startLocation = CLLocation(latitude: lineStart.latitude, longitude: lineStart.longitude)
        let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)

        let angularDistance13 = startLocation.distance(from: pointLocation) / earthRadiusMeters
        let bearing13 = bearingDegrees(from: lineStart, to: point) * .pi / 180
        let bearing12 = bearingDegrees(from: lineStart, to: lineEnd) * .pi / 180

        return asin(sin(angularDistance13) * sin(bearing13 - bearing12)) * earthRadiusMeters
    }

    /// Signed along-track distance in meters: how far the perpendicular
    /// foot of `point` lies along the line from `lineStart`. Negative
    /// means behind the start point.
    static func alongTrackDistanceMeters(
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D,
        point: CLLocationCoordinate2D
    ) -> Double {
        let startLocation = CLLocation(latitude: lineStart.latitude, longitude: lineStart.longitude)
        let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)

        let angularDistance13 = startLocation.distance(from: pointLocation) / earthRadiusMeters
        let bearing13 = bearingDegrees(from: lineStart, to: point) * .pi / 180
        let bearing12 = bearingDegrees(from: lineStart, to: lineEnd) * .pi / 180

        let angularCrossTrack = asin(sin(angularDistance13) * sin(bearing13 - bearing12))
        let cosCrossTrack = cos(angularCrossTrack)
        guard abs(cosCrossTrack) > 0.000000000001 else { return 0 }

        let ratio = min(1, max(-1, cos(angularDistance13) / cosCrossTrack))
        var alongTrack = acos(ratio) * earthRadiusMeters

        // Behind the start point if the bearing to the point differs from
        // the line bearing by more than 90 degrees.
        let bearingDifference = normalizedAngle180((bearing13 - bearing12) * 180 / .pi)
        if abs(bearingDifference) > 90 {
            alongTrack = -alongTrack
        }
        return alongTrack
    }

    /// Normalize an angle difference to -180...180 degrees.
    static func normalizedAngle180(_ degrees: Double) -> Double {
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        return angle
    }

    /// Normalize a bearing to 0...360 degrees.
    static func normalizedBearing360(_ degrees: Double) -> Double {
        var bearing = degrees.truncatingRemainder(dividingBy: 360)
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    static func totalDistanceMeters(for coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count > 1 else { return 0 }
        return zip(coordinates.dropLast(), coordinates.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    /// Build a corridor polygon around a polyline at the given total
    /// width (planar approximation with mitered joins; fine at survey
    /// scales). Used to save/export track and line buffers as polygons.
    static func bufferPolygon(
        around line: [CLLocationCoordinate2D],
        widthMeters: Double
    ) -> [CLLocationCoordinate2D] {
        guard line.count >= 2, widthMeters > 0 else { return [] }
        let half = widthMeters / 2
        let originLatitude = line[0].latitude
        let originLongitude = line[0].longitude
        let metersPerLatitude = 110_540.0
        let metersPerLongitude = max(1.0, 111_320.0 * cos(originLatitude * .pi / 180))

        // Project to local meters, dropping duplicate consecutive points.
        var points: [(x: Double, y: Double)] = []
        for coordinate in line {
            let x = (coordinate.longitude - originLongitude) * metersPerLongitude
            let y = (coordinate.latitude - originLatitude) * metersPerLatitude
            if let last = points.last, abs(last.x - x) < 0.01, abs(last.y - y) < 0.01 { continue }
            points.append((x, y))
        }
        guard points.count >= 2 else { return [] }

        func normalized(_ vector: (Double, Double)) -> (Double, Double)? {
            let length = sqrt(vector.0 * vector.0 + vector.1 * vector.1)
            guard length > 0.000001 else { return nil }
            return (vector.0 / length, vector.1 / length)
        }

        var leftSide: [(Double, Double)] = []
        var rightSide: [(Double, Double)] = []

        for index in points.indices {
            let directionIn: (Double, Double)? = index > 0
                ? normalized((points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
                : nil
            let directionOut: (Double, Double)? = index < points.count - 1
                ? normalized((points[index + 1].x - points[index].x, points[index + 1].y - points[index].y))
                : nil

            let normalIn = directionIn.map { (-$0.1, $0.0) }
            let normalOut = directionOut.map { (-$0.1, $0.0) }

            var miter: (Double, Double)
            var scale = 1.0
            if let normalIn = normalIn, let normalOut = normalOut {
                if let averaged = normalized((normalIn.0 + normalOut.0, normalIn.1 + normalOut.1)) {
                    miter = averaged
                    let cosine = miter.0 * normalOut.0 + miter.1 * normalOut.1
                    scale = 1.0 / max(0.34, cosine)   // miter limit ~3
                } else {
                    miter = normalOut                  // 180-degree turn; flat joint
                }
            } else {
                miter = normalIn ?? normalOut ?? (0, 1)
            }

            let offsetX = miter.0 * half * scale
            let offsetY = miter.1 * half * scale
            leftSide.append((points[index].x + offsetX, points[index].y + offsetY))
            rightSide.append((points[index].x - offsetX, points[index].y - offsetY))
        }

        let ring = leftSide + rightSide.reversed()
        return ring.map { point in
            CLLocationCoordinate2D(
                latitude: originLatitude + point.1 / metersPerLatitude,
                longitude: originLongitude + point.0 / metersPerLongitude
            )
        }
    }

    static func centroid(for coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        let latitude = coordinates.map { $0.latitude }.reduce(0, +) / Double(coordinates.count)
        let longitude = coordinates.map { $0.longitude }.reduce(0, +) / Double(coordinates.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func areaSquareMeters(for coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 3 else { return 0 }

        let origin = coordinates[0]
        let originLatitudeRadians = origin.latitude * .pi / 180
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = 111_320.0 * cos(originLatitudeRadians)

        let projected = coordinates.map { coordinate in
            (
                x: (coordinate.longitude - origin.longitude) * metersPerDegreeLongitude,
                y: (coordinate.latitude - origin.latitude) * metersPerDegreeLatitude
            )
        }

        var sum = 0.0
        for index in 0..<projected.count {
            let nextIndex = (index + 1) % projected.count
            sum += projected[index].x * projected[nextIndex].y
            sum -= projected[nextIndex].x * projected[index].y
        }

        return abs(sum) / 2.0
    }
}

// MARK: - GeoJSON export (GIS-friendly: attributes become table columns)

enum GeoJSONExporter {
    static func featureCollection(layers: [MapLayer]) -> String? {
        let dateFormatter = ISO8601DateFormatter()
        var features: [[String: Any]] = []

        for layer in layers {
            guard let geometry = geometry(for: layer) else { continue }

            var properties: [String: Any] = [
                "name": layer.name,
                "feature_type": layer.kind.rawValue,
                "created": dateFormatter.string(from: layer.createdAt)
            ]

            if !layer.notes.isEmpty {
                properties["notes"] = layer.notes
            }
            if !layer.group.isEmpty {
                properties["group"] = layer.group
            }

            properties["color"] = layer.effectiveColor.hexString
            if layer.kind == .polygon {
                properties["fill_color"] = layer.effectiveFillColor.hexString
                properties["fill_opacity"] = round(layer.fillOpacity * 100) / 100
                properties["fill_style"] = layer.fillStyle.rawValue
            }

            if !layer.photoFilenames.isEmpty {
                properties["photos"] = layer.photoFilenames.joined(separator: ", ")
            }

            switch layer.kind {
            case .track, .measure:
                properties["length_m"] = round(MeasurementMath.totalDistanceMeters(for: layer.clCoordinates) * 10) / 10
            case .polygon:
                let area = MeasurementMath.areaSquareMeters(for: layer.clCoordinates)
                properties["area_sqm"] = round(area * 10) / 10
                properties["area_acres"] = round(area / 4046.8564224 * 1000) / 1000
            case .point:
                break
            }

            for field in layer.fields {
                let key = field.key.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                properties[key] = field.value
            }

            features.append([
                "type": "Feature",
                "geometry": geometry,
                "properties": properties
            ])
        }

        let collection: [String: Any] = [
            "type": "FeatureCollection",
            "features": features
        ]

        guard JSONSerialization.isValidJSONObject(collection),
              let data = try? JSONSerialization.data(withJSONObject: collection, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func geometry(for layer: MapLayer) -> [String: Any]? {
        switch layer.kind {
        case .point:
            guard let coordinate = layer.coordinates.first else { return nil }
            return [
                "type": "Point",
                "coordinates": [coordinate.longitude, coordinate.latitude]
            ]
        case .track, .measure:
            guard layer.coordinates.count >= 2 else { return nil }
            return [
                "type": "LineString",
                "coordinates": layer.coordinates.map { [$0.longitude, $0.latitude] }
            ]
        case .polygon:
            guard layer.coordinates.count >= 3 else { return nil }
            var ring = layer.coordinates.map { [$0.longitude, $0.latitude] }
            if let first = ring.first, let last = ring.last, first != last {
                ring.append(first)
            }
            return [
                "type": "Polygon",
                "coordinates": [ring]
            ]
        }
    }
}

// MARK: - KML import

/// Parses KML Placemarks (Point, LineString, Polygon outer rings,
/// including MultiGeometry) into saved layers. Names, descriptions,
/// and ExtendedData attributes are preserved.
final class KMLImporter: NSObject, XMLParserDelegate {
    static func layers(from data: Data) -> [MapLayer] {
        let importer = KMLImporter()
        let parser = XMLParser(data: data)
        parser.delegate = importer
        parser.parse()
        return importer.layers
    }

    private var layers: [MapLayer] = []
    private var inPlacemark = false
    private var placemarkName = ""
    private var placemarkNotes = ""
    private var placemarkFields: [FeatureField] = []
    private var geometries: [(kind: MapLayerKind, coordinates: [LayerCoordinate])] = []
    private var currentGeometryKind: MapLayerKind?
    private var inOuterBoundary = false
    private var currentDataName: String?
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        switch elementName {
        case "Placemark":
            inPlacemark = true
            placemarkName = ""
            placemarkNotes = ""
            placemarkFields = []
            geometries = []
            currentGeometryKind = nil
            inOuterBoundary = false
        case "Point":
            if inPlacemark { currentGeometryKind = .point }
        case "LineString":
            if inPlacemark { currentGeometryKind = .measure }
        case "outerBoundaryIs":
            inOuterBoundary = true
        case "LinearRing":
            if inPlacemark && inOuterBoundary { currentGeometryKind = .polygon }
        case "Data", "SimpleData":
            currentDataName = attributeDict["name"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "name":
            if inPlacemark, placemarkName.isEmpty { placemarkName = trimmed }
        case "description":
            if inPlacemark { placemarkNotes = trimmed }
        case "value":
            if inPlacemark, let key = currentDataName, !key.isEmpty, !trimmed.isEmpty {
                placemarkFields.append(FeatureField(key: key, value: trimmed))
            }
        case "SimpleData":
            if inPlacemark, let key = currentDataName, !key.isEmpty, !trimmed.isEmpty {
                placemarkFields.append(FeatureField(key: key, value: trimmed))
            }
            currentDataName = nil
        case "Data":
            currentDataName = nil
        case "coordinates":
            if inPlacemark, let kind = currentGeometryKind {
                var coordinates = Self.parseCoordinates(trimmed)
                if kind == .polygon, coordinates.count > 1,
                   let first = coordinates.first, let last = coordinates.last,
                   abs(first.latitude - last.latitude) < 0.000000001,
                   abs(first.longitude - last.longitude) < 0.000000001 {
                    coordinates.removeLast()
                }
                if !coordinates.isEmpty {
                    geometries.append((kind, coordinates))
                }
            }
            currentGeometryKind = nil
        case "outerBoundaryIs":
            inOuterBoundary = false
        case "Placemark":
            inPlacemark = false
            for (index, geometry) in geometries.enumerated() {
                guard Self.hasEnoughVertices(geometry.kind, count: geometry.coordinates.count) else { continue }
                let baseName = placemarkName.isEmpty ? "Imported" : placemarkName
                let name = geometries.count > 1 ? "\(baseName) \(index + 1)" : baseName
                layers.append(MapLayer(
                    name: name,
                    kind: geometry.kind,
                    coordinates: geometry.coordinates,
                    notes: placemarkNotes,
                    fields: placemarkFields
                ))
            }
        default:
            break
        }
        buffer = ""
    }

    private static func hasEnoughVertices(_ kind: MapLayerKind, count: Int) -> Bool {
        switch kind {
        case .point: return count >= 1
        case .measure, .track: return count >= 2
        case .polygon: return count >= 3
        }
    }

    private static func parseCoordinates(_ text: String) -> [LayerCoordinate] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .compactMap { token in
                let parts = token.split(separator: ",")
                guard parts.count >= 2,
                      let lon = Double(parts[0]), let lat = Double(parts[1]),
                      lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
                return LayerCoordinate(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
    }
}

// MARK: - GeoJSON import

/// Parses a GeoJSON Feature or FeatureCollection into saved layers,
/// preserving names, notes, colors, and all properties as attributes.
enum GeoJSONImporter {
    static func layers(from data: Data) -> [MapLayer] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rootType = root["type"] as? String else { return [] }

        let features: [[String: Any]]
        if rootType == "FeatureCollection" {
            features = root["features"] as? [[String: Any]] ?? []
        } else if rootType == "Feature" {
            features = [root]
        } else {
            return []
        }

        var layers: [MapLayer] = []

        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any],
                  let geometryType = geometry["type"] as? String else { continue }
            let properties = feature["properties"] as? [String: Any] ?? [:]

            let name = (properties["name"] as? String) ?? "Imported"
            let notes = (properties["notes"] as? String) ?? ""
            let group = (properties["group"] as? String) ?? ""
            let colorHex = (properties["color"] as? String)?.uppercased()
            let color = LayerColor.allCases.first { $0.hexString.uppercased() == colorHex }
            let fillHex = (properties["fill_color"] as? String)?.uppercased()
            let fillColor = LayerColor.allCases.first { $0.hexString.uppercased() == fillHex }
            let fillOpacity = (properties["fill_opacity"] as? NSNumber)?.doubleValue ?? 0.25
            let fillStyle = PolygonFillStyle(rawValue: (properties["fill_style"] as? String) ?? "") ?? .solid

            var fields: [FeatureField] = []
            for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
                if key == "name" || key == "notes" || key == "color" || key == "group"
                    || key == "fill_color" || key == "fill_opacity" || key == "fill_style" { continue }
                fields.append(FeatureField(key: key, value: stringify(value)))
            }

            func append(_ kind: MapLayerKind, _ coordinates: [LayerCoordinate], suffix: String = "") {
                let minimum: Int
                switch kind {
                case .point: minimum = 1
                case .measure, .track: minimum = 2
                case .polygon: minimum = 3
                }
                guard coordinates.count >= minimum else { return }
                layers.append(MapLayer(
                    name: name + suffix,
                    kind: kind,
                    coordinates: coordinates,
                    notes: notes,
                    fields: fields,
                    color: color,
                    group: group,
                    fillColor: fillColor,
                    fillOpacity: fillOpacity,
                    fillStyle: fillStyle
                ))
            }

            switch geometryType {
            case "Point":
                if let position = geometry["coordinates"] as? [Any],
                   let coordinate = coordinate(position) {
                    append(.point, [coordinate])
                }
            case "MultiPoint":
                if let positions = geometry["coordinates"] as? [[Any]] {
                    for (index, position) in positions.enumerated() {
                        if let coordinate = coordinate(position) {
                            append(.point, [coordinate], suffix: " \(index + 1)")
                        }
                    }
                }
            case "LineString":
                if let positions = geometry["coordinates"] as? [[Any]] {
                    append(.measure, line(positions))
                }
            case "MultiLineString":
                if let lineSets = geometry["coordinates"] as? [[[Any]]] {
                    for (index, positions) in lineSets.enumerated() {
                        append(.measure, line(positions), suffix: lineSets.count > 1 ? " \(index + 1)" : "")
                    }
                }
            case "Polygon":
                if let rings = geometry["coordinates"] as? [[[Any]]], let outer = rings.first {
                    append(.polygon, ring(outer))
                }
            case "MultiPolygon":
                if let polygons = geometry["coordinates"] as? [[[[Any]]]] {
                    for (index, rings) in polygons.enumerated() {
                        if let outer = rings.first {
                            append(.polygon, ring(outer), suffix: polygons.count > 1 ? " \(index + 1)" : "")
                        }
                    }
                }
            default:
                break
            }
        }

        return layers
    }

    private static func coordinate(_ position: [Any]) -> LayerCoordinate? {
        guard position.count >= 2,
              let lon = doubleValue(position[0]),
              let lat = doubleValue(position[1]),
              lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
        return LayerCoordinate(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private static func line(_ positions: [[Any]]) -> [LayerCoordinate] {
        positions.compactMap { coordinate($0) }
    }

    private static func ring(_ positions: [[Any]]) -> [LayerCoordinate] {
        var coordinates = line(positions)
        if coordinates.count > 1,
           let first = coordinates.first, let last = coordinates.last,
           abs(first.latitude - last.latitude) < 0.000000001,
           abs(first.longitude - last.longitude) < 0.000000001 {
            coordinates.removeLast()
        }
        return coordinates
    }

    private static func doubleValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] { return array.map { stringify($0) }.joined(separator: ", ") }
        return String(describing: value)
    }
}

// MARK: - KML export

enum LayerKMLExporter {
    /// KML aabbggrr fill from the layer's fill color, opacity, and style
    /// (hatch exports as solid; "none" exports fully transparent).
    private static func kmlPolygonFill(for layer: MapLayer) -> String {
        let base = layer.effectiveFillColor.kmlFillColor   // aabbggrr with default alpha
        let bgr = String(base.suffix(6))
        let alphaValue = layer.fillStyle == PolygonFillStyle.none
            ? 0
            : Int(max(0, min(1, layer.fillOpacity)) * 255)
        return String(format: "%02x", alphaValue) + bgr
    }

    static func kml(layers: [MapLayer]) -> String {
        let placemarks = layers.map { layer in
            placemark(for: layer)
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <Style id="gpsTrackStyle">
              <LineStyle><color>ff0000ff</color><width>4</width></LineStyle>
            </Style>
            <Style id="measureStyle">
              <LineStyle><color>ff00ffff</color><width>4</width></LineStyle>
            </Style>
            <Style id="polygonStyle">
              <LineStyle><color>ff00ff00</color><width>4</width></LineStyle>
              <PolyStyle><color>5500ff00</color></PolyStyle>
            </Style>
            <Style id="pointStyle">
              <IconStyle>
                <color>ffff00ff</color>
                <scale>1.1</scale>
                <Icon><href>http://maps.google.com/mapfiles/kml/paddle/purple-circle.png</href></Icon>
              </IconStyle>
            </Style>
        \(placemarks)
          </Document>
        </kml>
        """
    }

    private static func placemark(for layer: MapLayer) -> String {
        switch layer.kind {
        case .track, .measure:
            return linePlacemark(for: layer)
        case .polygon:
            return polygonPlacemark(for: layer)
        case .point:
            return pointPlacemark(for: layer)
        }
    }

    /// Notes and custom attributes ride along as KML ExtendedData so they
    /// survive a round trip into Google Earth or GIS KML importers.
    private static func extendedData(for layer: MapLayer) -> String {
        var entries: [String] = []
        if !layer.notes.isEmpty {
            entries.append("      <Data name=\"notes\"><value>\(xmlEscape(layer.notes))</value></Data>")
        }
        if !layer.group.isEmpty {
            entries.append("      <Data name=\"group\"><value>\(xmlEscape(layer.group))</value></Data>")
        }
        for field in layer.fields {
            let key = field.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            entries.append("      <Data name=\"\(xmlEscape(key))\"><value>\(xmlEscape(field.value))</value></Data>")
        }
        if !layer.photoFilenames.isEmpty {
            entries.append("      <Data name=\"photos\"><value>\(xmlEscape(layer.photoFilenames.joined(separator: ", ")))</value></Data>")
        }

        guard !entries.isEmpty else { return "" }
        return """
              <ExtendedData>
        \(entries.joined(separator: "\n"))
              </ExtendedData>
        """
    }

    private static func linePlacemark(for layer: MapLayer) -> String {
        let coordinates = coordinateText(layer.coordinates)
        let description = layerDescription(for: layer)
        return """
            <Placemark>
              <name>\(xmlEscape(layer.name))</name>
              <description>\(xmlEscape(description))</description>
              <Style><LineStyle><color>\(layer.effectiveColor.kmlLineColor)</color><width>4</width></LineStyle></Style>
        \(extendedData(for: layer))
              <LineString>
                <tessellate>1</tessellate>
                <coordinates>\(coordinates)</coordinates>
              </LineString>
            </Placemark>
        """
    }

    private static func polygonPlacemark(for layer: MapLayer) -> String {
        var coordinates = layer.coordinates
        if let first = coordinates.first,
           let last = coordinates.last,
           first.latitude != last.latitude || first.longitude != last.longitude {
            coordinates.append(first)
        }

        return """
            <Placemark>
              <name>\(xmlEscape(layer.name))</name>
              <description>\(xmlEscape(layerDescription(for: layer)))</description>
              <Style>
                <LineStyle><color>\(layer.effectiveColor.kmlLineColor)</color><width>4</width></LineStyle>
                <PolyStyle><color>\(kmlPolygonFill(for: layer))</color></PolyStyle>
              </Style>
        \(extendedData(for: layer))
              <Polygon>
                <outerBoundaryIs>
                  <LinearRing>
                    <coordinates>\(coordinateText(coordinates))</coordinates>
                  </LinearRing>
                </outerBoundaryIs>
              </Polygon>
            </Placemark>
        """
    }

    private static func pointPlacemark(for layer: MapLayer) -> String {
        guard let coordinate = layer.coordinates.first else {
            return ""
        }

        return """
            <Placemark>
              <name>\(xmlEscape(layer.name))</name>
              <description>\(xmlEscape(layerDescription(for: layer)))</description>
              <Style><IconStyle><color>\(layer.effectiveColor.kmlLineColor)</color><scale>1.2</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle></Style>
        \(extendedData(for: layer))
              <Point>
                <coordinates>\(coordinate.longitude),\(coordinate.latitude),0</coordinates>
              </Point>
            </Placemark>
        """
    }

    private static func coordinateText(_ coordinates: [LayerCoordinate]) -> String {
        coordinates.map { "\($0.longitude),\($0.latitude),0" }.joined(separator: " ")
    }

    private static func layerDescription(for layer: MapLayer) -> String {
        switch layer.kind {
        case .track, .measure:
            let coordinates = layer.clCoordinates
            let distance = MeasurementMath.totalDistanceMeters(for: coordinates)
            let bearing = MeasurementMath.finalSegmentBearingDegrees(for: coordinates)
            let bearingText = bearing.map { String(format: "%.1f deg", $0) } ?? "not available"
            return String(format: "Distance: %.1f m / %.1f ft. Final segment bearing: %@.", distance, distance * 3.28084, bearingText)
        case .polygon:
            let area = MeasurementMath.areaSquareMeters(for: layer.clCoordinates)
            return String(format: "Area: %.1f sq m / %.3f acres.", area, area / 4046.8564224)
        case .point:
            guard let coordinate = layer.coordinates.first else {
                return "Point has no coordinate."
            }
            return String(format: "Point: %.6f, %.6f.", coordinate.latitude, coordinate.longitude)
        }
    }

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Track export

enum TrackExporter {
    static func gpx(locations: [CLLocation], name: String) -> String {
        let points = locations.map { location in
            let coordinate = location.coordinate
            return """
                <trkpt lat="\(coordinate.latitude)" lon="\(coordinate.longitude)">
                  <ele>\(location.altitude)</ele>
                  <time>\(iso8601(location.timestamp))</time>
                </trkpt>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="ArchaeologySurvey" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(xmlEscape(name))</name>
            <trkseg>
        \(points)
            </trkseg>
          </trk>
        </gpx>
        """
    }

    static func kml(locations: [CLLocation], name: String) -> String {
        let coordinates = locations.map { location in
            "\(location.coordinate.longitude),\(location.coordinate.latitude),\(location.altitude)"
        }.joined(separator: " ")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <Placemark>
              <name>\(xmlEscape(name))</name>
              <LineString>
                <tessellate>1</tessellate>
                <coordinates>\(coordinates)</coordinates>
              </LineString>
            </Placemark>
          </Document>
        </kml>
        """
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}


// MARK: - iPhone LiDAR scanning

/// Request to start an ARKit LiDAR scan tied to a map/GPS coordinate.
/// The coordinate becomes the scan origin for export.
struct LiDARScanRequest: Identifiable {
    let id = UUID()
    let name: String
    let originCoordinate: CLLocationCoordinate2D
    let originAltitude: Double?
    let headingDegrees: Double?
    let source: String
}

struct LiDARScanResult {
    let name: String
    let originCoordinate: CLLocationCoordinate2D
    let originAltitude: Double?
    let headingDegrees: Double?
    let source: String
    let vertexCount: Int
    let anchorCount: Int
    let plyURL: URL
    let lasURL: URL
    let photoFilenames: [String]
    let createdAt: Date
}

struct LiDARPointCloudDocument: Identifiable {
    let id = UUID()
    let name: String
    let plyURL: URL
    let lasURL: URL?
    let photoURLs: [URL]
    let originCoordinate: CLLocationCoordinate2D?
    let pointCount: Int
    let createdAt: Date
}

struct LiDARSharePackage: Identifiable {
    let id = UUID()
    let name: String
    let urls: [URL]
}

struct LiDARPointCloudViewer: View {
    let document: LiDARPointCloudDocument

    @Environment(\.dismiss) private var dismiss
    @State private var sharePackage: LiDARSharePackage?

    @State private var loadedScene: SCNScene?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Group {
                    if let loadedScene = loadedScene {
                        LiDARPointCloudSceneView(scene: loadedScene)
                    } else {
                        ZStack {
                            Color.black
                            VStack(spacing: 10) {
                                ProgressView()
                                    .tint(.white)
                                Text("Loading point cloud…")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }
                }
                .task {
                    let url = document.plyURL
                    let scene = await MainActor.run {
                        LiDARPLYSceneBuilder.scene(from: url)
                    }
                    loadedScene = scene
                }
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.name)
                                .font(.headline)
                            Text("PLY: \(document.plyURL.lastPathComponent)")
                                .font(.caption2.monospaced())
                            if let lasURL = document.lasURL {
                                Text("LAS: \(lasURL.lastPathComponent)")
                                    .font(.caption2.monospaced())
                            }
                            if document.pointCount > 0 {
                                Text("Points: \(document.pointCount)")
                                    .font(.caption.monospacedDigit())
                            }
                            if !document.photoURLs.isEmpty {
                                Text("Photos: \(document.photoURLs.count)")
                                    .font(.caption.monospacedDigit())
                            }
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Drag to rotate, pinch to zoom, and two-finger drag to pan the scan. Colors are real camera RGB where the camera saw the surface, with an elevation ramp elsewhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            sharePackage = LiDARSharePackage(name: document.name, urls: [document.plyURL])
                        } label: {
                            Label("Share PLY", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        if let lasURL = document.lasURL {
                            Button {
                                sharePackage = LiDARSharePackage(name: document.name, urls: [lasURL])
                            } label: {
                                Label("Share LAS", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                sharePackage = LiDARSharePackage(name: document.name, urls: [lasURL, document.plyURL])
                            } label: {
                                Label("Share Both", systemImage: "square.and.arrow.up.on.square")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if !document.photoURLs.isEmpty {
                            Button {
                                sharePackage = LiDARSharePackage(name: document.name, urls: document.photoURLs)
                            } label: {
                                Label("Share Photos", systemImage: "photo.on.rectangle")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                let cloudURLs = [document.lasURL, Optional(document.plyURL)].compactMap { $0 }
                                sharePackage = LiDARSharePackage(name: document.name, urls: cloudURLs + document.photoURLs)
                            } label: {
                                Label("Share All", systemImage: "square.and.arrow.up.on.square")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .navigationTitle("3D Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $sharePackage) { package in
                ShareSheet(activityItems: package.urls)
            }
        }
    }
}

struct LiDARPointCloudSceneView: UIViewRepresentable {
    let scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.scene = scene
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene !== scene {
            uiView.scene = scene
        }
    }
}

enum LiDARPLYSceneBuilder {
    static func scene(from url: URL) -> SCNScene {
        let scene = SCNScene()
        do {
            let cloud = try LiDARPLYLoader.localPoints(from: url, maxPoints: 150_000)
            let points = cloud.points
            guard !points.isEmpty else { throw NSError(domain: "PLY", code: 1) }

            // RGB from the file when present; otherwise an elevation ramp
            // so every cloud renders colorized.
            let colors = cloud.colors ?? elevationRampColors(for: points)

            let centered = centeredPoints(points)
            let geometry = pointGeometry(points: centered.points, colors: colors)
            let node = SCNNode(geometry: geometry)
            scene.rootNode.addChildNode(node)

            let axesNode = axes(length: max(0.25, centered.radius * 0.35))
            scene.rootNode.addChildNode(axesNode)

            let camera = SCNCamera()
            camera.zFar = 10_000
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            let distance = max(1.0, centered.radius * 2.8)
            cameraNode.position = SCNVector3(0, Float(-distance), Float(distance * 0.65))
            cameraNode.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(cameraNode)

            let light = SCNLight()
            light.type = .omni
            light.intensity = 600
            let lightNode = SCNNode()
            lightNode.light = light
            lightNode.position = SCNVector3(0, -2, 4)
            scene.rootNode.addChildNode(lightNode)
        } catch {
            let text = SCNText(string: "Could not load PLY", extrusionDepth: 0.01)
            text.font = UIFont.systemFont(ofSize: 0.2, weight: .bold)
            text.firstMaterial?.diffuse.contents = UIColor.white
            let node = SCNNode(geometry: text)
            node.position = SCNVector3(-1.2, 0, 0)
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    private static func centeredPoints(_ points: [SCNVector3]) -> (points: [SCNVector3], radius: Double) {
        let minX = points.map { $0.x }.min() ?? 0
        let maxX = points.map { $0.x }.max() ?? 0
        let minY = points.map { $0.y }.min() ?? 0
        let maxY = points.map { $0.y }.max() ?? 0
        let minZ = points.map { $0.z }.min() ?? 0
        let maxZ = points.map { $0.z }.max() ?? 0
        let center = SCNVector3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
        var radius: Double = 0
        let shifted = points.map { point -> SCNVector3 in
            let p = SCNVector3(point.x - center.x, point.y - center.y, point.z - center.z)
            radius = max(radius, Double(sqrt(p.x * p.x + p.y * p.y + p.z * p.z)))
            return p
        }
        return (shifted, radius)
    }

    /// Elevation ramp colors (PLY z = up) for clouds saved without RGB.
    private static func elevationRampColors(for points: [SCNVector3]) -> [SIMD3<Float>] {
        let minUp = points.map { $0.z }.min() ?? 0
        let maxUp = points.map { $0.z }.max() ?? 1
        let range = max(0.01, maxUp - minUp)
        return points.map { point in
            let rgb = LiDARColorSampler.elevationColor(normalized: Double((point.z - minUp) / range))
            return SIMD3<Float>(Float(rgb.red) / 255, Float(rgb.green) / 255, Float(rgb.blue) / 255)
        }
    }

    private static func pointGeometry(points: [SCNVector3], colors: [SIMD3<Float>]) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: points)

        var colorValues = colors
        if colorValues.count != points.count {
            colorValues = Array(repeating: SIMD3<Float>(0, 1, 1), count: points.count)
        }
        let colorData = colorValues.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let indices = points.indices.map { Int32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 6

        let geometry = SCNGeometry(sources: [source, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        geometry.materials = [material]
        return geometry
    }

    private static func axes(length: Double) -> SCNNode {
        let root = SCNNode()
        root.addChildNode(axisNode(to: SCNVector3(Float(length), 0, 0), color: .systemRed))
        root.addChildNode(axisNode(to: SCNVector3(0, Float(length), 0), color: .systemGreen))
        root.addChildNode(axisNode(to: SCNVector3(0, 0, Float(length)), color: .systemBlue))
        return root
    }

    private static func axisNode(to end: SCNVector3, color: UIColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: [SCNVector3(0, 0, 0), end])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.diffuse.contents = color
        return SCNNode(geometry: geometry)
    }
}

enum LiDARPLYLoader {
    struct LoadedCloud {
        let points: [SCNVector3]
        /// Per-point RGB (0-1), parallel to points; nil when the file has
        /// no color columns.
        let colors: [SIMD3<Float>]?
    }

    static func localPoints(from url: URL, maxPoints: Int) throws -> LoadedCloud {
        let text = try String(contentsOf: url, encoding: .utf8)

        // Use Foundation string splitting here instead of Character comparisons.
        // This avoids Xcode/Swift inference problems where a Substring.Element
        // can be treated as Character while the separator literal is inferred as String.
        let lines = text.components(separatedBy: .newlines)
        guard let headerEnd = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "end_header"
        }) else {
            return LoadedCloud(points: [], colors: nil)
        }

        // Map property names to column indices from the header, so files
        // with or without color (and from other tools) both load.
        var propertyNames: [String] = []
        for line in lines.prefix(headerEnd) {
            let parts = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            if parts.count >= 3, parts[0] == "property" {
                propertyNames.append(parts[2].lowercased())
            }
        }
        let xIndex = propertyNames.firstIndex(of: "x") ?? 0
        let yIndex = propertyNames.firstIndex(of: "y") ?? 1
        let zIndex = propertyNames.firstIndex(of: "z") ?? 2
        let redIndex = propertyNames.firstIndex(of: "red") ?? propertyNames.firstIndex(of: "r")
        let greenIndex = propertyNames.firstIndex(of: "green") ?? propertyNames.firstIndex(of: "g")
        let blueIndex = propertyNames.firstIndex(of: "blue") ?? propertyNames.firstIndex(of: "b")
        let hasColor = redIndex != nil && greenIndex != nil && blueIndex != nil

        let dataLines = Array(lines.dropFirst(headerEnd + 1))
        let sampleStride = max(1, dataLines.count / max(1, maxPoints))
        var points: [SCNVector3] = []
        var colors: [SIMD3<Float>] = []
        points.reserveCapacity(min(dataLines.count, maxPoints))
        if hasColor { colors.reserveCapacity(min(dataLines.count, maxPoints)) }

        for (index, line) in dataLines.enumerated() where index % sampleStride == 0 {
            let parts = line
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            guard parts.count > max(xIndex, max(yIndex, zIndex)),
                  let x = Float(parts[xIndex]),
                  let y = Float(parts[yIndex]),
                  let z = Float(parts[zIndex]) else { continue }

            points.append(SCNVector3(x, y, z))

            if hasColor,
               let redIndex = redIndex, let greenIndex = greenIndex, let blueIndex = blueIndex,
               parts.count > max(redIndex, max(greenIndex, blueIndex)),
               let red = Float(parts[redIndex]),
               let green = Float(parts[greenIndex]),
               let blue = Float(parts[blueIndex])
            {
                colors.append(SIMD3<Float>(red / 255, green / 255, blue / 255))
            }

            if points.count >= maxPoints { break }
        }

        let validColors = hasColor && colors.count == points.count
        return LoadedCloud(points: points, colors: validColors ? colors : nil)
    }
}

struct LiDARScanView: View {
    let request: LiDARScanRequest
    let onSave: (LiDARScanResult) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner: LiDARScanCoordinator
    @State private var scanName: String
    @State private var isSaving = false
    @State private var showMeshOverlay = true
    @State private var showFeaturePoints = false
    @State private var capturedPhotoFilenames: [String] = []

    init(
        request: LiDARScanRequest,
        onSave: @escaping (LiDARScanResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _scanner = StateObject(wrappedValue: LiDARScanCoordinator(request: request))
        _scanName = State(initialValue: request.name)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if LiDARScanCoordinator.isSupported {
                    ARLiDARScannerContainer(
                        scanner: scanner,
                        showMeshOverlay: showMeshOverlay,
                        showFeaturePoints: showFeaturePoints
                    )
                        .overlay(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Move slowly around the feature. Keep the object in view from multiple angles. Point colors come from the camera, so sweep every surface you want colorized.")
                                    .font(.caption)
                                Text("Mesh anchors: \(scanner.meshAnchorCount) | mesh vertices: \(scanner.vertexCount)")
                                    .font(.caption.monospacedDigit())
                                Text(scanner.statusMessage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial)
                        }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("LiDAR Not Available")
                            .font(.headline)
                        Text("This feature requires an iPhone or iPad with LiDAR scene reconstruction support.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Form {
                    Section(header: Text("Scan Origin")) {
                        Text(CoordinateFormatter.string(for: request.originCoordinate, format: .decimalDegrees))
                            .font(.footnote.monospacedDigit())
                            .textSelection(.enabled)
                        Text(CoordinateFormatter.utmString(for: request.originCoordinate))
                            .font(.footnote.monospacedDigit())
                            .textSelection(.enabled)
                        LabeledContent("Source", value: request.source)
                        LabeledContent("Heading", value: request.headingDegrees.map { String(format: "%.1f deg", $0) } ?? "unknown")
                        LabeledContent("Altitude", value: request.originAltitude.map { String(format: "%.2f m", $0) } ?? "unknown")
                    }

                    Section(header: Text("Name")) {
                        TextField("Scan name", text: $scanName)
                    }

                    Section(header: Text("Scan Detail")) {
                        Toggle("Show live mesh overlay", isOn: $showMeshOverlay)
                        Toggle("Show AR feature points", isOn: $showFeaturePoints)
                        Text("For more detail, move slowly, keep the phone steady, scan from multiple angles, and close loops around the object or feature. Export includes mesh vertices plus face-center sample points for a denser point cloud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(header: Text("High-Quality Photos")) {
                        Button {
                            captureLiDARPhoto()
                        } label: {
                            Label("Capture Photo", systemImage: "camera.fill")
                        }
                        .disabled(!LiDARScanCoordinator.isSupported)

                        LabeledContent("Photos captured", value: "\(capturedPhotoFilenames.count)")
                        Text("Each captured image is saved as a high-quality JPEG and attached to the LiDAR scan point layer for later viewing, export, or AirDrop with the PLY/LAS files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(header: Text("Export")) {
                        Text("Save creates a PLY point cloud, an approximate georeferenced LAS file, and any captured high-quality JPEG photos. The LAS is written in WGS84 / UTM meters using the scan origin zone, with coordinates derived from ARKit mesh geometry plus GPS, compass, and altitude.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 270)
            }
            .navigationTitle("3D Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        scanner.pause()
                        dismiss()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        saveScan()
                    }
                    .disabled(!LiDARScanCoordinator.isSupported || scanner.vertexCount == 0 || isSaving)
                }
            }
            .onDisappear {
                scanner.pause()
            }
        }
    }

    private func captureLiDARPhoto() {
        let base = scanName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? request.name : scanName
        if let filename = scanner.captureHighQualityPhoto(prefix: LiDARScanFileStore.safeBaseName(base)) {
            capturedPhotoFilenames.append(filename)
        }
    }

    private func saveScan() {
        isSaving = true
        do {
            let result = try scanner.savePLY(
                name: scanName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? request.name : scanName,
                photoFilenames: capturedPhotoFilenames
            )
            dismiss()
            onSave(result)
        } catch {
            scanner.statusMessage = "Save failed: \(error.localizedDescription)"
            isSaving = false
        }
    }
}

struct Photo3DModelScanView: View {
    let request: LiDARScanRequest
    let onSave: (LiDARScanResult) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner: Photo3DModelScanCoordinator
    @State private var modelName: String
    @State private var isSaving = false
    @State private var showFeaturePoints = true
    @State private var capturedPhotoFilenames: [String] = []

    init(
        request: LiDARScanRequest,
        onSave: @escaping (LiDARScanResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _scanner = StateObject(wrappedValue: Photo3DModelScanCoordinator(request: request))
        _modelName = State(initialValue: request.name)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if Photo3DModelScanCoordinator.isSupported {
                    ARPhoto3DScannerContainer(
                        scanner: scanner,
                        showFeaturePoints: showFeaturePoints
                    )
                    .overlay(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Walk slowly around the feature and take overlapping photos from multiple angles. Point colors come from the camera, so cover every side.")
                                .font(.caption)
                            Text("AR feature points: \(scanner.pointCount) | photos: \(capturedPhotoFilenames.count)")
                                .font(.caption.monospacedDigit())
                            Text(scanner.statusMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Photo 3D Capture Not Available")
                            .font(.headline)
                        Text("This feature requires ARKit world tracking.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Form {
                    Section(header: Text("Model Origin")) {
                        Text(CoordinateFormatter.string(for: request.originCoordinate, format: .decimalDegrees))
                            .font(.footnote.monospacedDigit())
                            .textSelection(.enabled)
                        Text(CoordinateFormatter.utmString(for: request.originCoordinate))
                            .font(.footnote.monospacedDigit())
                            .textSelection(.enabled)
                        LabeledContent("Source", value: request.source.replacingOccurrences(of: "photo_3d_", with: ""))
                        LabeledContent("Heading", value: request.headingDegrees.map { String(format: "%.1f deg", $0) } ?? "unknown")
                        LabeledContent("Altitude", value: request.originAltitude.map { String(format: "%.2f m", $0) } ?? "unknown")
                    }

                    Section(header: Text("Name")) {
                        TextField("Model name", text: $modelName)
                    }

                    Section(header: Text("Photo Capture")) {
                        Toggle("Show AR feature points", isOn: $showFeaturePoints)

                        Button {
                            capturePhotoModelImage()
                        } label: {
                            Label("Capture Overlap Photo", systemImage: "camera.fill")
                        }
                        .disabled(!Photo3DModelScanCoordinator.isSupported)

                        LabeledContent("Photos captured", value: "\(capturedPhotoFilenames.count)")
                        Text("For better models: collect at least 12-24 photos, overlap each view by about 70%, move in a slow arc around the feature, and avoid shiny or moving surfaces.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(header: Text("Export")) {
                        Text("Save creates a high-quality photo set plus an approximate georeferenced sparse PLY/LAS point cloud from ARKit visual feature points. For a dense textured mesh, export the photos to a photogrammetry package on a Mac/cloud/server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 300)
            }
            .navigationTitle("Photo 3D Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        scanner.pause()
                        dismiss()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        saveModel()
                    }
                    .disabled(!Photo3DModelScanCoordinator.isSupported || capturedPhotoFilenames.count < 3 || scanner.pointCount < 20 || isSaving)
                }
            }
            .onDisappear {
                scanner.pause()
            }
        }
    }

    private func capturePhotoModelImage() {
        let base = modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? request.name : modelName
        if let filename = scanner.captureHighQualityPhoto(prefix: LiDARScanFileStore.safeBaseName(base)) {
            capturedPhotoFilenames.append(filename)
        }
    }

    private func saveModel() {
        isSaving = true
        do {
            let result = try scanner.saveModel(
                name: modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? request.name : modelName,
                photoFilenames: capturedPhotoFilenames
            )
            dismiss()
            onSave(result)
        } catch {
            scanner.statusMessage = "Save failed: \(error.localizedDescription)"
            isSaving = false
        }
    }
}

struct ARPhoto3DScannerContainer: UIViewRepresentable {
    @ObservedObject var scanner: Photo3DModelScanCoordinator
    var showFeaturePoints: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        view.preferredFramesPerSecond = 60
        applyDebugOptions(to: view)
        scanner.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        applyDebugOptions(to: uiView)
    }

    private func applyDebugOptions(to view: ARSCNView) {
        var options: ARSCNDebugOptions = []
        if showFeaturePoints {
            options.insert(.showFeaturePoints)
        }
        view.debugOptions = options
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
    }
}

final class Photo3DModelScanCoordinator: NSObject, ObservableObject, ARSessionDelegate {
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    private let request: LiDARScanRequest
    private weak var sceneView: ARSCNView?
    private var worldPoints: [String: SIMD3<Float>] = [:]
    private let voxelSize: Float = 0.02
    private let maxStoredPoints = 300_000
    private let imageContext = CIContext()
    /// Rolling camera-color keyframes used to colorize the point cloud.
    private var colorKeyframes: [LiDARColorKeyframe] = []
    private var lastKeyframeTime: TimeInterval = 0

    @Published var pointCount: Int = 0
    @Published var statusMessage: String = "Starting photo 3D capture…"

    init(request: LiDARScanRequest) {
        self.request = request
        super.init()
    }

    func attach(to view: ARSCNView) {
        sceneView = view
        view.session.delegate = self
        runSession(on: view.session)
    }

    func pause() {
        sceneView?.session.pause()
    }

    private func runSession(on session: ARSession) {
        guard Self.isSupported else {
            statusMessage = "ARKit world tracking is not supported on this device."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravityAndHeading
        configuration.environmentTexturing = .automatic
        configuration.isAutoFocusEnabled = true
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        statusMessage = "Move slowly and capture overlapping photos."
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        ingestFeaturePoints(frame.rawFeaturePoints)
        captureColorKeyframeIfDue(frame)
    }

    private func captureColorKeyframeIfDue(_ frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        let now = frame.timestamp
        guard now - lastKeyframeTime >= LiDARColorSampler.keyframeInterval else { return }
        lastKeyframeTime = now
        guard let keyframe = LiDARColorSampler.makeKeyframe(from: frame, context: imageContext) else { return }
        colorKeyframes.append(keyframe)
        if colorKeyframes.count > LiDARColorSampler.maxKeyframes {
            colorKeyframes = colorKeyframes.enumerated()
                .filter { $0.offset % 2 == 0 }
                .map { $0.element }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.statusMessage = "AR session failed: \(error.localizedDescription)"
        }
    }

    private func ingestFeaturePoints(_ pointCloud: ARPointCloud?) {
        guard let pointCloud = pointCloud else { return }
        var added = 0
        for point in pointCloud.points {
            if worldPoints.count >= maxStoredPoints { break }
            let key = voxelKey(for: point)
            if worldPoints[key] == nil {
                worldPoints[key] = point
                added += 1
            }
        }
        guard added > 0 else { return }
        let count = worldPoints.count
        DispatchQueue.main.async {
            self.pointCount = count
            self.statusMessage = "Tracking good. Keep collecting photos from different angles."
        }
    }

    private func voxelKey(for point: SIMD3<Float>) -> String {
        let x = Int((point.x / voxelSize).rounded())
        let y = Int((point.y / voxelSize).rounded())
        let z = Int((point.z / voxelSize).rounded())
        return "\(x)_\(y)_\(z)"
    }

    func captureHighQualityPhoto(prefix: String) -> String? {
        guard let frame = sceneView?.session.currentFrame else {
            DispatchQueue.main.async { self.statusMessage = "No AR camera frame is available yet." }
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = imageContext.createCGImage(ciImage, from: ciImage.extent) else {
            DispatchQueue.main.async { self.statusMessage = "Could not render the AR camera image." }
            return nil
        }

        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        let filename = PhotoStore.save(image, compressionQuality: 0.98, prefix: "photo3d-\(prefix)-image")

        DispatchQueue.main.async {
            if filename != nil {
                self.statusMessage = "Captured overlap photo. Continue around the feature."
            } else {
                self.statusMessage = "Could not save photo."
            }
        }
        return filename
    }

    func saveModel(name: String, photoFilenames: [String]) throws -> LiDARScanResult {
        guard photoFilenames.count >= 3 else {
            throw NSError(domain: "Photo3DModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Capture at least three overlapping photos before saving."])
        }

        let points = Array(worldPoints.values)
        guard points.count >= 20 else {
            throw NSError(domain: "Photo3DModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not enough AR feature points were collected. Move slowly around textured surfaces and try again."])
        }

        let createdAt = Date()
        let folder = try LiDARScanFileStore.folderURL()
        let safeBase = LiDARScanFileStore.safeBaseName(name)
        let timestamp = Int(createdAt.timeIntervalSince1970)
        let plyURL = folder.appendingPathComponent("\(safeBase)-photo3d-\(timestamp).ply")
        let lasURL = folder.appendingPathComponent("\(safeBase)-photo3d-\(timestamp).las")

        let minUp = Double(points.map { $0.y }.min() ?? 0)
        let maxUp = Double(points.map { $0.y }.max() ?? 1)
        let upRange = max(0.01, maxUp - minUp)
        let exportPoints = points.map { point -> LiDARScanPoint in
            let world = SIMD4<Float>(point.x, point.y, point.z, 1)
            let color = LiDARColorSampler.sampleColor(worldPoint: world, keyframes: colorKeyframes)
                ?? LiDARColorSampler.elevationColor(normalized: (Double(point.y) - minUp) / upRange)
            return LiDARScanPointCollector.point(fromWorld: world, color: color, request: request)
        }
        let text = LiDARPLYExporter.ply(
            points: exportPoints,
            request: request,
            createdAt: createdAt
        )
        try text.write(to: plyURL, atomically: true, encoding: .utf8)

        let lasData = LiDARLASExporter.las(
            points: exportPoints,
            request: request,
            createdAt: createdAt
        )
        try lasData.write(to: lasURL, options: .atomic)

        return LiDARScanResult(
            name: name,
            originCoordinate: request.originCoordinate,
            originAltitude: request.originAltitude,
            headingDegrees: request.headingDegrees,
            source: request.source,
            vertexCount: exportPoints.count,
            anchorCount: 0,
            plyURL: plyURL,
            lasURL: lasURL,
            photoFilenames: photoFilenames,
            createdAt: createdAt
        )
    }

}

struct ARLiDARScannerContainer: UIViewRepresentable {
    @ObservedObject var scanner: LiDARScanCoordinator
    var showMeshOverlay: Bool
    var showFeaturePoints: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        view.preferredFramesPerSecond = 60
        applyDebugOptions(to: view)
        scanner.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        applyDebugOptions(to: uiView)
    }

    private func applyDebugOptions(to view: ARSCNView) {
        var options: ARSCNDebugOptions = []
        if showFeaturePoints {
            options.insert(.showFeaturePoints)
        }
        view.debugOptions = options
        scanner.setMeshOverlayVisible(showMeshOverlay)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
    }
}

final class LiDARScanCoordinator: NSObject, ObservableObject, ARSessionDelegate {
    static var isSupported: Bool {
        guard ARWorldTrackingConfiguration.isSupported else { return false }
        if #available(iOS 13.4, *) {
            return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) ||
                ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        }
        return false
    }

    private let request: LiDARScanRequest
    private weak var sceneView: ARSCNView?
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var meshNodes: [UUID: SCNNode] = [:]
    private var showMeshOverlay = true
    private let imageContext = CIContext()
    /// Rolling camera-color keyframes used to colorize the point cloud.
    private var colorKeyframes: [LiDARColorKeyframe] = []
    private var lastKeyframeTime: TimeInterval = 0

    @Published var meshAnchorCount: Int = 0
    @Published var vertexCount: Int = 0
    @Published var statusMessage: String = "Starting LiDAR scan…"

    init(request: LiDARScanRequest) {
        self.request = request
        super.init()
    }

    func attach(to view: ARSCNView) {
        sceneView = view
        view.session.delegate = self
        runSession(on: view.session)
    }

    func pause() {
        sceneView?.session.pause()
    }

    func setMeshOverlayVisible(_ visible: Bool) {
        showMeshOverlay = visible
        for node in meshNodes.values {
            node.isHidden = !visible
        }
    }

    func captureHighQualityPhoto(prefix: String) -> String? {
        guard let frame = sceneView?.session.currentFrame else {
            DispatchQueue.main.async { self.statusMessage = "No AR camera frame is available yet." }
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = imageContext.createCGImage(ciImage, from: ciImage.extent) else {
            DispatchQueue.main.async { self.statusMessage = "Could not render the AR camera image." }
            return nil
        }

        // ARKit camera frames are delivered in camera-native orientation.
        // .right gives a useful portrait-oriented JPEG for typical field use.
        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        let filename = PhotoStore.save(image, compressionQuality: 0.98, prefix: "lidar-\(prefix)-image")

        DispatchQueue.main.async {
            if filename != nil {
                self.statusMessage = "Captured high-quality LiDAR photo."
            } else {
                self.statusMessage = "Could not save LiDAR photo."
            }
        }
        return filename
    }

    private func runSession(on session: ARSession) {
        guard Self.isSupported else {
            statusMessage = "LiDAR scene reconstruction is not supported on this device."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravityAndHeading
        configuration.environmentTexturing = .automatic
        configuration.isAutoFocusEnabled = true
        if #available(iOS 13.4, *) {
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                configuration.sceneReconstruction = .meshWithClassification
            } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = .mesh
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        statusMessage = "Scanning. Move slowly around the feature."
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateMeshAnchors(anchors)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        captureColorKeyframeIfDue(frame)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateMeshAnchors(anchors)
    }

    private func captureColorKeyframeIfDue(_ frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        let now = frame.timestamp
        guard now - lastKeyframeTime >= LiDARColorSampler.keyframeInterval else { return }
        lastKeyframeTime = now
        guard let keyframe = LiDARColorSampler.makeKeyframe(from: frame, context: imageContext) else { return }
        colorKeyframes.append(keyframe)
        if colorKeyframes.count > LiDARColorSampler.maxKeyframes {
            // Thin evenly instead of dropping the oldest, so early views
            // of the subject keep contributing color.
            colorKeyframes = colorKeyframes.enumerated()
                .filter { $0.offset % 2 == 0 }
                .map { $0.element }
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            meshAnchors.removeValue(forKey: anchor.identifier)
            meshNodes.removeValue(forKey: anchor.identifier)?.removeFromParentNode()
        }
        publishCounts()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.statusMessage = "AR session failed: \(error.localizedDescription)"
        }
    }

    private func updateMeshAnchors(_ anchors: [ARAnchor]) {
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
                meshAnchors[mesh.identifier] = mesh
                updateMeshNode(for: mesh)
            }
        }
        publishCounts()
    }

    private func updateMeshNode(for mesh: ARMeshAnchor) {
        guard let sceneView = sceneView else { return }
        let node: SCNNode
        if let existing = meshNodes[mesh.identifier] {
            node = existing
        } else {
            node = SCNNode()
            meshNodes[mesh.identifier] = node
            sceneView.scene.rootNode.addChildNode(node)
        }
        node.simdTransform = mesh.transform
        node.geometry = Self.sceneKitGeometry(from: mesh.geometry)
        node.isHidden = !showMeshOverlay
    }

    private static func sceneKitGeometry(from geometry: ARMeshGeometry) -> SCNGeometry {
        let vertices = (0..<geometry.vertices.count).map { index -> SCNVector3 in
            let vertex = geometry.vertex(at: index)
            return SCNVector3(vertex.x, vertex.y, vertex.z)
        }
        let source = SCNGeometrySource(vertices: vertices)

        var indices: [Int32] = []
        indices.reserveCapacity(geometry.faces.count * geometry.faces.indexCountPerPrimitive)
        for faceIndex in 0..<geometry.faces.count {
            for index in geometry.faceIndices(at: faceIndex) {
                indices.append(Int32(index))
            }
        }

        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let meshGeometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.80)
        material.emission.contents = UIColor.systemTeal.withAlphaComponent(0.20)
        material.isDoubleSided = true
        material.fillMode = .lines
        meshGeometry.materials = [material]
        return meshGeometry
    }

    private func publishCounts() {
        let anchorCount = meshAnchors.count
        let vertices = meshAnchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
        DispatchQueue.main.async {
            self.meshAnchorCount = anchorCount
            self.vertexCount = vertices
        }
    }

    func savePLY(name: String, photoFilenames: [String] = []) throws -> LiDARScanResult {
        let anchors = Array(meshAnchors.values)
        guard !anchors.isEmpty else {
            throw NSError(domain: "LiDARScan", code: 1, userInfo: [NSLocalizedDescriptionKey: "No LiDAR mesh anchors were collected."])
        }

        let createdAt = Date()
        let folder = try LiDARScanFileStore.folderURL()
        let safeBase = LiDARScanFileStore.safeBaseName(name)
        let timestamp = Int(createdAt.timeIntervalSince1970)
        let plyURL = folder.appendingPathComponent("\(safeBase)-\(timestamp).ply")
        let lasURL = folder.appendingPathComponent("\(safeBase)-\(timestamp).las")

        let exportPoints = LiDARScanPointCollector.points(
            anchors: anchors,
            request: request,
            includeFaceCentroids: true,
            keyframes: colorKeyframes
        )
        guard !exportPoints.isEmpty else {
            throw NSError(domain: "LiDARScan", code: 2, userInfo: [NSLocalizedDescriptionKey: "The mesh contained no exportable points."])
        }

        let text = LiDARPLYExporter.ply(
            points: exportPoints,
            request: request,
            createdAt: createdAt
        )
        try text.write(to: plyURL, atomically: true, encoding: .utf8)

        let lasData = LiDARLASExporter.las(
            points: exportPoints,
            request: request,
            createdAt: createdAt
        )
        try lasData.write(to: lasURL, options: .atomic)

        return LiDARScanResult(
            name: name,
            originCoordinate: request.originCoordinate,
            originAltitude: request.originAltitude,
            headingDegrees: request.headingDegrees,
            source: request.source,
            vertexCount: exportPoints.count,
            anchorCount: anchors.count,
            plyURL: plyURL,
            lasURL: lasURL,
            photoFilenames: photoFilenames,
            createdAt: createdAt
        )
    }
}

enum LiDARScanFileStore {
    static func folderURL() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = documents.appendingPathComponent("LiDARScans", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func existingURL(filename: String?) -> URL? {
        guard let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !filename.isEmpty,
              let folder = try? folderURL() else { return nil }
        let url = folder.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func existingURLs(for layer: MapLayer) -> [URL] {
        var urls = [
            existingURL(filename: layer.lidarLASFilename),
            existingURL(filename: layer.lidarPLYFilename)
        ].compactMap { $0 }
        urls.append(contentsOf: layer.photoFilenames.compactMap { PhotoStore.existingURL(filename: $0) })
        return urls
    }

    static func safeBaseName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let raw = String(filtered).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "LiDAR-Scan" : raw.replacingOccurrences(of: " ", with: "-")
    }
}

struct LiDARScanPoint {
    let east: Double
    let north: Double
    let up: Double
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let easting: Double
    let northing: Double
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

// MARK: - Point cloud colorization

/// A lightweight color snapshot of the AR camera: pose, intrinsics, and a
/// downscaled RGBA bitmap. Scan points are projected back into these
/// keyframes to pick up real camera color.
struct LiDARColorKeyframe {
    let cameraTransform: simd_float4x4
    let inverseTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageWidth: Double
    let imageHeight: Double
    let bitmap: [UInt8]          // RGBA, bitmapWidth x bitmapHeight
    let bitmapWidth: Int
    let bitmapHeight: Int
}

enum LiDARColorSampler {
    static let maxKeyframes = 24
    static let keyframeInterval: TimeInterval = 0.6
    private static let bitmapTargetWidth = 320

    /// Downscale the AR camera image into an RGBA keyframe.
    static func makeKeyframe(from frame: ARFrame, context: CIContext) -> LiDARColorKeyframe? {
        let buffer = frame.capturedImage
        let imageWidth = Double(CVPixelBufferGetWidth(buffer))
        let imageHeight = Double(CVPixelBufferGetHeight(buffer))
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        let scale = Double(bitmapTargetWidth) / imageWidth
        let bitmapWidth = bitmapTargetWidth
        let bitmapHeight = max(2, Int((imageHeight * scale).rounded()))

        let ciImage = CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(
            ciImage,
            from: CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight)
        ) else { return nil }

        var pixels = [UInt8](repeating: 0, count: bitmapWidth * bitmapHeight * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let drawContext = CGContext(
            data: &pixels,
            width: bitmapWidth,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: bitmapWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        drawContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))

        return LiDARColorKeyframe(
            cameraTransform: frame.camera.transform,
            inverseTransform: frame.camera.transform.inverse,
            intrinsics: frame.camera.intrinsics,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            bitmap: pixels,
            bitmapWidth: bitmapWidth,
            bitmapHeight: bitmapHeight
        )
    }

    /// Project a world-space point into the keyframes (newest first) and
    /// sample the first frame that sees it.
    static func sampleColor(
        worldPoint: SIMD4<Float>,
        keyframes: [LiDARColorKeyframe]
    ) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        for keyframe in keyframes.reversed() {
            let cameraPoint = keyframe.inverseTransform * worldPoint
            // ARKit camera space: +x right, +y up, -z forward.
            let zForward = -cameraPoint.z
            guard zForward > 0.2 else { continue }

            let fx = keyframe.intrinsics[0][0]
            let fy = keyframe.intrinsics[1][1]
            let cx = keyframe.intrinsics[2][0]
            let cy = keyframe.intrinsics[2][1]
            let u = Double(fx * cameraPoint.x / zForward + cx)
            let v = Double(fy * (-cameraPoint.y) / zForward + cy)
            guard u >= 0, v >= 0, u < keyframe.imageWidth, v < keyframe.imageHeight else { continue }

            let px = Int(u / keyframe.imageWidth * Double(keyframe.bitmapWidth))
            let py = Int(v / keyframe.imageHeight * Double(keyframe.bitmapHeight))
            guard px >= 0, py >= 0, px < keyframe.bitmapWidth, py < keyframe.bitmapHeight else { continue }

            let index = (py * keyframe.bitmapWidth + px) * 4
            guard index + 2 < keyframe.bitmap.count else { continue }
            return (keyframe.bitmap[index], keyframe.bitmap[index + 1], keyframe.bitmap[index + 2])
        }
        return nil
    }

    /// Blue -> teal -> green -> yellow -> red elevation ramp for points no
    /// camera frame saw (and for files saved without RGB).
    static func elevationColor(normalized value: Double) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let t = max(0, min(1, value))
        let stops: [(Double, Double, Double)] = [
            (0.10, 0.30, 0.85),
            (0.10, 0.75, 0.80),
            (0.20, 0.80, 0.25),
            (0.95, 0.85, 0.15),
            (0.90, 0.20, 0.15)
        ]
        let scaled = t * Double(stops.count - 1)
        let lower = min(stops.count - 2, Int(scaled))
        let frac = scaled - Double(lower)
        let a = stops[lower]
        let b = stops[lower + 1]
        let r = a.0 + (b.0 - a.0) * frac
        let g = a.1 + (b.1 - a.1) * frac
        let bl = a.2 + (b.2 - a.2) * frac
        return (UInt8(r * 255), UInt8(g * 255), UInt8(bl * 255))
    }
}

enum LiDARScanPointCollector {
    static func points(
        anchors: [ARMeshAnchor],
        request: LiDARScanRequest,
        includeFaceCentroids: Bool,
        keyframes: [LiDARColorKeyframe] = []
    ) -> [LiDARScanPoint] {
        // Gather world-space positions first so the elevation ramp
        // (the fallback for points no camera frame saw) can be scaled
        // to the scan's actual height range.
        var worldPoints: [SIMD4<Float>] = []
        let estimatedCount = anchors.reduce(0) { total, anchor in
            total + anchor.geometry.vertices.count + (includeFaceCentroids ? anchor.geometry.faces.count : 0)
        }
        worldPoints.reserveCapacity(estimatedCount)

        for anchor in anchors {
            let geometry = anchor.geometry
            for index in 0..<geometry.vertices.count {
                let local = geometry.vertex(at: index)
                worldPoints.append(anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1))
            }

            if includeFaceCentroids {
                for faceIndex in 0..<geometry.faces.count {
                    let indices = geometry.faceIndices(at: faceIndex)
                    guard indices.count >= 3 else { continue }
                    let a = geometry.vertex(at: Int(indices[0]))
                    let b = geometry.vertex(at: Int(indices[1]))
                    let c = geometry.vertex(at: Int(indices[2]))
                    let centroid = SIMD4<Float>(
                        (a.x + b.x + c.x) / 3,
                        (a.y + b.y + c.y) / 3,
                        (a.z + b.z + c.z) / 3,
                        1
                    )
                    worldPoints.append(anchor.transform * centroid)
                }
            }
        }

        let minUp = Double(worldPoints.map { $0.y }.min() ?? 0)
        let maxUp = Double(worldPoints.map { $0.y }.max() ?? 1)
        let upRange = max(0.01, maxUp - minUp)

        return worldPoints.map { world in
            let color = LiDARColorSampler.sampleColor(worldPoint: world, keyframes: keyframes)
                ?? LiDARColorSampler.elevationColor(normalized: (Double(world.y) - minUp) / upRange)
            return point(fromWorld: world, color: color, request: request)
        }
    }

    static func point(
        fromWorld world4: SIMD4<Float>,
        color: (red: UInt8, green: UInt8, blue: UInt8),
        request: LiDARScanRequest
    ) -> LiDARScanPoint {
        let east = Double(world4.x)
        let north = Double(-world4.z)
        let up = Double(world4.y)
        let geo = approximateCoordinate(
            origin: request.originCoordinate,
            eastMeters: east,
            northMeters: north
        )
        let altitude = (request.originAltitude ?? 0) + up
        let utm = CoordinateFormatter.utm(for: geo)
        return LiDARScanPoint(
            east: east,
            north: north,
            up: up,
            latitude: geo.latitude,
            longitude: geo.longitude,
            altitude: altitude,
            easting: utm.easting,
            northing: utm.northing,
            red: color.red,
            green: color.green,
            blue: color.blue
        )
    }

    private static func approximateCoordinate(
        origin: CLLocationCoordinate2D,
        eastMeters: Double,
        northMeters: Double
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6_378_137.0
        let dLat = northMeters / earthRadius
        let dLon = eastMeters / (earthRadius * cos(origin.latitude * .pi / 180))
        return CLLocationCoordinate2D(
            latitude: origin.latitude + dLat * 180 / .pi,
            longitude: origin.longitude + dLon * 180 / .pi
        )
    }
}

enum LiDARPLYExporter {
    static func ply(points: [LiDARScanPoint], request: LiDARScanRequest, createdAt: Date) -> String {
        var rows: [String] = []
        rows.reserveCapacity(points.count)

        for point in points {
            rows.append(String(
                format: "%.4f %.4f %.4f %d %d %d %.8f %.8f %.4f %.3f %.3f",
                point.east,
                point.north,
                point.up,
                Int(point.red),
                Int(point.green),
                Int(point.blue),
                point.latitude,
                point.longitude,
                point.altitude,
                point.easting,
                point.northing
            ))
        }

        let originAltitudeText = request.originAltitude.map { String($0) } ?? "unknown"
        let headingText = request.headingDegrees.map { String($0) } ?? "unknown"

        var header: [String] = [
            "ply",
            "format ascii 1.0",
            "comment generated_by FieldMapper iPhone 3D scanner",
            "comment georeference approximate_from_gps_compass_arkit",
            "comment origin_latitude \(request.originCoordinate.latitude)",
            "comment origin_longitude \(request.originCoordinate.longitude)",
            "comment origin_altitude_m \(originAltitudeText)",
            "comment heading_degrees \(headingText)",
            "comment created \(ISO8601DateFormatter().string(from: createdAt))",
            "element vertex \(rows.count)",
            "property float x",
            "property float y",
            "property float z",
            "property uchar red",
            "property uchar green",
            "property uchar blue",
            "property double latitude",
            "property double longitude",
            "property float altitude_m",
            "property double utm_easting_m",
            "property double utm_northing_m",
            "end_header"
        ]
        header.append(contentsOf: rows)
        return header.joined(separator: "\n") + "\n"
    }
}

enum LiDARLASExporter {
    static func las(points: [LiDARScanPoint], request: LiDARScanRequest, createdAt: Date) -> Data {
        var data = Data()
        guard !points.isEmpty else { return data }

        let xs = points.map { $0.easting }
        let ys = points.map { $0.northing }
        let zs = points.map { $0.altitude }
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let minZ = zs.min() ?? 0
        let maxZ = zs.max() ?? 0

        let scaleX = 0.001
        let scaleY = 0.001
        let scaleZ = 0.001
        let offsetX = minX
        let offsetY = minY
        let offsetZ = minZ

        let originUTM = CoordinateFormatter.utm(for: request.originCoordinate)
        let wkt = utmWKT(zone: originUTM.zone, northernHemisphere: originUTM.hemisphere == "N") + "\0"
        let wktBytes = Array(wkt.utf8)

        let headerSize: UInt16 = 375
        let vlrHeaderSize = 54
        let offsetToPointData = UInt32(Int(headerSize) + vlrHeaderSize + wktBytes.count)
        // Point data record format 7 = format 6 plus 16-bit RGB.
        let pointRecordLength: UInt16 = 36
        let pointCount = UInt64(points.count)
        let legacyPointCount = UInt32(min(pointCount, UInt64(UInt32.max)))

        data.appendFixedASCII("LASF", length: 4)
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(16))
        data.appendLE(UInt32(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        for _ in 0..<8 { data.appendByte(0) }
        data.appendByte(1)
        data.appendByte(4)
        data.appendFixedASCII("FieldMapper iPhone", length: 32)
        data.appendFixedASCII("FieldMapper", length: 32)
        data.appendLE(UInt16(createdAt.dayOfYearUTC))
        data.appendLE(UInt16(createdAt.yearUTC))
        data.appendLE(headerSize)
        data.appendLE(offsetToPointData)
        data.appendLE(UInt32(1))
        data.appendByte(7)
        data.appendLE(pointRecordLength)
        data.appendLE(legacyPointCount)
        data.appendLE(legacyPointCount)
        for _ in 0..<4 { data.appendLE(UInt32(0)) }
        data.appendDouble(scaleX)
        data.appendDouble(scaleY)
        data.appendDouble(scaleZ)
        data.appendDouble(offsetX)
        data.appendDouble(offsetY)
        data.appendDouble(offsetZ)
        data.appendDouble(maxX)
        data.appendDouble(minX)
        data.appendDouble(maxY)
        data.appendDouble(minY)
        data.appendDouble(maxZ)
        data.appendDouble(minZ)
        data.appendLE(UInt64(0))
        data.appendLE(UInt64(0))
        data.appendLE(UInt32(0))
        data.appendLE(pointCount)
        data.appendLE(pointCount)
        for _ in 0..<14 { data.appendLE(UInt64(0)) }

        data.appendLE(UInt16(0))
        data.appendFixedASCII("LASF_Projection", length: 16)
        data.appendLE(UInt16(2112))
        data.appendLE(UInt16(min(wktBytes.count, Int(UInt16.max))))
        data.appendFixedASCII("WKT Coordinate System", length: 32)
        data.append(contentsOf: wktBytes.prefix(Int(UInt16.max)))

        for (index, point) in points.enumerated() {
            let xInt = scaledInt32(value: point.easting, offset: offsetX, scale: scaleX)
            let yInt = scaledInt32(value: point.northing, offset: offsetY, scale: scaleY)
            let zInt = scaledInt32(value: point.altitude, offset: offsetZ, scale: scaleZ)
            data.appendLE(xInt)
            data.appendLE(yInt)
            data.appendLE(zInt)
            data.appendLE(UInt16(0))
            data.appendByte(17)
            data.appendByte(0)
            data.appendByte(0)
            data.appendByte(0)
            data.appendLE(Int16(0))
            data.appendLE(UInt16(0))
            data.appendDouble(Double(index) / 10.0)
            // PDRF 7 RGB: 8-bit camera color scaled to 16-bit.
            data.appendLE(UInt16(point.red) * 257)
            data.appendLE(UInt16(point.green) * 257)
            data.appendLE(UInt16(point.blue) * 257)
        }

        return data
    }

    private static func scaledInt32(value: Double, offset: Double, scale: Double) -> Int32 {
        let scaled = ((value - offset) / scale).rounded()
        if scaled > Double(Int32.max) { return Int32.max }
        if scaled < Double(Int32.min) { return Int32.min }
        return Int32(scaled)
    }

    private static func utmWKT(zone: Int, northernHemisphere: Bool) -> String {
        let centralMeridian = Double(zone - 1) * 6.0 - 180.0 + 3.0
        let falseNorthing = northernHemisphere ? 0 : 10_000_000
        let epsg = (northernHemisphere ? 32600 : 32700) + zone
        let hemi = northernHemisphere ? "N" : "S"
        return "PROJCS[\"WGS 84 / UTM zone \(zone)\(hemi)\",GEOGCS[\"WGS 84\",DATUM[\"WGS_1984\",SPHEROID[\"WGS 84\",6378137,298.257223563]],PRIMEM[\"Greenwich\",0],UNIT[\"degree\",0.0174532925199433]],PROJECTION[\"Transverse_Mercator\"],PARAMETER[\"latitude_of_origin\",0],PARAMETER[\"central_meridian\",\(centralMeridian)],PARAMETER[\"scale_factor\",0.9996],PARAMETER[\"false_easting\",500000],PARAMETER[\"false_northing\",\(falseNorthing)],UNIT[\"metre\",1],AUTHORITY[\"EPSG\",\"\(epsg)\"]]"
    }
}

private extension Date {
    var yearUTC: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.year, from: self)
    }

    var dayOfYearUTC: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.ordinality(of: .day, in: .year, for: self) ?? 1
    }
}

private extension Data {
    mutating func appendByte(_ value: UInt8) {
        append(contentsOf: [value])
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendDouble(_ value: Double) {
        var number = value
        Swift.withUnsafeBytes(of: &number) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendFixedASCII(_ text: String, length: Int) {
        var bytes = Array(text.utf8.prefix(length))
        if bytes.count < length {
            bytes.append(contentsOf: repeatElement(0, count: length - bytes.count))
        }
        append(contentsOf: bytes)
    }
}

extension ARMeshGeometry {
    func vertex(at index: Int) -> SIMD3<Float> {
        let source = vertices
        let pointer = source.buffer.contents().advanced(by: source.offset + source.stride * index)
        let floats = pointer.assumingMemoryBound(to: Float.self)
        return SIMD3<Float>(floats[0], floats[1], floats[2])
    }

    func faceIndices(at faceIndex: Int) -> [UInt32] {
        let element = faces
        let indexCount = element.indexCountPerPrimitive
        let bytesPerIndex = element.bytesPerIndex
        let baseOffset = faceIndex * indexCount * bytesPerIndex
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)

        for i in 0..<indexCount {
            let pointer = element.buffer.contents().advanced(by: baseOffset + i * bytesPerIndex)
            switch bytesPerIndex {
            case 2:
                indices.append(UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee))
            case 4:
                indices.append(pointer.assumingMemoryBound(to: UInt32.self).pointee)
            default:
                break
            }
        }
        return indices
    }
}


// MARK: - GeoTIFF reading (RVT imports + USGS 3DEP elevation)

/// A decoded (Geo)TIFF: either a single-band float raster (elevation or
/// an RVT float visualization) or an RGB(A) image, plus its WGS84
/// extent when the GeoTIFF tags resolve to a supported CRS.
struct GeoTIFFImage {
    let width: Int
    let height: Int
    /// Single-band values (row-major, top row first). Nil for RGB files.
    let floatValues: [Float]?
    /// RGBA bytes (4 per pixel) for RGB/RGBA files. Nil for single-band.
    let rgba: [UInt8]?
    let noDataValue: Float?
    /// Corner extent in WGS84 when georeferencing was readable.
    let extent: GeoExtent?
}

enum GeoTIFFError: LocalizedError {
    case notATIFF
    case unsupported(String)
    case noGeoreference

    var errorDescription: String? {
        switch self {
        case .notATIFF:
            return "That file is not a readable TIFF."
        case .unsupported(let what):
            return "Unsupported TIFF variant: \(what)."
        case .noGeoreference:
            return "No usable GeoTIFF georeferencing was found. Export the file in EPSG:4326 (WGS84) or WGS84/NAD83 UTM and try again."
        }
    }
}

enum GeoTIFFReader {
    static func read(data: Data) throws -> GeoTIFFImage {
        let reader = try TIFFByteReader(data: data)
        let tags = try reader.readIFD()

        guard let width = tags.firstInt(256), let height = tags.firstInt(257),
              width > 0, height > 0, width * height <= 40_000_000 else {
            throw GeoTIFFError.unsupported("missing or oversized dimensions")
        }

        let samplesPerPixel = tags.firstInt(277) ?? 1
        let bitsPerSample = tags.ints(258) ?? [8]
        let bits = bitsPerSample.first ?? 8
        let compression = tags.firstInt(259) ?? 1
        let predictor = tags.firstInt(317) ?? 1
        let sampleFormats = tags.ints(339) ?? [1]
        let sampleFormat = sampleFormats.first ?? 1
        let planarConfig = tags.firstInt(284) ?? 1
        guard planarConfig == 1 else { throw GeoTIFFError.unsupported("planar configuration 2") }

        let bytesPerSample = bits / 8
        guard bytesPerSample >= 1 else { throw GeoTIFFError.unsupported("\(bits)-bit samples") }
        let bytesPerPixel = bytesPerSample * samplesPerPixel
        let rowBytes = width * bytesPerPixel

        // Assemble the full decompressed raster, strip- or tile-organized.
        var raster = [UInt8](repeating: 0, count: rowBytes * height)

        if let tileOffsets = tags.ints(324), let tileCounts = tags.ints(325),
           let tileWidth = tags.firstInt(322), let tileLength = tags.firstInt(323),
           tileWidth > 0, tileLength > 0 {
            let tilesAcross = (width + tileWidth - 1) / tileWidth
            let tileRowBytes = tileWidth * bytesPerPixel
            for (index, offset) in tileOffsets.enumerated() {
                guard index < tileCounts.count else { break }
                let compressed = try reader.bytes(at: offset, count: tileCounts[index])
                var tile = try decompress(compressed, method: compression,
                                          expectedSize: tileRowBytes * tileLength)
                applyPredictor(&tile, predictor: predictor, width: tileWidth,
                               rows: tileLength, samplesPerPixel: samplesPerPixel,
                               bytesPerSample: bytesPerSample)
                let tileX = (index % tilesAcross) * tileWidth
                let tileY = (index / tilesAcross) * tileLength
                let copyCols = min(tileWidth, width - tileX)
                guard copyCols > 0 else { continue }
                let copyRows = min(tileLength, height - tileY)
                for row in 0..<max(0, copyRows) {
                    let src = row * tileRowBytes
                    let dst = (tileY + row) * rowBytes + tileX * bytesPerPixel
                    let count = copyCols * bytesPerPixel
                    if src + count <= tile.count, dst + count <= raster.count {
                        raster.replaceSubrange(dst..<(dst + count), with: tile[src..<(src + count)])
                    }
                }
            }
        } else if let stripOffsets = tags.ints(273), let stripCounts = tags.ints(279) {
            let rowsPerStrip = tags.firstInt(278) ?? height
            var destinationRow = 0
            for (index, offset) in stripOffsets.enumerated() {
                guard index < stripCounts.count, destinationRow < height else { break }
                let rowsInStrip = min(rowsPerStrip, height - destinationRow)
                let compressed = try reader.bytes(at: offset, count: stripCounts[index])
                var strip = try decompress(compressed, method: compression,
                                           expectedSize: rowBytes * rowsInStrip)
                applyPredictor(&strip, predictor: predictor, width: width,
                               rows: rowsInStrip, samplesPerPixel: samplesPerPixel,
                               bytesPerSample: bytesPerSample)
                let dst = destinationRow * rowBytes
                let count = min(strip.count, rowBytes * rowsInStrip)
                if dst + count <= raster.count {
                    raster.replaceSubrange(dst..<(dst + count), with: strip[0..<count])
                }
                destinationRow += rowsInStrip
            }
        } else {
            throw GeoTIFFError.unsupported("no strip or tile layout")
        }

        // No-data value (GDAL convention: ASCII tag 42113).
        var noData: Float?
        if let noDataText = tags.ascii(42113), let value = Float(noDataText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            noData = value
        }

        // Pixel decode.
        var floatValues: [Float]?
        var rgba: [UInt8]?

        if samplesPerPixel == 1 {
            var values = [Float](repeating: 0, count: width * height)
            switch (sampleFormat, bits) {
            case (3, 32):
                raster.withUnsafeBytes { buffer in
                    for index in 0..<(width * height) {
                        let raw = buffer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                        let bits = reader.isLittleEndian ? UInt32(littleEndian: raw) : UInt32(bigEndian: raw)
                        values[index] = Float(bitPattern: bits)
                    }
                }
            case (_, 16):
                raster.withUnsafeBytes { buffer in
                    for index in 0..<(width * height) {
                        let raw = buffer.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)
                        let value = reader.isLittleEndian ? UInt16(littleEndian: raw) : UInt16(bigEndian: raw)
                        if sampleFormat == 2 {
                            values[index] = Float(Int16(bitPattern: value))
                        } else {
                            values[index] = Float(value)
                        }
                    }
                }
            case (_, 8):
                for index in 0..<(width * height) {
                    values[index] = Float(raster[index])
                }
            default:
                throw GeoTIFFError.unsupported("\(bits)-bit sample format \(sampleFormat)")
            }
            floatValues = values
        } else if samplesPerPixel >= 3, bits == 8 {
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for index in 0..<(width * height) {
                let src = index * bytesPerPixel
                let dst = index * 4
                pixels[dst] = raster[src]
                pixels[dst + 1] = raster[src + 1]
                pixels[dst + 2] = raster[src + 2]
                if samplesPerPixel >= 4 { pixels[dst + 3] = raster[src + 3] }
            }
            rgba = pixels
        } else {
            throw GeoTIFFError.unsupported("\(samplesPerPixel) samples at \(bits) bits")
        }

        let extent = try? georeference(tags: tags, width: width, height: height)

        return GeoTIFFImage(
            width: width,
            height: height,
            floatValues: floatValues,
            rgba: rgba,
            noDataValue: noData,
            extent: extent
        )
    }

    // MARK: Georeferencing

    private static func georeference(tags: TIFFTags, width: Int, height: Int) throws -> GeoExtent {
        // Pixel -> model transform from either the affine matrix or
        // tiepoint + pixel scale.
        var toModel: ((Double, Double) -> (x: Double, y: Double))?

        if let matrix = tags.doubles(34264), matrix.count >= 16 {
            toModel = { px, py in
                (matrix[0] * px + matrix[1] * py + matrix[3],
                 matrix[4] * px + matrix[5] * py + matrix[7])
            }
        } else if let tie = tags.doubles(33922), tie.count >= 6,
                  let scale = tags.doubles(33550), scale.count >= 2 {
            let i = tie[0], j = tie[1], modelX = tie[3], modelY = tie[4]
            toModel = { px, py in
                (modelX + (px - i) * scale[0],
                 modelY - (py - j) * scale[1])
            }
        }
        guard let transform = toModel else { throw GeoTIFFError.noGeoreference }

        // CRS from the GeoKey directory.
        var modelType = 0
        var geographicCRS = 0
        var projectedCRS = 0
        if let keys = tags.ints(34735), keys.count >= 4 {
            let keyCount = keys[3]
            for keyIndex in 0..<keyCount {
                let base = 4 + keyIndex * 4
                guard base + 3 < keys.count else { break }
                let keyID = keys[base]
                let value = keys[base + 3]
                switch keyID {
                case 1024: modelType = value
                case 2048: geographicCRS = value
                case 3072: projectedCRS = value
                default: break
                }
            }
        }

        let corners = [(0.0, 0.0), (Double(width), 0.0),
                       (0.0, Double(height)), (Double(width), Double(height))]
        var coordinates: [CLLocationCoordinate2D] = []

        if modelType == 2 || (projectedCRS == 0 && (geographicCRS == 4326 || geographicCRS == 4269 || geographicCRS == 0)) {
            // Geographic: model units are already degrees.
            for corner in corners {
                let model = transform(corner.0, corner.1)
                coordinates.append(CLLocationCoordinate2D(latitude: model.y, longitude: model.x))
            }
        } else if (32601...32660).contains(projectedCRS) || (32701...32760).contains(projectedCRS)
                    || (26901...26923).contains(projectedCRS) || (26701...26722).contains(projectedCRS) {
            // WGS84, NAD83, or NAD27 UTM (datum differences are well under
            // a pixel at survey scale, so all treated as UTM-on-WGS84).
            let northern = !(32701...32760).contains(projectedCRS)
            let zone: Int
            if (32701...32760).contains(projectedCRS) { zone = projectedCRS - 32700 }
            else if (32601...32660).contains(projectedCRS) { zone = projectedCRS - 32600 }
            else if (26901...26923).contains(projectedCRS) { zone = projectedCRS - 26900 }
            else { zone = projectedCRS - 26700 }
            for corner in corners {
                let model = transform(corner.0, corner.1)
                coordinates.append(CoordinateFormatter.coordinate(
                    fromUTMZone: zone,
                    northernHemisphere: northern,
                    easting: model.x,
                    northing: model.y
                ))
            }
        } else {
            // Unknown/absent CRS: infer from coordinate magnitudes. If the
            // model coordinates fall in degree range, treat as geographic;
            // otherwise fail clearly so the user can reproject.
            let sample = transform(Double(width) / 2, Double(height) / 2)
            let looksGeographic = abs(sample.x) <= 180 && abs(sample.y) <= 90
            if looksGeographic {
                for corner in corners {
                    let model = transform(corner.0, corner.1)
                    coordinates.append(CLLocationCoordinate2D(latitude: model.y, longitude: model.x))
                }
            } else {
                throw GeoTIFFError.unsupported("a projected CRS the app does not recognize. Reproject to EPSG:4326 (WGS84) or a WGS84/NAD83 UTM zone")
            }
        }

        guard let minLat = coordinates.map(\.latitude).min(),
              let maxLat = coordinates.map(\.latitude).max(),
              let minLon = coordinates.map(\.longitude).min(),
              let maxLon = coordinates.map(\.longitude).max() else {
            throw GeoTIFFError.noGeoreference
        }
        let extent = GeoExtent(minLatitude: minLat, maxLatitude: maxLat,
                               minLongitude: minLon, maxLongitude: maxLon)
        guard extent.isValid else { throw GeoTIFFError.noGeoreference }
        return extent
    }

    // MARK: Decompression

    private static func decompress(_ input: [UInt8], method: Int, expectedSize: Int) throws -> [UInt8] {
        switch method {
        case 1:
            return input
        case 5:
            return try lzwDecode(input, expectedSize: expectedSize)
        case 8, 32946:
            return try zlibDecode(input, expectedSize: expectedSize)
        case 32773:
            return packBitsDecode(input, expectedSize: expectedSize)
        default:
            throw GeoTIFFError.unsupported("compression \(method)")
        }
    }

    private static func zlibDecode(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        // TIFF Deflate strips are zlib streams: skip the 2-byte zlib
        // header and inflate the raw deflate payload.
        guard input.count > 2 else { throw GeoTIFFError.unsupported("empty deflate strip") }
        let payload = Array(input.dropFirst(2))
        var output = [UInt8](repeating: 0, count: max(expectedSize, 64))
        let written = payload.withUnsafeBufferPointer { source -> Int in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, destination.count,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw GeoTIFFError.unsupported("deflate decode failed") }
        return Array(output.prefix(written))
    }

    private static func packBitsDecode(_ input: [UInt8], expectedSize: Int) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(expectedSize)
        var index = 0
        while index < input.count, output.count < expectedSize {
            let control = Int8(bitPattern: input[index])
            index += 1
            if control >= 0 {
                let count = Int(control) + 1
                let end = min(index + count, input.count)
                output.append(contentsOf: input[index..<end])
                index = end
            } else if control != -128 {
                let count = 1 - Int(control)
                if index < input.count {
                    output.append(contentsOf: repeatElement(input[index], count: count))
                    index += 1
                }
            }
        }
        return output
    }

    /// TIFF-variant LZW (MSB-first codes, early code-size change).
    private static func lzwDecode(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        let clearCode = 256
        let endCode = 257
        var output: [UInt8] = []
        output.reserveCapacity(expectedSize)

        var dictionary: [[UInt8]] = []
        func resetDictionary() {
            dictionary = (0..<256).map { [UInt8($0)] }
            dictionary.append([])  // clear
            dictionary.append([])  // end
        }
        resetDictionary()

        var bitBuffer = 0
        var bitCount = 0
        var codeSize = 9
        var byteIndex = 0
        var previous: [UInt8]?

        func nextCode() -> Int? {
            while bitCount < codeSize {
                guard byteIndex < input.count else { return nil }
                bitBuffer = (bitBuffer << 8) | Int(input[byteIndex])
                byteIndex += 1
                bitCount += 8
            }
            let code = (bitBuffer >> (bitCount - codeSize)) & ((1 << codeSize) - 1)
            bitCount -= codeSize
            return code
        }

        while let code = nextCode() {
            if code == clearCode {
                resetDictionary()
                codeSize = 9
                previous = nil
                continue
            }
            if code == endCode { break }

            var entry: [UInt8]
            if code < dictionary.count, code != clearCode, code != endCode {
                entry = dictionary[code]
            } else if let previous = previous, code == dictionary.count {
                entry = previous + [previous[0]]
            } else {
                throw GeoTIFFError.unsupported("corrupt LZW stream")
            }

            output.append(contentsOf: entry)
            if let previous = previous {
                dictionary.append(previous + [entry[0]])
            }
            previous = entry

            // TIFF early change: bump the code size one entry early.
            if dictionary.count >= (1 << codeSize) - 1, codeSize < 12 {
                codeSize += 1
            }
            if output.count >= expectedSize { break }
        }
        return output
    }

    // MARK: Predictors

    private static func applyPredictor(
        _ buffer: inout [UInt8],
        predictor: Int,
        width: Int,
        rows: Int,
        samplesPerPixel: Int,
        bytesPerSample: Int
    ) {
        let rowBytes = width * samplesPerPixel * bytesPerSample
        guard buffer.count >= rowBytes else { return }

        switch predictor {
        case 2 where bytesPerSample == 1:
            for row in 0..<rows {
                let base = row * rowBytes
                guard base + rowBytes <= buffer.count else { break }
                for column in samplesPerPixel..<rowBytes {
                    buffer[base + column] = buffer[base + column] &+ buffer[base + column - samplesPerPixel]
                }
            }
        case 2 where bytesPerSample == 2:
            for row in 0..<rows {
                let base = row * rowBytes
                guard base + rowBytes <= buffer.count else { break }
                let sampleStride = samplesPerPixel
                var values = [UInt16](repeating: 0, count: width * samplesPerPixel)
                for index in 0..<values.count {
                    let offset = base + index * 2
                    values[index] = UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
                }
                for index in sampleStride..<values.count {
                    values[index] = values[index] &+ values[index - sampleStride]
                }
                for index in 0..<values.count {
                    let offset = base + index * 2
                    buffer[offset] = UInt8(values[index] & 0xFF)
                    buffer[offset + 1] = UInt8(values[index] >> 8)
                }
            }
        case 3 where bytesPerSample == 4:
            // Floating-point predictor: per row, undo byte differencing,
            // then re-interleave the byte planes into native floats.
            let floatsPerRow = width * samplesPerPixel
            for row in 0..<rows {
                let base = row * rowBytes
                guard base + rowBytes <= buffer.count else { break }
                for column in 1..<rowBytes {
                    buffer[base + column] = buffer[base + column] &+ buffer[base + column - 1]
                }
                var reordered = [UInt8](repeating: 0, count: rowBytes)
                for floatIndex in 0..<floatsPerRow {
                    for byteIndex in 0..<4 {
                        // Planes are stored most-significant first.
                        reordered[floatIndex * 4 + (3 - byteIndex)] =
                            buffer[base + byteIndex * floatsPerRow + floatIndex]
                    }
                }
                buffer.replaceSubrange(base..<(base + rowBytes), with: reordered)
            }
        default:
            break
        }
    }
}

/// Minimal endian-aware TIFF structure reader.
private final class TIFFByteReader {
    private let data: Data
    let isLittleEndian: Bool
    private let firstIFDOffset: Int

    init(data: Data) throws {
        self.data = data
        guard data.count > 8 else { throw GeoTIFFError.notATIFF }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        if b0 == 0x49, b1 == 0x49 {
            isLittleEndian = true
        } else if b0 == 0x4D, b1 == 0x4D {
            isLittleEndian = false
        } else {
            throw GeoTIFFError.notATIFF
        }
        let magic = Self.readU16(data, 2, isLittleEndian)
        guard magic == 42 else { throw GeoTIFFError.notATIFF }
        firstIFDOffset = Int(Self.readU32(data, 4, isLittleEndian))
    }

    private static func readU16(_ data: Data, _ offset: Int, _ little: Bool) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        let a = UInt16(data[data.startIndex + offset])
        let b = UInt16(data[data.startIndex + offset + 1])
        return little ? (b << 8) | a : (a << 8) | b
    }

    private static func readU32(_ data: Data, _ offset: Int, _ little: Bool) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        let bytes = (0..<4).map { UInt32(data[data.startIndex + offset + $0]) }
        return little
            ? bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
            : (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
    }

    func u16(_ offset: Int) -> UInt16 { Self.readU16(data, offset, isLittleEndian) }
    func u32(_ offset: Int) -> UInt32 { Self.readU32(data, offset, isLittleEndian) }

    func bytes(at offset: Int, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw GeoTIFFError.unsupported("out-of-range data block")
        }
        return [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
    }

    func readIFD() throws -> TIFFTags {
        var tags = TIFFTags()
        let entryCount = Int(u16(firstIFDOffset))
        for entryIndex in 0..<entryCount {
            let base = firstIFDOffset + 2 + entryIndex * 12
            guard base + 12 <= data.count else { break }
            let tag = Int(u16(base))
            let type = Int(u16(base + 2))
            let count = Int(u32(base + 4))

            let typeSize: Int
            switch type {
            case 1, 2, 6, 7: typeSize = 1
            case 3, 8: typeSize = 2
            case 4, 9, 11: typeSize = 4
            case 5, 10, 12: typeSize = 8
            default: continue
            }

            let totalSize = typeSize * count
            let valueOffset = totalSize <= 4 ? base + 8 : Int(u32(base + 8))
            guard valueOffset + totalSize <= data.count, count <= 200_000 else { continue }

            switch type {
            case 2:
                if let raw = try? bytes(at: valueOffset, count: count) {
                    tags.asciiValues[tag] = String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""
                }
            case 3, 8:
                tags.intValues[tag] = (0..<count).map { Int(u16(valueOffset + $0 * 2)) }
            case 1, 6, 7:
                tags.intValues[tag] = (0..<count).map { Int(data[data.startIndex + valueOffset + $0]) }
            case 4, 9:
                tags.intValues[tag] = (0..<count).map { Int(u32(valueOffset + $0 * 4)) }
            case 11:
                tags.doubleValues[tag] = (0..<count).map { Double(Float(bitPattern: u32(valueOffset + $0 * 4))) }
            case 12:
                tags.doubleValues[tag] = (0..<count).map { index -> Double in
                    let low = UInt64(u32(valueOffset + index * 8))
                    let high = UInt64(u32(valueOffset + index * 8 + 4))
                    let bits = isLittleEndian ? (high << 32) | low : (low << 32) | high
                    return Double(bitPattern: bits)
                }
            case 5, 10:
                tags.doubleValues[tag] = (0..<count).map { index -> Double in
                    let numerator = Double(u32(valueOffset + index * 8))
                    let denominator = Double(u32(valueOffset + index * 8 + 4))
                    return denominator == 0 ? 0 : numerator / denominator
                }
            default:
                break
            }
        }
        return tags
    }
}

private struct TIFFTags {
    var intValues: [Int: [Int]] = [:]
    var doubleValues: [Int: [Double]] = [:]
    var asciiValues: [Int: String] = [:]

    func firstInt(_ tag: Int) -> Int? { intValues[tag]?.first }
    func ints(_ tag: Int) -> [Int]? { intValues[tag] }
    func doubles(_ tag: Int) -> [Double]? { doubleValues[tag] }
    func ascii(_ tag: Int) -> String? { asciiValues[tag] }
}


// MARK: - LiDAR terrain visualization (RVT-style, on-device)

/// A georeferenced elevation grid (DEM), downloaded from USGS 3DEP or
/// decoded from a GeoTIFF. Doubles as the offline elevation source for
/// the crosshair readout and feature stamping.
struct DEMGrid: Codable {
    let width: Int
    let height: Int
    /// Row-major elevations in meters; row 0 is the NORTH edge.
    let values: [Float]
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    var extent: GeoExtent {
        GeoExtent(minLatitude: minLatitude, maxLatitude: maxLatitude,
                  minLongitude: minLongitude, maxLongitude: maxLongitude)
    }

    /// Approximate ground resolution in meters per cell.
    var cellSizeMeters: (x: Double, y: Double) {
        let midLatitude = (minLatitude + maxLatitude) / 2
        let metersX = (maxLongitude - minLongitude) * 111_320 * cos(midLatitude * .pi / 180)
        let metersY = (maxLatitude - minLatitude) * 110_540
        return (metersX / Double(max(1, width - 1)), metersY / Double(max(1, height - 1)))
    }

    /// Bilinear elevation at a coordinate, nil outside or on no-data.
    func elevation(at coordinate: CLLocationCoordinate2D) -> Double? {
        guard maxLongitude > minLongitude, maxLatitude > minLatitude else { return nil }
        let fx = (coordinate.longitude - minLongitude) / (maxLongitude - minLongitude) * Double(width - 1)
        let fy = (maxLatitude - coordinate.latitude) / (maxLatitude - minLatitude) * Double(height - 1)
        guard fx >= 0, fy >= 0, fx <= Double(width - 1), fy <= Double(height - 1) else { return nil }

        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))

        let v00 = values[y0 * width + x0]
        let v10 = values[y0 * width + x1]
        let v01 = values[y1 * width + x0]
        let v11 = values[y1 * width + x1]
        let candidates = [v00, v10, v01, v11]
        guard candidates.allSatisfy({ $0.isFinite && $0 > -10_000 }) else { return nil }

        let top = v00 + (v10 - v00) * tx
        let bottom = v01 + (v11 - v01) * tx
        return Double(top + (bottom - top) * ty)
    }

    /// Downsampled copy for compact on-disk storage.
    func downsampled(maxDimension: Int) -> DEMGrid {
        guard width > maxDimension || height > maxDimension else { return self }
        let scale = Double(maxDimension) / Double(max(width, height))
        let newWidth = max(2, Int(Double(width) * scale))
        let newHeight = max(2, Int(Double(height) * scale))
        var newValues = [Float](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let sourceY = min(height - 1, Int(Double(y) / Double(newHeight - 1) * Double(height - 1)))
            for x in 0..<newWidth {
                let sourceX = min(width - 1, Int(Double(x) / Double(newWidth - 1) * Double(width - 1)))
                newValues[y * newWidth + x] = values[sourceY * width + sourceX]
            }
        }
        return DEMGrid(width: newWidth, height: newHeight, values: newValues,
                       minLatitude: minLatitude, maxLatitude: maxLatitude,
                       minLongitude: minLongitude, maxLongitude: maxLongitude)
    }

    /// Crop to a sub-extent (clamped to this grid's bounds), preserving
    /// the source resolution. Returns nil if the overlap is too small.
    func cropped(to target: GeoExtent) -> DEMGrid? {
        guard maxLongitude > minLongitude, maxLatitude > minLatitude else { return nil }
        let lonMin = max(minLongitude, target.minLongitude)
        let lonMax = min(maxLongitude, target.maxLongitude)
        let latMin = max(minLatitude, target.minLatitude)
        let latMax = min(maxLatitude, target.maxLatitude)
        guard lonMax > lonMin, latMax > latMin else { return nil }

        func col(_ lon: Double) -> Int {
            Int(((lon - minLongitude) / (maxLongitude - minLongitude) * Double(width - 1)).rounded())
        }
        // Row 0 = north (maxLatitude).
        func row(_ lat: Double) -> Int {
            Int(((maxLatitude - lat) / (maxLatitude - minLatitude) * Double(height - 1)).rounded())
        }
        let x0 = max(0, min(width - 1, col(lonMin)))
        let x1 = max(0, min(width - 1, col(lonMax)))
        let y0 = max(0, min(height - 1, row(latMax)))   // north
        let y1 = max(0, min(height - 1, row(latMin)))   // south
        let newWidth = x1 - x0 + 1
        let newHeight = y1 - y0 + 1
        guard newWidth >= 4, newHeight >= 4 else { return nil }

        var newValues = [Float](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let srcRow = (y0 + y) * width
            for x in 0..<newWidth {
                newValues[y * newWidth + x] = values[srcRow + x0 + x]
            }
        }
        // Recover the exact geographic bounds of the cropped cells.
        let newMinLon = minLongitude + Double(x0) / Double(width - 1) * (maxLongitude - minLongitude)
        let newMaxLon = minLongitude + Double(x1) / Double(width - 1) * (maxLongitude - minLongitude)
        let newMaxLat = maxLatitude - Double(y0) / Double(height - 1) * (maxLatitude - minLatitude)
        let newMinLat = maxLatitude - Double(y1) / Double(height - 1) * (maxLatitude - minLatitude)
        return DEMGrid(width: newWidth, height: newHeight, values: newValues,
                       minLatitude: newMinLat, maxLatitude: newMaxLat,
                       minLongitude: newMinLon, maxLongitude: newMaxLon)
    }
}

/// Per-map persisted elevation grids (compact, for the crosshair
/// readout and feature elevation stamping on any map).
enum ElevationGridStore {
    private static func folderURL() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("ElevationGrids", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func fileURL(forMapNamed mapName: String) throws -> URL {
        let safe = mapName.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        return try folderURL().appendingPathComponent("\(safe.isEmpty ? "map" : safe).elevation.json")
    }

    static func save(_ grid: DEMGrid, forMapNamed mapName: String) {
        guard let url = try? fileURL(forMapNamed: mapName),
              let data = try? JSONEncoder().encode(grid.downsampled(maxDimension: 280)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load(forMapNamed mapName: String) -> DEMGrid? {
        guard let url = try? fileURL(forMapNamed: mapName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DEMGrid.self, from: data)
    }
}

enum DEMDownloadError: LocalizedError {
    case badResponse
    case noCoverage

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "USGS 3DEP did not return readable elevation data. Check the connection and try a smaller area."
        case .noCoverage:
            return "USGS 3DEP has no elevation coverage for that area (coverage is United States only)."
        }
    }
}

enum DEMDownloader {
    /// Fetch a Float32 DEM for the extent from the USGS 3DEP
    /// ImageServer (nationwide lidar-derived elevation).
    static func fetch3DEP(extent: GeoExtent, longEdgePixels: Int) async throws -> DEMGrid {
        let midLatitude = (extent.minLatitude + extent.maxLatitude) / 2
        let metersX = (extent.maxLongitude - extent.minLongitude) * 111_320 * cos(midLatitude * .pi / 180)
        let metersY = (extent.maxLatitude - extent.minLatitude) * 110_540
        let aspect = max(0.1, min(10, metersX / max(1, metersY)))

        let longEdge = max(64, min(4096, longEdgePixels))
        let width = aspect >= 1 ? longEdge : max(64, Int(Double(longEdge) * aspect))
        let height = aspect >= 1 ? max(64, Int(Double(longEdge) / aspect)) : longEdge

        var components = URLComponents(string: "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage")!
        components.queryItems = [
            URLQueryItem(name: "bbox", value: "\(extent.minLongitude),\(extent.minLatitude),\(extent.maxLongitude),\(extent.maxLatitude)"),
            URLQueryItem(name: "bboxSR", value: "4326"),
            URLQueryItem(name: "imageSR", value: "4326"),
            URLQueryItem(name: "size", value: "\(width),\(height)"),
            URLQueryItem(name: "format", value: "tiff"),
            URLQueryItem(name: "pixelType", value: "F32"),
            // Bilinear resampling (not nearest/natural-neighbour) for
            // smooth elevation; the exact bbox is honoured so the grid
            // lines up cell-for-cell with the requested extent.
            URLQueryItem(name: "interpolation", value: "RSP_BilinearInterpolation"),
            URLQueryItem(name: "adjustAspectRatio", value: "false"),
            URLQueryItem(name: "f", value: "image")
        ]
        guard let url = components.url else { throw DEMDownloadError.badResponse }

        var request = URLRequest(url: url)
        request.setValue("AvenzaStyleFieldMapper/1.0 field survey app", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DEMDownloadError.badResponse
        }

        let tiff: GeoTIFFImage
        do {
            tiff = try GeoTIFFReader.read(data: data)
        } catch {
            throw DEMDownloadError.badResponse
        }
        guard var values = tiff.floatValues else { throw DEMDownloadError.badResponse }

        // Treat the service no-data sentinel and absurd values as holes,
        // then check there is real terrain in the result.
        let noData = tiff.noDataValue
        var validCount = 0
        for index in values.indices {
            let value = values[index]
            if !value.isFinite || value < -10_500 || value > 9_000 || (noData != nil && value == noData!) {
                values[index] = .nan
            } else {
                validCount += 1
            }
        }
        guard validCount > values.count / 20 else { throw DEMDownloadError.noCoverage }

        // Fill small holes with the nearest valid neighbor along rows.
        for row in 0..<tiff.height {
            let base = row * tiff.width
            var lastValid: Float?
            for column in 0..<tiff.width {
                if values[base + column].isNaN {
                    if let lastValid = lastValid { values[base + column] = lastValid }
                } else {
                    lastValid = values[base + column]
                }
            }
            var nextValid: Float?
            for column in stride(from: tiff.width - 1, through: 0, by: -1) {
                if values[base + column].isNaN {
                    if let nextValid = nextValid { values[base + column] = nextValid }
                } else {
                    nextValid = values[base + column]
                }
            }
        }
        let fallback = values.first(where: { !$0.isNaN }) ?? 0
        for index in values.indices where values[index].isNaN {
            values[index] = fallback
        }

        return DEMGrid(width: tiff.width, height: tiff.height, values: values,
                       minLatitude: extent.minLatitude, maxLatitude: extent.maxLatitude,
                       minLongitude: extent.minLongitude, maxLongitude: extent.maxLongitude)
    }
}

// MARK: RVT-style visualization kinds and parameters

enum TerrainVisualizationKind: String, CaseIterable, Identifiable {
    case vatHillshade
    case multiScaleTopographicIndex
    case mstiVatComposite
    case multiHillshade
    case customHillshade
    case svf
    case svfHillshade
    case openness
    case localRelief
    case slope

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vatHillshade: return "VAT Hillshade (RVT Blend)"
        case .multiScaleTopographicIndex: return "Multi-Scale Topographic Index"
        case .mstiVatComposite: return "MSTI × VAT Composite"
        case .multiHillshade: return "Multidirectional Hillshade"
        case .customHillshade: return "Custom Hillshade"
        case .svf: return "Sky-View Factor"
        case .svfHillshade: return "SVF × Hillshade Blend"
        case .openness: return "Positive Openness"
        case .localRelief: return "Local Relief Model"
        case .slope: return "Slope"
        }
    }

    var subtitle: String {
        switch self {
        case .vatHillshade:
            return "Archaeology-focused VAT/RVT blend: multidirectional hillshade, sky-view contrast, local relief texture, and slope contrast."
        case .multiScaleTopographicIndex:
            return "Multi-scale local topographic position/index. Combines several relief radii so small mounds, ditches, berms, and low platforms remain visible without choosing only one scale."
        case .mstiVatComposite:
            return "Multiplies the Multi-Scale Topographic Index into the VAT blend. This is useful for Maya mound/terrace detection because VAT gives shaded terrain context while MSTI boosts repeated microtopography."
        case .multiHillshade:
            return "Hillshades from several sun directions averaged — no direction bias, the standard first look."
        case .customHillshade:
            return "Single sun direction you choose (azimuth, altitude, vertical exaggeration)."
        case .svf:
            return "How much sky each cell sees. Depressions and ditches darken; mounds brighten. RVT's signature visualization."
        case .svfHillshade:
            return "Sky-view factor multiplied over a multidirectional hillshade — the classic archaeological prospection blend."
        case .openness:
            return "Mean horizon angle. Like SVF but emphasizes convexity; great for berms and lynchets."
        case .localRelief:
            return "Elevation minus its smoothed trend. Subtle mounds red, depressions blue, regardless of slope position."
        case .slope:
            return "Steepness in gray (steeper = darker). Terraces and scarps stand out."
        }
    }

    var usesAzimuth: Bool { self == .customHillshade }
    var usesDirections: Bool {
        self == .multiHillshade || self == .svf || self == .svfHillshade
        || self == .openness || self == .vatHillshade || self == .mstiVatComposite
    }
    var usesRadius: Bool {
        self == .svf || self == .svfHillshade || self == .openness
        || self == .vatHillshade || self == .multiScaleTopographicIndex || self == .mstiVatComposite
    }
    var usesLRMRadius: Bool { self == .localRelief || self == .vatHillshade || self == .mstiVatComposite }
    var usesHillshadeParameters: Bool {
        self == .customHillshade || self == .multiHillshade || self == .svfHillshade
        || self == .vatHillshade || self == .mstiVatComposite
    }

    /// Multi-Scale Topographic Index uses the radius slider as its largest
    /// local-relief scale instead of a sky-view horizon search.
    var usesMSTI: Bool { self == .multiScaleTopographicIndex || self == .mstiVatComposite }

    /// MSTI × VAT has a second multiply-strength control.
    var usesMSTIBlend: Bool { self == .mstiVatComposite }

    /// Local Relief renders as a diverging color image; everything else
    /// is grayscale. Used to pick the overlay blend mode.
    var producesColorImage: Bool { self == .localRelief }

    /// SVF, openness, and MSTI can use the warm archaeological color ramp.
    var supportsWarmRamp: Bool { self == .svf || self == .openness || self == .multiScaleTopographicIndex }

    /// Whether the SVF×hillshade / VAT blend control applies.
    var usesHillshadeBlend: Bool { self == .svfHillshade || self == .vatHillshade || self == .mstiVatComposite }
}

struct TerrainVizParameters: Equatable {
    var azimuthDegrees: Double = 315
    var altitudeDegrees: Double = 45
    var verticalExaggeration: Double = 1.0
    var directions: Int = 16
    var radiusMeters: Double = 10
    var lrmRadiusMeters: Double = 20
    /// Output contrast/gamma. <1 brightens midtones, >1 deepens shadows.
    var gamma: Double = 1.0
    /// For SVF×Hillshade and VAT: how strongly the hillshade darkens the
    /// sky-view base (0 = pure SVF, 1 = full multiply).
    var hillshadeBlend: Double = 0.5
    /// For MSTI × VAT: how strongly the Multi-Scale Topographic Index
    /// multiplies into the VAT visualization (0 = VAT only, 1 = full MSTI multiply).
    var mstiBlend: Double = 0.65
    /// Color ramp for SVF / openness / MSTI: false = grayscale, true = warm
    /// archaeological ramp (dark red lows to pale highs).
    var warmColorRamp: Bool = false

    /// Reasonable defaults tuned per visualization.
    static func defaults(for kind: TerrainVisualizationKind) -> TerrainVizParameters {
        var p = TerrainVizParameters()
        switch kind {
        case .svf, .openness:
            p.radiusMeters = 10
        case .multiScaleTopographicIndex:
            p.radiusMeters = 30
            p.gamma = 1.1
        case .svfHillshade, .vatHillshade:
            p.radiusMeters = 10
            p.hillshadeBlend = 0.55
        case .mstiVatComposite:
            p.radiusMeters = 30
            p.lrmRadiusMeters = 20
            p.hillshadeBlend = 0.55
            p.mstiBlend = 0.65
            p.gamma = 1.05
        case .localRelief:
            p.lrmRadiusMeters = 20
        case .customHillshade, .multiHillshade:
            p.altitudeDegrees = 45
        case .slope:
            break
        }
        return p
    }
}

enum TerrainRenderer {
    /// Render an RVT-style visualization of the DEM to an image.
    static func render(
        kind: TerrainVisualizationKind,
        dem: DEMGrid,
        parameters: TerrainVizParameters
    ) -> UIImage? {
        let width = dem.width
        let height = dem.height
        guard width > 2, height > 2 else { return nil }
        let cell = dem.cellSizeMeters
        let z = Float(parameters.verticalExaggeration)

        var gray: [Float]
        var rgba: [UInt8]?

        switch kind {
        case .vatHillshade:
            gray = vatBlend(dem: dem, parameters: parameters, z: z, cell: cell)
        case .multiScaleTopographicIndex:
            gray = multiScaleTopographicIndex(
                dem: dem,
                minRadiusMeters: 3,
                maxRadiusMeters: max(6, parameters.radiusMeters),
                cell: cell
            )
            stretch(&gray, lowPercentile: 0.01, highPercentile: 0.99)
        case .mstiVatComposite:
            let vat = vatBlend(dem: dem, parameters: parameters, z: z, cell: cell)
            var msti = multiScaleTopographicIndex(
                dem: dem,
                minRadiusMeters: 3,
                maxRadiusMeters: max(6, parameters.radiusMeters),
                cell: cell
            )
            stretch(&msti, lowPercentile: 0.01, highPercentile: 0.99)
            let blend = Float(max(0, min(1, parameters.mstiBlend)))
            gray = zip(vat, msti).map { vatValue, mstiValue in
                let multiplied = vatValue * mstiValue
                return max(0, min(1, vatValue * (1 - blend) + multiplied * blend))
            }
            stretch(&gray, lowPercentile: 0.01, highPercentile: 0.99)
        case .customHillshade:
            gray = hillshade(dem: dem, azimuth: parameters.azimuthDegrees,
                             altitude: parameters.altitudeDegrees, z: z, cell: cell)
        case .multiHillshade:
            gray = multiHillshade(dem: dem, directions: parameters.directions,
                                  altitude: parameters.altitudeDegrees, z: z, cell: cell)
        case .slope:
            gray = slopeImage(dem: dem, cell: cell)
        case .svf:
            gray = skyViewFactor(dem: dem, directions: parameters.directions,
                                 radiusMeters: parameters.radiusMeters, cell: cell, openness: false)
            stretch(&gray, lowPercentile: 0.02, highPercentile: 0.98)
        case .openness:
            gray = skyViewFactor(dem: dem, directions: parameters.directions,
                                 radiusMeters: parameters.radiusMeters, cell: cell, openness: true)
            stretch(&gray, lowPercentile: 0.02, highPercentile: 0.98)
        case .svfHillshade:
            var svf = skyViewFactor(dem: dem, directions: parameters.directions,
                                    radiusMeters: parameters.radiusMeters, cell: cell, openness: false)
            stretch(&svf, lowPercentile: 0.02, highPercentile: 0.98)
            let shade = multiHillshade(dem: dem, directions: max(6, parameters.directions / 2),
                                       altitude: parameters.altitudeDegrees, z: z, cell: cell)
            // Blend SVF with hillshade: blend=0 keeps pure SVF, blend=1 is
            // a full multiply. Linear mix of the two keeps it controllable.
            let b = Float(max(0, min(1, parameters.hillshadeBlend)))
            gray = zip(svf, shade).map { s, h in s * (1 - b) + (s * h) * b }
            stretch(&gray, lowPercentile: 0.01, highPercentile: 0.99)
        case .localRelief:
            let radiusPixels = max(2, Int(parameters.lrmRadiusMeters / max(0.5, cell.x)))
            var relief = localRelief(dem: dem, radiusPixels: radiusPixels)
            rgba = divergingImage(&relief, width: width, height: height)
            gray = []
        }

        // Apply output gamma to grayscale products (deepen or lift the
        // shadows). Color (diverging) output keeps its own mapping.
        if rgba == nil, parameters.gamma != 1.0 {
            let g = Float(max(0.3, min(3.0, parameters.gamma)))
            for index in gray.indices {
                gray[index] = powf(max(0, min(1, gray[index])), g)
            }
        }

        if rgba == nil {
            rgba = (parameters.warmColorRamp && kind.supportsWarmRamp)
                ? warmRampImage(gray, width: width, height: height)
                : grayImage(gray, width: width, height: height)
        }
        guard let pixels = rgba else { return nil }
        return image(fromRGBA: pixels, width: width, height: height)
    }

    /// Warm archaeological ramp for SVF / openness: deep red-brown lows
    /// through orange to pale yellow highs. Reads like classic RVT SVF.
    private static func warmRampImage(_ values: [Float], width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let stops: [(Float, Float, Float)] = [
            (0.20, 0.05, 0.05),
            (0.55, 0.18, 0.08),
            (0.82, 0.45, 0.15),
            (0.95, 0.78, 0.45),
            (1.0, 0.98, 0.88)
        ]
        for index in 0..<(width * height) {
            let t = max(0, min(1, values[index])) * Float(stops.count - 1)
            let lower = min(stops.count - 2, Int(t))
            let f = t - Float(lower)
            let a = stops[lower], b = stops[lower + 1]
            pixels[index * 4] = UInt8(max(0, min(255, (a.0 + (b.0 - a.0) * f) * 255)))
            pixels[index * 4 + 1] = UInt8(max(0, min(255, (a.1 + (b.1 - a.1) * f) * 255)))
            pixels[index * 4 + 2] = UInt8(max(0, min(255, (a.2 + (b.2 - a.2) * f) * 255)))
        }
        return pixels
    }


    /// VAT/RVT blend used by the VAT option and the MSTI × VAT composite.
    private static func vatBlend(
        dem: DEMGrid,
        parameters: TerrainVizParameters,
        z: Float,
        cell: (x: Double, y: Double)
    ) -> [Float] {
        let shade = multiHillshade(
            dem: dem,
            directions: max(8, parameters.directions),
            altitude: parameters.altitudeDegrees,
            z: z,
            cell: cell
        )
        var svf = skyViewFactor(
            dem: dem,
            directions: max(8, parameters.directions),
            radiusMeters: parameters.radiusMeters,
            cell: cell,
            openness: false
        )
        stretch(&svf, lowPercentile: 0.02, highPercentile: 0.98)

        var relief = localRelief(
            dem: dem,
            radiusPixels: max(2, Int(parameters.lrmRadiusMeters / max(0.5, min(cell.x, cell.y))))
        )
        stretch(&relief, lowPercentile: 0.03, highPercentile: 0.97)

        let slope = slopeImage(dem: dem, cell: cell)

        // hillshadeBlend shifts weight between a shaded-relief look
        // (high) and a flatter SVF/relief look (low).
        let hsWeight = Float(0.30 + parameters.hillshadeBlend * 0.32)
        let svfWeight = Float(0.40 - parameters.hillshadeBlend * 0.16)
        var output = zip(zip(shade, svf), zip(relief, slope)).map { left, right in
            let blended = left.0 * hsWeight + left.1 * svfWeight + right.0 * 0.18 + right.1 * 0.08
            return max(0, min(1, blended))
        }
        stretch(&output, lowPercentile: 0.01, highPercentile: 0.99)
        return output
    }

    /// Approximate RVT-style Multi-Scale Topographic Index / multi-scale
    /// topographic position. It averages local-relief residuals at several
    /// neighborhood radii so small archaeological earthworks and broader
    /// terrace/road forms can be visible in one output.
    private static func multiScaleTopographicIndex(
        dem: DEMGrid,
        minRadiusMeters: Double,
        maxRadiusMeters: Double,
        cell: (x: Double, y: Double)
    ) -> [Float] {
        let cellSize = max(0.5, min(cell.x, cell.y))
        let minRadius = max(2.0, minRadiusMeters)
        let maxRadius = max(minRadius + 1.0, maxRadiusMeters)
        let scaleCount = 5
        let radiiMeters = (0..<scaleCount).map { index -> Double in
            let t = Double(index) / Double(max(1, scaleCount - 1))
            // Geometric-ish spacing gives extra attention to microrelief.
            return minRadius * pow(maxRadius / minRadius, t)
        }

        var accumulated = [Float](repeating: 0, count: dem.width * dem.height)
        for radiusMeters in radiiMeters {
            let radiusPixels = max(1, min(80, Int((radiusMeters / cellSize).rounded())))
            var relief = localRelief(dem: dem, radiusPixels: radiusPixels)
            stretch(&relief, lowPercentile: 0.02, highPercentile: 0.98)
            for index in accumulated.indices {
                accumulated[index] += relief[index]
            }
        }

        let scale = Float(1.0 / Double(radiiMeters.count))
        for index in accumulated.indices {
            accumulated[index] *= scale
        }
        stretch(&accumulated, lowPercentile: 0.01, highPercentile: 0.99)
        return accumulated
    }


    // MARK: Core math

    /// Horn-method surface normals -> shade for one sun position.
    private static func hillshade(
        dem: DEMGrid, azimuth: Double, altitude: Double, z: Float,
        cell: (x: Double, y: Double)
    ) -> [Float] {
        let width = dem.width, height = dem.height
        let values = dem.values
        var output = [Float](repeating: 0.5, count: width * height)

        let azimuthRad = Float((360 - azimuth + 90).truncatingRemainder(dividingBy: 360) * .pi / 180)
        let altitudeRad = Float(altitude * .pi / 180)
        let sinAlt = sin(altitudeRad), cosAlt = cos(altitudeRad)
        let lx = cosAlt * cos(azimuthRad)
        let ly = cosAlt * sin(azimuthRad)
        let lz = sinAlt
        let inv2dx = z / Float(2 * cell.x)
        let inv2dy = z / Float(2 * cell.y)

        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let index = row + x
                let dzdx = (values[index + 1] - values[index - 1]) * inv2dx
                let dzdy = (values[index - width] - values[index + width]) * inv2dy
                let length = sqrt(dzdx * dzdx + dzdy * dzdy + 1)
                let shade = (-dzdx * lx - dzdy * ly + lz) / length
                output[index] = max(0, min(1, shade))
            }
        }
        return output
    }

    private static func multiHillshade(
        dem: DEMGrid, directions: Int, altitude: Double, z: Float,
        cell: (x: Double, y: Double)
    ) -> [Float] {
        let count = max(3, min(32, directions))
        var accumulated = [Float](repeating: 0, count: dem.width * dem.height)
        for directionIndex in 0..<count {
            let azimuth = Double(directionIndex) * 360.0 / Double(count)
            let shade = hillshade(dem: dem, azimuth: azimuth, altitude: altitude, z: z, cell: cell)
            for index in accumulated.indices { accumulated[index] += shade[index] }
        }
        let scale = 1 / Float(count)
        for index in accumulated.indices { accumulated[index] *= scale }
        var output = accumulated
        stretch(&output, lowPercentile: 0.01, highPercentile: 0.99)
        return output
    }

    private static func slopeImage(dem: DEMGrid, cell: (x: Double, y: Double)) -> [Float] {
        let width = dem.width, height = dem.height
        let values = dem.values
        var output = [Float](repeating: 1, count: width * height)
        let inv2dx = 1 / Float(2 * cell.x)
        let inv2dy = 1 / Float(2 * cell.y)
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let index = row + x
                let dzdx = (values[index + 1] - values[index - 1]) * inv2dx
                let dzdy = (values[index - width] - values[index + width]) * inv2dy
                let slopeDegrees = atan(sqrt(dzdx * dzdx + dzdy * dzdy)) * 180 / .pi
                // RVT convention: steeper = darker; clip at 55 degrees.
                output[index] = 1 - min(1, slopeDegrees / 55)
            }
        }
        return output
    }

    /// Sky-view factor (or positive openness) by horizon search along
    /// evenly spaced directions out to the search radius.
    private static func skyViewFactor(
        dem: DEMGrid, directions: Int, radiusMeters: Double,
        cell: (x: Double, y: Double), openness: Bool
    ) -> [Float] {
        let width = dem.width, height = dem.height
        let values = dem.values
        let directionCount = max(4, min(32, directions))
        let cellSize = Float(max(0.25, min(cell.x, cell.y)))
        let radiusPixels = max(2, min(40, Int(Float(radiusMeters) / cellSize)))

        // Precompute direction step vectors and sample distances.
        var stepVectors: [(dx: Float, dy: Float)] = []
        for directionIndex in 0..<directionCount {
            let angle = Float(directionIndex) * 2 * .pi / Float(directionCount)
            stepVectors.append((cos(angle), sin(angle)))
        }
        let sampleDistances: [Int] = {
            // Up to 12 samples, denser close in where it matters.
            var distances: Set<Int> = []
            let samples = min(12, radiusPixels)
            for sampleIndex in 1...samples {
                let t = Float(sampleIndex) / Float(samples)
                distances.insert(max(1, Int((t * t) * Float(radiusPixels))))
            }
            return distances.sorted()
        }()

        var output = [Float](repeating: 1, count: width * height)

        // Each thread writes a disjoint row band, so raw buffer access
        // is safe and avoids array exclusivity traps under
        // concurrentPerform.
        values.withUnsafeBufferPointer { buffer in
            output.withUnsafeMutableBufferPointer { result in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    guard y >= 1, y < height - 1 else { return }
                    let row = y * width
                    for x in 1..<(width - 1) {
                        let index = row + x
                        let z0 = buffer[index]
                        var sum: Float = 0
                        for vector in stepVectors {
                            var maxTan: Float = 0
                            for distance in sampleDistances {
                                let sx = x + Int((vector.dx * Float(distance)).rounded())
                                let sy = y + Int((vector.dy * Float(distance)).rounded())
                                guard sx >= 0, sy >= 0, sx < width, sy < height else { break }
                                let dz = buffer[sy * width + sx] - z0
                                let tangent = dz / (Float(distance) * cellSize)
                                if tangent > maxTan { maxTan = tangent }
                            }
                            let horizonAngle = atan(maxTan)
                            if openness {
                                // Positive openness: mean zenith angle (90 - horizon).
                                sum += (.pi / 2 - horizonAngle)
                            } else {
                                sum += 1 - sin(max(0, horizonAngle))
                            }
                        }
                        result[index] = openness
                            ? sum / (Float(directionCount) * .pi / 2)
                            : sum / Float(directionCount)
                    }
                }
            }
        }
        return output
    }

    /// DEM minus its smoothed trend (two-pass box blur ≈ gaussian).
    private static func localRelief(dem: DEMGrid, radiusPixels: Int) -> [Float] {
        let width = dem.width, height = dem.height
        var smoothed = dem.values
        for _ in 0..<2 {
            smoothed = boxBlur(smoothed, width: width, height: height, radius: radiusPixels)
        }
        var output = [Float](repeating: 0, count: width * height)
        for index in output.indices {
            output[index] = dem.values[index] - smoothed[index]
        }
        return output
    }

    private static func boxBlur(_ input: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var horizontal = [Float](repeating: 0, count: input.count)
        let window = Float(2 * radius + 1)
        // Horizontal pass with running sums.
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for x in -radius...radius {
                sum += input[row + max(0, min(width - 1, x))]
            }
            for x in 0..<width {
                horizontal[row + x] = sum / window
                let outgoing = input[row + max(0, min(width - 1, x - radius))]
                let incoming = input[row + max(0, min(width - 1, x + radius + 1))]
                sum += incoming - outgoing
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        // Vertical pass.
        for x in 0..<width {
            var sum: Float = 0
            for y in -radius...radius {
                sum += horizontal[max(0, min(height - 1, y)) * width + x]
            }
            for y in 0..<height {
                output[y * width + x] = sum / window
                let outgoing = horizontal[max(0, min(height - 1, y - radius)) * width + x]
                let incoming = horizontal[max(0, min(height - 1, y + radius + 1)) * width + x]
                sum += incoming - outgoing
            }
        }
        return output
    }

    // MARK: Image output

    /// Percentile contrast stretch in place to 0...1.
    static func stretch(_ values: inout [Float], lowPercentile: Double, highPercentile: Double) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        let low = sorted[max(0, min(sorted.count - 1, Int(Double(sorted.count) * lowPercentile)))]
        let high = sorted[max(0, min(sorted.count - 1, Int(Double(sorted.count) * highPercentile)))]
        let range = max(0.000001, high - low)
        for index in values.indices {
            values[index] = max(0, min(1, (values[index] - low) / range))
        }
    }

    static func grayImage(_ values: [Float], width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let level = UInt8(max(0, min(255, values[index] * 255)))
            pixels[index * 4] = level
            pixels[index * 4 + 1] = level
            pixels[index * 4 + 2] = level
        }
        return pixels
    }

    /// Blue (negative) – white (zero) – red (positive) for local relief.
    private static func divergingImage(_ values: inout [Float], width: Int, height: Int) -> [UInt8] {
        let sorted = values.map { abs($0) }.sorted()
        let limit = max(0.05, sorted[max(0, min(sorted.count - 1, Int(Double(sorted.count) * 0.95)))])
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let t = max(-1, min(1, values[index] / limit))
            let red: Float, green: Float, blue: Float
            if t >= 0 {
                red = 1; green = 1 - t * 0.75; blue = 1 - t * 0.85
            } else {
                red = 1 + t * 0.85; green = 1 + t * 0.55; blue = 1
            }
            pixels[index * 4] = UInt8(max(0, min(255, red * 255)))
            pixels[index * 4 + 1] = UInt8(max(0, min(255, green * 255)))
            pixels[index * 4 + 2] = UInt8(max(0, min(255, blue * 255)))
        }
        return pixels
    }

    static func image(fromRGBA pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var data = pixels
        guard let context = CGContext(
            data: &data, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Writes a visualization (or imported GeoTIFF) image as a
/// georeferenced offline-map PDF the app can load as a basemap.
enum TerrainMapWriter {
    static func writePDFMap(image: UIImage, extent: GeoExtent, title: String, label: String) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let mapsFolder = documents.appendingPathComponent("GeneratedMaps", isDirectory: true)
        try FileManager.default.createDirectory(at: mapsFolder, withIntermediateDirectories: true)
        let safeTitle = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let url = mapsFolder.appendingPathComponent("\(safeTitle.isEmpty ? "Terrain" : safeTitle)-\(Int(Date().timeIntervalSince1970)).pdf")

        let aspect = max(0.25, min(4.0, image.size.width / max(1, image.size.height)))
        let base: CGFloat = 1000
        let pageSize = aspect >= 1
            ? CGSize(width: base, height: base / aspect)
            : CGSize(width: base * aspect, height: base)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: pageSize))
            image.draw(in: CGRect(origin: .zero, size: pageSize))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(10, pageSize.width * 0.016), weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let textSize = label.size(withAttributes: attributes)
            let pad: CGFloat = 8
            let rect = CGRect(
                x: pad, y: pageSize.height - textSize.height - pad * 2,
                width: min(pageSize.width - pad * 2, textSize.width + pad * 2),
                height: textSize.height + pad)
            UIColor.black.withAlphaComponent(0.5).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
            label.draw(in: rect.insetBy(dx: pad, dy: pad / 2), withAttributes: attributes)
        }
        return url
    }
}

/// Whether a terrain visualization should replace the map as a basemap or draw over it.
enum TerrainOutputMode: String, CaseIterable, Identifiable {
    case overlay
    case basemap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overlay: return "Transparent overlay on current map"
        case .basemap: return "New offline terrain basemap"
        }
    }
}

/// In-memory raster overlay drawn above the current PDF/offline map.
struct TerrainRasterOverlay: Identifiable {
    let id = UUID()
    let title: String
    let image: UIImage
    let extent: GeoExtent
    let createdAt: Date
    let sourceLabel: String
    let fileURL: URL?
    /// True for color (diverging) visualizations like Local Relief, which
    /// should blend normally rather than multiply (which would muddy the
    /// red/blue). Grayscale hillshades/SVF look best multiplied.
    var isColor: Bool = false
}

/// Persists the most recent RVT/VAT overlay image and metadata for offline reuse.
enum TerrainOverlayStore {
    private struct Metadata: Codable {
        let title: String
        let sourceLabel: String
        let imageFilename: String
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double
        let createdAt: Date
        var isColor: Bool? = nil
    }

    private static func folderURL() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = documents.appendingPathComponent("TerrainOverlays", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func save(image: UIImage, extent: GeoExtent, title: String, sourceLabel: String, isColor: Bool = false) throws -> TerrainRasterOverlay {
        let folder = try folderURL()
        let safeTitle = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stem = "\(safeTitle.isEmpty ? "Terrain-Overlay" : safeTitle)-\(Int(Date().timeIntervalSince1970))"
        let imageURL = folder.appendingPathComponent("\(stem).png")
        let metadataURL = folder.appendingPathComponent("\(stem).json")

        guard let data = image.pngData() else {
            throw NSError(domain: "TerrainOverlay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode overlay PNG."])
        }
        try data.write(to: imageURL, options: [.atomic])

        let metadata = Metadata(
            title: title,
            sourceLabel: sourceLabel,
            imageFilename: imageURL.lastPathComponent,
            minLatitude: extent.minLatitude,
            maxLatitude: extent.maxLatitude,
            minLongitude: extent.minLongitude,
            maxLongitude: extent.maxLongitude,
            createdAt: Date(),
            isColor: isColor
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL, options: [.atomic])

        return TerrainRasterOverlay(
            title: title,
            image: image,
            extent: extent,
            createdAt: metadata.createdAt,
            sourceLabel: sourceLabel,
            fileURL: imageURL,
            isColor: isColor
        )
    }

    static func loadLast() -> TerrainRasterOverlay? {
        guard let folder = try? folderURL(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }

        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        let sorted = jsonFiles.sorted { left, right in
            let lDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }

        let decoder = JSONDecoder()
        for metadataURL in sorted {
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? decoder.decode(Metadata.self, from: data) else { continue }
            let imageURL = folder.appendingPathComponent(metadata.imageFilename)
            guard let image = UIImage(contentsOfFile: imageURL.path) else { continue }
            let extent = GeoExtent(
                minLatitude: metadata.minLatitude,
                maxLatitude: metadata.maxLatitude,
                minLongitude: metadata.minLongitude,
                maxLongitude: metadata.maxLongitude
            )
            guard extent.isValid else { continue }
            return TerrainRasterOverlay(
                title: metadata.title,
                image: image,
                extent: extent,
                createdAt: metadata.createdAt,
                sourceLabel: metadata.sourceLabel,
                fileURL: imageURL,
                isColor: metadata.isColor ?? false
            )
        }
        return nil
    }

    static func clearAll() {
        guard let folder = try? folderURL(),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}


/// A loaded user DEM waiting for on-device VAT/RVT processing.
struct ImportedDEMTerrainRequest: Identifiable {
    let id = UUID()
    let sourceName: String
    let dem: DEMGrid
}

extension DEMGrid {
    /// Build a DEMGrid from a georeferenced single-band GeoTIFF DEM.
    /// Supports the same GeoTIFF CRS limits as GeoTIFFReader: EPSG:4326
    /// and WGS84/NAD83 UTM. Values are treated as meters.
    static func fromGeoTIFF(_ tiff: GeoTIFFImage) throws -> DEMGrid {
        guard let extent = tiff.extent else { throw GeoTIFFError.noGeoreference }
        guard var values = tiff.floatValues else {
            throw GeoTIFFError.unsupported("single-band DEM values")
        }

        let noData = tiff.noDataValue
        var validCount = 0
        for index in values.indices {
            let value = values[index]
            if !value.isFinite || value < -100_000 || value > 100_000 || (noData != nil && value == noData!) {
                values[index] = .nan
            } else {
                validCount += 1
            }
        }
        guard validCount > max(10, values.count / 100) else {
            throw GeoTIFFError.unsupported("DEM contains too few valid elevation cells")
        }

        // Fill no-data gaps along each row, then fall back to the first
        // valid value. This keeps RVT filters from exploding on NaNs.
        for row in 0..<tiff.height {
            let base = row * tiff.width
            var lastValid: Float?
            for column in 0..<tiff.width {
                let index = base + column
                if values[index].isNaN {
                    if let lastValid = lastValid { values[index] = lastValid }
                } else {
                    lastValid = values[index]
                }
            }
            var nextValid: Float?
            for column in stride(from: tiff.width - 1, through: 0, by: -1) {
                let index = base + column
                if values[index].isNaN {
                    if let nextValid = nextValid { values[index] = nextValid }
                } else {
                    nextValid = values[index]
                }
            }
        }
        let fallback = values.first(where: { $0.isFinite && !$0.isNaN }) ?? 0
        for index in values.indices where !values[index].isFinite || values[index].isNaN {
            values[index] = fallback
        }

        return DEMGrid(width: tiff.width, height: tiff.height, values: values,
                       minLatitude: extent.minLatitude, maxLatitude: extent.maxLatitude,
                       minLongitude: extent.minLongitude, maxLongitude: extent.maxLongitude)
    }
}

struct ImportedDEMTerrainToolboxView: View {
    let request: ImportedDEMTerrainRequest
    let hasCurrentPDFBasemap: Bool
    let onComplete: (URL, GeoExtent, DEMGrid, TerrainVisualizationKind, UIImage, TerrainOutputMode, TerrainVizParameters) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: TerrainVisualizationKind = .vatHillshade
    @State private var outputMode: TerrainOutputMode = .overlay
    @State private var parameters = TerrainVizParameters()
    @State private var detailIndex = 1
    @State private var outputName = ""
    @State private var isWorking = false
    @State private var statusMessage: String?

    private let detailOptions: [(label: String, maxDimension: Int)] = [
        ("Fast", 800),
        ("Standard", 1400),
        ("Fine", 2200),
        ("Native", 10000)
    ]

    private var effectiveMaxDimension: Int {
        let requested = detailOptions[detailIndex].maxDimension
        // Horizon-based visualizations are expensive on phones. Keep
        // them field-practical unless the user explicitly chooses Native.
        if kind.usesRadius && requested < 10000 { return min(requested, 1600) }
        return requested
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    LabeledContent("Source", value: request.sourceName)
                    LabeledContent("DEM size", value: "\(request.dem.width) × \(request.dem.height)")
                    LabeledContent("Extent", value: request.dem.extent.bboxDescription)
                } header: {
                    Text("Imported DEM")
                } footer: {
                    Text("This tool runs RVT/VAT-style terrain visualizations directly on your imported georeferenced GeoTIFF DEM and saves the result as an offline georeferenced basemap.")
                }

                Section {
                    Picker("Visualization", selection: $kind) {
                        ForEach(TerrainVisualizationKind.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Text(kind.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("VAT / RVT Visualization")
                }

                Section {
                    Picker("Output", selection: $outputMode) {
                        if hasCurrentPDFBasemap {
                            Text(TerrainOutputMode.overlay.title).tag(TerrainOutputMode.overlay)
                        }
                        Text(TerrainOutputMode.basemap.title).tag(TerrainOutputMode.basemap)
                    }
                } footer: {
                    Text(hasCurrentPDFBasemap
                        ? "Overlay keeps your current PDF map visible and draws grayscale RVT/VAT/MSTI results with multiply blending and adjustable transparency. The overlay is also saved offline."
                        : "Load a GeoPDF first to use transparent overlay mode; otherwise create a terrain basemap.")
                }
                .onAppear {
                    if !hasCurrentPDFBasemap { outputMode = .basemap }
                }

                Section(header: Text("Parameters")) {
                    if kind.usesAzimuth {
                        VStack(alignment: .leading) {
                            Text("Sun azimuth: \(Int(parameters.azimuthDegrees))°")
                                .font(.caption)
                            Slider(value: $parameters.azimuthDegrees, in: 0...360, step: 5)
                        }
                    }
                    if kind.usesHillshadeParameters {
                        VStack(alignment: .leading) {
                            Text("Sun altitude: \(Int(parameters.altitudeDegrees))°")
                                .font(.caption)
                            Slider(value: $parameters.altitudeDegrees, in: 20...70, step: 5)
                        }
                        VStack(alignment: .leading) {
                            Text("Vertical exaggeration: \(String(format: "%.1f", parameters.verticalExaggeration))×")
                                .font(.caption)
                            Slider(value: $parameters.verticalExaggeration, in: 1...4, step: 0.5)
                        }
                    }
                    if kind.usesDirections {
                        Picker("Directions", selection: $parameters.directions) {
                            Text("8").tag(8)
                            Text("16").tag(16)
                            Text("24").tag(24)
                            Text("32").tag(32)
                        }
                    }
                    if kind.usesRadius {
                        VStack(alignment: .leading) {
                            Text(kind.usesMSTI ? "MSTI max scale: \(Int(parameters.radiusMeters)) m" : "Sky-view radius: \(Int(parameters.radiusMeters)) m")
                                .font(.caption)
                            Slider(value: $parameters.radiusMeters, in: 3...60, step: 1)
                        }
                    }
                    if kind.usesLRMRadius {
                        VStack(alignment: .leading) {
                            Text("Local relief radius: \(Int(parameters.lrmRadiusMeters)) m")
                                .font(.caption)
                            Slider(value: $parameters.lrmRadiusMeters, in: 5...60, step: 5)
                        }
                    }
                    if kind.usesHillshadeBlend {
                        VStack(alignment: .leading) {
                            Text("Hillshade blend: \(Int(parameters.hillshadeBlend * 100))%")
                                .font(.caption)
                            Slider(value: $parameters.hillshadeBlend, in: 0...1, step: 0.05)
                        }
                    }
                    if kind.usesMSTIBlend {
                        VStack(alignment: .leading) {
                            Text("MSTI multiply: \(Int(parameters.mstiBlend * 100))%")
                                .font(.caption)
                            Slider(value: $parameters.mstiBlend, in: 0...1, step: 0.05)
                            Text("Higher values multiply the multi-scale topographic index into VAT more strongly; lower values keep more of the original VAT look.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !kind.producesColorImage {
                        VStack(alignment: .leading) {
                            Text("Contrast (gamma): \(String(format: "%.1f", parameters.gamma))")
                                .font(.caption)
                            Slider(value: $parameters.gamma, in: 0.4...2.5, step: 0.1)
                        }
                    }
                    if kind.supportsWarmRamp {
                        Toggle("Warm archaeological color ramp", isOn: $parameters.warmColorRamp)
                    }
                }

                Section {
                    Picker("Processing detail", selection: $detailIndex) {
                        ForEach(0..<detailOptions.count, id: \.self) { index in
                            Text(detailOptions[index].label).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Output map name", text: $outputName)
                } footer: {
                    Text("Standard is usually best in the field. Native keeps all DEM cells but may be slow or memory-heavy on large lidar tiles.")
                }

                Section {
                    Button {
                        create()
                    } label: {
                        if isWorking {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(statusMessage ?? "Working…")
                            }
                        } else {
                            Label(outputMode == .overlay ? "Create Transparent Overlay" : "Create Offline Terrain Basemap", systemImage: outputMode == .overlay ? "square.2.layers.3d" : "mountain.2.fill")
                        }
                    }
                    .disabled(isWorking)

                    if let statusMessage = statusMessage, !isWorking {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("DEM VAT/RVT Toolbox")
            .onChange(of: kind) { newKind in
                parameters = TerrainVizParameters.defaults(for: newKind)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
        .onAppear {
            if outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outputName = request.sourceName
            }
        }
    }

    private func create() {
        isWorking = true
        statusMessage = "Preparing imported DEM…"
        let renderKind = kind
        let renderParameters = parameters
        let sourceName = outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? request.sourceName
            : outputName.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxDimension = effectiveMaxDimension
        let sourceDEM = request.dem

        Task {
            do {
                let renderDEM = await MainActor.run {
                    sourceDEM.downsampled(maxDimension: maxDimension)
                }
                await MainActor.run { statusMessage = "Computing \(renderKind.title)…" }
                let image = await MainActor.run {
                    TerrainRenderer.render(kind: renderKind, dem: renderDEM, parameters: renderParameters)
                }
                guard let image = image else {
                    throw NSError(domain: "Terrain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rendering failed."])
                }
                await MainActor.run { statusMessage = "Writing georeferenced offline map…" }
                let url = try TerrainMapWriter.writePDFMap(
                    image: image,
                    extent: renderDEM.extent,
                    title: "\(sourceName)-\(renderKind.title)",
                    label: "\(renderKind.title) • imported DEM: \(sourceName)"
                )
                await MainActor.run {
                    isWorking = false
                    onComplete(url, renderDEM.extent, renderDEM, renderKind, image, outputMode, renderParameters)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Terrain visualization UI

struct TerrainVisualizationView: View {
    let mapExtent: GeoExtent?
    let gpsCoordinate: CLLocationCoordinate2D?
    let onComplete: (URL, GeoExtent, DEMGrid, TerrainVisualizationKind, UIImage, TerrainOutputMode, TerrainVizParameters) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: TerrainVisualizationKind = .vatHillshade
    @State private var outputMode: TerrainOutputMode
    @State private var parameters = TerrainVizParameters()
    @State private var extentSource: Int
    @State private var resolutionIndex = 1
    @State private var isWorking = false
    @State private var statusMessage: String?

    private let resolutionOptions: [(label: String, longEdge: Int)] = [
        ("Fast", 800), ("Standard", 1400), ("Fine", 2400)
    ]

    init(
        mapExtent: GeoExtent?,
        gpsCoordinate: CLLocationCoordinate2D?,
        onComplete: @escaping (URL, GeoExtent, DEMGrid, TerrainVisualizationKind, UIImage, TerrainOutputMode, TerrainVizParameters) -> Void
    ) {
        self.mapExtent = mapExtent
        self.gpsCoordinate = gpsCoordinate
        self.onComplete = onComplete
        _extentSource = State(initialValue: mapExtent != nil ? 0 : 1)
        _outputMode = State(initialValue: mapExtent != nil ? .overlay : .basemap)
    }

    private var selectedExtent: GeoExtent? {
        switch extentSource {
        case 0:
            return mapExtent
        case 1:
            return gpsCoordinate.map { GeoExtent.around($0, radiusMeters: 1_000) }
        default:
            return gpsCoordinate.map { GeoExtent.around($0, radiusMeters: 2_000) }
        }
    }

    private var effectiveLongEdge: Int {
        let requested = resolutionOptions[resolutionIndex].longEdge
        // Horizon searches are heavy; cap their grid for field phones.
        if kind.usesRadius { return min(requested, 900) }
        return requested
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Area", selection: $extentSource) {
                        if mapExtent != nil {
                            Text("Current map extent").tag(0)
                        }
                        if gpsCoordinate != nil {
                            Text("1 km around GPS").tag(1)
                            Text("2 km around GPS").tag(2)
                        }
                    }
                } header: {
                    Text("Area")
                } footer: {
                    Text("Elevation comes from USGS 3DEP lidar (United States coverage). Needs service once; the result is a fully offline basemap.")
                }

                Section {
                    Picker("Visualization", selection: $kind) {
                        ForEach(TerrainVisualizationKind.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Text(kind.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Visualization (RVT-style)")
                }

                Section {
                    Picker("Output", selection: $outputMode) {
                        if mapExtent != nil {
                            Text(TerrainOutputMode.overlay.title).tag(TerrainOutputMode.overlay)
                        }
                        Text(TerrainOutputMode.basemap.title).tag(TerrainOutputMode.basemap)
                    }
                } footer: {
                    Text(mapExtent != nil
                        ? "Overlay mode keeps the current PDF/offline basemap visible and draws grayscale RVT/VAT/MSTI products with multiply blending and adjustable transparency."
                        : "Load a georeferenced map first to use transparent overlay mode; otherwise create a new terrain basemap.")
                }
                .onAppear {
                    if mapExtent == nil { outputMode = .basemap }
                }

                Section(header: Text("Parameters")) {
                    if kind.usesAzimuth {
                        VStack(alignment: .leading) {
                            Text("Sun azimuth: \(Int(parameters.azimuthDegrees))° (\(Int(parameters.azimuthDegrees)) from north)")
                                .font(.caption)
                            Slider(value: $parameters.azimuthDegrees, in: 0...360, step: 5)
                        }
                    }
                    if kind.usesHillshadeParameters {
                        VStack(alignment: .leading) {
                            Text("Sun altitude: \(Int(parameters.altitudeDegrees))°")
                                .font(.caption)
                            Slider(value: $parameters.altitudeDegrees, in: 20...70, step: 5)
                        }
                        VStack(alignment: .leading) {
                            Text("Vertical exaggeration: \(String(format: "%.1f", parameters.verticalExaggeration))×")
                                .font(.caption)
                            Slider(value: $parameters.verticalExaggeration, in: 1...3, step: 0.5)
                        }
                    }
                    if kind.usesDirections {
                        Picker("Directions", selection: $parameters.directions) {
                            Text("8").tag(8)
                            Text("16").tag(16)
                            Text("24").tag(24)
                            Text("32").tag(32)
                        }
                    }
                    if kind.usesRadius {
                        VStack(alignment: .leading) {
                            Text(kind.usesMSTI ? "MSTI max scale: \(Int(parameters.radiusMeters)) m" : "Search radius: \(Int(parameters.radiusMeters)) m")
                                .font(.caption)
                            Slider(value: $parameters.radiusMeters, in: 5...60, step: 5)
                            Text(kind.usesMSTI ? "Smaller max scales emphasize pits, platforms, and house mounds; larger scales also bring out terraces, causeways, and broader landforms." : "Small radius (5–10 m) finds pits, hearths, and house floors; larger finds enclosures and terraces.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if kind.usesLRMRadius {
                        VStack(alignment: .leading) {
                            Text("Smoothing radius: \(Int(parameters.lrmRadiusMeters)) m")
                                .font(.caption)
                            Slider(value: $parameters.lrmRadiusMeters, in: 10...50, step: 5)
                            Text("Features larger than this blend into the trend; features smaller than this pop out.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if kind.usesHillshadeBlend {
                        VStack(alignment: .leading) {
                            Text("Hillshade blend: \(Int(parameters.hillshadeBlend * 100))%")
                                .font(.caption)
                            Slider(value: $parameters.hillshadeBlend, in: 0...1, step: 0.05)
                            Text("Higher favors shaded relief; lower keeps the flatter sky-view look.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if kind.usesMSTIBlend {
                        VStack(alignment: .leading) {
                            Text("MSTI multiply: \(Int(parameters.mstiBlend * 100))%")
                                .font(.caption)
                            Slider(value: $parameters.mstiBlend, in: 0...1, step: 0.05)
                            Text("Higher values multiply MSTI into VAT more strongly; lower values keep more of the original VAT shading.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !kind.producesColorImage {
                        VStack(alignment: .leading) {
                            Text("Contrast (gamma): \(String(format: "%.1f", parameters.gamma))")
                                .font(.caption)
                            Slider(value: $parameters.gamma, in: 0.4...2.5, step: 0.1)
                            Text("Above 1 deepens shadows; below 1 lifts them.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if kind.supportsWarmRamp {
                        Toggle("Warm archaeological color ramp", isOn: $parameters.warmColorRamp)
                    }
                }

                Section {
                    Picker("Detail", selection: $resolutionIndex) {
                        ForEach(0..<3, id: \.self) { index in
                            Text(resolutionOptions[index].label).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kind.usesRadius
                        ? (kind.usesMSTI
                            ? "MSTI builds several local-relief surfaces at different scales. Use Fast/Standard for field checks and Fine for final review."
                            : "Sky-view and openness compute a horizon search per pixel — expect several seconds at Standard detail. You can fine-tune every setting live on the map afterward.")
                        : "Fine detail downloads a larger elevation grid and renders sharper contours. You can fine-tune every setting live on the map afterward.")
                }

                Section {
                    Button {
                        create()
                    } label: {
                        if isWorking {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(statusMessage ?? "Working…")
                                    .font(.callout)
                            }
                        } else {
                            Label(outputMode == .overlay ? "Create Transparent Overlay" : "Create Terrain Basemap", systemImage: outputMode == .overlay ? "square.2.layers.3d" : "mountain.2.fill")
                        }
                    }
                    .disabled(isWorking || selectedExtent == nil)

                    if !isWorking, let statusMessage = statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("LiDAR Terrain")
            .onChange(of: kind) { newKind in
                parameters = TerrainVizParameters.defaults(for: newKind)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func create() {
        guard let extent = selectedExtent else {
            statusMessage = "Pick an area first."
            return
        }
        isWorking = true
        statusMessage = "Downloading USGS 3DEP elevation…"
        let renderKind = kind
        let renderParameters = parameters
        let longEdge = effectiveLongEdge

        Task {
            do {
                let dem = try await DEMDownloader.fetch3DEP(extent: extent, longEdgePixels: longEdge)
                await MainActor.run { statusMessage = "Computing \(renderKind.title)…" }
                let image = await MainActor.run {
                    TerrainRenderer.render(kind: renderKind, dem: dem, parameters: renderParameters)
                }
                guard let image = image else {
                    throw NSError(domain: "Terrain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rendering failed."])
                }
                await MainActor.run { statusMessage = "Writing georeferenced map…" }
                let label = "\(renderKind.title) • USGS 3DEP lidar"
                let url = try TerrainMapWriter.writePDFMap(
                    image: image,
                    extent: extent,
                    title: renderKind.title,
                    label: label
                )
                await MainActor.run {
                    isWorking = false
                    onComplete(url, extent, dem, renderKind, image, outputMode, renderParameters)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}

struct TerrainOverlayControlsView: View {
    @Binding var overlay: TerrainRasterOverlay?
    @Binding var opacity: Double
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                if let overlay = overlay {
                    Section(header: Text("Active RVT/VAT Overlay")) {
                        LabeledContent("Name", value: overlay.title)
                        LabeledContent("Source", value: overlay.sourceLabel)
                        LabeledContent("Extent", value: overlay.extent.bboxDescription)
                        if let fileURL = overlay.fileURL {
                            LabeledContent("Offline file", value: fileURL.lastPathComponent)
                        }
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Opacity: \(Int(opacity * 100))%")
                                .font(.callout.monospacedDigit())
                            Slider(value: $opacity, in: 0.05...0.95, step: 0.05)
                        }
                    } footer: {
                        Text("Lower opacity lets the PDF map labels, contours, and aerial imagery show through; higher opacity emphasizes subtle lidar mounds, platforms, terraces, roads, and ditches.")
                    }

                    Section {
                        Button(role: .destructive) {
                            onClear()
                            dismiss()
                        } label: {
                            Label("Clear Overlay", systemImage: "eye.slash")
                        }
                    }
                } else {
                    Section {
                        Text("No RVT/VAT overlay is active.")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Use Import > DEM / VAT-RVT Toolbox or Import > LiDAR Terrain Visualization and choose Transparent Overlay.")
                    }
                }
            }
            .navigationTitle("RVT/VAT Overlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


// MARK: - Unified map layer manager additions
// Appended to the current full app source so this file can replace the older single-file Swift source.

//
//  MapLayerManagerView.swift
//  ArchaeologySurvey
//
//  Adds a unified map-layer stack for imported GeoPDFs, generated offline maps,
//  USGS current/historical topo maps, satellite/orthophoto imagery, DEM/RVT/VAT
//  terrain rasters, and field-record layers.
//
//  Drop this file into the Xcode project and present MapLayerManagerView from
//  the existing Review Layers / Manage Offline Maps / map toolbar flow.
//
//  Integration points to connect in the existing app:
//  1. When a GeoPDF, GeoTIFF, generated offline map, USGS topo, historical topo,
//     imagery raster, DEM, RVT, VAT, or Apple preview layer is added, create or
//     update a SurveyMapLayer in SurveyLayerStore.
//  2. Use SurveyLayerStore.renderableLayers from the existing map renderer so
//     layers are drawn in top-to-bottom order with visibility, opacity, blend
//     mode, and lock status honored.
//  3. Keep field data, active GPS, tracks, DPR features, and measurement graphics
//     locked above raster basemap layers by default.
//  4. Treat Apple Satellite as onlinePreviewOnly; do not mark it as downloaded.
//


// MARK: - Layer metadata

public enum SurveyLayerGroup: String, Codable, CaseIterable, Identifiable {
    case fieldData = "Field Data"
    case importedMaps = "Imported Maps"
    case downloadedOfflineMaps = "Downloaded Offline Maps"
    case terrainVisualization = "Terrain / LiDAR Visualization"
    case onlinePreview = "Online Preview Layers"
    case referenceVectors = "Reference Vectors"

    public var id: String { rawValue }

    public var defaultLockedToTop: Bool {
        switch self {
        case .fieldData:
            return true
        default:
            return false
        }
    }

    public var iconName: String {
        switch self {
        case .fieldData: return "mappin.and.ellipse"
        case .importedMaps: return "doc.richtext"
        case .downloadedOfflineMaps: return "externaldrive.fill"
        case .terrainVisualization: return "mountain.2.fill"
        case .onlinePreview: return "wifi"
        case .referenceVectors: return "point.3.connected.trianglepath.dotted"
        }
    }
}

public enum SurveyLayerKind: String, Codable, CaseIterable, Identifiable {
    case geoPDF = "GeoPDF"
    case geoTIFF = "GeoTIFF"
    case mbTiles = "MBTiles / Tile Package"
    case usgsCurrentTopo = "USGS Current Topo"
    case usgsHistoricalTopo = "USGS Historical Topo"
    case usgsImagery = "USGS / TNM Imagery"
    case naipImagery = "NAIP / Orthophoto Imagery"
    case appleSatellitePreview = "Apple Satellite Preview"
    case dem = "DEM"
    case hillshade = "Hillshade"
    case slope = "Slope"
    case rvtVat = "RVT / VAT / Terrain Raster"
    case osmVectors = "OSM Vector Layers"
    case plss = "PLSS"
    case countyBoundaries = "County Boundaries"
    case usgsQuadIndex = "USGS Quad Index"
    case fieldFeature = "Field Feature"
    case gpsTrack = "GPS Track"
    case dprForms = "DPR Forms"
    case measurement = "Measurement / Bearing"
    case lidarScan = "LiDAR / 3D Scan"
    case other = "Other"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .geoPDF: return "doc.richtext"
        case .geoTIFF, .usgsImagery, .naipImagery: return "photo.on.rectangle"
        case .mbTiles: return "square.grid.3x3"
        case .usgsCurrentTopo, .usgsHistoricalTopo, .usgsQuadIndex: return "map"
        case .appleSatellitePreview: return "wifi"
        case .dem, .hillshade, .slope, .rvtVat: return "mountain.2.fill"
        case .osmVectors: return "point.3.connected.trianglepath.dotted"
        case .plss: return "square.grid.2x2"
        case .countyBoundaries: return "map.fill"
        case .fieldFeature: return "mappin.circle"
        case .gpsTrack: return "figure.walk"
        case .dprForms: return "doc.text"
        case .measurement: return "ruler"
        case .lidarScan: return "cube.transparent"
        case .other: return "square.stack.3d.up"
        }
    }
}

public enum LayerOfflineStatus: String, Codable, CaseIterable, Identifiable {
    case downloaded = "Downloaded for offline use"
    case importedLocal = "Imported local file"
    case onlinePreviewOnly = "Online preview only"
    case notDownloaded = "Not downloaded"
    case missingFile = "Missing local file"
    case needsRefresh = "Needs refresh"

    public var id: String { rawValue }

    public var isUsableOffline: Bool {
        switch self {
        case .downloaded, .importedLocal:
            return true
        default:
            return false
        }
    }

    public var color: Color {
        switch self {
        case .downloaded, .importedLocal: return .green
        case .onlinePreviewOnly: return .blue
        case .notDownloaded, .needsRefresh: return .orange
        case .missingFile: return .red
        }
    }

    public var symbolName: String {
        switch self {
        case .downloaded, .importedLocal: return "checkmark.circle.fill"
        case .onlinePreviewOnly: return "wifi"
        case .notDownloaded: return "arrow.down.circle"
        case .missingFile: return "exclamationmark.triangle.fill"
        case .needsRefresh: return "arrow.clockwise.circle"
        }
    }
}

public enum SurveyLayerBlendMode: String, Codable, CaseIterable, Identifiable {
    case normal = "Normal"
    case multiply = "Multiply"
    case overlay = "Overlay"
    case screen = "Screen"
    case darken = "Darken"
    case lighten = "Lighten"

    public var id: String { rawValue }

    public var swiftUIBlendMode: BlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .overlay: return .overlay
        case .screen: return .screen
        case .darken: return .darken
        case .lighten: return .lighten
        }
    }

    /// Core Animation filter names used by the PDF tile layer. Field overlays
    /// are separate and stay fully visible; only the basemap tiles use this.
    public var coreAnimationCompositingFilter: String? {
        switch self {
        case .normal: return nil
        case .multiply: return "multiplyBlendMode"
        case .overlay: return "overlayBlendMode"
        case .screen: return "screenBlendMode"
        case .darken: return "darkenBlendMode"
        case .lighten: return "lightenBlendMode"
        }
    }

    public var recommendedUse: String {
        switch self {
        case .normal:
            return "Best for GeoPDFs and normal raster maps."
        case .multiply:
            return "Good for black topo linework over imagery."
        case .overlay:
            return "Good for hillshade, RVT, VAT, and terrain over imagery."
        case .screen:
            return "Lightens a dark layer; useful for some shaded relief products."
        case .darken:
            return "Keeps darker lines visible over light basemaps."
        case .lighten:
            return "Keeps lighter scanned map details visible over dark basemaps."
        }
    }
}

public struct SurveyMapLayer: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var subtitle: String
    public var group: SurveyLayerGroup
    public var kind: SurveyLayerKind
    public var isVisible: Bool
    public var isLocked: Bool
    public var opacity: Double
    public var blendMode: SurveyLayerBlendMode
    public var offlineStatus: LayerOfflineStatus
    public var sourceDescription: String
    public var yearLabel: String?
    public var resolutionLabel: String?
    public var coverageLabel: String?
    public var storageLabel: String?
    public var localFilePath: String?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String = "",
        group: SurveyLayerGroup,
        kind: SurveyLayerKind,
        isVisible: Bool = true,
        isLocked: Bool? = nil,
        opacity: Double = 1.0,
        blendMode: SurveyLayerBlendMode = .normal,
        offlineStatus: LayerOfflineStatus = .notDownloaded,
        sourceDescription: String = "",
        yearLabel: String? = nil,
        resolutionLabel: String? = nil,
        coverageLabel: String? = nil,
        storageLabel: String? = nil,
        localFilePath: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.group = group
        self.kind = kind
        self.isVisible = isVisible
        self.isLocked = isLocked ?? group.defaultLockedToTop
        self.opacity = min(max(opacity, 0.0), 1.0)
        self.blendMode = blendMode
        self.offlineStatus = offlineStatus
        self.sourceDescription = sourceDescription
        self.yearLabel = yearLabel
        self.resolutionLabel = resolutionLabel
        self.coverageLabel = coverageLabel
        self.storageLabel = storageLabel
        self.localFilePath = localFilePath
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public static func importedGeoPDF(name: String, localFilePath: String, coverage: String? = nil) -> SurveyMapLayer {
        SurveyMapLayer(
            name: name,
            subtitle: "Imported GeoPDF",
            group: .importedMaps,
            kind: .geoPDF,
            isVisible: true,
            isLocked: false,
            opacity: 0.70,
            blendMode: .normal,
            offlineStatus: .importedLocal,
            sourceDescription: "User-imported georeferenced PDF",
            coverageLabel: coverage,
            localFilePath: localFilePath
        )
    }

    public static func generatedOfflineRaster(name: String, kind: SurveyLayerKind, localFilePath: String, year: String? = nil) -> SurveyMapLayer {
        SurveyMapLayer(
            name: name,
            subtitle: "Generated offline raster map",
            group: .downloadedOfflineMaps,
            kind: kind,
            isVisible: true,
            isLocked: false,
            opacity: 1.0,
            blendMode: kind == .hillshade || kind == .rvtVat ? .overlay : .normal,
            offlineStatus: .downloaded,
            sourceDescription: "Offline basemap generated by the app",
            yearLabel: year,
            localFilePath: localFilePath
        )
    }

    public static func appleSatellitePreview() -> SurveyMapLayer {
        SurveyMapLayer(
            name: "Apple Satellite Preview",
            subtitle: "Online preview only",
            group: .onlinePreview,
            kind: .appleSatellitePreview,
            isVisible: false,
            isLocked: false,
            opacity: 1.0,
            blendMode: .normal,
            offlineStatus: .onlinePreviewOnly,
            sourceDescription: "Apple satellite imagery is visible while online but is not stored as an offline basemap."
        )
    }
}

// MARK: - Presets and compare state

public enum SurveyLayerPreset: String, CaseIterable, Identifiable {
    case archaeologyFieldView = "Archaeology Field View"
    case satelliteCheck = "Satellite Check"
    case historicalMapReview = "Historical Map Review"
    case navigationMode = "Navigation Mode"
    case lidarTerrainMode = "LiDAR / Terrain Mode"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .archaeologyFieldView:
            return "Field data on top, GeoPDF semi-transparent, topo and imagery below."
        case .satelliteCheck:
            return "Imagery prominent, GeoPDF dimmed, field points visible."
        case .historicalMapReview:
            return "Historical topo prominent for comparing old map evidence."
        case .navigationMode:
            return "Current basemap and GPS/track layers prioritized."
        case .lidarTerrainMode:
            return "Hillshade/RVT/VAT terrain overlay over imagery or topo."
        }
    }
}

public struct LayerCompareConfiguration: Codable, Equatable {
    public var isEnabled: Bool
    public var leftLayerID: UUID?
    public var rightLayerID: UUID?
    public var dividerPercent: Double

    public init(isEnabled: Bool = false, leftLayerID: UUID? = nil, rightLayerID: UUID? = nil, dividerPercent: Double = 0.5) {
        self.isEnabled = isEnabled
        self.leftLayerID = leftLayerID
        self.rightLayerID = rightLayerID
        self.dividerPercent = dividerPercent
    }
}

// MARK: - Store

@MainActor
public final class SurveyLayerStore: ObservableObject {
    @Published public var layers: [SurveyMapLayer] = [] {
        didSet { saveIfPossible() }
    }

    @Published public var compareConfiguration = LayerCompareConfiguration() {
        didSet { saveIfPossible() }
    }

    private let persistenceURL: URL?
    private var isLoading = false

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL ?? SurveyLayerStore.defaultPersistenceURL()
        loadIfPossible()
        if layers.isEmpty {
            layers = SurveyLayerStore.defaultLayers()
        }
    }

    public static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SurveyLayerStack.json")
    }

    public static func defaultLayers() -> [SurveyMapLayer] {
        [
            SurveyMapLayer(
                name: "Current GPS Location",
                subtitle: "Locked field overlay",
                group: .fieldData,
                kind: .fieldFeature,
                isLocked: true,
                opacity: 1.0,
                offlineStatus: .downloaded,
                sourceDescription: "Device or external GNSS position"
            ),
            SurveyMapLayer(
                name: "DPR Site Points / Forms",
                subtitle: "Locked field overlay",
                group: .fieldData,
                kind: .dprForms,
                isLocked: true,
                opacity: 1.0,
                offlineStatus: .downloaded,
                sourceDescription: "Created field records and attached DPR forms"
            ),
            SurveyMapLayer.appleSatellitePreview()
        ]
    }

    public var renderableLayers: [SurveyMapLayer] {
        layers.filter { $0.isVisible }
    }

    public var offlineWarnings: [SurveyMapLayer] {
        layers.filter { $0.isVisible && !$0.offlineStatus.isUsableOffline }
    }

    public func binding(for id: UUID) -> Binding<SurveyMapLayer>? {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.layers[index] },
            set: { newValue in
                var updated = newValue
                updated.opacity = min(max(updated.opacity, 0.0), 1.0)
                updated.modifiedAt = Date()
                self.layers[index] = updated
                self.normalizeLockedLayerOrder()
            }
        )
    }

    public func addOrReplace(_ layer: SurveyMapLayer) {
        if let index = layers.firstIndex(where: { $0.id == layer.id }) {
            layers[index] = layer
        } else if let existingPath = layer.localFilePath,
                  let index = layers.firstIndex(where: { $0.localFilePath == existingPath }) {
            layers[index] = layer
        } else {
            layers.append(layer)
        }
        normalizeLockedLayerOrder()
    }

    public func remove(id: UUID) {
        layers.removeAll { $0.id == id && !$0.isLocked }
    }

    public func toggleVisibility(id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].isVisible.toggle()
        layers[index].modifiedAt = Date()
    }

    public func moveLayers(from source: IndexSet, to destination: Int) {
        layers.move(fromOffsets: source, toOffset: destination)
        normalizeLockedLayerOrder()
    }

    public func moveLayer(id: UUID, above targetID: UUID) {
        guard let from = layers.firstIndex(where: { $0.id == id }),
              let to = layers.firstIndex(where: { $0.id == targetID }) else { return }
        let layer = layers.remove(at: from)
        let insertIndex = from < to ? max(0, to - 1) : to
        layers.insert(layer, at: insertIndex)
        normalizeLockedLayerOrder()
    }

    public func setOpacity(id: UUID, opacity: Double) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].opacity = min(max(opacity, 0.0), 1.0)
        layers[index].modifiedAt = Date()
    }

    public func normalizeLockedLayerOrder() {
        guard !isLoading else { return }
        let locked = layers.filter { $0.isLocked }
        let unlocked = layers.filter { !$0.isLocked }
        layers = locked + unlocked
    }

    public func applyPreset(_ preset: SurveyLayerPreset) {
        for index in layers.indices {
            let kind = layers[index].kind
            let group = layers[index].group

            switch preset {
            case .archaeologyFieldView:
                layers[index].isVisible = true
                if group == .fieldData { layers[index].opacity = 1.0 }
                if kind == .geoPDF { layers[index].opacity = 0.60; layers[index].blendMode = .normal }
                if kind == .appleSatellitePreview { layers[index].isVisible = false }
                if kind == .hillshade || kind == .rvtVat { layers[index].opacity = 0.45; layers[index].blendMode = .overlay }

            case .satelliteCheck:
                if group == .fieldData { layers[index].isVisible = true; layers[index].opacity = 1.0 }
                if kind == .geoPDF { layers[index].isVisible = true; layers[index].opacity = 0.40 }
                if kind == .naipImagery || kind == .usgsImagery { layers[index].isVisible = true; layers[index].opacity = 1.0 }
                if kind == .usgsHistoricalTopo { layers[index].isVisible = false }

            case .historicalMapReview:
                if group == .fieldData { layers[index].isVisible = true; layers[index].opacity = 1.0 }
                if kind == .usgsHistoricalTopo { layers[index].isVisible = true; layers[index].opacity = 0.90; layers[index].blendMode = .multiply }
                if kind == .geoPDF { layers[index].isVisible = true; layers[index].opacity = 0.35 }
                if kind == .naipImagery || kind == .usgsImagery { layers[index].opacity = 0.70 }

            case .navigationMode:
                if group == .fieldData { layers[index].isVisible = true; layers[index].opacity = 1.0 }
                if kind == .usgsCurrentTopo || kind == .naipImagery || kind == .usgsImagery { layers[index].isVisible = true; layers[index].opacity = 1.0 }
                if kind == .geoPDF { layers[index].opacity = 0.35 }
                if kind == .usgsHistoricalTopo { layers[index].isVisible = false }

            case .lidarTerrainMode:
                if group == .fieldData { layers[index].isVisible = true; layers[index].opacity = 1.0 }
                if kind == .hillshade || kind == .rvtVat || kind == .slope || kind == .dem {
                    layers[index].isVisible = true
                    layers[index].opacity = 0.75
                    layers[index].blendMode = .overlay
                }
                if kind == .geoPDF { layers[index].opacity = 0.35 }
            }

            layers[index].modifiedAt = Date()
        }
        normalizeLockedLayerOrder()
    }

    public func makeOfflineReadinessSummary() -> OfflineReadinessSummary {
        let visible = layers.filter { $0.isVisible }
        let ready = visible.filter { $0.offlineStatus.isUsableOffline }
        let warnings = visible.filter { !$0.offlineStatus.isUsableOffline }
        return OfflineReadinessSummary(readyLayers: ready, warningLayers: warnings)
    }

    private struct PersistedState: Codable {
        var layers: [SurveyMapLayer]
        var compareConfiguration: LayerCompareConfiguration
    }

    private func loadIfPossible() {
        guard let persistenceURL,
              FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            isLoading = true
            defer { isLoading = false }
            let data = try Data(contentsOf: persistenceURL)
            let decoded = try JSONDecoder.surveyLayerDecoder.decode(PersistedState.self, from: data)
            layers = decoded.layers
            compareConfiguration = decoded.compareConfiguration
            normalizeLockedLayerOrder()
        } catch {
            print("SurveyLayerStore load failed: \(error)")
        }
    }

    private func saveIfPossible() {
        guard !isLoading, let persistenceURL else { return }
        do {
            let state = PersistedState(layers: layers, compareConfiguration: compareConfiguration)
            let data = try JSONEncoder.surveyLayerEncoder.encode(state)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            print("SurveyLayerStore save failed: \(error)")
        }
    }
}

public struct OfflineReadinessSummary {
    public let readyLayers: [SurveyMapLayer]
    public let warningLayers: [SurveyMapLayer]

    public var isReady: Bool { warningLayers.isEmpty }
}

private extension JSONEncoder {
    static var surveyLayerEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var surveyLayerDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Main layer manager UI

public struct MapLayerManagerView: View {
    @ObservedObject private var store: SurveyLayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedPreset: SurveyLayerPreset = .archaeologyFieldView
    @State private var showOfflineReadiness = false
    @State private var showComparePicker = false

    public init(store: SurveyLayerStore) {
        self.store = store
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredLayers: [SurveyMapLayer] {
        let trimmed = trimmedSearchText
        guard !trimmed.isEmpty else { return store.layers }
        return store.layers.filter { layer in
            layer.name.localizedCaseInsensitiveContains(trimmed) ||
            layer.subtitle.localizedCaseInsensitiveContains(trimmed) ||
            layer.kind.rawValue.localizedCaseInsensitiveContains(trimmed) ||
            layer.group.rawValue.localizedCaseInsensitiveContains(trimmed) ||
            layer.sourceDescription.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var offlineSummary: OfflineReadinessSummary {
        store.makeOfflineReadinessSummary()
    }

    public var body: some View {
        NavigationView {
            layerListView
                .searchable(text: $searchText, prompt: "Search name, group, source, year")
                .navigationTitle("Map Layers")
                .navigationBarItems(
                    leading: EditButton(),
                    trailing: Button("Done") { dismiss() }
                )
                .sheet(isPresented: $showOfflineReadiness) {
                    OfflineReadinessView(summary: store.makeOfflineReadinessSummary())
                }
                .sheet(isPresented: $showComparePicker) {
                    LayerComparePickerView(store: store)
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var layerListView: some View {
        List {
            introSection
            presetSection
            offlineSection
            compareSection
            layerRowsSection
        }
    }

    private var introSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Layer stack")
                        .font(.headline)
                    Text("Top layers draw above lower layers. Drag to reorder. Use opacity so GeoPDFs do not hide USGS topo or imagery.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var presetSection: some View {
        Section(header: Text("Quick presets")) {
            Picker("Preset", selection: $selectedPreset) {
                ForEach(SurveyLayerPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            Button {
                store.applyPreset(selectedPreset)
            } label: {
                Label("Apply \(selectedPreset.rawValue)", systemImage: "wand.and.stars")
            }
            Text(selectedPreset.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var offlineSection: some View {
        Section(header: Text("Offline status")) {
            Button {
                showOfflineReadiness = true
            } label: {
                Label(offlineSummary.isReady ? "All visible layers are offline-ready" : "Review offline warnings", systemImage: offlineSummary.isReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(offlineSummary.isReady ? .green : .orange)
            }
            if !offlineSummary.warningLayers.isEmpty {
                Text("\(offlineSummary.warningLayers.count) visible layer(s) are online-only, not downloaded, missing, or need refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compareSection: some View {
        Section(header: Text("Compare")) {
            Button {
                showComparePicker = true
            } label: {
                Label(store.compareConfiguration.isEnabled ? "Edit swipe comparison" : "Start swipe comparison", systemImage: "rectangle.split.2x1")
            }
            if store.compareConfiguration.isEnabled {
                Button(role: .destructive) {
                    store.compareConfiguration.isEnabled = false
                } label: {
                    Label("Turn off comparison", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var layerRowsSection: some View {
        Section(
            header: Text("Layers - top to bottom"),
            footer: Text("Locked field layers stay above raster maps to keep GPS, tracks, DPR points, measurements, and active editing graphics visible.")
        ) {
            ForEach(filteredLayers) { layer in
                mapLayerRow(for: layer)
            }
            .onMove(perform: moveLayers)
        }
    }

    @ViewBuilder
    private func mapLayerRow(for layer: SurveyMapLayer) -> some View {
        if let binding = store.binding(for: layer.id) {
            MapLayerManagerRow(layer: binding) {
                store.remove(id: layer.id)
            }
            .moveDisabled(!trimmedSearchText.isEmpty || layer.isLocked)
        }
    }

    private func moveLayers(from source: IndexSet, to destination: Int) {
        guard trimmedSearchText.isEmpty else { return }
        store.moveLayers(from: source, to: destination)
    }
}

public struct MapLayerManagerRow: View {
    @Binding var layer: SurveyMapLayer
    var deleteAction: () -> Void
    @State private var expanded = false

    public init(layer: Binding<SurveyMapLayer>, deleteAction: @escaping () -> Void) {
        self._layer = layer
        self.deleteAction = deleteAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: layer.kind.iconName)
                    .font(.title3)
                    .foregroundStyle(layer.isVisible ? .blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(layer.name)
                            .font(.headline)
                            .lineLimit(2)
                        if layer.isLocked {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    Text(layer.subtitle.isEmpty ? layer.kind.rawValue : layer.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Image(systemName: layer.offlineStatus.symbolName)
                        Text(layer.offlineStatus.rawValue)
                        if let year = layer.yearLabel { Text("• \(year)") }
                    }
                    .font(.caption)
                    .foregroundStyle(layer.offlineStatus.color)
                }

                Spacer()

                Toggle("Visible", isOn: $layer.isVisible)
                    .labelsHidden()

                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Opacity")
                        Slider(value: $layer.opacity, in: 0...1)
                        Text("\(Int(layer.opacity * 100))%")
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }

                    Picker("Blend", selection: $layer.blendMode) {
                        ForEach(SurveyLayerBlendMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(layer.blendMode.recommendedUse)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Lock this layer above raster maps", isOn: $layer.isLocked)

                    LayerMetadataGrid(layer: layer)

                    if !layer.isLocked {
                        Button(role: .destructive, action: deleteAction) {
                            Label("Remove from layer stack", systemImage: "trash")
                        }
                    }
                }
                .font(.subheadline)
                .padding(.leading, 40)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }
}

public struct LayerMetadataGrid: View {
    let layer: SurveyMapLayer

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            metadataRow("Group", layer.group.rawValue)
            metadataRow("Type", layer.kind.rawValue)
            if let year = layer.yearLabel { metadataRow("Year", year) }
            if let resolution = layer.resolutionLabel { metadataRow("Resolution", resolution) }
            if let coverage = layer.coverageLabel { metadataRow("Coverage", coverage) }
            if let storage = layer.storageLabel { metadataRow("Storage", storage) }
            if !layer.sourceDescription.isEmpty { metadataRow("Source", layer.sourceDescription) }
            if let path = layer.localFilePath { metadataRow("File", URL(fileURLWithPath: path).lastPathComponent) }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(3)
        }
    }
}

// MARK: - Offline readiness sheet

public struct OfflineReadinessView: View {
    @Environment(\.dismiss) private var dismiss
    let summary: OfflineReadinessSummary

    public init(summary: OfflineReadinessSummary) {
        self.summary = summary
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: summary.isReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(summary.isReady ? .green : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.isReady ? "Ready for offline use" : "Fix these before going offline")
                                .font(.headline)
                            Text(summary.isReady ? "Every visible layer is either downloaded or imported as a local file." : "Visible online-only or missing layers may disappear in airplane mode or outside service.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !summary.readyLayers.isEmpty {
                    Section(header: Text("Downloaded or imported")) {
                        ForEach(summary.readyLayers) { layer in
                            Label(layer.name, systemImage: layer.offlineStatus.symbolName)
                                .foregroundStyle(.green)
                        }
                    }
                }

                if !summary.warningLayers.isEmpty {
                    Section(
                        header: Text("Warnings"),
                        footer: Text("Download missing offline layers, import local GeoTIFF/GeoPDF/MBTiles files, or turn off online preview layers before leaving service.")
                    ) {
                        ForEach(summary.warningLayers) { layer in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(layer.name, systemImage: layer.offlineStatus.symbolName)
                                    .foregroundStyle(layer.offlineStatus.color)
                                Text(layer.offlineStatus.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Offline Check")
            .navigationBarItems(
                trailing: Button("Done") { dismiss() }
            )
        }
    }
}

// MARK: - Swipe compare picker

public struct LayerComparePickerView: View {
    @ObservedObject private var store: SurveyLayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var leftLayerID: UUID?
    @State private var rightLayerID: UUID?
    @State private var dividerPercent = 0.5

    public init(store: SurveyLayerStore) {
        self.store = store
        self._leftLayerID = State(initialValue: store.compareConfiguration.leftLayerID)
        self._rightLayerID = State(initialValue: store.compareConfiguration.rightLayerID)
        self._dividerPercent = State(initialValue: store.compareConfiguration.dividerPercent)
    }

    private var candidates: [SurveyMapLayer] {
        store.layers.filter { $0.isVisible && $0.group != .fieldData }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(
                    header: Text("Compare two map layers"),
                    footer: Text("Use swipe comparison for historical topo vs current topo, GeoPDF vs satellite, GeoPDF vs USGS topo, LiDAR terrain vs imagery, or old imagery vs new imagery.")
                ) {
                    Picker("Left side", selection: $leftLayerID) {
                        Text("Choose layer").tag(UUID?.none)
                        ForEach(candidates) { layer in
                            Text(layer.name).tag(UUID?.some(layer.id))
                        }
                    }
                    Picker("Right side", selection: $rightLayerID) {
                        Text("Choose layer").tag(UUID?.none)
                        ForEach(candidates) { layer in
                            Text(layer.name).tag(UUID?.some(layer.id))
                        }
                    }
                    HStack {
                        Text("Swipe divider")
                        Slider(value: $dividerPercent, in: 0.05...0.95)
                    }
                }
            }
            .navigationTitle("Compare Layers")
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Start") {
                    store.compareConfiguration = LayerCompareConfiguration(
                        isEnabled: leftLayerID != nil && rightLayerID != nil,
                        leftLayerID: leftLayerID,
                        rightLayerID: rightLayerID,
                        dividerPercent: dividerPercent
                    )
                    dismiss()
                }
                .disabled(leftLayerID == nil || rightLayerID == nil || leftLayerID == rightLayerID)
            )
        }
    }
}

// MARK: - Renderer helper

public struct SurveyLayerStackOverlay<LayerContent: View>: View {
    private let layers: [SurveyMapLayer]
    private let content: (SurveyMapLayer) -> LayerContent

    public init(layers: [SurveyMapLayer], @ViewBuilder content: @escaping (SurveyMapLayer) -> LayerContent) {
        self.layers = layers
        self.content = content
    }

    public var body: some View {
        ZStack {
            // Store order is top-to-bottom for the manager, so render the array
            // reversed: bottom layers first, top layers last.
            ForEach(layers.reversed()) { layer in
                content(layer)
                    .opacity(layer.opacity)
                    .blendMode(layer.blendMode.swiftUIBlendMode)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Preview data

#if DEBUG
struct MapLayerManagerView_Previews: PreviewProvider {
    static var previews: some View {
        let store = SurveyLayerStore(persistenceURL: nil)
        store.layers = [
            SurveyMapLayer(
                name: "Current GPS Location",
                subtitle: "Locked field overlay",
                group: .fieldData,
                kind: .fieldFeature,
                isLocked: true,
                opacity: 1.0,
                offlineStatus: .downloaded
            ),
            SurveyMapLayer(
                name: "DPR Site Points / Forms",
                subtitle: "Locked field overlay",
                group: .fieldData,
                kind: .dprForms,
                isLocked: true,
                opacity: 1.0,
                offlineStatus: .downloaded
            ),
            .importedGeoPDF(name: "_ags_8482ab64-654a-11f1-b104-203a43051df3.pdf", localFilePath: "/Imported/_ags_8482.pdf", coverage: "40.85594 to 40.85851, -124.06040 to -124.05720"),
            SurveyMapLayer.generatedOfflineRaster(name: "USGS Historical Topo - 1952", kind: .usgsHistoricalTopo, localFilePath: "/GeneratedMaps/usgs_historical_1952.pdf", year: "1952"),
            SurveyMapLayer.generatedOfflineRaster(name: "Best Public Imagery", kind: .naipImagery, localFilePath: "/GeneratedMaps/best_public_imagery.pdf"),
            SurveyMapLayer.generatedOfflineRaster(name: "LiDAR Hillshade / RVT", kind: .rvtVat, localFilePath: "/Terrain/RVT_VAT.tif"),
            .appleSatellitePreview()
        ]
        return MapLayerManagerView(store: store)
    }
}
#endif
