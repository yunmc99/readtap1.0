require 'xcodeproj'
project_path = 'readtap.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first
group = project.main_group.find_subpath(File.join('readtap'), true)
file_ref = group.new_file('MyMemoryTranslationService.swift')
target.source_build_phase.add_file_reference(file_ref)
project.save
