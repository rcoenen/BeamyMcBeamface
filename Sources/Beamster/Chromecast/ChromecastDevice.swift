import Foundation

struct ChromecastDevice: Sendable {
    let name: String
    let address: String
    let port: Int
    let id: String
    let model: String?

    init(name: String, address: String, port: Int, id: String, model: String? = nil) {
        self.name = name
        self.address = address
        self.port = port
        self.id = id
        self.model = model
    }
}
