import Foundation

@main
struct UpdateVersionTests {
    static func main() {
        assert(availableUpdate("v1.10.0", current: "1.9.9") == "1.10.0")
        assert(availableUpdate("1.2.4", current: "1.2.3") == "1.2.4")
        assert(availableUpdate("1.2.3", current: "1.2.3") == nil)
        assert(availableUpdate("1.2", current: "1.2.0") == nil)
        assert(availableUpdate("1.0002.3", current: "1.2.3") == nil)
        assert(availableUpdate("1.2.2", current: "1.2.3") == nil)
        assert(availableUpdate("1.999999999999999999999999.0", current: "1.10.0") != nil)
        for invalid: Any in [NSNull(), 123, "", "v", "1..2", "1.2.3.4", "1.2-beta", "1/2", "-1.0", "1. 2", "１.2", "1.2\n", "1.2\r"] {
            assert(availableUpdate(invalid, current: "1.0.0") == nil)
        }
        assert(availableUpdate(nil, current: "1.0.0") == nil)
        assert(availableUpdate("2.0.0", current: "invalid") == nil)
        print("PASS: saved update availability for newer, equal, older and invalid versions")
    }
}
