# Copyright 2018 - 2020 Cyface GmbH
#
# This file is part of the Cyface SDK for iOS.
#
# The Cyface SDK for iOS is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# The Cyface SDK for iOS is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with the Cyface SDK for iOS. If not, see <http://www.gnu.org/licenses/>.

Pod::Spec.new do |s|
  s.name             = 'DataCapturing'
  s.version          = '6.0.1'
  s.summary          = 'Framework used to continuously capture data from all available sensors on an iOS device and transmit it to a Cyface-API compatible server.'

  s.description      = <<-DESC
This framework can be included by your App if you are going to capture sensor data and transmit that data to a Cyface-API server for further analysis.
                       DESC

  s.homepage              = 'https://cyface.de'
  s.license               = { :type => 'GPL', :file => '../LICENSE' }
  s.authors               = 'Cyface GmbH'
  s.source                = { :git => 'https://github.com/cyface-de/ios-backend.git', :tag => s.version.to_s }
  s.social_media_url    = 'https://twitter.com/CyfaceDE'

  s.platform	          = :ios, '12.4'
  s.ios.deployment_target = '12.4'
  s.swift_version         = '5.0'

  s.source_files = 'Source/**/*{.h,.m,.swift}'
  s.resources = [ 'Source/**/*{.xcdatamodeld,.xcdatamodel,.xcmappingmodel}' ]

  s.frameworks = 'CoreData', 'CoreLocation', 'CoreMotion'
  
  # The following transitive dependencies are used by this project:
  # This one is used to handle network traffic like multipart requests
  s.dependency 'Alamofire', '~> 4.9.0'
  # A wrapper for the complicated ObjectiveC compression API.
  s.dependency 'DataCompression', '~> 3.4.0'

  s.test_spec 'Tests' do |test_spec|
    test_spec.source_files = '../Tests/**/*.swift'
  end

end
