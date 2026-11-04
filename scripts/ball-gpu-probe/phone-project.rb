require 'xcodeproj'
require 'fileutils'
root = File.expand_path('../..', __dir__)
out = File.join(root,'artifacts/ball-gpu-probe/phone-project')
FileUtils.mkdir_p(out)
# Reuse the same paired-image metrics and exact isolated renderer used on Mac.
main = File.read(File.join(__dir__,'Main.swift'))
metrics = main.split('@main enum Probe').first.gsub("import AppKit\n",'')
File.write(File.join(out,'Metrics.swift'),metrics)
File.write(File.join(out,'Support.swift'), <<~SWIFT)
import CoreGraphics
import Foundation
import simd
nonisolated final class LabSkinRenderer {
    static var shared: LabSkinRenderer? { nil }
    func image(skin: BallSkin, orientation: simd_quatf, size: Int) -> CGImage? { nil }
}
SWIFT
FileUtils.cp(File.join(__dir__,'Sphere.metal'),File.join(out,'Sphere.txt'))
project = Xcodeproj::Project.new(File.join(out,'GPUProbe.xcodeproj'))
target = project.new_target(:application,'GPUProbe',:ios,'18.0')
sources = ['scripts/ball-gpu-probe/Phone.swift','scripts/ball-gpu-probe/GPUSphere.swift',
           'artifacts/ball-gpu-probe/build/BallSkinSphereRenderer.swift','kicklab/Effects/BallSkin.swift','kicklab/Effects/BallCollectionMaterial.swift']
sources.map! { |path| File.join(root,path) }
sources += [File.join(out,'Metrics.swift'),File.join(out,'Support.swift')]
sources.each { |path| target.source_build_phase.add_file_reference(project.main_group.new_file(path)) }
resources = Dir.glob(File.join(root,'kicklab/Resources/BallMaterials/*.jdmaterial')) + [File.join(out,'Sphere.txt')]
resources.each { |path| target.resources_build_phase.add_file_reference(project.main_group.new_file(path)) }
target.build_configurations.each do |config|
  config.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER'=>'com.juggledude.gpuprobe.debug','DEVELOPMENT_TEAM'=>'G276PSQ2LH',
    'CODE_SIGN_STYLE'=>'Automatic','GENERATE_INFOPLIST_FILE'=>'YES','INFOPLIST_KEY_CFBundleDisplayName'=>'Juggle GPU Probe',
    'INFOPLIST_KEY_UILaunchScreen_Generation'=>'YES','TARGETED_DEVICE_FAMILY'=>'1','SWIFT_VERSION'=>'5.0',
    'SWIFT_OPTIMIZATION_LEVEL'=>'-O','SWIFT_COMPILATION_MODE'=>'wholemodule','IPHONEOS_DEPLOYMENT_TARGET'=>'18.0',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS'=>'BALL_SKIN_CPU_REFERENCE',
    'MARKETING_VERSION'=>'1.0','CURRENT_PROJECT_VERSION'=>'1','ASSETCATALOG_COMPILER_APPICON_NAME'=>'',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation'=>'YES'})
end
scheme=Xcodeproj::XCScheme.new;scheme.add_build_target(target);scheme.set_launch_target(target);scheme.save_as(project.path,'GPUProbe',true)
project.save
puts project.path
