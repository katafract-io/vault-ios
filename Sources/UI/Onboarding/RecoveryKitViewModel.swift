import Foundation
import SwiftUI
import CryptoKit
import CoreMotion
import PDFKit
import CommonCrypto

/// Manages the full Recovery Kit ceremony: entropy animation, phrase generation,
/// confirmation quiz, and PDF export with PBKDF2 key wrapping.
@MainActor
class RecoveryKitViewModel: NSObject, ObservableObject {
    enum State {
        case entropyAnimation
        case displayPhrase
        case confirmationQuiz(selectedIndices: Set<Int>)
        case complete
    }

    enum ConfirmationState {
        case waitingForFirst
        case waitingForSecond
        case waitingForThird
        case waitingForFourth
        case complete
        case error(String)
    }

    @Published var currentState: State = .entropyAnimation
    @Published var confirmationState: ConfirmationState = .waitingForFirst
    @Published var entropy: Data = Data()
    @Published var phrase: [String] = []
    @Published var entropyProgress: Double = 0.0
    @Published var selectedConfirmations: [Int] = []
    @Published var quizWords: [(index: Int, word: String)] = []
    @Published var sigilID: String = ""
    @Published var vaultEndpoint: String = ""

    private let motionManager = CMMotionManager()
    private var accelerometerData: [CMAcceleration] = []
    private let masterKey: SymmetricKey

    init(masterKey: SymmetricKey, sigilID: String = "", vaultEndpoint: String = "vault.katafract.com") {
        self.masterKey = masterKey
        self.sigilID = sigilID
        self.vaultEndpoint = vaultEndpoint
        super.init()
    }

    // MARK: - Entropy Generation with Accelerometer Mixing

    func startEntropyAnimation(duration: TimeInterval = 8.0) {
        // Initialize base entropy from secure random
        var baseEntropy = Data(count: 32)
        _ = baseEntropy.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        entropy = baseEntropy

        // Start collecting accelerometer data
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.01
            motionManager.startAccelerometerUpdates()
        }

