//
//  ServerConnection.swift
//  DataCapturing
//
//  Created by Team Cyface on 18.12.17.
//  Copyright © 2017 Cyface GmbH. All rights reserved.
//

import Foundation
import os.log

/**
 Instances of this class represent connections to a Cyface server API.
 
 - Author: Klemens Muthmann
 - Version: 1.0.0
 - Since: 1.0.0
 */
public class CyfaceServerConnection: ServerConnection {

    // MARK: - Properties
    private let LOG = OSLog(subsystem: "de.cyface", category: "ServerConnection")

    /// Session object to upload captured data to a Cyface server.
    private lazy var apiSession: URLSession = {
        return URLSession(configuration: .default)
    }()

    /// A `URL` used to upload data to. There should be a server complying to a Cyface REST interface available at that location.
    private let apiURL: URL

    /// Authentication token provided by a JWT authentication request. This property is `nil` as long as àuthenticate was not called successfully yet. Otherwise it contains the JWT bearer required as content for the Authorization header.
    private var jwtBearer: String?

    private var onAuthenticationFinishedHandler: ((Error?) -> Void)?

    private lazy var deviceModelIdentifier: String = {
        if let simulatorModelIdentifier = ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] {return simulatorModelIdentifier}
        var sysinfo = utsname()
        uname(&sysinfo) // ignore return value
        return String(bytes: Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN)), encoding: .ascii)!.trimmingCharacters(in: .controlCharacters)
    }()

    private let persistenceLayer: PersistenceLayer

    // MARK: - Initializers
    /**
     Creates a new `ServerConnection` to the provided URL.
     - Parameters:
     -  url: A `URL` used to upload data to. There should be a server complying to a Cyface REST interface available at that location.
     */
    public required init(apiURL url: URL, persistenceLayer: PersistenceLayer) {
        self.apiURL=url
        self.persistenceLayer = persistenceLayer
    }

    // MARK: - Methods
    public func authenticate(with username: String, and password: String, onFinish handler: ((Error?) -> Void)?) {
        let loginURL = apiURL.appendingPathComponent("login")
        var request = URLRequest(url: loginURL)
        self.onAuthenticationFinishedHandler = handler
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "login": "\(username)",
            "password": "\(password)"]) else {
            fatalError("authenticate(username: \(username), password: \(password)): Unable to encode username and password into a JSON request.")
        }
        request.httpBody = body

        if jwtBearer==nil {
            let authenticationTask = apiSession.dataTask(with: request, completionHandler: onAuthenticationResponse)
            authenticationTask.resume()
        }
    }

    public func sync(measurement: MeasurementEntity, onFinishedCall handler: @escaping (MeasurementEntity, ServerConnectionError?) -> Void) {
        debugPrint("Trying to synchronize measurement \(measurement.identifier)")
        guard isAuthenticated() else {
            fatalError("CyfaceServerConnection.sync(measurementIdentifiedBy: \(measurement.identifier)): Unable to sync with not authenticated client.")
        }

        let measurementIdentifier = measurement.identifier
        installationIdentifier { error, deviceIdentifier in
            if let error = error {
                handler(measurement, error)
                return
            } else if let identifier = deviceIdentifier {
                self.transmit(measurement: measurement, forDevice: identifier, onFinish: handler)
            } else {
                fatalError("CyfaceServerConnection.sync(measurement: \(measurementIdentifier)): Neither identifier nor error information available.")
            }
        }
    }

    public func isAuthenticated() -> Bool {
        return jwtBearer != nil && !jwtBearer!.isEmpty
    }

    public func getURL() -> URL {
        return apiURL
    }

    private func transmit(measurement: MeasurementEntity, forDevice deviceIdentifier: String, onFinish handler: @escaping (MeasurementEntity, ServerConnectionError?) -> Void) {

        var request = URLRequest(url: apiURL.appendingPathComponent("measurements"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(jwtBearer, forHTTPHeaderField: "Authorization")

        makeUploadChunks(fromMeasurement: measurement, forInstallation: deviceIdentifier) { chunk in
            guard let jsonChunk = try? JSONSerialization.data(withJSONObject: chunk, options: .sortedKeys) else {
                fatalError("ServerConnection.transmit(measurement: \(measurement.identifier), forDevice: \(deviceIdentifier)): Invalid measurement format.")
            }

            let submissionTask = self.apiSession.uploadTask(with: request, from: jsonChunk) { _, response, error in
                if let error = error {
                    handler(measurement, ServerConnectionError(
                        title: "Data Transmission Error",
                        description: "Error while transmitting data to the server at \(self.apiURL)! Error was: \(error)"))
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    handler(measurement, ServerConnectionError(
                        title: "Data Transmission Error",
                        description: "Received erroneous response from \(String(describing: request.url))!"))
                    return
                }

                let statusCode = response.statusCode
                guard statusCode == 201 else {
                    handler(measurement, ServerConnectionError(
                        title: "Invalid Status Code Error",
                        description: "Invalid status code \(statusCode) received from server at \(String(describing: request.url))!"))
                    return
                }

                handler(measurement, nil)
            }
            submissionTask.resume()
        }
    }

    private func makeUploadChunks(
        fromMeasurement measurement: MeasurementEntity,
        forInstallation installationIdentifier: String, onChunkFinishedCall handler: @escaping ([String: Any]) -> Void) {

        persistenceLayer.load(measurementIdentifiedBy: measurement.identifier) { measurement in

            var geoLocations = [[String: String]]()
            if let measurementLocations = measurement.geoLocations {
                for location in measurementLocations {
                    geoLocations.append([
                        "lat": String(location.lat),
                        "lon": String(location.lon),
                        "speed": String(location.speed),
                        "timestamp": String(location.timestamp),
                        "accuracy": String(Int(location.accuracy))])
                }
            }

            var accelerationPoints = [[String: String]]()
            if let accelerations = measurement.accelerations {
                for acceleration in accelerations {
                    accelerationPoints.append([
                        "ax": String(acceleration.ax),
                        "ay": String(acceleration.ay),
                        "az": String(acceleration.az),
                        "timestamp": String(acceleration.timestamp)])
                }
            }

            handler([
                "deviceId": installationIdentifier,
                "id": String(measurement.identifier),
                "vehicle": "BICYCLE",
                "gpsPoints": geoLocations,
                "accelerationPoints": accelerationPoints])
        }
    }

    /**
     Used to register this application with the server.
     The method checks whether an application identifier has been generated.
     If not it generates one and registers it with the server.
     If there already is an existing application identifier registered it looks whether the server
     knows about that identifier and if not registers it.
     
     - Parameter handler: Handler called when registration with the server has been completed.
     */
    private func installationIdentifier(
        withCompletionHandler handler: @escaping (ServerConnectionError?, String?) -> Void) {

        let completionHandler: (ServerConnectionError?, String?) -> Void = { error, appIdentifier in
            if let error = error {
                handler(error, nil)
                return
            }
            guard let appIdentifier = appIdentifier else {
                handler(ServerConnectionError(
                    title: "Device Registration Error",
                    description: "Unable to get application identifier"), nil)
                return
            }

            UserDefaults.standard.set(appIdentifier, forKey: "de.cyface.identifier")
            handler(nil, appIdentifier)
        }

        if let applicationIdentifier = UserDefaults.standard.string(forKey: "de.cyface.identifier") {
            // Check if identifier is registered at server.
            checkDevice(withIdentifier: applicationIdentifier) { error, identifierFound in
                if let error = error {
                    handler(error, nil)
                    return
                }
                if identifierFound {
                    // Identifier was registered
                    handler(nil, applicationIdentifier)
                } else {
                    // Identifier was not registered. Register again.
                    self.registerDevice(withIdentifier: applicationIdentifier, completionHandler: completionHandler)
                }
            }

        } else {
            // otherwise generate new application identifier
            let applicationIdentifier = UUID.init().uuidString
            registerDevice(withIdentifier: applicationIdentifier, completionHandler: completionHandler)
        }
    }

    private func checkDevice(
        withIdentifier identifier: String,
        completionHandler handler: @escaping (ServerConnectionError?, Bool) -> Void) {

        guard isAuthenticated() else {
            fatalError("""
                ServerConnection.checkDevice(\(identifier)): Unable to check for registered device
                for non-authenticated client.
                """)
        }

        var request = URLRequest(url: self.apiURL.appendingPathComponent("devices"))
        request.httpMethod = "GET"
        request.setValue(jwtBearer, forHTTPHeaderField: "Authorization")

        let deviceRetrievalTask = self.apiSession.dataTask(with: request) { data, response, error in
            if let error = error {
                handler(ServerConnectionError(
                    title: "Device Registration Error",
                    description: "Server error while checking if server knows me!, Error \(error)"), false)
                return
            }

            guard let response = response as? HTTPURLResponse else {
                handler(ServerConnectionError(
                    title: "Device Registration Error",
                    description: "Invalid reponse received while checking for registered device"), false)
                return
            }

            guard response.statusCode == 200 else {
                handler(ServerConnectionError(
                    title: "Device Registration Error",
                    description: """
                    Invalid status code while checking if device exists. Status Code: \(response.statusCode)
                    """), false)
                return
            }

            guard let data = data else {
                handler(ServerConnectionError(
                    title: "Device Registration Error",
                    description: "Unable to unwrap server response from checking for existing device."), false)
                return
            }

            var foundDevice = false
            if let devices = try? JSONDecoder().decode([Device].self, from: data) {
                for device in devices {
                    foundDevice = (device.identifier==identifier) || foundDevice
                }
            }

            handler(nil, foundDevice)

        }

        deviceRetrievalTask.resume()
    }

    private func registerDevice(
        withIdentifier identifier: String,
        completionHandler handler: @escaping (ServerConnectionError?, String?) -> Void) {

        guard isAuthenticated() else {
            fatalError("""
                ServerConnection.registerDevice(\(identifier)): Unable to register device for non-authenticated client.
                """)
        }

        var request = URLRequest(url: self.apiURL.appendingPathComponent("devices"))
        request.httpMethod = "POST"
        request.setValue(jwtBearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let deviceCreationBody = ["id": identifier, "name": deviceModelIdentifier]
        request.httpBody = try? JSONSerialization.data(withJSONObject: deviceCreationBody, options: .sortedKeys)

        let deviceCreationTask = self.apiSession.dataTask(with: request) { data, response, error in
            if let error = error {
                handler(ServerConnectionError(
                    title: "Device Registration Error",
                    description: "Server error during device registration!, Error \(error)"), identifier)
                return
            }

            guard let response = response as? HTTPURLResponse else {
                handler(ServerConnectionError(
                    title: "Device Registration Error",
                    description: """
                    Unable to unwrap response received after trying to register device with \(self.apiURL)).
                    """), identifier)
                return
            }

            guard response.statusCode == 201 else {
                handler(ServerConnectionError(
                    title: "Device Registration Error",
                    description: """
                    Invalid response status code \(response.statusCode) from server \(String(describing: request.url))!
                    """), identifier)
                return
            }

            handler(nil, identifier)
        }

        deviceCreationTask.resume()
    }

    private func onAuthenticationResponse(_: Data?, response: URLResponse?, error: Error?) {
        guard let handler = onAuthenticationFinishedHandler else {
            fatalError("No handler for authentication finished event available!")
        }

        if let error = error {
            handler(error)
            return
        }

        guard let unwrappedResponse = response as? HTTPURLResponse else {
            handler(ServerConnectionError(
                title: "Authentication Error",
                description: """
                There has been a client side error while authenticating with the Cyface API available at \(self.apiURL).
                """))
            return
        }

        let statusCode = unwrappedResponse.statusCode
        let authenticationToken = unwrappedResponse.allHeaderFields["Authorization"] as? String

        guard let unwrappedAuthenticationToken = authenticationToken else {
            handler(ServerConnectionError(
                title: "Authentication Error",
                description: "No Authorization token received from Cyface API available at \(self.apiURL)."))
            return
        }

        if statusCode == 200 {
            self.jwtBearer = unwrappedAuthenticationToken
            handler(nil)
        } else {
            handler(ServerConnectionError(
                title: "Authentication Error",
                description: """
                There has been a client side error while authenticating with the Cyface API
                available at \(self.apiURL).
                The call provided the following status code \(statusCode).
                """))
        }
    }
}

public struct ServerConnectionError: LocalizedError {

    var title: String?
    public var errorDescription: String? { return _description }
    public var failureReason: String? { return _description }

    private var _description: String

    init(title: String?, description: String) {
        self.title = title ?? "Error"
        self._description = description
    }
}

struct Device: Codable {
    var identifier: String
}
