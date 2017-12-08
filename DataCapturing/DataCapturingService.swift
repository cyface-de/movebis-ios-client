//
//  DataCapturingService.swift
//  DataCapturingServices
//
//  Created by Team Cyface on 02.11.17.
//  Copyright © 2017 Cyface GmbH. All rights reserved.
//

import Foundation
import CoreMotion
import CoreLocation
import os.log
import CoreData

/**
 An object of this class handles the lifecycle of starting and stopping data capturing as well as transmitting results to an appropriate server.
 
 - Author: Klemens Muthmann
 - Version: 1.0.0
 - Since: 1.0.0
 
 To avoid using the users traffic or incurring costs, the service waits for Wifi access before transmitting any data. You may however force synchronization if required, using `forceSyncU()`.
 
 An object of this class is not thread safe and should only be used once per application. Youmay start and stop the service as often as you like and reuse the object.
 */
public class DataCapturingService: NSObject, CLLocationManagerDelegate {
    //MARK: Properties
    /**
     `true` if data capturing is running; `false` otherwise.
     */
    private(set) public var isRunning: Bool
    
    /**
     A listener that is notified of important events during data capturing.
     */
    private var listener: DataCapturingListener?
    
    /*
    /**
     A poor mans data storage.
     
     This is only in memory and will be replaced by a database on persistent storage during final implementation.
     */
    private(set) public var unsyncedMeasurements: [MeasurementMO]
 */
    
    private var currentMeasurement: MeasurementMO?
    
    /**
     An instance of `CMMotionManager`. There should be only one instance of this type in your application.
     */
    private let motionManager: CMMotionManager
    
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.allowsBackgroundLocationUpdates = true
        manager.activityType = .other
        manager.showsBackgroundLocationIndicator = true
        manager.distanceFilter = kCLDistanceFilterNone
        manager.requestAlwaysAuthorization()
        return manager
    }()
    
    private let persistenceLayer: PersistenceLayer

    
    //MARK: Initializers
    /**
     Creates a new completely initialized `DataCapturingService`.
     - parameters:
     - motionManager: An instance of `CMMotionManager`. There should be only one instance of this type in your application. Since it seems to be impossible to create that instance inside a framework at the moment, you have to provide it via this parameter.
     - interval: The accelerometer update interval in Hertz.
     */
    public init(withManager motionManager:CMMotionManager, andUpdateInterval interval : Double, using persistence: PersistenceLayer) {
        //unsyncedMeasurements = [] // TODO init persistence layer here and load unsynced measurements
        self.persistenceLayer = persistence
        isRunning = false
        self.motionManager = motionManager
        motionManager.accelerometerUpdateInterval = 1.0 / interval
        super.init()
    }
    
    //MARK: Methods
    /**
     Starts the capturing process. This operation is idempotent.
     */
    public func start() {
        guard !isRunning else {
            fatalError("Trying to start DataCapturingService which is already running!")
        }
        
        self.locationManager.startUpdatingLocation()
        self.isRunning = true
        let measurement = persistenceLayer.createMeasurement(at: currentTimeInMillisSince1970())
        // TODO Create persistent measurement here
        self.currentMeasurement = measurement
        //self.unsyncedMeasurements.append(measurement)
        
        if(motionManager.isAccelerometerAvailable) {
            motionManager.startAccelerometerUpdates(to: OperationQueue.current!) { data, error in
                guard let myData = data else {
                    fatalError("No Accelerometer data available!")
                }
                
                let accValues = myData.acceleration
                //let eventDate = NSDate(timeInterval: myData.timestamp, sinceDate: bootTime)
                let acc = self.persistenceLayer.createAcceleration(x: accValues.x,y: accValues.y, z: accValues.z,at: self.currentTimeInMillisSince1970())
                measurement.addToAccelerations(acc)
            }
        }
    }
    
    /**
     Starts the capturing process with a listener that is notified of important events occuring while the capturing process is running. This operation is idempotent.
     
     - parameters:
     - listener: A listener that is notified of important events during data capturing.
     */
    public func start(with listener:DataCapturingListener) {
        self.listener = listener
        self.start()
    }
    
    /**
     Stops the currently running data capturing process or does nothing of the process is not running.
     */
    public func stop() {
        isRunning = false
        motionManager.stopAccelerometerUpdates()
        locationManager.stopUpdatingLocation()
    }
    
    /**
     Forces the service to synchronize all Measurements now if a connection is available. If this is not called the service might wait for an opprotune moment to start synchronization.
     */
    public func forceSync() {
        // TODO add transmission code.
        persistenceLayer.deleteMeasurements()
    }
    
    /**
     Deletes an unsynchronized `Measurement` from this device.
     */
    public func delete(unsynced measurement : MeasurementMO) {
        persistenceLayer.delete(measurement: measurement)
    }
    
    /**
     Provides the current time in milliseconds since january 1st 1970 (UTC).
     */
    private func currentTimeInMillisSince1970() -> Int64 {
        return convertToUtcTimestamp(date: Date())
    }
    
    private func convertToUtcTimestamp(date value: Date) -> Int64 {
        return Int64(value.timeIntervalSince1970*1000.0)
    }
    
    // MARK: CLLocationManagerDelegate
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        
        guard !locations.isEmpty else {
            fatalError("No location available for DataCapturingService!")
        }
        let location: CLLocation = locations[0]
        os_log("New location: lat %@, lon %@",type: .info, location.coordinate.latitude.description,location.coordinate.longitude.description)
        
        guard let measurement = currentMeasurement else {
            fatalError("No current measurement to save the location to! Data capturing impossible.")
        }
        let geoLocation = persistenceLayer.createGeoLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy, speed: location.speed, at: convertToUtcTimestamp(date: location.timestamp))
        measurement.addToGeoLocations(geoLocation)
        
        
        persistenceLayer.save()
    }
}
