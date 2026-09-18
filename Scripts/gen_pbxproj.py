#!/usr/bin/env python3
"""Regenerates AirLiftFileManager.xcodeproj/project.pbxproj from the source tree.

Run from repo root:  python3 Scripts/gen_pbxproj.py
Deterministic output; no Xcode required to regenerate.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC_DIR = "AirLiftFileManager"
TEST_DIR = "Tests"

APP_EXCLUDE = {"Assets.xcassets"}


def build_number() -> str:
    """Monotonic build number from the commit count, so the on-device
    Version Info screen identifies exactly which build is installed."""
    try:
        out = subprocess.run(["git", "rev-list", "--count", "HEAD"],
                             capture_output=True, text=True, cwd=ROOT, check=True).stdout
        return out.strip() or "1"
    except Exception:
        return "1"


def scan_sources(base: str, exclude_dirs=frozenset()) -> list[str]:
    out = []
    for p in sorted((ROOT / base).rglob("*.swift")):
        rel = p.relative_to(ROOT).as_posix()
        if any(part in exclude_dirs for part in p.parts):
            continue
        out.append(rel)
    return out


def resources() -> list[str]:
    out = []
    assets = ROOT / SRC_DIR / "Resources" / "Assets.xcassets"
    if assets.exists():
        out.append(assets.relative_to(ROOT).as_posix())
    return out


def stable_id(prefix: str, name: str, kind: str) -> str:
    import hashlib
    digest = hashlib.sha256(f"{prefix}|{name}|{kind}".encode()).hexdigest()[:24].upper()
    return digest


def gen() -> str:
    app_sources = scan_sources(SRC_DIR)
    test_sources = scan_sources(TEST_DIR)
    res = resources()

    app_name = "AirLiftFileManager"
    tests_name = "AirLiftFileManagerTests"
    bundle_id = "com.bbaobaob.airliftfilemanager"
    tests_bundle_id = "com.bbaobaob.airliftfilemanager.tests"

    L: list[str] = []
    a = L.append

    a("// !$*UTF8*$!")
    a("{")
    a("\tarchiveVersion = 1;")
    a("\tclasses = {")
    a("\t};")
    a("\tobjectVersion = 56;")
    a("\tobjects = {")

    # PBXBuildFile + PBXFileReference for app sources
    for rel in app_sources + res:
        name = pathlib.PurePosixPath(rel).name
        fr = stable_id("file", rel, "ref")
        if rel.endswith(".xcassets"):
            a(f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {rel!r}; sourceTree = SOURCE_ROOT; }};")
        else:
            a(f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {rel!r}; sourceTree = SOURCE_ROOT; }};")
    for rel in test_sources:
        name = pathlib.PurePosixPath(rel).name
        fr = stable_id("tfile", rel, "ref")
        a(f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {rel!r}; sourceTree = SOURCE_ROOT; }};")

    app_target_id = "AA0000000000000000000001"
    tests_target_id = "AA0000000000000000000002"
    app_product_id = "AA0000000000000000000010"
    tests_product_id = "AA0000000000000000000011"

    a(f"\t\t{app_product_id} /* {app_name}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {app_name}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    a(f"\t\t{tests_product_id} /* {tests_name}.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {tests_name}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")

    # Build files for sources phase
    for rel in app_sources:
        name = pathlib.PurePosixPath(rel).name
        bf = stable_id("bf", rel, "app")
        fr = stable_id("file", rel, "ref")
        a(f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")
    for rel in test_sources:
        name = pathlib.PurePosixPath(rel).name
        bf = stable_id("bf", rel, "tests")
        fr = stable_id("tfile", rel, "ref")
        a(f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")
    for rel in res:
        name = pathlib.PurePosixPath(rel).name
        bf = stable_id("bf", rel, "res")
        fr = stable_id("file", rel, "ref")
        a(f"\t\t{bf} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")

    a("")
    # Groups
    main_group = "AA0000000000000000000020"
    products_group = "AA0000000000000000000021"
    a(f"\t\tAA0000000000000000000022 /* Project object */ = {{")
    a(f"\t\t\tisa = PBXGroup;")
    a(f"\t\t\tchildren = (")
    a(f"\t\t\t\t{main_group} /* {app_name} */,")
    a(f"\t\t\t\t{products_group} /* Products */,")
    a(f"\t\t\t);")
    a(f"\t\t\tsourceTree = \"<group>\";")
    a(f"\t\t}};")
    a(f"\t\t{main_group} /* {app_name} */ = {{")
    a(f"\t\t\tisa = PBXGroup;")
    a(f"\t\t\tchildren = (")
    for rel in app_sources + test_sources + res:
        name = pathlib.PurePosixPath(rel).name
        fr = stable_id("file", rel, "ref") if not rel.startswith(TEST_DIR) else stable_id("tfile", rel, "ref")
        a(f"\t\t\t\t{fr} /* {name} */,")
    a(f"\t\t\t);")
    a(f"\t\t\tpath = {SRC_DIR};".replace(SRC_DIR, "")) if False else a(f"\t\t\tname = {app_name};")
    a(f"\t\t\tsourceTree = \"<group>\";")
    a(f"\t\t}};")
    a(f"\t\t{products_group} /* Products */ = {{")
    a(f"\t\t\tisa = PBXGroup;")
    a(f"\t\t\tchildren = (")
    a(f"\t\t\t\t{app_product_id} /* {app_name}.app */,")
    a(f"\t\t\t\t{tests_product_id} /* {tests_name}.xctest */,")
    a(f"\t\t\t);")
    a(f"\t\t\tname = Products;")
    a(f"\t\t\tsourceTree = \"<group>\";")
    a(f"\t\t}};")

    # Build phases
    def sources_phase(pid, files, kind):
        a(f"\t\t{pid} /* Sources */ = {{")
        a(f"\t\t\tisa = PBXSourcesBuildPhase;")
        a(f"\t\t\tbuildActionMask = 2147483647;")
        a(f"\t\t\tfiles = (")
        for rel in files:
            name = pathlib.PurePosixPath(rel).name
            bf = stable_id("bf", rel, kind)
            a(f"\t\t\t\t{bf} /* {name} in Sources */,")
        a(f"\t\t\t);")
        a(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        a(f"\t\t}};")

    sources_phase("AA0000000000000000000030", app_sources, "app")
    sources_phase("AA0000000000000000000031", test_sources, "tests")

    a(f"\t\tAA0000000000000000000032 /* Frameworks */ = {{")
    a(f"\t\t\tisa = PBXFrameworksBuildPhase;")
    a(f"\t\t\tbuildActionMask = 2147483647;")
    a(f"\t\t\tfiles = (")
    a(f"\t\t\t);")
    a(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a(f"\t\t}};")

    a(f"\t\tAA0000000000000000000033 /* Resources */ = {{")
    a(f"\t\t\tisa = PBXResourcesBuildPhase;")
    a(f"\t\t\tbuildActionMask = 2147483647;")
    a(f"\t\t\tfiles = (")
    for rel in res:
        name = pathlib.PurePosixPath(rel).name
        bf = stable_id("bf", rel, "res")
        a(f"\t\t\t\t{bf} /* {name} in Resources */,")
    a(f"\t\t\t);")
    a(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a(f"\t\t}};")

    # Native targets
    a(f"\t\tAA0000000000000000000034 /* PBXTargetDependency */ = {{")
    a(f"\t\t\tisa = PBXTargetDependency;")
    a(f"\t\t\ttarget = {app_target_id} /* {app_name} */;")
    a(f"\t\t\ttargetProxy = AA0000000000000000000035 /* PBXContainerItemProxy */;")
    a(f"\t\t}};")
    a(f"\t\tAA0000000000000000000035 /* PBXContainerItemProxy */ = {{")
    a(f"\t\t\tisa = PBXContainerItemProxy;")
    a(f"\t\t\tcontainerPortal = AA000000000000000000000021 /* Project object */;")
    a(f"\t\t\tproxyType = 1;")
    a(f"\t\t\tremoteGlobalIDString = {app_target_id};")
    a(f"\t\t\tremoteInfo = {app_name};")
    a(f"\t\t}};")
    a(f"\t\t{app_target_id} /* {app_name} */ = {{")
    a(f"\t\t\tisa = PBXNativeTarget;")
    a(f"\t\t\tbuildConfigurationList = AA0000000000000000000040 /* Build configuration list for PBXNativeTarget \"{app_name}\" */;")
    a(f"\t\t\tbuildPhases = (")
    a(f"\t\t\t\tAA0000000000000000000030 /* Sources */,")
    a(f"\t\t\t\tAA0000000000000000000032 /* Frameworks */,")
    a(f"\t\t\t\tAA0000000000000000000033 /* Resources */,")
    a(f"\t\t\t);")
    a(f"\t\t\tbuildRules = (")
    a(f"\t\t\t);")
    a(f"\t\t\tdependencies = (")
    a(f"\t\t\t);")
    a(f"\t\t\tname = {app_name};")
    a(f"\t\t\tproductName = {app_name};")
    a(f"\t\t\tproductReference = {app_product_id} /* {app_name}.app */;")
    a(f"\t\t\tproductType = \"com.apple.product-type.application\";")
    a(f"\t\t}};")
    a(f"\t\t{tests_target_id} /* {tests_name} */ = {{")
    a(f"\t\t\tisa = PBXNativeTarget;")
    a(f"\t\t\tbuildConfigurationList = AA0000000000000000000041 /* Build configuration list for PBXNativeTarget \"{tests_name}\" */;")
    a(f"\t\t\tbuildPhases = (")
    a(f"\t\t\t\tAA0000000000000000000031 /* Sources */,")
    a(f"\t\t\t\tAA0000000000000000000032 /* Frameworks */,")
    a(f"\t\t\t);")
    a(f"\t\t\tbuildRules = (")
    a(f"\t\t\t);")
    a(f"\t\t\tdependencies = (")
    a(f"\t\t\t\tAA0000000000000000000034 /* PBXTargetDependency */,")
    a(f"\t\t\t);")
    a(f"\t\t\tname = {tests_name};")
    a(f"\t\t\tproductName = {tests_name};")
    a(f"\t\t\tproductReference = {tests_product_id} /* {tests_name}.xctest */;")
    a(f"\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";")
    a(f"\t\t}};")

    # Project object
    a(f"\t\tAA000000000000000000000021 /* PBXProject holder */ = {{")
    a(f"\t\t\tisa = PBXProject;")
    a(f"\t\t\tattributes = {{")
    a(f"\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    a(f"\t\t\t\tLastUpgradeCheck = 1600;")
    a(f"\t\t\t\tTargetAttributes = {{")
    a(f"\t\t\t\t\t{app_target_id} = {{CreatedOnToolsVersion = 16.0; }};")
    a(f"\t\t\t\t\t{tests_target_id} = {{CreatedOnToolsVersion = 16.0; }};")
    a(f"\t\t\t\t}};")
    a(f"\t\t\t}};")
    a(f"\t\t\tbuildConfigurationList = AA0000000000000000000042 /* Build configuration list for PBXProject \"{app_name}\" */;")
    a(f"\t\t\tcompatibilityVersion = \"Xcode 15.0\";")
    a(f"\t\t\tdevelopmentRegion = en;")
    a(f"\t\t\thasScannedForEncodings = 0;")
    a(f"\t\t\tknownRegions = (")
    a(f"\t\t\t\ten,")
    a(f"\t\t\t\tBase,")
    a(f"\t\t\t);")
    a(f"\t\t\tmainGroup = AA0000000000000000000022;")
    a(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    a(f"\t\t\tprojectDirPath = \"\";")
    a(f"\t\t\tprojectRoot = \"\";")
    a(f"\t\t\ttargets = (")
    a(f"\t\t\t\t{app_target_id} /* {app_name} */,")
    a(f"\t\t\t\t{tests_target_id} /* {tests_name} */,")
    a(f"\t\t\t);")
    a(f"\t\t}};")

    # Build configurations
    common_project_debug = """\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\tENABLE_TESTABILITY = YES;
