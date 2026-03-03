#!/usr/bin/env python3
"""
Generate a complete HybridCoach.xcodeproj for an iOS app.

Creates:
  - HybridCoach.xcodeproj/project.pbxproj
  - HybridCoach/Assets.xcassets/Contents.json
  - HybridCoach/Assets.xcassets/AppIcon.appiconset/Contents.json
  - HybridCoach/Assets.xcassets/AccentColor.colorset/Contents.json
  - HybridCoach/Info.plist
  - HybridCoach/Preview Content/Preview Assets.xcassets/Contents.json
  - HybridCoach.xcodeproj/xcshareddata/xcschemes/HybridCoach.xcscheme
"""

import json
import os

# ---------------------------------------------------------------------------
# Deterministic UUID generator so re-runs produce the same project file
# ---------------------------------------------------------------------------
_UUID_COUNTER = 0

def make_uuid():
    global _UUID_COUNTER
    _UUID_COUNTER += 1
    return f"{_UUID_COUNTER:024X}"

# ---------------------------------------------------------------------------
# Source files - (relative_folder, filename)
# ---------------------------------------------------------------------------
SOURCE_FILES = [
    ("App",                     "HybridCoachApp.swift"),
    ("App",                     "ContentView.swift"),
    ("BLE",                     "BLEConstants.swift"),
    ("BLE",                     "OBDAdapter.swift"),
    ("BLE",                     "BluetoothManager.swift"),
    ("BLE",                     "ELM327Adapter.swift"),
    ("BLE",                     "AutoPhixAdapter.swift"),
    ("BLE",                     "ProtocolAnalyzerStore.swift"),
    ("BLE",                     "ProtocolProber.swift"),
    ("OBD",                     "PIDDefinitions.swift"),
    ("OBD",                     "OBDResponse.swift"),
    ("OBD",                     "OBDService.swift"),
    ("OBD",                     "DTCModels.swift"),
    ("OBD",                     "DTCService.swift"),
    ("Data",                    "DrivingDataStore.swift"),
    ("Data",                    "EfficiencyAnalyzer.swift"),
    ("Data",                    "TripRecorder.swift"),
    ("Data",                    "Trip.swift"),
    ("Data",                    "AppSettings.swift"),
    ("Data",                    "TripAggregator.swift"),
    ("Data",                    "EVGoalStore.swift"),
    ("Data",                    "Route.swift"),
    ("Data",                    "LocationTracker.swift"),
    ("Data",                    "RouteStore.swift"),
    ("Data",                    "RouteCoachingEngine.swift"),
    ("Data",                    "PlannedRoute.swift"),
    ("Data",                    "PlannedRouteStore.swift"),
    ("Data",                    "RoutePlanningService.swift"),
    ("Data",                    "TripImprovementAnalyzer.swift"),
    ("Views/Dashboard",         "DashboardView.swift"),
    ("Views/Dashboard",         "GaugeView.swift"),
    ("Views/Dashboard",         "EVModeIndicator.swift"),
    ("Views/Dashboard",         "MPGDisplayView.swift"),
    ("Views/Coaching",          "CoachingView.swift"),
    ("Views/Coaching",          "CoachingTipRow.swift"),
    ("Views/Connection",        "ConnectionView.swift"),
    ("Views/Connection",        "DeviceRow.swift"),
    ("Views/Connection",        "ProtocolAnalyzerView.swift"),
    ("Views/Connection",        "DTCReaderView.swift"),
    ("Views/Connection",        "InteractiveConsoleView.swift"),
    ("Views/Connection",        "TrafficLogRow.swift"),
    ("Views/Trips",             "TripHistoryView.swift"),
    ("Views/Trips",             "TripDetailView.swift"),
    ("Views/Trips",             "TripChartView.swift"),
    ("Views/Trips",             "LifetimeStatsView.swift"),
    ("Views/Trips",             "TripImprovementMapView.swift"),
    ("Views/Goals",             "EVGoalView.swift"),
    ("Views/Routes",            "RouteListView.swift"),
    ("Views/Routes",            "RouteDetailView.swift"),
    ("Views/Routes",            "RouteMapView.swift"),
    ("Views/Routes",            "RouteComparisonView.swift"),
    ("Views/Routes",            "PlannedRouteEntryView.swift"),
    ("Views/Routes",            "PlannedRouteAnalysisView.swift"),
    ("Views/Routes",            "PlannedRouteMapView.swift"),
    ("Views/Settings",          "SettingsView.swift"),
    ("CarPlay",                 "CarPlaySceneDelegate.swift"),
    ("CarPlay",                 "CarPlayDashboardManager.swift"),
    ("Utilities",               "Units.swift"),
    ("Preview Content",         "MockOBDAdapter.swift"),
]

