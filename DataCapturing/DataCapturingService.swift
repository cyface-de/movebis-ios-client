/*
 * Copyright 2017 Cyface GmbH
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
import CoreMotion
import CoreLocation
import os.log

/**
 An object of this class handles the lifecycle of starting and stopping data capturing as well as transmitting results to an appropriate server.
 
 To avoid using the users traffic or incurring costs, the service waits for Wifi access before transmitting any data. You may however force synchronization if required, using the provides `Synchronizer`.
 
 An object of this class is not thread safe and should only be used once per application. You may start and stop the service as often as you like and reuse the object.
 
 - Author: Klemens Muthmann
 - Version: 6.0.0
 - Since: 1.0.0
 */
public class DataCapturingService: NSObject {

    // MARK: - Properties
    /// Data used to identify log messages created by this component.
    private let LOG = OSLog(subsystem: "de.cyface", category: "DataCapturingService")

    /// `true` if data capturing is running; `false` otherwise.
    public var isRunning: Bool

    /// `true` if data capturing was running but is currently paused; `false` otherwise.
    public var isPaused: Bool

    /// A listener that is notified of important events during data capturing.
    private var handler: ((DataCapturingEvent) -> Void)

    /// The currently recorded `Measurement` or `nil` if there is no active recording.
    public var currentMeasurement: MeasurementEntity?

    /// An instance of `CMMotionManager`. There should be only one instance of this type in your application.
    private let motionManager: CMMotionManager

