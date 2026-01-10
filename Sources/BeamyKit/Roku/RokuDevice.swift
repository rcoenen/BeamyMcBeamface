import Foundation

public struct RokuDevice: Identifiable, Hashable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let address: String
    public let port: Int
    public let serialNumber: String
    public let model: String

    public var baseURL: URL {
        URL(string: "http://\(address):\(port)")!
    }

    public init(id: String, name: String, address: String, port: Int = 8060, serialNumber: String = "", model: String = "") {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.serialNumber = serialNumber
        self.model = model
    }

    public static func == (lhs: RokuDevice, rhs: RokuDevice) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
