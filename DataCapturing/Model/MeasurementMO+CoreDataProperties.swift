//
//  MeasurementMO+CoreDataProperties.swift
//  DataCapturing
//
//  Created by Team Cyface on 18.05.18.
//
//

import Foundation
import CoreData

extension MeasurementMO {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<MeasurementMO> {
        return NSFetchRequest<MeasurementMO>(entityName: "Measurement")
    }

    @NSManaged public var identifier: Int64
    @NSManaged public var synchronized: Bool
    @NSManaged public var timestamp: Int64
    @NSManaged public var context: String
    @NSManaged public var accelerations: [AccelerationPointMO]
    @NSManaged public var geoLocations: [GeoLocationMO]

}

// MARK: Generated accessors for accelerations
extension MeasurementMO {

    @objc(insertObject:inAccelerationsAtIndex:)
    @NSManaged public func insertIntoAccelerations(_ value: AccelerationPointMO, at idx: Int)

    @objc(removeObjectFromAccelerationsAtIndex:)
    @NSManaged public func removeFromAccelerations(at idx: Int)

    @objc(insertAccelerations:atIndexes:)
    @NSManaged public func insertIntoAccelerations(_ values: [AccelerationPointMO], at indexes: NSIndexSet)

    @objc(removeAccelerationsAtIndexes:)
    @NSManaged public func removeFromAccelerations(at indexes: NSIndexSet)

    @objc(replaceObjectInAccelerationsAtIndex:withObject:)
    @NSManaged public func replaceAccelerations(at idx: Int, with value: AccelerationPointMO)

    @objc(replaceAccelerationsAtIndexes:withAccelerations:)
    @NSManaged public func replaceAccelerations(at indexes: NSIndexSet, with values: [AccelerationPointMO])

    @objc(addAccelerationsObject:)
    @NSManaged public func addToAccelerations(_ value: AccelerationPointMO)

    @objc(removeAccelerationsObject:)
    @NSManaged public func removeFromAccelerations(_ value: AccelerationPointMO)

    @objc(addAccelerations:)
    @NSManaged public func addToAccelerations(_ values: NSOrderedSet)

    @objc(removeAccelerations:)
    @NSManaged public func removeFromAccelerations(_ values: NSOrderedSet)

}

// MARK: Generated accessors for geoLocations
extension MeasurementMO {

    @objc(insertObject:inGeoLocationsAtIndex:)
    @NSManaged public func insertIntoGeoLocations(_ value: GeoLocationMO, at idx: Int)

    @objc(removeObjectFromGeoLocationsAtIndex:)
    @NSManaged public func removeFromGeoLocations(at idx: Int)

    @objc(insertGeoLocations:atIndexes:)
    @NSManaged public func insertIntoGeoLocations(_ values: [GeoLocationMO], at indexes: NSIndexSet)

    @objc(removeGeoLocationsAtIndexes:)
    @NSManaged public func removeFromGeoLocations(at indexes: NSIndexSet)

    @objc(replaceObjectInGeoLocationsAtIndex:withObject:)
    @NSManaged public func replaceGeoLocations(at idx: Int, with value: GeoLocationMO)

    @objc(replaceGeoLocationsAtIndexes:withGeoLocations:)
    @NSManaged public func replaceGeoLocations(at indexes: NSIndexSet, with values: [GeoLocationMO])

    @objc(addGeoLocationsObject:)
    @NSManaged public func addToGeoLocations(_ value: GeoLocationMO)

    @objc(removeGeoLocationsObject:)
    @NSManaged public func removeFromGeoLocations(_ value: GeoLocationMO)

    @objc(addGeoLocations:)
    @NSManaged public func addToGeoLocations(_ values: NSOrderedSet)

    @objc(removeGeoLocations:)
    @NSManaged public func removeFromGeoLocations(_ values: NSOrderedSet)

}