    /**
     Provides access to the devices geo location capturing hardware (such as GPS, GLONASS, GALILEO, etc.)
     and handles geo location updates in the background.
     */
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.showsBackgroundLocationIndicator = true
        manager.distanceFilter = kCLDistanceFilterNone
        manager.requestAlwaysAuthorization()
        return manager
    }()

    /**
     An API to store, retrieve and update captured data to the local system until the App
     can transmit it to a server.
     */
    let persistenceLayer: PersistenceLayer

    /// An in memory storage for accelerations, before they are written to disk.
    private var accelerationsCache = [Acceleration]()

    /// An in memory storage for geo locations, before they are written to disk.
    private var locationsCache = [GeoLocation]()

    /// The background queue used to capture data.
    private let capturingQueue = DispatchQueue.global(qos: .userInitiated)

    /// Synchronizes read and write operations on the `locationsCache` and the `accelerationsCache`.
    private let cacheSynchronizationQueue = DispatchQueue(label: "cacheSynchronization", attributes: .concurrent)

    /// The interval between data write opertions, during data capturing.
    private let savingInterval: TimeInterval

    /// A timer called in regular intervals to save the captured data to the underlying database.
    private var backgroundSynchronizationTimer: Timer!

    /// An optional API that is responsible for synchronizing data with a Cyface server.
    public var synchronizer: Synchronizer?

    // MARK: - Initializers
    /**
     Creates a new completely initialized `DataCapturingService` transmitting data
     via the provided server connection and accessing data a certain amount of times per second.
     - Parameters:
     
     - sensorManager: An instance of `CMMotionManager`.
     There should be only one instance of this type in your application.
     Since it seems to be impossible to create that instance inside a framework at the moment,
     you have to provide it via this parameter.
     - updateInterval: The accelerometer update interval in Hertz. By default this is set to the supported maximum of 100 Hz.
     - savingInterval: The interval in seconds to wait between saving data to the database. A higher number increses speed but requires more memory and leads to a bigger risk of data loss. A lower number incurs higher demands on the systems processing speed.
     - persistenceLayer: An API to store, retrieve and update captured data to the local system until the App can transmit it to a server.
     - dataSynchronizationIsActive: A flag telling the system, whether it should synchronize data or not. If this is `true` data will be synchronized; if it is `false`, no data will be synchronized.
     - eventHandler: An optional handler used by the capturing process to inform about `DataCapturingEvent`s.
     */
    public init(
        sensorManager manager: CMMotionManager,
        updateInterval interval: Double = 100,
        savingInterval time: TimeInterval = 30,
        persistenceLayer persistence: PersistenceLayer,
        synchronizer: Synchronizer?,
        eventHandler: @escaping ((DataCapturingEvent) -> Void)) {

        self.isRunning = false
        self.isPaused = false
        self.persistenceLayer = persistence
        self.motionManager = manager
        motionManager.accelerometerUpdateInterval = 1.0 / interval
        self.handler = eventHandler
        self.synchronizer = synchronizer
        self.savingInterval = time

        super.init()
    }

    // MARK: - Methods

    /**
     Starts the capturing process with an optional closure, that is notified of important events during the capturing process. This operation is idempotent.
     
     - Parameters:
     - context: The `MeasurementContext` to use for the newly created measurement.
     - onFinishedCall: The handler to call as soon as this call to start has completed and measuring has started. If an error happened during this process, it is provided as part of this handlers `Status` argument.
     - Throws:
     - `DataCapturingError.isPaused` if the service was paused and thus starting it makes no sense. If you need to continue call `resume(((DataCapturingEvent) -> Void))`.
     */
    public func start(inContext context: MeasurementContext, onFinishedCall handler: @escaping (Status) -> Void) throws {
        guard !isPaused else {
            throw DataCapturingError.isPaused
        }

        let timestamp = currentTimeInMillisSince1970()
        persistenceLayer.createMeasurement(at: timestamp, withContext: context) { measurement, status in
            if case .error = status {
                return handler(status)
            } else {

            guard let measurement = measurement, let measurementContext = measurement.context else {
                return handler(.error(PersistenceError.measurementNotLoadable(timestamp)))
            }
            let entity = MeasurementEntity(identifier: measurement.identifier, context: MeasurementContext(rawValue: measurementContext)!)
            self.currentMeasurement = entity
            self.startCapturing(savingEvery: savingInterval)
            self.handler(DataCapturingEvent.serviceStarted(measurement: entity))
            }
        }
    }

    // TODO: Add a queue that runs all the lifecycle methods
    /**
     Stops the currently running data capturing process or does nothing if the process is not
     running.

     - Throws:
     - `DataCapturingError.isPaused` if the service was paused and thus stopping it makes no sense.
     */
    public func stop() throws {
        guard !isPaused else {
            throw DataCapturingError.isPaused
        }

        stopCapturing()
        currentMeasurement = nil
        if let synchronizer = synchronizer {
            synchronizer.activate()
        }
    }

    // TODO: Add a queue that runs all the lifecylce methods
    /**
     Pauses the current data capturing measurement for the moment. No data is captured until `resume()` has been called, but upon the call to `resume()` the last measurement will be continued instead of beginning a new now. After using `pause()` you must call resume before you can call any other lifecycle method like `stop()`, for example.

     - Throws:
     - `DataCaturingError.notRunning` if the service was not running and thus pausing it makes no sense.
     - `DataCapturingError.isPaused` if the service was already paused and pausing it again makes no sense.
     */
    public func pause() throws {
        guard isRunning else {
            throw DataCapturingError.notRunning
        }

        guard !isPaused else {
            throw DataCapturingError.isPaused
        }

        stopCapturing()
        isPaused = true
    }

    // TODO: Add a queue that runs all the lifecycle methdos
    /**
     Resumes the current data capturing with the data capturing measurement that was running when `pause()` was called. A call to this method is only valid after a call to `pause()`. It is going to fail if used after `start()` or `stop()`.

     - Throws:
     - `DataCapturingError.notPaused` if the service was not paused and thus resuming it makes no sense.
     - `DataCapturingError.isRunning` if the service was running and thus resuming it makes no sense.
     */
    public func resume() throws {
        guard isPaused else {
            throw DataCapturingError.notPaused
        }

        guard !isRunning else {
            throw DataCapturingError.isRunning
        }

        startCapturing(savingEvery: savingInterval)
        isPaused = false
    }

    /// Provides the current time in milliseconds since january 1st 1970 (UTC).
    private func currentTimeInMillisSince1970() -> Int64 {
        return convertToUtcTimestamp(date: Date())
    }

    /// Converts a `Data` object to a UTC milliseconds timestamp since january 1st 1970.
    private func convertToUtcTimestamp(date value: Date) -> Int64 {
        return Int64(value.timeIntervalSince1970*1000.0)
    }

    // TODO: Saving interval should be a parameter.
    /**
     Internal method for starting the capturing process. This can optionally take in a handler for events occuring during data capturing.

     - Parameter savingEvery: The interval in seconds to wait between saving data to the database. A higher number increses speed but requires more memory and leads to a bigger risk of data loss. A lower number incurs higher demands on the systems processing speed.
     */
    func startCapturing(savingEvery time: TimeInterval) {
        // Preconditions
        guard !isRunning else {
            os_log("DataCapturingService.startCapturing(): Trying to start DataCapturingService which is already running!", log: LOG, type: .info)
            return
        }

        DispatchQueue.main.async {
            self.locationManager.delegate = self
            self.locationManager.startUpdatingLocation()
        }

        let queue = OperationQueue()
        queue.qualityOfService = QualityOfService.userInitiated
        queue.underlyingQueue = capturingQueue
        if motionManager.isAccelerometerAvailable {
            motionManager.startAccelerometerUpdates(to: queue) { data, _ in
                guard let myData = data else {
                    // Should only happen if the device accelerometer is broken or something similar. If this leads to problems we can substitute by a soft error handling such as a warning or something similar. However in such a case we might think everything works fine, while it really does not.
                    fatalError("DataCapturingService.start(): No Accelerometer data available!")
                }

                let accValues = myData.acceleration
                let acc = Acceleration(timestamp: self.currentTimeInMillisSince1970(),
                                       x: accValues.x,
                                       y: accValues.y,
                                       z: accValues.z)
                // Synchronize this write operation.
                self.cacheSynchronizationQueue.async(flags: .barrier) {
                    self.accelerationsCache.append(acc)
                }
            }
        }

        backgroundSynchronizationTimer = Timer.scheduledTimer(withTimeInterval: time, repeats: true, block: saveCapturedData)

        isRunning = true
    }

    /**
     An internal helper method for stopping the capturing process.
     */
    func stopCapturing() {
        guard isRunning else {
            os_log("Trying to stop a non running service!", log: LOG, type: .info)
            return
        }

        motionManager.stopAccelerometerUpdates()
        locationManager.stopUpdatingLocation()
        locationManager.delegate = nil
        backgroundSynchronizationTimer.fire()
        backgroundSynchronizationTimer.invalidate()
        isRunning = false

    }

    /**
     Method called by the `backgroundSynchronizationTimer` on each invocation. This method saves all data from `accelerationsCache` and from `locationsCache` to the underlying data storage (database and file system) and cleans both caches.

     - Parameter timer: The timer used to call this method.
     */
    func saveCapturedData(timer: Timer) {
        guard let measurement = currentMeasurement else {
            // Using a fatal error here since we can not provide a callback or throw an error. If this leads to App crashes a soft catch of this error is possible, by just printing a warning or something similar.
            fatalError("No current measurement to save the location to! Data capturing impossible.")
        }

        cacheSynchronizationQueue.async(flags: .barrier) {
            let localAccelerationsCache = self.accelerationsCache
            let localLocationsCache = self.locationsCache

            // These calls are nested to make sure, that not two operations are writing via different contexts to the database.
            self.persistenceLayer.save(locations: localLocationsCache, toMeasurement: measurement) {_, _ in
                self.persistenceLayer.save(accelerations: localAccelerationsCache, toMeasurement: measurement) { _, _ in

                }
            }
            self.accelerationsCache = [Acceleration]()
            self.locationsCache = [GeoLocation]()
        }
    }
}

// MARK: - CLLocationManagerDelegate
/**
 Extension making a `CLLocationManagerDelegate` out of the `DataCapturingService`. This adds the capability of listining for geo location changes.
 */
extension DataCapturingService: CLLocationManagerDelegate {

    /**
     The listener method that is informed about new geo locations.

     - Parameters:
     - manager: The location manager used.
     - didUpdateLocation: An array of the updated locations.
     */
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {

        for location in locations {
            // Smooth the way by removing outlier coordinates.
            let howRecent = location.timestamp.timeIntervalSinceNow
            guard location.horizontalAccuracy < 20 && abs(howRecent) < 10 else { continue }

            let geoLocation = GeoLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy,
                speed: location.speed,
                timestamp: convertToUtcTimestamp(date: location.timestamp))

            cacheSynchronizationQueue.async(flags: .barrier) {
                self.locationsCache.append(geoLocation)
            }

            DispatchQueue.main.async {
                self.handler(.geoLocationAcquired(position: geoLocation))
            }
        }
    }
}
