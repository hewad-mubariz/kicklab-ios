require 'xcodeproj'
require 'fileutils'
root = File.expand_path('../..', __dir__)
out = File.join(root, 'artifacts/crystal-first-use-20261103/project')
FileUtils.mkdir_p(out)
project = Xcodeproj::Project.new(File.join(out, 'CrystalProbe.xcodeproj'))
target = project.new_target(:application, 'CrystalProbe', :ios, '18.0')
sources = %w[scripts/crystal-preview-probe/Phone.swift kicklab/Effects/Lab/CrystalLabRenderer.swift
  kicklab/Effects/Lab/CrystalScene.swift kicklab/Effects/Lab/IceTextures.swift kicklab/Effects/Lab/IceGeometry.swift
  kicklab/Effects/Metal/EffectResourcePreparation.swift
  kicklab/Effects/Metal/CrystalEffect.metal]
sources.each { |path| target.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, path))) }
Dir.glob(File.join(root, 'kicklab/Effects/Lab/Crystal/*')).each do |path|
  target.resources_build_phase.add_file_reference(project.main_group.new_file(path)) if File.file?(path)
end
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.juggledude.crystalprobe.debug', 'DEVELOPMENT_TEAM' => 'G276PSQ2LH',
    'CODE_SIGN_STYLE' => 'Automatic', 'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'Crystal Check', 'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    'TARGETED_DEVICE_FAMILY' => '1', 'SWIFT_VERSION' => '5.0', 'SWIFT_OPTIMIZATION_LEVEL' => '-O',
    'SWIFT_COMPILATION_MODE' => 'wholemodule', 'IPHONEOS_DEPLOYMENT_TARGET' => '18.0',
    'MARKETING_VERSION' => '1.0', 'CURRENT_PROJECT_VERSION' => '1', 'ASSETCATALOG_COMPILER_APPICON_NAME' => '',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES'
  })
end
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target); scheme.set_launch_target(target); scheme.save_as(project.path, 'CrystalProbe', true)
project.save
puts project.path
