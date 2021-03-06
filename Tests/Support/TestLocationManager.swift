/*
 * Copyright 2019 Cyface GmbH
 *
 * This file is part of the Cyface SDK for iOS.
 *
 * The Cyface SDK for iOS is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * The Cyface SDK for iOS is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with the Cyface SDK for iOS. If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation
import CoreLocation
@testable import DataCapturing

/**
 A mock implementation of a `LocationManager` used during testing. This implementation simply does nothing, because location updates are simulated during testing. It is still required to be mocked. Otherwise the test environment throws errors, since a real `CLLocationManager` is not allowed to be used during tests.

 - Author: Klemens Muthmann
 - Version: 1.0.0
 - Since: 4.0.0
 */
class TestLocationManager: LocationManager {

    weak var locationDelegate: CLLocationManagerDelegate?

    func startUpdatingLocation() {
        print("start updating location")
    }

    func stopUpdatingLocation() {
        print("stop updating location")
    }
}
