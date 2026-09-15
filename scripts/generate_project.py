#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def ident(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

def add(key, isa, **fields):
    uid = ident(key)
    objects[uid] = dict(isa=isa, **fields)
    return uid

def serialize(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(indent + "\t" + serialize(k) + " = " + serialize(v, depth + 1) + ";\n" for k, v in value.items()) + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join(indent + "\t" + serialize(v, depth + 1) + ",\n" for v in value) + indent + ")"
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

package = add("package", "XCLocalSwiftPackageReference", relativePath=".")
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="Agent Meter.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="AgentMeterTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
groups = []

def source_phase(name, directory):
    refs, builds = [], []
    for file in sorted((ROOT / directory).glob("*.swift")):
        path = file.relative_to(ROOT).as_posix()
        ref = add(path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path, sourceTree="SOURCE_ROOT")
        refs.append(ref)
        builds.append(add("build-" + path, "PBXBuildFile", fileRef=ref))
    groups.append(add(name + "-group", "PBXGroup", name=name, children=refs, sourceTree="<group>"))
    return add(name + "-sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")

def dependencies(name, products):
    refs, builds = [], []
    for product in products:
        ref = add(name + product, "XCSwiftPackageProductDependency", package=package, productName=product)
        refs.append(ref)
        builds.append(add(name + product + "-link", "PBXBuildFile", productRef=ref))
    phase = add(name + "-frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")
    return refs, phase

def configurations(name, settings):
    configs = []
    for mode in ("Debug", "Release"):
        current = dict(settings)
        current["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if mode == "Debug" else "-O"
        current["DEBUG_INFORMATION_FORMAT"] = "dwarf" if mode == "Debug" else "dwarf-with-dsym"
        current["ONLY_ACTIVE_ARCH"] = "YES" if mode == "Debug" else "NO"
        if mode == "Debug":
            current["ENABLE_TESTABILITY"] = "YES"
            current["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        configs.append(add(name + mode, "XCBuildConfiguration", buildSettings=current, name=mode))
    return add(name + "-configs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

app_sources = source_phase("App", "Sources/AgentMeter")
test_sources = source_phase("Tests", "Tests/AuditorCoreTests")
app_deps, app_frameworks = dependencies("App", ["AuditorCore", "AccessibilityKit"])
test_deps, test_frameworks = dependencies("Tests", ["AuditorCore"])
app_config = configurations("app", {
    "PRODUCT_NAME": "Agent Meter", "PRODUCT_BUNDLE_IDENTIFIER": "local.agentmeter.app",
    "INFOPLIST_FILE": "Config/Info.plist", "CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_IDENTITY": "-",
    "ENABLE_APP_SANDBOX": "NO", "ENABLE_HARDENED_RUNTIME": "YES",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "COMBINE_HIDPI_IMAGES": "YES",
})
test_config = configurations("test", {
    "PRODUCT_NAME": "AgentMeterTests", "PRODUCT_BUNDLE_IDENTIFIER": "local.agentmeter.tests",
    "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Automatic",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@loader_path/../Frameworks"],
})
app = add("app-target", "PBXNativeTarget", name="AgentMeterApp", buildConfigurationList=app_config,
          buildPhases=[app_sources, app_frameworks], buildRules=[], dependencies=[],
          packageProductDependencies=app_deps, productName="Agent Meter", productReference=app_product,
          productType="com.apple.product-type.application")
tests = add("test-target", "PBXNativeTarget", name="AgentMeterTests", buildConfigurationList=test_config,
            buildPhases=[test_sources, test_frameworks], buildRules=[], dependencies=[],
            packageProductDependencies=test_deps, productName="AgentMeterTests", productReference=test_product,
            productType="com.apple.product-type.bundle.unit-test")
products = add("products", "PBXGroup", name="Products", children=[app_product, test_product], sourceTree="<group>")
main = add("main", "PBXGroup", children=groups + [products], sourceTree="<group>")
project_config = configurations("project", {
    "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "13.0", "SWIFT_VERSION": "5.0",
    "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SWIFT_STRICT_CONCURRENCY": "targeted",
})
project = add("project", "PBXProject", attributes={"LastUpgradeCheck": "1600", "BuildIndependentTargetsInParallel": "YES"},
              buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0", developmentRegion="en",
              hasScannedForEncodings="0", knownRegions=["en", "Base", "zh-Hans"], mainGroup=main,
              productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, tests], packageReferences=[package])
project_dir = ROOT / "AgentMeter.xcodeproj"
project_dir.mkdir(exist_ok=True)
(project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=project)) + "\n")

def reference(target, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:AgentMeter.xcodeproj"/>'

app_ref = reference(app, "AgentMeterApp", "Agent Meter.app")
test_ref = reference(tests, "AgentMeterTests", "AgentMeterTests.xctest")
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
schemes = project_dir / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "AgentMeter.xcscheme").write_text(scheme)
print(project_dir)