# ---------------------------------------------------------------------------
# Allocate UUIDs
# ---------------------------------------------------------------------------

# Root / project
UUID_PROJECT            = make_uuid()
UUID_ROOT_GROUP         = make_uuid()
UUID_MAIN_GROUP         = make_uuid()
UUID_PRODUCTS_GROUP     = make_uuid()
UUID_FRAMEWORKS_GROUP   = make_uuid()

# Target
UUID_NATIVE_TARGET      = make_uuid()
UUID_APP_PRODUCT_FILEREF = make_uuid()

# Build phases
UUID_SOURCES_PHASE      = make_uuid()
UUID_FRAMEWORKS_PHASE   = make_uuid()
UUID_RESOURCES_PHASE    = make_uuid()

# Build configurations (project level)
UUID_PROJECT_CONFIG_LIST   = make_uuid()
UUID_PROJECT_DEBUG_CONFIG  = make_uuid()
UUID_PROJECT_RELEASE_CONFIG = make_uuid()

# Build configurations (target level)
UUID_TARGET_CONFIG_LIST    = make_uuid()
UUID_TARGET_DEBUG_CONFIG   = make_uuid()
UUID_TARGET_RELEASE_CONFIG = make_uuid()

# CoreBluetooth framework
UUID_COREBLUETOOTH_FILEREF = make_uuid()
UUID_COREBLUETOOTH_BUILD   = make_uuid()

# Charts framework (SwiftUI Charts)
UUID_CHARTS_FILEREF = make_uuid()
UUID_CHARTS_BUILD   = make_uuid()

# CoreLocation framework
UUID_CORELOCATION_FILEREF = make_uuid()
UUID_CORELOCATION_BUILD   = make_uuid()

# MapKit framework
UUID_MAPKIT_FILEREF = make_uuid()
UUID_MAPKIT_BUILD   = make_uuid()

# CarPlay framework
UUID_CARPLAY_FILEREF = make_uuid()
UUID_CARPLAY_BUILD   = make_uuid()

# Entitlements
UUID_ENTITLEMENTS_FILEREF = make_uuid()

# Assets.xcassets
UUID_ASSETS_FILEREF     = make_uuid()
UUID_ASSETS_BUILDFILE   = make_uuid()

# Info.plist
UUID_INFOPLIST_FILEREF  = make_uuid()

# Per source file UUIDs
file_uuids = {}
for folder, name in SOURCE_FILES:
    file_uuids[(folder, name)] = (make_uuid(), make_uuid())

# Group UUIDs
group_paths = set()
for folder, _ in SOURCE_FILES:
    parts = folder.split("/")
    for i in range(len(parts)):
        group_paths.add("/".join(parts[: i + 1]))
group_uuids = {}
for gp in sorted(group_paths):
    group_uuids[gp] = make_uuid()

# ---------------------------------------------------------------------------
# Group tree helpers
# ---------------------------------------------------------------------------
def build_group_tree():
    tree = {gp: [] for gp in sorted(group_paths)}
    for gp in sorted(group_paths):
        parts = gp.split("/")
        if len(parts) > 1:
            parent = "/".join(parts[:-1])
            if parent in tree:
                tree[parent].append(gp)
    return tree

group_tree = build_group_tree()

def top_level_groups():
    return sorted([gp for gp in group_paths if "/" not in gp])

def files_in_group(group_path):
    return [(f, n) for f, n in SOURCE_FILES if f == group_path]

# ---------------------------------------------------------------------------
# Render a PBX group
# ---------------------------------------------------------------------------
def render_group(group_path):
    gid = group_uuids[group_path]
    name = group_path.split("/")[-1]
    children_lines = []
    for child in sorted(group_tree.get(group_path, [])):
        children_lines.append(f'\t\t\t\t{group_uuids[child]} /* {child.split("/")[-1]} */,')
    for folder, fname in files_in_group(group_path):
        fref, _ = file_uuids[(folder, fname)]
        children_lines.append(f'\t\t\t\t{fref} /* {fname} */,')
    children_str = "\n".join(children_lines)
    return (
        f'\t\t{gid} /* {name} */ = {{\n'
        f'\t\t\tisa = PBXGroup;\n'
        f'\t\t\tchildren = (\n'
        f'{children_str}\n'
        f'\t\t\t);\n'
        f'\t\t\tpath = "{name}";\n'
        f'\t\t\tsourceTree = "<group>";\n'
        f'\t\t}};'
    )

