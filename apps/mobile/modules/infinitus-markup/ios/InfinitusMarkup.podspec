Pod::Spec.new do |s|
  s.name           = 'InfinitusMarkup'
  s.version        = '1.0.0'
  s.summary        = 'Quick Look markup over a draft image before it is sent.'
  s.description    = 'Presents a private copy of a composer image in Quick Look with editing on, so the pen, shapes and text tools flatten into the file that replaces the attachment.'
  s.author         = 'Infinitus'
  s.homepage       = 'https://infinitus.run'
  s.platforms      = {
    :ios => '18.0',
  }
  s.source         = { :path => '.' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
  s.source_files = '**/*.{h,m,mm,swift,hpp,cpp}'
end