\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\tMTL_FAST_MATH = YES;
\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\tSDKROOT = iphoneos;
\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";"""

    common_project_release = """\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\tMTL_FAST_MATH = YES;
\t\t\tONLY_ACTIVE_ARCH = NO;
\t\t\tSDKROOT = iphoneos;
\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";"""

    def target_settings(bundle, tests=False):
        if tests:
            base = f"""\t\t\tCODE_SIGN_STYLE = Manual;
\t\t\tCODE_SIGN_IDENTITY = "";
\t\t\tCODE_SIGNING_REQUIRED = NO;
\t\t\tCODE_SIGNING_ALLOWED = NO;
\t\t\tDEVELOPMENT_TEAM = "";
\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\tLD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks";
\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/AirLiftFileManager.app/AirLiftFileManager";
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle};
\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\tSDKROOT = iphoneos;
\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\tSWIFT_VERSION = 5.0;
\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""
            return base
        build_no = build_number()
        return f"""\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\tCODE_SIGN_STYLE = Manual;
\t\t\tCODE_SIGN_IDENTITY = "";
\t\t\tCODE_SIGNING_REQUIRED = NO;
\t\t\tCODE_SIGNING_ALLOWED = NO;
\t\t\tDEVELOPMENT_TEAM = "";
\t\t\tCURRENT_PROJECT_VERSION = {build_no};
\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\tINFOPLIST_FILE = AirLiftFileManager/Resources/Info.plist;
\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\tLD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
\t\t\tMARKETING_VERSION = 1.0;
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle};
\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\tSDKROOT = iphoneos;
\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\tSWIFT_VERSION = 5.0;
\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""

    def config(cid, name, settings, is_project=False):
        a(f"\t\t{cid} /* {name} */ = {{")
        a(f"\t\t\tisa = XCBuildConfiguration;")
        a(f"\t\t\tbuildSettings = {{")
        if is_project:
            a(settings)
        else:
            a(settings)
        a(f"\t\t\t}};")
        a(f"\t\t\tname = {name};")
        a(f"\t\t}};")

    # Project-level configs
    config("AA0000000000000000000050", "Debug", common_project_debug, True)
    config("AA0000000000000000000051", "Release", common_project_release, True)
    # App target configs
    config("AA0000000000000000000052", "Debug", target_settings(bundle_id))
    config("AA0000000000000000000053", "Release", target_settings(bundle_id))
    # Tests target configs
    config("AA0000000000000000000054", "Debug", target_settings(tests_bundle_id, tests=True))
    config("AA0000000000000000000055", "Release", target_settings(tests_bundle_id, tests=True))

    # Configuration lists
    def cfg_list(cid, name, entries, owner):
        a(f"\t\t{cid} /* Build configuration list for {owner} */ = {{")
        a(f"\t\t\tisa = XCConfigurationList;")
        a(f"\t\t\tbuildConfigurations = (")
        for e in entries:
            a(f"\t\t\t\t{e},")
        a(f"\t\t\t);")
        a(f"\t\t\tdefaultConfigurationIsVisible = 0;")
        a(f"\t\t\tdefaultConfigurationName = Release;")
        a(f"\t\t}};")

    cfg_list("AA0000000000000000000042", "", ["AA0000000000000000000050 /* Debug */", "AA0000000000000000000051 /* Release */"], f"PBXProject \"{app_name}\"")
    cfg_list("AA0000000000000000000040", "", ["AA0000000000000000000052 /* Debug */", "AA0000000000000000000053 /* Release */"], f"PBXNativeTarget \"{app_name}\"")
    cfg_list("AA0000000000000000000041", "", ["AA0000000000000000000054 /* Debug */", "AA0000000000000000000055 /* Release */"], f"PBXNativeTarget \"{tests_name}\"")

    a("\t};")
    a(f"\trootObject = AA000000000000000000000021 /* Project object */;")
    a("}")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    out = ROOT / f"AirLiftFileManager.xcodeproj/project.pbxproj"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(gen(), encoding="utf-8")
    print(f"wrote {out}")
