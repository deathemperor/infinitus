Pod::Spec.new do |s|
  s.name           = 'InfinitusLoopbackCatch'
  s.version        = '1.0.0'
  s.summary        = 'Answers the sign-in redirect the AWS / gcloud CLIs send to loopback.'
  s.description    = 'A one-shot HTTP listener on the phone\'s own loopback address, for the port a CLI\'s OAuth client redirects to. The page the browser lands on is answered here and its URL handed back verbatim, so the Mac can replay it against the CLI\'s own listener.'
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
