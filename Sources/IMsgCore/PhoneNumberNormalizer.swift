import Foundation
import PhoneNumberKit

final class PhoneNumberNormalizer {
  private lazy var phoneNumberUtility: PhoneNumberUtility? = {
    guard PhoneNumberNormalizer.hasResourceBundle else { return nil }
    return PhoneNumberUtility()
  }()

  private static let hasResourceBundle: Bool = {
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      .resolvingSymlinksInPath()
    let bundleURL = executableURL.deletingLastPathComponent()
      .appendingPathComponent("PhoneNumberKit_PhoneNumberKit.bundle")
    return FileManager.default.fileExists(atPath: bundleURL.path)
  }()

  func normalize(_ input: String, region: String) -> String {
    do {
      guard let phoneNumberUtility else { return input }
      let number = try phoneNumberUtility.parse(input, withRegion: region, ignoreType: true)
      return phoneNumberUtility.format(number, toType: .e164)
    } catch {
      return input
    }
  }
}
