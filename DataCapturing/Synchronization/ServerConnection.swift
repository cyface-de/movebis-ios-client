/*
 * Copyright 2018 Cyface GmbH
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
import Alamofire
import os.log

/**
 Realizes a connection to a Cyface Collector server.

 An object of this class realizes a connection between an iOS app capturing some data and a Cyface Collector server receiving that data.
 The data is transmitted using HTTPS in chunks of one measurement.
 The transmission format is compressed Cyface binary format.
 The cyface binary format is created by a `CyfaceBinaryFormatSerializer`.

 This implementation follows code published here: https://gist.github.com/toddhopkinson/60cae9e48e845ce02bcf526f388cfa63

 - Author: Klemens Muthmann
 - Version: 6.0.0
 - Since: 1.0.0
 */
public class ServerConnection {

    // MARK: - Properties

    /// The logger used for objects of this class.
    private static let osLog = OSLog(subsystem: "ServerConnection", category: "de.cyface")
    /// An `URL` used to upload data to. There should be a server available at that location.
    public var apiURL: URL
    /// An object used to authenticate this app with a Cyface Collector server.
    public let authenticator: Authenticator
    /// A name that tells the system which kind of iOS device this is.
    private var modelIdentifier: String {
        if let simulatorModelIdentifier = ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulatorModelIdentifier }
        var sysinfo = utsname()
        uname(&sysinfo) // ignore return value
        return String(bytes: Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN)), encoding: .ascii)!.trimmingCharacters(in: .controlCharacters)
    }

    /**
     A globally unique identifier of this device. This is used to separate data transmitted by one device from data transmitted by another one on the server side. An installation identifier is not device specific for technical and data protection reasons it is recreated every time the app is reinstalled.
     */
    var installationIdentifier: String {
        if let applicationIdentifier = UserDefaults.standard.string(forKey: "de.cyface.identifier") {
            return applicationIdentifier
        } else {
            let applicationIdentifier = UUID.init().uuidString
            UserDefaults.standard.set(applicationIdentifier, forKey: "de.cyface.identifier")
            return applicationIdentifier
        }
    }

    /// The *CoreData* stack used to access the data to transfer.
    let manager: CoreDataManager

    // MARK: - Initializers

    /**
     Creates a new server connection to a certain endpoint, using the provided authentication method.

     - Parameters:
        - apiURL: The URL endpoint to upload data to.
        - authenticator: An object used to authenticate this app with a Cyface Collector server.
        - onManager: The *CoreData* stack used to load the data to transmit.
     */
    public required init(apiURL url: URL, authenticator: Authenticator, onManager manager: CoreDataManager) {
        self.apiURL = url
        self.authenticator = authenticator
        self.manager = manager
    }

    // MARK: - Methods

    /**
     Synchronizes the provided `measurement` with a remote server and calls either a `success` or `failure` handler when finished.

     - Parameters:
        - measurement: The measurement to synchronize.
        - onSuccess: The handler to call, when synchronization has succeeded. This handler is provided with the synchronized `MeasurementEntity`.
        - onFailure: The handler to call, when the synchronization has failed. This handler provides an error status. The error contains the reason of the failure. The `MeasurementEntity` is the same as the one provided as parameter to this method.
     */
    public func sync(measurement: MeasurementEntity, onSuccess success: @escaping ((MeasurementEntity) -> Void) = {_ in }, onFailure failure: @escaping ((MeasurementEntity, Error) -> Void) = {_, _ in }) {

        authenticator.authenticate(onSuccess: {jwtToken in
            self.onAuthenticated(token: jwtToken, measurement: measurement, onSuccess: success, onFailure: failure)
        }, onFailure: { error in
            failure(measurement, error)
        })

    }

    /**
     The handler called after this app has successfully authenticated with a Cyface Collector server.

     - Parameters:
        - token: The Java Web Token returned by the authentication process
        - measurement: The measurement to transmit.
        - onSuccess: Called after successful data transmission with information about which measurement was transmitted.
        - onFailure: Called after a failed data transmission with information about which measurement failed and the error.
     */
    func onAuthenticated(token: String, measurement: MeasurementEntity, onSuccess: @escaping (MeasurementEntity) -> Void, onFailure: @escaping (MeasurementEntity, Error) -> Void) {
        let url = apiURL.appendingPathComponent("measurements")
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(token)",
            "Content-type": "multipart/form-data"
        ]

        let encode: ((MultipartFormData) -> Void) = {data in
            os_log("Encoding!", log: ServerConnection.osLog, type: OSLogType.default)
            do {
                try self.create(request: data, for: measurement)
            } catch let error {
                os_log("Encoding data failed! Error %{PUBLIC}@", log: ServerConnection.osLog, type: .error, error.localizedDescription)
            }
        }
        Networking.sharedInstance.backgroundSessionManager.upload(multipartFormData: encode, usingThreshold: SessionManager.multipartFormDataEncodingMemoryThreshold, to: url, method: .post, headers: headers, encodingCompletion: {encodingResult in
            do {
                try self.onEncodingComplete(for: measurement, with: encodingResult, onSuccess: onSuccess, onFailure: onFailure)
            } catch {
                onFailure(measurement, error)
            }
        })
    }

    /**
     Create a MultiPart/FormData request to transmit a measurement to a Cyface Collector server.

     - Parameters:
        - request: The request to fill with data.
        - for: The measurement to transmit.
     - Throws:
        - `ServerConnectionError.missingInstallationIdentifier` If there is no valid installation identifier to identify this SDK installation with a server.
        - `ServerConnectionError.missingMeasurementIdentifier` If the current measurement has no valid device wide unique identifier.
        - `ServerConnectionError.missingDeviceType` If the device type of this device could not be figured out.
        - `PersistenceError.dataNotLoadable` If there is no such measurement.
        - `PersistenceError.noContext` If there is no current context and no background context can be created. If this happens something is seriously wrong with CoreData.
        - `PersistenceError.modelNotLoabable` If the model is not loadable
        - `PersistenceError.modelNotInitializable` If the model was loaded (so it is available) but can not be initialized.
        - `SerializationError.missingData` If no track data was found.
        - `SerializationError.invalidData` If the database provided inconsistent and wrongly typed data. Something is seriously wrong in these cases.
        - `FileSupportError.notReadable` If the data file was not readable.
        - Some unspecified errors from within CoreData.
        - Some unspecified undocumented file system error if file was not accessible.
     */
    func create(request: MultipartFormData, for measurement: MeasurementEntity) throws {
        os_log("Creating request", log: ServerConnection.osLog, type: .default)
        // Load and serialize measurement synchronously.
        let persistenceLayer = PersistenceLayer(onManager: manager)
        persistenceLayer.context = persistenceLayer.makeContext()
        let measurement = try persistenceLayer.load(measurementIdentifiedBy: measurement.identifier)

        try addMetaData(to: request, for: measurement)

        let payloadUrl = try write(measurement)
        request.append(payloadUrl, withName: "fileToUpload", fileName: "\(self.installationIdentifier)_\(measurement.identifier).cyf", mimeType: "application/octet-stream")
    }

    func addMetaData(to request: MultipartFormData, for measurement: MeasurementMO) throws {
        guard let deviceIdData = installationIdentifier.data(using: String.Encoding.utf8) else {
            throw ServerConnectionError.missingInstallationIdentifier
        }
        guard let measurementIdData = String(measurement.identifier).data(using: String.Encoding.utf8) else {
            throw ServerConnectionError.missingMeasurementIdentifier
        }
        guard let deviceTypeData = modelIdentifier.data(using: String.Encoding.utf8) else {
            throw ServerConnectionError.missingDeviceType
        }

        let bundle = Bundle(for: type(of: self))
        guard let appVersion = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)?.data(using: String.Encoding.utf8) else {
            throw ServerConnectionError.missingAppVersion
        }

        let length = String(measurement.trackLength).data(using: String.Encoding.utf8)!
        let locationCount = try PersistenceLayer.collectGeoLocations(from: measurement).count
        let locationCountData = String(locationCount).data(using: String.Encoding.utf8)!

            if let startLocationRaw = (measurement.tracks?.firstObject as? Track)?.locations?.firstObject as? GeoLocationMO {
                let startLocationLat = "\(startLocationRaw.lat)".data(using: String.Encoding.utf8)!
                let startLocationLon = "\(startLocationRaw.lon)".data(using: String.Encoding.utf8)!
                let startLocationTs = "\(startLocationRaw.timestamp)".data(using: String.Encoding.utf8)!
                request.append(startLocationLat, withName: "startLocationLat")
                request.append(startLocationLon, withName: "startLocationLon")
                request.append(startLocationTs, withName: "startLocationTs")
            }

            if let endLocationRaw = (measurement.tracks?.lastObject as? Track)?.locations?.lastObject as? GeoLocationMO {
                let endLocationLat = "\(endLocationRaw.lat)".data(using: String.Encoding.utf8)!
                let endLocationLon = "\(endLocationRaw.lon)".data(using: String.Encoding.utf8)!
                let endLocationTs = "\(endLocationRaw.timestamp)".data(using: String.Encoding.utf8)!
                request.append(endLocationLat, withName: "endLocationLat")
                request.append(endLocationLon, withName: "endLocationLon")
                request.append(endLocationTs, withName: "endLocationTs")
            }

        request.append(deviceIdData, withName: "deviceId")
        request.append(measurementIdData, withName: "measurementId")
        request.append(deviceTypeData, withName: "deviceType")
        request.append("iOS \(UIDevice.current.systemVersion)".data(using: String.Encoding.utf8)!, withName: "osVersion")
        request.append(appVersion, withName: "appVersion")
        request.append(length, withName: "length")
        request.append(locationCountData, withName: "locationCount")
    }

    /**
     Called by Alamofire when encoding the request by Alamofire was finished.
     Starts the actual data transmission if encoding was successful.

     - Parameters:
        - for: The measurement that was encoded into a transmission request
        - with: The encoded measurement.
        - onSuccess: Called if data transmission was successful. Gets the transmitted measurement as a parameter.
        - onFailure: Called if data transmission failed for some reason. Gets the transmitted measurement and information about the error.
     - Throws:
        - Some unspecified undocumented error if encoding has failed. But even if no error is thrown encoding might have failed. There is currently no way in Alamofire to know for sure.
     */
    func onEncodingComplete(for measurement: MeasurementEntity, with result: SessionManager.MultipartFormDataEncodingResult, onSuccess success: @escaping ((MeasurementEntity) -> Void), onFailure failure: @escaping ((MeasurementEntity, Error) -> Void)) throws {
        os_log("encoding complete", log: ServerConnection.osLog, type: .default)
        switch result {
        case .success(let upload, _, _):
            // Two status codes are acceptable. A 201 is a successful upload, while a 409 is a conflict. In both cases the measurement should be marked as uploaded successfully.
            upload.validate(statusCode: [201, 409]).responseString { response in
                os_log("Validating Upload!", log: ServerConnection.osLog, type: .default)
                switch response.result {
                case .success:
                    success(measurement)
                case .failure(let error):
                    failure(measurement, error)
                }
            }
        case .failure(let error):
            throw error
        }
    }

    /**
     Write the provided `measurement` to a file for background synchronization

     - Parameter measurement: The measurement to serialize as a file.
     - Returns: The url of the file containing the measurement data.
     - Throws:
        - `SerializationError.missingData` If no track data was found.
        - `SerializationError.invalidData` If the database provided inconsistent and wrongly typed data. Something is seriously wrong in these cases.
        - `FileSupportError.notReadable` If the data file was not readable.
        - Some unspecified undocumented file system error if file was not accessible.
     */
    private func write(_ measurement: MeasurementMO) throws -> URL {
        let measurementFile = MeasurementFile()
        return try measurementFile.write(serializable: measurement, to: measurement.identifier)
    }
}

/**
 An enumeration encapsulating errors used by server connections.
 ````
 case authenticationNotSuccessful
 case notAuthenticated
 case serializationTimeout
 case missingInstallationIdentifier
 case missingMeasurementIdentifier
 case missingDeviceType
 case invalidResponse
 case unexpectedError
 ````

 - Author: Klemens Muthmann
 - Version: 3.1.0
 - Since: 1.0.0
 */
public enum ServerConnectionError: Error {
    /// If authentication was carried out but was not successful
    case authenticationNotSuccessful
    /// Error occuring if this client tried to communicate with the server without proper authentication.
    case notAuthenticated
    /// If data serialization for upload took too long.
    case serializationTimeout
    /// Thrown if no installation identifier is available.
    case missingInstallationIdentifier
    /// Thrown if the measurement was not persistent and thus has not identifier
    case missingMeasurementIdentifier
    /// Thrown if no device type was available from the system.
    case missingDeviceType
    /// Thrown if the response was not parseable.
    case invalidResponse
    /// Used for all unexpected errors, that should not occur during normal operation.
    case unexpectedError
    /// This applications version could not be loaded
    case missingAppVersion
}