# ---------------------------------------------------------------------------
# Generate project.pbxproj
# ---------------------------------------------------------------------------
def generate_pbxproj():
    lines = []
    L = lines.append

    L('// !$*UTF8*$!')
    L('{')
    L('\tarchiveVersion = 1;')
    L('\tclasses = {')
    L('\t};')
    L('\tobjectVersion = 56;')
    L('\tobjects = {')
    L('')

    # ---- PBXBuildFile ----
    L('/* Begin PBXBuildFile section */')
    for folder, name in SOURCE_FILES:
        fref, bfile = file_uuids[(folder, name)]
        L(f'\t\t{bfile} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fref} /* {name} */; }};')
    L(f'\t\t{UUID_ASSETS_BUILDFILE} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {UUID_ASSETS_FILEREF} /* Assets.xcassets */; }};')
    L(f'\t\t{UUID_COREBLUETOOTH_BUILD} /* CoreBluetooth.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {UUID_COREBLUETOOTH_FILEREF} /* CoreBluetooth.framework */; }};')
    L(f'\t\t{UUID_CHARTS_BUILD} /* Charts.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {UUID_CHARTS_FILEREF} /* Charts.framework */; }};')
    L(f'\t\t{UUID_CORELOCATION_BUILD} /* CoreLocation.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {UUID_CORELOCATION_FILEREF} /* CoreLocation.framework */; }};')
    L(f'\t\t{UUID_MAPKIT_BUILD} /* MapKit.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {UUID_MAPKIT_FILEREF} /* MapKit.framework */; }};')
    L(f'\t\t{UUID_CARPLAY_BUILD} /* CarPlay.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {UUID_CARPLAY_FILEREF} /* CarPlay.framework */; }};')
    L('/* End PBXBuildFile section */')
    L('')

    # ---- PBXFileReference ----
    L('/* Begin PBXFileReference section */')
    for folder, name in SOURCE_FILES:
        fref, _ = file_uuids[(folder, name)]
        L(f'\t\t{fref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>"; }};')
    L(f'\t\t{UUID_ASSETS_FILEREF} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
    L(f'\t\t{UUID_INFOPLIST_FILEREF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    L(f'\t\t{UUID_APP_PRODUCT_FILEREF} /* HybridCoach.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = HybridCoach.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    L(f'\t\t{UUID_COREBLUETOOTH_FILEREF} /* CoreBluetooth.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CoreBluetooth.framework; path = System/Library/Frameworks/CoreBluetooth.framework; sourceTree = SDKROOT; }};')
    L(f'\t\t{UUID_CHARTS_FILEREF} /* Charts.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = Charts.framework; path = System/Library/Frameworks/Charts.framework; sourceTree = SDKROOT; }};')
    L(f'\t\t{UUID_CORELOCATION_FILEREF} /* CoreLocation.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CoreLocation.framework; path = System/Library/Frameworks/CoreLocation.framework; sourceTree = SDKROOT; }};')
    L(f'\t\t{UUID_MAPKIT_FILEREF} /* MapKit.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = MapKit.framework; path = System/Library/Frameworks/MapKit.framework; sourceTree = SDKROOT; }};')
    L(f'\t\t{UUID_CARPLAY_FILEREF} /* CarPlay.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CarPlay.framework; path = System/Library/Frameworks/CarPlay.framework; sourceTree = SDKROOT; }};')
    L(f'\t\t{UUID_ENTITLEMENTS_FILEREF} /* HybridCoach.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = HybridCoach.entitlements; sourceTree = "<group>"; }};')
    L('/* End PBXFileReference section */')
    L('')

    # ---- PBXFrameworksBuildPhase ----
    L('/* Begin PBXFrameworksBuildPhase section */')
    L(f'\t\t{UUID_FRAMEWORKS_PHASE} /* Frameworks */ = {{')
    L('\t\t\tisa = PBXFrameworksBuildPhase;')
    L('\t\t\tbuildActionMask = 2147483647;')
    L('\t\t\tfiles = (')
    L(f'\t\t\t\t{UUID_COREBLUETOOTH_BUILD} /* CoreBluetooth.framework in Frameworks */,')
    L(f'\t\t\t\t{UUID_CHARTS_BUILD} /* Charts.framework in Frameworks */,')
    L(f'\t\t\t\t{UUID_CORELOCATION_BUILD} /* CoreLocation.framework in Frameworks */,')
    L(f'\t\t\t\t{UUID_MAPKIT_BUILD} /* MapKit.framework in Frameworks */,')
    L(f'\t\t\t\t{UUID_CARPLAY_BUILD} /* CarPlay.framework in Frameworks */,')
    L('\t\t\t);')
    L('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    L('\t\t};')
    L('/* End PBXFrameworksBuildPhase section */')
    L('')

    # ---- PBXGroup ----
    L('/* Begin PBXGroup section */')

    # Root group
    L(f'\t\t{UUID_ROOT_GROUP} = {{')
    L('\t\t\tisa = PBXGroup;')
    L('\t\t\tchildren = (')
    L(f'\t\t\t\t{UUID_MAIN_GROUP} /* HybridCoach */,')
    L(f'\t\t\t\t{UUID_PRODUCTS_GROUP} /* Products */,')
    L(f'\t\t\t\t{UUID_FRAMEWORKS_GROUP} /* Frameworks */,')
    L('\t\t\t);')
    L('\t\t\tsourceTree = "<group>";')
    L('\t\t};')

    # Main group (HybridCoach source root)
    main_children = []
    for tg in top_level_groups():
        main_children.append(f'\t\t\t\t{group_uuids[tg]} /* {tg} */,')
    main_children.append(f'\t\t\t\t{UUID_ASSETS_FILEREF} /* Assets.xcassets */,')
    main_children.append(f'\t\t\t\t{UUID_INFOPLIST_FILEREF} /* Info.plist */,')
    main_children.append(f'\t\t\t\t{UUID_ENTITLEMENTS_FILEREF} /* HybridCoach.entitlements */,')

    L(f'\t\t{UUID_MAIN_GROUP} /* HybridCoach */ = {{')
    L('\t\t\tisa = PBXGroup;')
    L('\t\t\tchildren = (')
    for c in main_children:
        L(c)
    L('\t\t\t);')
    L('\t\t\tpath = HybridCoach;')
    L('\t\t\tsourceTree = "<group>";')
    L('\t\t};')

    # Products group
    L(f'\t\t{UUID_PRODUCTS_GROUP} /* Products */ = {{')
    L('\t\t\tisa = PBXGroup;')
    L('\t\t\tchildren = (')
    L(f'\t\t\t\t{UUID_APP_PRODUCT_FILEREF} /* HybridCoach.app */,')
    L('\t\t\t);')
    L('\t\t\tname = Products;')
    L('\t\t\tsourceTree = "<group>";')
    L('\t\t};')

    # Frameworks group
    L(f'\t\t{UUID_FRAMEWORKS_GROUP} /* Frameworks */ = {{')
    L('\t\t\tisa = PBXGroup;')
    L('\t\t\tchildren = (')
    L(f'\t\t\t\t{UUID_COREBLUETOOTH_FILEREF} /* CoreBluetooth.framework */,')
    L(f'\t\t\t\t{UUID_CHARTS_FILEREF} /* Charts.framework */,')
    L(f'\t\t\t\t{UUID_CORELOCATION_FILEREF} /* CoreLocation.framework */,')
    L(f'\t\t\t\t{UUID_MAPKIT_FILEREF} /* MapKit.framework */,')
    L(f'\t\t\t\t{UUID_CARPLAY_FILEREF} /* CarPlay.framework */,')
    L('\t\t\t);')
    L('\t\t\tname = Frameworks;')
    L('\t\t\tsourceTree = "<group>";')
    L('\t\t};')

    # All source groups
    for gp in sorted(group_paths):
        L(render_group(gp))

    L('/* End PBXGroup section */')
    L('')

    # ---- PBXNativeTarget ----
    L('/* Begin PBXNativeTarget section */')
    L(f'\t\t{UUID_NATIVE_TARGET} /* HybridCoach */ = {{')
    L('\t\t\tisa = PBXNativeTarget;')
    L(f'\t\t\tbuildConfigurationList = {UUID_TARGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "HybridCoach" */;')
    L('\t\t\tbuildPhases = (')
    L(f'\t\t\t\t{UUID_SOURCES_PHASE} /* Sources */,')
    L(f'\t\t\t\t{UUID_FRAMEWORKS_PHASE} /* Frameworks */,')
    L(f'\t\t\t\t{UUID_RESOURCES_PHASE} /* Resources */,')
    L('\t\t\t);')
    L('\t\t\tbuildRules = (')
    L('\t\t\t);')
    L('\t\t\tdependencies = (')
    L('\t\t\t);')
    L('\t\t\tname = HybridCoach;')
    L('\t\t\tproductName = HybridCoach;')
    L(f'\t\t\tproductReference = {UUID_APP_PRODUCT_FILEREF} /* HybridCoach.app */;')
    L('\t\t\tproductType = "com.apple.product-type.application";')
    L('\t\t};')
    L('/* End PBXNativeTarget section */')
    L('')

    # ---- PBXProject ----
    L('/* Begin PBXProject section */')
    L(f'\t\t{UUID_PROJECT} /* Project object */ = {{')
    L('\t\t\tisa = PBXProject;')
    L('\t\t\tattributes = {')
    L('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
    L('\t\t\t\tLastSwiftUpdateCheck = 1600;')
    L('\t\t\t\tLastUpgradeCheck = 1600;')
    L('\t\t\t\tTargetAttributes = {')
    L(f'\t\t\t\t\t{UUID_NATIVE_TARGET} = {{')
    L('\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;')
    L('\t\t\t\t\t};')
    L('\t\t\t\t};')
    L('\t\t\t};')
    L(f'\t\t\tbuildConfigurationList = {UUID_PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "HybridCoach" */;')
    L('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    L('\t\t\tdevelopmentRegion = en;')
    L('\t\t\thasScannedForEncodings = 0;')
    L('\t\t\tknownRegions = (')
    L('\t\t\t\ten,')
    L('\t\t\t\tBase,')
    L('\t\t\t);')
    L(f'\t\t\tmainGroup = {UUID_ROOT_GROUP};')
    L(f'\t\t\tproductRefGroup = {UUID_PRODUCTS_GROUP} /* Products */;')
    L('\t\t\tprojectDirPath = "";')
    L('\t\t\tprojectRoot = "";')
    L('\t\t\ttargets = (')
    L(f'\t\t\t\t{UUID_NATIVE_TARGET} /* HybridCoach */,')
    L('\t\t\t);')
    L('\t\t};')
    L('/* End PBXProject section */')
    L('')

    # ---- PBXResourcesBuildPhase ----
    L('/* Begin PBXResourcesBuildPhase section */')
    L(f'\t\t{UUID_RESOURCES_PHASE} /* Resources */ = {{')
    L('\t\t\tisa = PBXResourcesBuildPhase;')
    L('\t\t\tbuildActionMask = 2147483647;')
    L('\t\t\tfiles = (')
    L(f'\t\t\t\t{UUID_ASSETS_BUILDFILE} /* Assets.xcassets in Resources */,')
    L('\t\t\t);')
    L('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    L('\t\t};')
    L('/* End PBXResourcesBuildPhase section */')
    L('')

    # ---- PBXSourcesBuildPhase ----
    L('/* Begin PBXSourcesBuildPhase section */')
    L(f'\t\t{UUID_SOURCES_PHASE} /* Sources */ = {{')
    L('\t\t\tisa = PBXSourcesBuildPhase;')
    L('\t\t\tbuildActionMask = 2147483647;')
    L('\t\t\tfiles = (')
    for folder, name in SOURCE_FILES:
        _, bfile = file_uuids[(folder, name)]
        L(f'\t\t\t\t{bfile} /* {name} in Sources */,')
    L('\t\t\t);')
    L('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    L('\t\t};')
    L('/* End PBXSourcesBuildPhase section */')
    L('')

    # ---- XCBuildConfiguration ----
    L('/* Begin XCBuildConfiguration section */')

    # Project Debug
    L(f'\t\t{UUID_PROJECT_DEBUG_CONFIG} /* Debug */ = {{')
    L('\t\t\tisa = XCBuildConfiguration;')
    L('\t\t\tbuildSettings = {')
    L('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;')
    L('\t\t\t\tCLANG_ANALYZER_NONNULL = YES;')
    L('\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;')
    L('\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";')
    L('\t\t\t\tCLANG_ENABLE_MODULES = YES;')
    L('\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;')
    L('\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;')
    L('\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;')
    L('\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_COMMA = YES;')
    L('\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;')
    L('\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;')
    L('\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;')
    L('\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;')
    L('\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;')
    L('\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;')
    L('\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;')
    L('\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;')
    L('\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;')
    L('\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;')
    L('\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;')
    L('\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;')
    L('\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;')
    L('\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;')
    L('\t\t\t\tCOPY_PHASE_STRIP = NO;')
    L('\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;')
    L('\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;')
    L('\t\t\t\tENABLE_TESTABILITY = YES;')
    L('\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;')
    L('\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;')
    L('\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;')
    L('\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;')
    L('\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;')
    L('\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (')
    L('\t\t\t\t\t"DEBUG=1",')
    L('\t\t\t\t\t"$(inherited)",')
    L('\t\t\t\t);')
    L('\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;')
    L('\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;')
    L('\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;')
    L('\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;')
    L('\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;')
    L('\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;')
    L('\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;')
    L('\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;')
    L('\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;')
    L('\t\t\t\tMTL_FAST_MATH = YES;')
    L('\t\t\t\tONLY_ACTIVE_ARCH = YES;')
    L('\t\t\t\tSDKROOT = iphoneos;')
    L('\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) DEBUG";')
    L('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";')
    L('\t\t\t\tSWIFT_VERSION = 6.0;')
    L('\t\t\t};')
    L('\t\t\tname = Debug;')
    L('\t\t};')

    # Project Release
    L(f'\t\t{UUID_PROJECT_RELEASE_CONFIG} /* Release */ = {{')
    L('\t\t\tisa = XCBuildConfiguration;')
    L('\t\t\tbuildSettings = {')
    L('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;')
    L('\t\t\t\tCLANG_ANALYZER_NONNULL = YES;')
    L('\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;')
    L('\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";')
    L('\t\t\t\tCLANG_ENABLE_MODULES = YES;')
    L('\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;')
    L('\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;')
    L('\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;')
    L('\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_COMMA = YES;')
    L('\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;')
    L('\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;')
    L('\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;')
    L('\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;')
    L('\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;')
    L('\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;')
    L('\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;')
    L('\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;')
    L('\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;')
    L('\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;')
    L('\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;')
    L('\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;')
    L('\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;')
    L('\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;')
    L('\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;')
    L('\t\t\t\tCOPY_PHASE_STRIP = NO;')
    L('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
    L('\t\t\t\tENABLE_NS_ASSERTIONS = NO;')
    L('\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;')
    L('\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;')
    L('\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;')
    L('\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;')
    L('\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;')
    L('\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;')
    L('\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;')
    L('\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;')
    L('\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;')
    L('\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;')
    L('\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;')
    L('\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;')
    L('\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;')
    L('\t\t\t\tMTL_FAST_MATH = YES;')
    L('\t\t\t\tSDKROOT = iphoneos;')
    L('\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;')
    L('\t\t\t\tSWIFT_VERSION = 6.0;')
    L('\t\t\t\tVALIDATE_PRODUCT = YES;')
    L('\t\t\t};')
    L('\t\t\tname = Release;')
    L('\t\t};')

    # Target Debug
    L(f'\t\t{UUID_TARGET_DEBUG_CONFIG} /* Debug */ = {{')
    L('\t\t\tisa = XCBuildConfiguration;')
    L('\t\t\tbuildSettings = {')
    L('\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
    L('\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;')
    L('\t\t\t\tCODE_SIGN_ENTITLEMENTS = HybridCoach/HybridCoach.entitlements;')
    L('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
    L('\t\t\t\tCURRENT_PROJECT_VERSION = 1;')
    L('\t\t\t\tDEVELOPMENT_ASSET_PATHS = "HybridCoach/Preview\\\\ Content";')
    L('\t\t\t\tENABLE_PREVIEWS = YES;')
    L('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
    L('\t\t\t\tINFOPLIST_FILE = HybridCoach/Info.plist;')
    L('\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = HybridCoach;')
    L('\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = NO;')
    L('\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;')
    L('\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;')
    L('\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";')
    L('\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";')
    L('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (')
    L('\t\t\t\t\t"$(inherited)",')
    L('\t\t\t\t\t"@executable_path/Frameworks",')
    L('\t\t\t\t);')
    L('\t\t\t\tMARKETING_VERSION = 1.0;')
    L('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.hybridcoach.app;')
    L('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
    L('\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";')
    L('\t\t\t\tSUPPORTS_MACCATALYST = NO;')
    L('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
    L('\t\t\t\tSWIFT_VERSION = 6.0;')
    L('\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";')
    L('\t\t\t};')
    L('\t\t\tname = Debug;')
    L('\t\t};')

    # Target Release
    L(f'\t\t{UUID_TARGET_RELEASE_CONFIG} /* Release */ = {{')
    L('\t\t\tisa = XCBuildConfiguration;')
    L('\t\t\tbuildSettings = {')
    L('\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
    L('\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;')
    L('\t\t\t\tCODE_SIGN_ENTITLEMENTS = HybridCoach/HybridCoach.entitlements;')
    L('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
    L('\t\t\t\tCURRENT_PROJECT_VERSION = 1;')
    L('\t\t\t\tDEVELOPMENT_ASSET_PATHS = "HybridCoach/Preview\\\\ Content";')
    L('\t\t\t\tENABLE_PREVIEWS = YES;')
    L('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
    L('\t\t\t\tINFOPLIST_FILE = HybridCoach/Info.plist;')
    L('\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = HybridCoach;')
    L('\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = NO;')
    L('\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;')
    L('\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;')
    L('\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";')
    L('\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";')
    L('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (')
    L('\t\t\t\t\t"$(inherited)",')
    L('\t\t\t\t\t"@executable_path/Frameworks",')
    L('\t\t\t\t);')
    L('\t\t\t\tMARKETING_VERSION = 1.0;')
    L('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.hybridcoach.app;')
    L('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
    L('\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";')
    L('\t\t\t\tSUPPORTS_MACCATALYST = NO;')
    L('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
    L('\t\t\t\tSWIFT_VERSION = 6.0;')
    L('\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";')
    L('\t\t\t};')
    L('\t\t\tname = Release;')
    L('\t\t};')

    L('/* End XCBuildConfiguration section */')
    L('')

    # ---- XCConfigurationList ----
    L('/* Begin XCConfigurationList section */')
    L(f'\t\t{UUID_PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "HybridCoach" */ = {{')
    L('\t\t\tisa = XCConfigurationList;')
    L('\t\t\tbuildConfigurations = (')
    L(f'\t\t\t\t{UUID_PROJECT_DEBUG_CONFIG} /* Debug */,')
    L(f'\t\t\t\t{UUID_PROJECT_RELEASE_CONFIG} /* Release */,')
    L('\t\t\t);')
    L('\t\t\tdefaultConfigurationIsVisible = 0;')
    L('\t\t\tdefaultConfigurationName = Release;')
    L('\t\t};')
    L(f'\t\t{UUID_TARGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "HybridCoach" */ = {{')
    L('\t\t\tisa = XCConfigurationList;')
    L('\t\t\tbuildConfigurations = (')
    L(f'\t\t\t\t{UUID_TARGET_DEBUG_CONFIG} /* Debug */,')
    L(f'\t\t\t\t{UUID_TARGET_RELEASE_CONFIG} /* Release */,')
    L('\t\t\t);')
    L('\t\t\tdefaultConfigurationIsVisible = 0;')
    L('\t\t\tdefaultConfigurationName = Release;')
    L('\t\t};')
    L('/* End XCConfigurationList section */')

    L('\t};')
    L(f'\trootObject = {UUID_PROJECT} /* Project object */;')
    L('}')

    return "\n".join(lines)

# ---------------------------------------------------------------------------
# Info.plist
# ---------------------------------------------------------------------------
def generate_info_plist():
    return '''\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>NSBluetoothAlwaysUsageDescription</key>
\t<string>HybridCoach uses Bluetooth to communicate with your OBD-II adapter for real-time vehicle data.</string>
\t<key>NSLocationWhenInUseUsageDescription</key>
\t<string>HybridCoach uses your location to track driving routes and provide route-specific efficiency coaching.</string>
\t<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
\t<string>HybridCoach uses background location to continue tracking your route while you drive with the screen off.</string>
\t<key>UIBackgroundModes</key>
\t<array>
\t\t<string>bluetooth-central</string>
\t\t<string>location</string>
\t</array>
</dict>
</plist>
'''

# ---------------------------------------------------------------------------
# Asset catalog JSON files
# ---------------------------------------------------------------------------
def generate_assets_contents_json():
    return json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"

def generate_appicon_contents_json():
    return json.dumps({
        "images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}
    }, indent=2) + "\n"

def generate_accent_color_contents_json():
    return json.dumps({
        "colors": [{"idiom": "universal"}],
        "info": {"author": "xcode", "version": 1}
    }, indent=2) + "\n"

def generate_preview_assets_contents_json():
    return json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"

# ---------------------------------------------------------------------------
# Xcode scheme
# ---------------------------------------------------------------------------
def generate_xcscheme():
    return f'''\
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{UUID_NATIVE_TARGET}"
               BuildableName = "HybridCoach.app"
               BlueprintName = "HybridCoach"
               ReferencedContainer = "container:HybridCoach.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{UUID_NATIVE_TARGET}"
            BuildableName = "HybridCoach.app"
            BlueprintName = "HybridCoach"
            ReferencedContainer = "container:HybridCoach.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{UUID_NATIVE_TARGET}"
            BuildableName = "HybridCoach.app"
            BlueprintName = "HybridCoach"
            ReferencedContainer = "container:HybridCoach.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    base = os.path.dirname(os.path.abspath(__file__))
    source_root = os.path.join(base, "HybridCoach")

    # .xcodeproj
    xcodeproj_dir = os.path.join(base, "HybridCoach.xcodeproj")
    os.makedirs(xcodeproj_dir, exist_ok=True)

    pbxproj_path = os.path.join(xcodeproj_dir, "project.pbxproj")
    with open(pbxproj_path, "w") as f:
        f.write(generate_pbxproj())
    print(f"[OK] Created {pbxproj_path}")

    # Scheme
    scheme_dir = os.path.join(xcodeproj_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    scheme_path = os.path.join(scheme_dir, "HybridCoach.xcscheme")
    with open(scheme_path, "w") as f:
        f.write(generate_xcscheme())
    print(f"[OK] Created {scheme_path}")

    # Info.plist
    info_plist_path = os.path.join(source_root, "Info.plist")
    with open(info_plist_path, "w") as f:
        f.write(generate_info_plist())
    print(f"[OK] Created {info_plist_path}")

    # Assets.xcassets
    assets_dir = os.path.join(source_root, "Assets.xcassets")
    os.makedirs(assets_dir, exist_ok=True)
    with open(os.path.join(assets_dir, "Contents.json"), "w") as f:
        f.write(generate_assets_contents_json())
    print(f"[OK] Created {assets_dir}/Contents.json")

    appicon_dir = os.path.join(assets_dir, "AppIcon.appiconset")
    os.makedirs(appicon_dir, exist_ok=True)
    with open(os.path.join(appicon_dir, "Contents.json"), "w") as f:
        f.write(generate_appicon_contents_json())
    print(f"[OK] Created {appicon_dir}/Contents.json")

    accent_dir = os.path.join(assets_dir, "AccentColor.colorset")
    os.makedirs(accent_dir, exist_ok=True)
    with open(os.path.join(accent_dir, "Contents.json"), "w") as f:
        f.write(generate_accent_color_contents_json())
    print(f"[OK] Created {accent_dir}/Contents.json")

    # Preview Content / Preview Assets.xcassets
    preview_assets_dir = os.path.join(source_root, "Preview Content", "Preview Assets.xcassets")
    os.makedirs(preview_assets_dir, exist_ok=True)
    with open(os.path.join(preview_assets_dir, "Contents.json"), "w") as f:
        f.write(generate_preview_assets_contents_json())
    print(f"[OK] Created {preview_assets_dir}/Contents.json")

    print(f"\n=== Xcode project generation complete! ===")
    print(f"    Project: {xcodeproj_dir}")
    print(f"    Source files: {len(SOURCE_FILES)} Swift files referenced")
    print(f"    Target: HybridCoach (iOS 17.0, Swift 6.0)")
    print(f"    Frameworks: CoreBluetooth, Charts, CoreLocation, MapKit, CarPlay")
    print(f"    Bundle ID: com.hybridcoach.app")


if __name__ == "__main__":
    main()
