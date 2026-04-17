# Vaultyx iOS/macOS

Zero-knowledge client-side encrypted file storage for iOS and macOS.

## Product Overview

**Vaultyx** is a privacy-first file storage solution where:
- All encryption happens on your device
- Server (Shards/S3) sees only ciphertext and chunk hashes
- Files are split into content-addressed chunks via FastCDC
- Recovery is possible with a 24-word mnemonic

## Architecture

### W1: Crypto Engine (`Sources/Crypto/`)

**VaultCrypto**
- PBKDF2-SHA256 master key derivation (600,000 iterations per NIST SP 800-132)
- AES-256-GCM symmetric encryption
- Key hierarchy: master key → folder keys → chunk keys
- SHA-256 chunk addressing for deduplication

**VaultKeyManager**
- In-memory key caching with Keychain persistence
- Secure folder key storage (encrypted with master key)
- Recovery mnemonic generation (BIP-39 style)

### W3: FastCDC Chunker (`Sources/Chunker/`)

**FastCDC**
- Content-defined chunking with deterministic boundaries
- Min: 16KB, Avg: 64KB, Max: 256KB
- Edits invalidate only ~1-2 chunks (vs. file-level re-encryption)
- Gear hash table for O(1) boundary detection

### Models (`Sources/Models/`)

- **VaultFile**: Metadata (encrypted filename, MIME type, timestamps)
- **VaultChunk**: Chunk descriptors (hash, size, encrypted key)
- **VaultManifest**: Complete file → chunks mapping (JSON, encrypted)

### Network (`Sources/Network/`)

**VaultAPIClient** (actor-based)
- `/v1/vault/presign` — S3 PUT/GET URL presigning
- `/v1/vault/manifest` — Upload/fetch encrypted manifests
- `/v1/vault/keys` — Store/retrieve folder keys

## Usage Example

```swift
// 1. Derive master key from password
let salt = keyManager.generateSalt()
try keyManager.loadMasterKey(password: "user-password", salt: salt)

// 2. Create folder and generate folder key
let folderKey = try keyManager.generateAndStoreFolderKey(folderId: "folder-123")

// 3. Split file into chunks
let fileData = /* ... */
let chunks = FastCDC.split(fileData)

// 4. Encrypt each chunk
for chunk in chunks {
    let chunkKey = keyManager.generateChunkKey()
    let encryptedChunk = try VaultCrypto.encrypt(
        fileData[chunk.offset..<chunk.offset + chunk.length],
        key: chunkKey
    )
    // Upload to S3 with key hash as object name
}

// 5. Create and upload manifest
let manifest = VaultManifest(
    fileId: "file-123",
    filenameEnc: /* encrypted filename */,
    mimeTypeEnc: /* encrypted MIME type */,
    totalSize: Int64(fileData.count),
    createdAt: Date().timeIntervalSince1970,
    modifiedAt: Date().timeIntervalSince1970,
    chunks: /* ... */
)
let encryptedManifest = try VaultCrypto.encrypt(
    JSONEncoder().encode(manifest),
    key: folderKey
)
try await apiClient.uploadManifest(fileId: "file-123", encryptedManifest: encryptedManifest)
```

## Security Notes

- Master key is **never** sent to server
- Folder keys are encrypted with master key before Keychain storage
- Chunk keys are encrypted with folder key, stored in manifest
- All S3 operations use presigned URLs (time-limited, no auth token in URL)
- Recovery mnemonic: 24-word backup for account recovery (implements BIP-39 in future iteration)

## Next Steps

1. **Unit tests** for VaultCrypto, FastCDC, VaultKeyManager
2. **UI layer** for authentication, folder/file management
3. **Backend integration** — implement `/v1/vault/*` endpoints on artemis
4. **S3 integration** — presigning and chunk storage on Shards
5. **Recovery flow** — mnemonic backup and account recovery
6. **Conflict resolution** — parentVersion-based merging for concurrent edits

## Deployment

Build via Xcode:
```bash
xcodebuild -scheme Vaultyx -configuration Release build
```

## Files

- `Sources/App/` — SwiftUI app entry + UI stubs
- `Sources/Crypto/` — AES-256-GCM, PBKDF2, key management
- `Sources/Chunker/` — FastCDC content-defined chunking
- `Sources/Models/` — Data structures
- `Sources/Network/` — API client
