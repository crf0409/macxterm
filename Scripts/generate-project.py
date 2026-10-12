#!/usr/bin/env python3
"""Generate a deterministic Xcode project without requiring XcodeGen."""
import hashlib,json,pathlib
root=pathlib.Path(__file__).resolve().parent.parent
objects={}
def oid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(label,isa,**fields):
 key=oid(label); objects[key]={'isa':isa,**fields}; return key
refs=[]; sources=[]; resources=[]
for p in sorted((root/'Sources/MacXTermApp').rglob('*')):
 if p.suffix not in ['.swift','.xcprivacy','.xcstrings','.txt','.icns']: continue
 rel=str(p.relative_to(root)); kind={'.swift':'sourcecode.swift','.xcprivacy':'text.xml','.xcstrings':'text.json.xcstrings','.txt':'text','.icns':'image.icns'}[p.suffix]
 ref=add(rel,'PBXFileReference',lastKnownFileType=kind,path=rel,sourceTree='<group>'); refs.append(ref)
 bf=add(rel+'-build','PBXBuildFile',fileRef=ref)
 (sources if p.suffix=='.swift' else resources).append(bf)
for name in ['Base.xcconfig','Info.plist','MacXTerm.entitlements','ByPyHelper.entitlements']:
 rel='Config/'+name; refs.append(add(rel,'PBXFileReference',lastKnownFileType='text.xcconfig' if name.endswith('xcconfig') else 'text.plist.xml',path=rel,sourceTree='<group>'))
product=add('product','PBXFileReference',explicitFileType='wrapper.application',path='MacXTerm.app',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
products=add('products','PBXGroup',children=[product],name='Products',sourceTree='<group>')
group=add('root-group','PBXGroup',children=refs+[products],sourceTree='<group>')
local=add('local-package','XCLocalSwiftPackageReference',relativePath='.')
remote=add('swiftterm','XCRemoteSwiftPackageReference',repositoryURL='https://github.com/migueldeicaza/SwiftTerm.git',requirement={'kind':'exactVersion','version':'1.20.0'})
core=add('core-product','XCSwiftPackageProductDependency',package=local,productName='MacXTermCore')
term=add('terminal-product','XCSwiftPackageProductDependency',package=remote,productName='SwiftTerm')
frameworks=[]
for dep in [core,term]: frameworks.append(add(dep+'-build','PBXBuildFile',productRef=dep))
sourcesPhase=add('sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=sources,runOnlyForDeploymentPostprocessing=0)
resourcePhase=add('resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=resources,runOnlyForDeploymentPostprocessing=0)
frameworkPhase=add('frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=frameworks,runOnlyForDeploymentPostprocessing=0)
byPyPhase=add('bypy-runtime','PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],
    inputPaths=[],outputPaths=[],runOnlyForDeploymentPostprocessing=0,shellPath='/bin/sh',
    shellScript='python3 "$SRCROOT/Scripts/bundle-bypy-runtime.py" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ByPy"',
    alwaysOutOfDate=1,name='Bundle bypy runtime')
def configs(prefix,app=False):
 result=[]
 for config in ['Debug','Release']:
  settings={'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if config=='Debug' else 'dwarf-with-dsym','ONLY_ACTIVE_ARCH':'YES' if config=='Debug' else 'NO'}
  if config=='Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
  if app: settings['COMBINE_HIDPI_IMAGES']='YES'
  result.append(add(prefix+config,'XCBuildConfiguration',baseConfigurationReference=oid('Config/Base.xcconfig'),buildSettings=settings,name=config))
 return add(prefix+'list','XCConfigurationList',buildConfigurations=result,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
target=add('target','PBXNativeTarget',buildConfigurationList=configs('app-',True),buildPhases=[sourcesPhase,frameworkPhase,resourcePhase,byPyPhase],buildRules=[],dependencies=[],name='MacXTerm',packageProductDependencies=[core,term],productName='MacXTerm',productReference=product,productType='com.apple.product-type.application')
project=add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2600'},buildConfigurationList=configs('project-'),compatibilityVersion='Xcode 14.0',developmentRegion='zh-Hans',hasScannedForEncodings=0,knownRegions=['zh-Hans','en','Base'],mainGroup=group,packageReferences=[local,remote],productRefGroup=products,projectDirPath='',projectRoot='',targets=[target])
def plist(value,depth=0):
 if isinstance(value,dict): return '{\n'+''.join('\t'*(depth+1)+json.dumps(str(k))+ ' = '+plist(v,depth+1)+';\n' for k,v in value.items())+'\t'*depth+'}'
 if isinstance(value,list): return '('+', '.join(plist(v,depth+1) for v in value)+')'
 if isinstance(value,int): return str(value)
 return json.dumps(value,ensure_ascii=False)
p=root/'MacXTerm.xcodeproj'; p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n'+plist({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
schemes=p/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="MacXTerm.app" BlueprintName="MacXTerm" ReferencedContainer="container:MacXTerm.xcodeproj"/>'
(schemes/'MacXTerm.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug"/><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
workspace=p/'project.xcworkspace/xcshareddata/swiftpm'; workspace.mkdir(parents=True,exist_ok=True)
lock=root/'Package.resolved'
if lock.exists(): (workspace/'Package.resolved').write_bytes(lock.read_bytes())
print(p)
