require 'xcodeproj'
require 'fileutils'
root = File.expand_path('../..', __dir__)
out = File.join(root, 'artifacts/rf-gpu-20261108/project')
FileUtils.mkdir_p(out)
project = Xcodeproj::Project.new(File.join(out, 'RFModelProbe.xcodeproj'))
target = project.new_target(:application, 'RFModelProbe', :ios, '18.0')
['scripts/rf-gpu-probe/Probe.swift', 'kicklab/Detection/RFInputNormalization.swift'].each do |source|
  target.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, source)))
end
resources = [File.join(root, 'kicklab/Models/RFDETRSmallRecovery040FP16.mlpackage')]
resources += Dir.glob('/Users/hewadmubariz/Desktop/projects/kicklab-lab/runs/v2/20261108-iphone11-current-gpu-001/*.mlpackage')
resources += Dir.glob(File.join(root, 'artifacts/rf-gpu-20261108/frames/*.png'))
resources.each { |path| target.resources_build_phase.add_file_reference(project.main_group.new_file(path)) }
target.build_configurations.each do |config|
  config.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER'=>'com.juggledude.modelprobe.debug',
    'DEVELOPMENT_TEAM'=>'G276PSQ2LH','CODE_SIGN_STYLE'=>'Automatic','GENERATE_INFOPLIST_FILE'=>'YES',
    'INFOPLIST_KEY_CFBundleDisplayName'=>'Juggle Model Check','INFOPLIST_KEY_UILaunchScreen_Generation'=>'YES',
    'TARGETED_DEVICE_FAMILY'=>'1','SWIFT_VERSION'=>'5.0','SWIFT_OPTIMIZATION_LEVEL'=>'-O',
    'SWIFT_COMPILATION_MODE'=>'wholemodule','MARKETING_VERSION'=>'1.0','CURRENT_PROJECT_VERSION'=>'1',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation'=>'YES'})
end
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target); scheme.set_launch_target(target); scheme.save_as(project.path, 'RFModelProbe', true)
project.save
puts project.path