        // Animate progress and mix entropy periodically
        let startTime = Date()
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / duration, 1.0)

            DispatchQueue.main.async {
                self?.entropyProgress = progress
                self?.mixAccelerometerEntropy()
            }

            if progress >= 1.0 {
                timer?.invalidate()
                DispatchQueue.main.async {
                    self?.motionManager.stopAccelerometerUpdates()
                    self?.finalizeEntropy()
                }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func mixAccelerometerEntropy() {
        guard let accel = motionManager.accelerometerData else { return }
        accelerometerData.append(accel.acceleration)

        // Every 20 samples, mix into entropy
        if accelerometerData.count >= 20 {
            var mixed = entropy
            for sample in accelerometerData {
                let x = Self.entropyByte(sample.x)
                let y = Self.entropyByte(sample.y)
                let z = Self.entropyByte(sample.z)
                for i in 0..<min(3, mixed.count) {
                    mixed[i] = mixed[i] ^ x ^ y ^ z
                }
            }
            entropy = mixed
            accelerometerData.removeAll()
        }
    }

    /// Map a raw accelerometer axis to a byte. Acceleration exceeds ±1g the
    /// moment the phone is moved (a shake hits several g), so `Int8(value * 127)`
    /// — a trapping initializer — would crash on any out-of-range or NaN value.
    /// Clamp into Int8 range first.
    private static func entropyByte(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        let scaled = (value * 127).rounded()
        let clamped = Swift.max(-128.0, Swift.min(127.0, scaled))
        return UInt8(bitPattern: Int8(clamped))
    }

    private func finalizeEntropy() {
        // Ensure entropy is exactly 32 bytes
        if entropy.count < 32 {
            var padded = entropy
            padded.reserveCapacity(32)
            while padded.count < 32 {
                padded.append(0)
            }
            entropy = padded
        } else if entropy.count > 32 {
            entropy = entropy.prefix(32)
        }

        // Derive the phrase from the REAL master key (same as Settings'
        // RecoveryPhrase.phrase(for: services.masterKey)). Encoding the random
        // ceremony `entropy` here was the data-loss bug: restore decodes the
        // phrase straight back to a key, so it MUST encode the master key the
        // user's files are actually sealed under, or restore yields a different
        // key and nothing decrypts. The entropy animation is now pure UX.
        phrase = RecoveryPhrase.phrase(for: masterKey)

        // Transition to phrase display
        withAnimation {
            currentState = .displayPhrase
        }
    }

    // MARK: - Confirmation Quiz

    func startConfirmationQuiz() {
        selectedConfirmations.removeAll()
        confirmationState = .waitingForFirst

        // Pick 4 random words
        let indices = Array(0..<24).shuffled().prefix(4).sorted()
        quizWords = indices.map { (index: $0, word: phrase[$0]) }
    }

    func selectQuizWord(at index: Int) {
        selectedConfirmations.append(index)

        let isCorrect = index == quizWords[selectedConfirmations.count - 1].index

        if !isCorrect {
            confirmationState = .error("That's not the right word. Try again.")
            selectedConfirmations.removeAll()
            return
        }

        switch selectedConfirmations.count {
        case 1:
            confirmationState = .waitingForSecond
        case 2:
            confirmationState = .waitingForThird
        case 3:
            confirmationState = .waitingForFourth
        case 4:
            confirmationState = .complete
            withAnimation {
                currentState = .complete
            }
        default:
            break
        }
    }

    func retryConfirmation() {
        selectedConfirmations.removeAll()
        confirmationState = .waitingForFirst
        withAnimation {
            currentState = .confirmationQuiz(selectedIndices: Set())
        }
    }

    // MARK: - PBKDF2 Key Wrapping

    /// Wrap the master key under PBKDF2(mnemonic, salt=sigilID).
    /// Returns (wrappedKey, salt) as base64 strings.
    func wrapMasterKeyWithMnemonic() -> (wrappedKey: String, salt: String)? {
        let mnemonicString = phrase.joined(separator: " ")
        let mnemonicData = mnemonicString.data(using: .utf8) ?? Data()

        // Salt is the Sigil ID (or 32 random bytes if no Sigil ID)
        let saltData = sigilID.data(using: .utf8) ?? Data(count: 32)

        // PBKDF2 with SHA256, 100,000 iterations, 32-byte output
        guard let derivedKey = PBKDF2.deriveKey(
            password: mnemonicData,
            salt: saltData,
            keySize: 32
        ) else {
            print("PBKDF2 failed")
            return nil
        }

        // Wrap the master key using the derived key
        let masterKeyData = masterKey.withUnsafeBytes { Data($0) }
        let sealedBox = try? AES.GCM.seal(masterKeyData, using: SymmetricKey(data: derivedKey))

        guard let sealedBox = sealedBox else { return nil }

        // Combine nonce + ciphertext + tag into one blob
        let wrappedData = sealedBox.nonce.withUnsafeBytes { Data($0) }
            + sealedBox.ciphertext
            + sealedBox.tag

        return (
            wrappedKey: wrappedData.base64EncodedString(),
            salt: saltData.base64EncodedString()
        )
    }

    // MARK: - PDF Generation

    /// Generate a printable Recovery Kit PDF with mnemonic, QR code, and instructions.
    func generateRecoveryKitPDF() -> Data? {
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))

        let pdf = pdfRenderer.pdfData { context in
            context.beginPage()

            let margin: CGFloat = 40
            var yPosition: CGFloat = margin

            // Title
            let titleFont = UIFont.systemFont(ofSize: 28, weight: .bold)
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.black]
            let titleString = NSAttributedString(string: "Recovery Kit", attributes: titleAttrs)
            titleString.draw(at: CGPoint(x: margin, y: yPosition))
            yPosition += 40

            // Subtitle
            let subtitleFont = UIFont.systemFont(ofSize: 12)
            let subtitleAttrs: [NSAttributedString.Key: Any] = [.font: subtitleFont, .foregroundColor: UIColor.darkGray]
            let subtitleString = NSAttributedString(
                string: "This is your master recovery key. Store this document safely.",
                attributes: subtitleAttrs
            )
            subtitleString.draw(in: CGRect(x: margin, y: yPosition, width: 532, height: 30))
            yPosition += 50

            // Sigil ID
            let labelFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: UIColor.darkGray]
            let sigilLabelString = NSAttributedString(string: "SIGIL ID", attributes: labelAttrs)
            sigilLabelString.draw(at: CGPoint(x: margin, y: yPosition))
            yPosition += 16

            let valueFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: UIColor.black]
            let sigilString = NSAttributedString(string: sigilID, attributes: valueAttrs)
            sigilString.draw(at: CGPoint(x: margin, y: yPosition))
            yPosition += 30

            // 24 words in a grid
            let wordLabelString = NSAttributedString(string: "24-WORD RECOVERY PHRASE", attributes: labelAttrs)
            wordLabelString.draw(at: CGPoint(x: margin, y: yPosition))
            yPosition += 16

            let wordFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let wordAttrs: [NSAttributedString.Key: Any] = [.font: wordFont, .foregroundColor: UIColor.black]

            let colWidth: CGFloat = 140
            let rowHeight: CGFloat = 16
            var col = 0
            var row = 0

            for (idx, word) in phrase.enumerated() {
                let xOffset = margin + CGFloat(col) * colWidth
                let yOffset = yPosition + CGFloat(row) * rowHeight
                let numberedWord = String(format: "%2d. %@", idx + 1, word)
                let wordString = NSAttributedString(string: numberedWord, attributes: wordAttrs)
                wordString.draw(at: CGPoint(x: xOffset, y: yOffset))

                col += 1
                if col >= 3 {
                    col = 0
                    row += 1
                }
            }
            yPosition += CGFloat(8 * rowHeight) + 20

            // QR Code (if we can generate it)
            if let qrImage = generateQRCode() {
                let qrRect = CGRect(x: margin, y: yPosition, width: 150, height: 150)
                qrImage.draw(in: qrRect)
                yPosition += 170
            }

            // Instructions
            let instructionsFont = UIFont.systemFont(ofSize: 9)
            let instructionsAttrs: [NSAttributedString.Key: Any] = [.font: instructionsFont, .foregroundColor: UIColor.darkGray]
            let instructions = """
            INSTRUCTIONS:
            1. Store this document in a safe place (fireproof safe, safety deposit box, etc.)
            2. Do not photograph or digitize these words
            3. Do not share with anyone
            4. To recover your vault, scan the QR code or visit vaultyx-recover:// with your mnemonic
            """
            let instructionsString = NSAttributedString(string: instructions, attributes: instructionsAttrs)
            instructionsString.draw(in: CGRect(x: margin, y: yPosition, width: 532, height: 200))
        }

        return pdf
    }

    /// Generate QR code for vaultyx-recover:// URI
    private func generateQRCode() -> UIImage? {
        let mnemonicString = phrase.joined(separator: " ")
        let qrString = "vaultyx-recover://restore?mnemonic=\(mnemonicString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"

        guard let qrData = qrString.data(using: .ascii) else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(qrData, forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel")

        guard let qrImage = filter?.outputImage else { return nil }

        // Scale up the QR code for readability
        let scale = 10.0
        let scaledImage = qrImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // A CIImage-backed UIImage does NOT reliably draw into a CG/PDF context
        // (it has no CGImage backing) — the first PDF render comes out blank.
        // Rasterize through a CIContext to a concrete CGImage so draw(in:) works.
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Keychain Storage

    /// Store the wrapped key in App Group keychain
    func storeWrappedKeyInKeychain() -> Bool {
        guard let (wrappedKey, salt) = wrapMasterKeyWithMnemonic() else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.katafract.vault.recovery",
            kSecAttrAccount as String: sigilID,
            kSecAttrAccessGroup as String: "group.com.katafract.enclave",
            kSecValueData as String: "\(wrappedKey):\(salt)".data(using: .utf8) ?? Data(),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

// MARK: - PBKDF2 Helper

enum PBKDF2 {
    static func deriveKey(password: Data, salt: Data, keySize: Int = 32, iterations: Int = 100000) -> Data? {
        var derivedKey = [UInt8](repeating: 0, count: keySize)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            [UInt8](password), password.count,
            [UInt8](salt), salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &derivedKey,
            keySize
        )

        guard status == kCCSuccess else { return nil }
        return Data(derivedKey)
    }
}
