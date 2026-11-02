#!/usr/bin/env python3
"""Generate the checked-in, conventional Xcode project. Python 3 stdlib only."""
from pathlib import Path
import hashlib
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output-root", type=Path, help="Write a separate project copy without changing local signing settings")
args = parser.parse_args()

ROOT = Path(__file__).resolve().parent.parent
objects = []

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def ref(name):
    return uid(name)

def add(name, body):
    objects.append(f'\t\t{uid(name)} = {{ {body} }};')

def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

def settings(values):
    return '{ ' + ' '.join(f'{key} = {value};' for key, value in values.items()) + ' }'

sources = sorted((ROOT / 'App').glob('*.swift'))
for path in sources:
    add('file:' + path.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(path.name)}; sourceTree = "<group>";')
    add('build:' + path.name, f'isa = PBXBuildFile; fileRef = {ref("file:" + path.name)};')
add('file:Assets.xcassets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
add('build:Assets.xcassets', f'isa = PBXBuildFile; fileRef = {ref("file:Assets.xcassets")};')
add('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MiniTerm.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('AppGroup', 'isa = PBXGroup; children = (' + ', '.join(ref('file:' + p.name) for p in sources) + ', ' + ref('file:Assets.xcassets') + ',); path = App; sourceTree = "<group>";')
add('Products', f'isa = PBXGroup; children = ({ref("app")},); name = Products; sourceTree = "<group>";')
add('MainGroup', f'isa = PBXGroup; children = ({ref("AppGroup")}, {ref("Products")},); sourceTree = "<group>";')
add('GhosttyPackage', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/Lakr233/libghostty-spm.git"; requirement = {kind = exactVersion; version = 2.2.2026102101;};')
add('CorePackage', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
for name, package in [('GhosttyTerminal', 'GhosttyPackage'), ('MiniTermCore', 'CorePackage')]:
    add('product:' + name, f'isa = XCSwiftPackageProductDependency; package = {ref(package)}; productName = {name};')
    add('link:' + name, f'isa = PBXBuildFile; productRef = {ref("product:" + name)};')
add('Sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ', '.join(ref('build:' + p.name) for p in sources) + ',); runOnlyForDeploymentPostprocessing = 0;')
add('Frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (' + ', '.join(ref('link:' + n) for n in ['MiniTermCore', 'GhosttyTerminal']) + ',); runOnlyForDeploymentPostprocessing = 0;')
add('Resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (' + ref('build:Assets.xcassets') + ',); runOnlyForDeploymentPostprocessing = 0;')
project_settings = {
    'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
    'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SDKROOT': 'iphoneos', 'SWIFT_VERSION': '6.0',
}
target_settings = {
    'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
    'PRODUCT_BUNDLE_IDENTIFIER': 'com.samesense.mini-term', 'PRODUCT_NAME': 'MiniTerm',
    'CODE_SIGN_STYLE': 'Automatic', 'DEVELOPMENT_TEAM': '""', 'TARGETED_DEVICE_FAMILY': '2',
    'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_KEY_CFBundleDisplayName': '"Mini Term"',
    'INFOPLIST_KEY_LSApplicationCategoryType': '"public.app-category.developer-tools"',
    'INFOPLIST_KEY_NSLocalNetworkUsageDescription': '"Connect to your Mac over SSH on the local network."',
    'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES',
    'INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents': 'YES',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad': '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
    'CURRENT_PROJECT_VERSION': '1', 'MARKETING_VERSION': '0.1.0',
    'SUPPORTED_PLATFORMS': '"iphoneos iphonesimulator"', 'SUPPORTS_MACCATALYST': 'NO',
    'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD': 'NO', 'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD': 'NO',
    'LD_RUNPATH_SEARCH_PATHS': '"$(inherited) @executable_path/Frameworks"',
}
for scope, base in [('Project', project_settings), ('Target', target_settings)]:
    for configuration in ['Debug', 'Release']:
        values = dict(base)
        if scope == 'Project':
            values.update({'DEBUG_INFORMATION_FORMAT': 'dwarf' if configuration == 'Debug' else '"dwarf-with-dsym"',
                           'SWIFT_OPTIMIZATION_LEVEL': '"-Onone"' if configuration == 'Debug' else '"-O"',
                           'ENABLE_TESTABILITY': 'YES' if configuration == 'Debug' else 'NO'})
            if configuration == 'Debug':
                values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '"DEBUG $(inherited)"'
        add(scope + configuration, f'isa = XCBuildConfiguration; buildSettings = {settings(values)}; name = {configuration};')
    add(scope + 'Configs', f'isa = XCConfigurationList; buildConfigurations = ({ref(scope + "Debug")}, {ref(scope + "Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('Target', f'isa = PBXNativeTarget; buildConfigurationList = {ref("TargetConfigs")}; buildPhases = ({ref("Sources")}, {ref("Frameworks")}, {ref("Resources")},); buildRules = (); dependencies = (); name = MiniTerm; packageProductDependencies = ({ref("product:MiniTermCore")}, {ref("product:GhosttyTerminal")},); productName = MiniTerm; productReference = {ref("app")}; productType = "com.apple.product-type.application";')
add('Project', f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{{ref("Target")} = {{CreatedOnToolsVersion = 26.0;}};}};}}; buildConfigurationList = {ref("ProjectConfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {ref("MainGroup")}; packageReferences = ({ref("CorePackage")}, {ref("GhosttyPackage")},); productRefGroup = {ref("Products")}; projectDirPath = ""; projectRoot = ""; targets = ({ref("Target")},);')
project = (args.output_root or ROOT) / 'MiniTerm.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {ref("Project")};\n}}\n')
scheme = project / 'xcshareddata/xcschemes/MiniTerm.xcscheme'
scheme.parent.mkdir(parents=True, exist_ok=True)
buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref("Target")}" BuildableName="MiniTerm.app" BlueprintName="MiniTerm" ReferencedContainer="container:MiniTerm.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated MiniTerm.xcodeproj')
