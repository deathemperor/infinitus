import Foundation

/// Minimal byte-mode QR code encoder supporting versions 1–10.
/// Pure Swift with no platform dependencies.
public enum QRCode {
    public enum Correction: Sendable {
        case l, m, q, h

        var bits: Int {
            switch self {
            case .m: return 0
            case .l: return 1
            case .h: return 2
            case .q: return 3
            }
        }
    }

    public struct Matrix: Sendable, Equatable {
        public let size: Int              // modules per side
        public let modules: [Bool]        // row-major, size*size

        public init(size: Int, modules: [Bool]) {
            self.size = size
            self.modules = modules
        }

        public subscript(x: Int, y: Int) -> Bool {
            modules[y * size + x]
        }
    }

    // MARK: - RS Block Specification
    private struct RSBlockSpec {
        let totalCount: Int
        let dataCount: Int
    }

    private static func rsBlocks(version: Int, correction: Correction) -> [RSBlockSpec] {
        switch correction {
        case .l:
            switch version {
            case 1: return [RSBlockSpec(totalCount: 26, dataCount: 19)]
            case 2: return [RSBlockSpec(totalCount: 44, dataCount: 34)]
            case 3: return [RSBlockSpec(totalCount: 70, dataCount: 55)]
            case 4: return [RSBlockSpec(totalCount: 100, dataCount: 80)]
            case 5: return [RSBlockSpec(totalCount: 134, dataCount: 108)]
            case 6: return [RSBlockSpec(totalCount: 86, dataCount: 68), RSBlockSpec(totalCount: 86, dataCount: 68)]
            case 7: return [RSBlockSpec(totalCount: 98, dataCount: 78), RSBlockSpec(totalCount: 98, dataCount: 78)]
            case 8: return [RSBlockSpec(totalCount: 121, dataCount: 97), RSBlockSpec(totalCount: 121, dataCount: 97)]
            case 9: return [RSBlockSpec(totalCount: 146, dataCount: 116), RSBlockSpec(totalCount: 146, dataCount: 116)]
            case 10: return [RSBlockSpec(totalCount: 86, dataCount: 68), RSBlockSpec(totalCount: 86, dataCount: 68),
                             RSBlockSpec(totalCount: 87, dataCount: 69), RSBlockSpec(totalCount: 87, dataCount: 69)]
            default: return []
            }
        case .m:
            switch version {
            case 1: return [RSBlockSpec(totalCount: 26, dataCount: 16)]
            case 2: return [RSBlockSpec(totalCount: 44, dataCount: 28)]
            case 3: return [RSBlockSpec(totalCount: 70, dataCount: 44)]
            case 4: return [RSBlockSpec(totalCount: 50, dataCount: 32), RSBlockSpec(totalCount: 50, dataCount: 32)]
            case 5: return [RSBlockSpec(totalCount: 67, dataCount: 43), RSBlockSpec(totalCount: 67, dataCount: 43)]
            case 6: return [RSBlockSpec(totalCount: 43, dataCount: 27), RSBlockSpec(totalCount: 43, dataCount: 27),
                            RSBlockSpec(totalCount: 43, dataCount: 27), RSBlockSpec(totalCount: 43, dataCount: 27)]
            case 7: return [RSBlockSpec(totalCount: 49, dataCount: 31), RSBlockSpec(totalCount: 49, dataCount: 31),
                            RSBlockSpec(totalCount: 49, dataCount: 31), RSBlockSpec(totalCount: 49, dataCount: 31)]
            case 8: return [RSBlockSpec(totalCount: 60, dataCount: 38), RSBlockSpec(totalCount: 60, dataCount: 38),
                            RSBlockSpec(totalCount: 61, dataCount: 39), RSBlockSpec(totalCount: 61, dataCount: 39)]
            case 9: return [RSBlockSpec(totalCount: 58, dataCount: 36), RSBlockSpec(totalCount: 58, dataCount: 36),
                            RSBlockSpec(totalCount: 58, dataCount: 36), RSBlockSpec(totalCount: 59, dataCount: 37),
                            RSBlockSpec(totalCount: 59, dataCount: 37)]
            case 10: return [RSBlockSpec(totalCount: 69, dataCount: 43), RSBlockSpec(totalCount: 69, dataCount: 43),
                             RSBlockSpec(totalCount: 69, dataCount: 43), RSBlockSpec(totalCount: 69, dataCount: 43),
                             RSBlockSpec(totalCount: 70, dataCount: 44)]
            default: return []
            }
        case .q:
            switch version {
            case 1: return [RSBlockSpec(totalCount: 26, dataCount: 13)]
            case 2: return [RSBlockSpec(totalCount: 44, dataCount: 22)]
            case 3: return [RSBlockSpec(totalCount: 35, dataCount: 17), RSBlockSpec(totalCount: 35, dataCount: 17)]
            case 4: return [RSBlockSpec(totalCount: 50, dataCount: 24), RSBlockSpec(totalCount: 50, dataCount: 24)]
            case 5: return [RSBlockSpec(totalCount: 33, dataCount: 15), RSBlockSpec(totalCount: 33, dataCount: 15),
                            RSBlockSpec(totalCount: 34, dataCount: 16), RSBlockSpec(totalCount: 34, dataCount: 16)]
            case 6: return [RSBlockSpec(totalCount: 43, dataCount: 19), RSBlockSpec(totalCount: 43, dataCount: 19),
                            RSBlockSpec(totalCount: 43, dataCount: 19), RSBlockSpec(totalCount: 43, dataCount: 19)]
            case 7: return [RSBlockSpec(totalCount: 32, dataCount: 14), RSBlockSpec(totalCount: 32, dataCount: 14),
                            RSBlockSpec(totalCount: 33, dataCount: 15), RSBlockSpec(totalCount: 33, dataCount: 15),
                            RSBlockSpec(totalCount: 33, dataCount: 15), RSBlockSpec(totalCount: 33, dataCount: 15)]
            case 8: return [RSBlockSpec(totalCount: 40, dataCount: 18), RSBlockSpec(totalCount: 40, dataCount: 18),
                            RSBlockSpec(totalCount: 40, dataCount: 18), RSBlockSpec(totalCount: 40, dataCount: 18),
                            RSBlockSpec(totalCount: 41, dataCount: 19), RSBlockSpec(totalCount: 41, dataCount: 19)]
            case 9: return [RSBlockSpec(totalCount: 36, dataCount: 16), RSBlockSpec(totalCount: 36, dataCount: 16),
                            RSBlockSpec(totalCount: 36, dataCount: 16), RSBlockSpec(totalCount: 36, dataCount: 16),
                            RSBlockSpec(totalCount: 37, dataCount: 17), RSBlockSpec(totalCount: 37, dataCount: 17),
                            RSBlockSpec(totalCount: 37, dataCount: 17), RSBlockSpec(totalCount: 37, dataCount: 17)]
            case 10: return [RSBlockSpec(totalCount: 43, dataCount: 19), RSBlockSpec(totalCount: 43, dataCount: 19),
                             RSBlockSpec(totalCount: 43, dataCount: 19), RSBlockSpec(totalCount: 43, dataCount: 19),
                             RSBlockSpec(totalCount: 43, dataCount: 19), RSBlockSpec(totalCount: 43, dataCount: 19),
                             RSBlockSpec(totalCount: 44, dataCount: 20), RSBlockSpec(totalCount: 44, dataCount: 20)]
            default: return []
            }
        case .h:
            switch version {
            case 1: return [RSBlockSpec(totalCount: 26, dataCount: 9)]
            case 2: return [RSBlockSpec(totalCount: 44, dataCount: 16)]
            case 3: return [RSBlockSpec(totalCount: 35, dataCount: 13), RSBlockSpec(totalCount: 35, dataCount: 13)]
            case 4: return [RSBlockSpec(totalCount: 25, dataCount: 9), RSBlockSpec(totalCount: 25, dataCount: 9),
                            RSBlockSpec(totalCount: 25, dataCount: 9), RSBlockSpec(totalCount: 25, dataCount: 9)]
            case 5: return [RSBlockSpec(totalCount: 33, dataCount: 11), RSBlockSpec(totalCount: 33, dataCount: 11),
                            RSBlockSpec(totalCount: 34, dataCount: 12), RSBlockSpec(totalCount: 34, dataCount: 12)]
            case 6: return [RSBlockSpec(totalCount: 43, dataCount: 15), RSBlockSpec(totalCount: 43, dataCount: 15),
                            RSBlockSpec(totalCount: 43, dataCount: 15), RSBlockSpec(totalCount: 43, dataCount: 15)]
            case 7: return [RSBlockSpec(totalCount: 39, dataCount: 13), RSBlockSpec(totalCount: 39, dataCount: 13),
                            RSBlockSpec(totalCount: 39, dataCount: 13), RSBlockSpec(totalCount: 39, dataCount: 13),
                            RSBlockSpec(totalCount: 40, dataCount: 14)]
            case 8: return [RSBlockSpec(totalCount: 40, dataCount: 14), RSBlockSpec(totalCount: 40, dataCount: 14),
                            RSBlockSpec(totalCount: 40, dataCount: 14), RSBlockSpec(totalCount: 40, dataCount: 14),
                            RSBlockSpec(totalCount: 41, dataCount: 15), RSBlockSpec(totalCount: 41, dataCount: 15)]
            case 9: return [RSBlockSpec(totalCount: 36, dataCount: 12), RSBlockSpec(totalCount: 36, dataCount: 12),
                            RSBlockSpec(totalCount: 36, dataCount: 12), RSBlockSpec(totalCount: 36, dataCount: 12),
                            RSBlockSpec(totalCount: 37, dataCount: 13), RSBlockSpec(totalCount: 37, dataCount: 13),
                            RSBlockSpec(totalCount: 37, dataCount: 13), RSBlockSpec(totalCount: 37, dataCount: 13)]
            case 10: return [RSBlockSpec(totalCount: 43, dataCount: 15), RSBlockSpec(totalCount: 43, dataCount: 15),
                             RSBlockSpec(totalCount: 43, dataCount: 15), RSBlockSpec(totalCount: 43, dataCount: 15),
                             RSBlockSpec(totalCount: 43, dataCount: 15), RSBlockSpec(totalCount: 43, dataCount: 15),
                             RSBlockSpec(totalCount: 44, dataCount: 16), RSBlockSpec(totalCount: 44, dataCount: 16)]
            default: return []
            }
        }
    }

    private static let patternPositions: [[Int]] = [
        [],                 // v0
        [],                 // v1
        [6, 18],            // v2
        [6, 22],            // v3
        [6, 26],            // v4
        [6, 30],            // v5
        [6, 34],            // v6
        [6, 22, 38],        // v7
        [6, 24, 42],        // v8
        [6, 26, 46],        // v9
        [6, 28, 50]         // v10
    ]

    // MARK: - GF(256) Math
    private static let expTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            table[i] = UInt8(x)
            x <<= 1
            if x >= 256 {
                x ^= 0x11d
            }
        }
        table[255] = table[0]
        return table
    }()

    private static let logTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<255 {
            table[Int(expTable[i])] = UInt8(i)
        }
        return table
    }()

    private static func gexp(_ n: Int) -> UInt8 {
        expTable[(n % 255 + 255) % 255]
    }

    private static func glog(_ n: UInt8) -> Int {
        Int(logTable[Int(n)])
    }

    private static func gmul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return gexp(glog(a) + glog(b))
    }

    private static func rsGeneratorPolynomial(ecCount: Int) -> [UInt8] {
        var poly: [UInt8] = [1]
        for i in 0..<ecCount {
            let root = gexp(i)
            var nextPoly = [UInt8](repeating: 0, count: poly.count + 1)
            for j in 0..<poly.count {
                nextPoly[j] ^= poly[j]
                nextPoly[j + 1] ^= gmul(poly[j], root)
            }
            poly = nextPoly
        }
        return poly
    }

    private static func rsEncode(data: [UInt8], ecCount: Int) -> [UInt8] {
        let gen = rsGeneratorPolynomial(ecCount: ecCount)
        var msg = data + [UInt8](repeating: 0, count: ecCount)
        for i in 0..<data.count {
            let coef = msg[i]
            if coef != 0 {
                for j in 1..<gen.count {
                    let term = gmul(coef, gen[j])
                    msg[i + j] ^= term
                }
            }
        }
        return Array(msg.suffix(ecCount))
    }

    // MARK: - BCH Code
    private static let g15 = 0x537
    private static let g15Mask = 0x5412
    private static let g18 = 0x1f25

    private static func bchDigit(_ val: Int) -> Int {
        var d = 0
        var v = val
        while v > 0 {
            d += 1
            v >>= 1
        }
        return d
    }

    private static func bchTypeInfo(data: Int) -> Int {
        var d = data << 10
        while bchDigit(d) - bchDigit(g15) >= 0 {
            d ^= g15 << (bchDigit(d) - bchDigit(g15))
        }
        return ((data << 10) | d) ^ g15Mask
    }

    private static func bchTypeNumber(version: Int) -> Int {
        var d = version << 12
        while bchDigit(d) - bchDigit(g18) >= 0 {
            d ^= g18 << (bchDigit(d) - bchDigit(g18))
        }
        return (version << 12) | d
    }

    // MARK: - Encode Entry Point
    public static func encode(_ text: String, correction: Correction = .m) -> Matrix? {
        let utf8Bytes = Array(text.utf8)

        // Find smallest version (1..10) that fits
        var pickedVersion: Int? = nil
        var pickedBlocks: [RSBlockSpec] = []
        for v in 1...10 {
            let blocks = rsBlocks(version: v, correction: correction)
            let totalDataCodewords = blocks.reduce(0) { $0 + $1.dataCount }
            let countBits = v < 10 ? 8 : 16
            let totalBits = 4 + countBits + utf8Bytes.count * 8
            if totalBits <= totalDataCodewords * 8 {
                pickedVersion = v
                pickedBlocks = blocks
                break
            }
        }

        guard let version = pickedVersion else { return nil }

        // Build data bit stream
        var bitBuffer: [Bool] = []
        func putBits(_ value: Int, count: Int) {
            for i in (0..<count).reversed() {
                bitBuffer.append(((value >> i) & 1) == 1)
            }
        }

        // Mode: 8-bit byte (0100 = 4)
        putBits(4, count: 4)

        // Character count
        let countBits = version < 10 ? 8 : 16
        putBits(utf8Bytes.count, count: countBits)

        // Data bytes
        for byte in utf8Bytes {
            putBits(Int(byte), count: 8)
        }

        let totalDataCodewords = pickedBlocks.reduce(0) { $0 + $1.dataCount }
        let maxDataBits = totalDataCodewords * 8

        // Terminator (up to 4 zero bits)
        let termLen = min(4, maxDataBits - bitBuffer.count)
        for _ in 0..<termLen {
            bitBuffer.append(false)
        }

        // Byte alignment
        while bitBuffer.count % 8 != 0 {
            bitBuffer.append(false)
        }

        // Convert bit buffer to bytes
        var dataBytes: [UInt8] = []
        for i in stride(from: 0, to: bitBuffer.count, by: 8) {
            var b: UInt8 = 0
            for j in 0..<8 {
                if bitBuffer[i + j] {
                    b |= (1 << (7 - j))
                }
            }
            dataBytes.append(b)
        }

        // Pad bytes (0xEC, 0x11)
        var padIndex = 0
        while dataBytes.count < totalDataCodewords {
            dataBytes.append(padIndex % 2 == 0 ? 0xEC : 0x11)
            padIndex += 1
        }

        // Split into RS blocks and compute EC codewords
        var dcData: [[UInt8]] = []
        var ecData: [[UInt8]] = []
        var byteOffset = 0
        var maxDcCount = 0
        var maxEcCount = 0

        for block in pickedBlocks {
            let dcCount = block.dataCount
            let ecCount = block.totalCount - dcCount
            maxDcCount = max(maxDcCount, dcCount)
            maxEcCount = max(maxEcCount, ecCount)

            let chunk = Array(dataBytes[byteOffset..<(byteOffset + dcCount)])
            byteOffset += dcCount
            let ec = rsEncode(data: chunk, ecCount: ecCount)

            dcData.append(chunk)
            ecData.append(ec)
        }

        // Interleave data codewords and error correction codewords
        var finalCodewords: [UInt8] = []
        for i in 0..<maxDcCount {
            for dc in dcData {
                if i < dc.count {
                    finalCodewords.append(dc[i])
                }
            }
        }
        for i in 0..<maxEcCount {
            for ec in ecData {
                if i < ec.count {
                    finalCodewords.append(ec[i])
                }
            }
        }

        // Best mask evaluation
        var bestMask = 0
        var minLostPoint = Int.max

        for maskPattern in 0..<8 {
            let (modules, _) = buildMatrix(version: version, correction: correction,
                                           maskPattern: maskPattern, codewords: finalCodewords)
            let lost = calculateLostPoint(modules: modules)
            if lost < minLostPoint {
                minLostPoint = lost
                bestMask = maskPattern
            }
        }

        // Final build with best mask
        let (finalModules, size) = buildMatrix(version: version, correction: correction,
                                               maskPattern: bestMask, codewords: finalCodewords)

        var flat: [Bool] = []
        flat.reserveCapacity(size * size)
        for row in 0..<size {
            for col in 0..<size {
                flat.append(finalModules[row][col])
            }
        }

        return Matrix(size: size, modules: flat)
    }

    // MARK: - Matrix Construction
    private static func buildMatrix(
        version: Int,
        correction: Correction,
        maskPattern: Int,
        codewords: [UInt8]
    ) -> (modules: [[Bool]], size: Int) {
        let size = version * 4 + 17
        var modules = [[Bool?]](repeating: [Bool?](repeating: nil, count: size), count: size)

        // 1. Finder patterns
        func placeFinder(row: Int, col: Int) {
            for r in -1...7 {
                let currR = row + r
                if currR < 0 || currR >= size { continue }
                for c in -1...7 {
                    let currC = col + c
                    if currC < 0 || currC >= size { continue }
                    if (0 <= r && r <= 6 && (c == 0 || c == 6))
                        || (0 <= c && c <= 6 && (r == 0 || r == 6))
                        || (2 <= r && r <= 4 && 2 <= c && c <= 4) {
                        modules[currR][currC] = true
                    } else {
                        modules[currR][currC] = false
                    }
                }
            }
        }

        placeFinder(row: 0, col: 0)
        placeFinder(row: size - 7, col: 0)
        placeFinder(row: 0, col: size - 7)

        // 2. Alignment patterns
        let positions = patternPositions[version]
        for row in positions {
            for col in positions {
                if modules[row][col] != nil { continue }
                for r in -2...2 {
                    for c in -2...2 {
                        let isEdge = (r == -2 || r == 2 || c == -2 || c == 2 || (r == 0 && c == 0))
                        modules[row + r][col + c] = isEdge
                    }
                }
            }
        }

        // 3. Timing patterns
        for r in 8..<(size - 8) {
            if modules[r][6] == nil {
                modules[r][6] = (r % 2 == 0)
            }
        }
        for c in 8..<(size - 8) {
            if modules[6][c] == nil {
                modules[6][c] = (c % 2 == 0)
            }
        }

        // 4. Type info
        let typeData = (correction.bits << 3) | maskPattern
        let typeBits = bchTypeInfo(data: typeData)

        // Vertical type info. Written in trial builds too (test == true):
        // mask scoring per ISO 18004 reads the fully-populated matrix, so
        // the trial's own type bits must be in place or the penalty
        // misranks masks.
        for i in 0..<15 {
            let mod = ((typeBits >> i) & 1) == 1
            if i < 6 {
                modules[i][8] = mod
            } else if i < 8 {
                modules[i + 1][8] = mod
            } else {
                modules[size - 15 + i][8] = mod
            }
        }

        // Horizontal type info
        for i in 0..<15 {
            let mod = ((typeBits >> i) & 1) == 1
            if i < 8 {
                modules[8][size - i - 1] = mod
            } else if i < 9 {
                modules[8][15 - i] = mod
            } else {
                modules[8][15 - i - 1] = mod
            }
        }

        // Fixed dark module
        modules[size - 8][8] = true

        // 5. Version info (v >= 7)
        if version >= 7 {
            let verBits = bchTypeNumber(version: version)
            for i in 0..<18 {
                let mod = ((verBits >> i) & 1) == 1
                modules[i / 3][i % 3 + size - 11] = mod
                modules[i % 3 + size - 11][i / 3] = mod
            }
        }

        // 6. Map data with mask function
        let maskFunc = getMaskFunc(maskPattern)
        var inc = -1
        var row = size - 1
        var bitIndex = 7
        var byteIndex = 0
        let codewordsCount = codewords.count

        var col = size - 1
        while col > 0 {
            if col == 6 { col -= 1 }

            while true {
                for c in [col, col - 1] {
                    if modules[row][c] == nil {
                        var dark = false
                        if byteIndex < codewordsCount {
                            dark = ((Int(codewords[byteIndex]) >> bitIndex) & 1) == 1
                        }
                        if maskFunc(row, c) {
                            dark = !dark
                        }
                        modules[row][c] = dark

                        bitIndex -= 1
                        if bitIndex == -1 {
                            byteIndex += 1
                            bitIndex = 7
                        }
                    }
                }

                row += inc
                if row < 0 || row >= size {
                    row -= inc
                    inc = -inc
                    break
                }
            }

            col -= 2
        }

        var result = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
        for r in 0..<size {
            for c in 0..<size {
                result[r][c] = modules[r][c] ?? false
            }
        }
        return (result, size)
    }

    private static func getMaskFunc(_ pattern: Int) -> (Int, Int) -> Bool {
        switch pattern {
        case 0: return { (i, j) in (i + j) % 2 == 0 }
        case 1: return { (i, _) in i % 2 == 0 }
        case 2: return { (_, j) in j % 3 == 0 }
        case 3: return { (i, j) in (i + j) % 3 == 0 }
        case 4: return { (i, j) in (i / 2 + j / 3) % 2 == 0 }
        case 5: return { (i, j) in (i * j) % 2 + (i * j) % 3 == 0 }
        case 6: return { (i, j) in ((i * j) % 2 + (i * j) % 3) % 2 == 0 }
        case 7: return { (i, j) in ((i * j) % 3 + (i + j) % 2) % 2 == 0 }
        default: return { (_, _) in false }
        }
    }

    // MARK: - Penalty / Lost Point Calculation
    private static func calculateLostPoint(modules: [[Bool]]) -> Int {
        let size = modules.count
        var lostPoint = 0

        // Rule 1: 5 or more consecutive modules of the same color
        var container = [Int](repeating: 0, count: size + 1)
        for row in 0..<size {
            var prevColor = modules[row][0]
            var length = 0
            for col in 0..<size {
                if modules[row][col] == prevColor {
                    length += 1
                } else {
                    if length >= 5 { container[length] += 1 }
                    length = 1
                    prevColor = modules[row][col]
                }
            }
            if length >= 5 { container[length] += 1 }
        }
        for col in 0..<size {
            var prevColor = modules[0][col]
            var length = 0
            for row in 0..<size {
                if modules[row][col] == prevColor {
                    length += 1
                } else {
                    if length >= 5 { container[length] += 1 }
                    length = 1
                    prevColor = modules[row][col]
                }
            }
            if length >= 5 { container[length] += 1 }
        }
        for len in 5...size {
            lostPoint += container[len] * (len - 2)
        }

        // Rule 2: 2x2 blocks of same color
        for row in 0..<(size - 1) {
            for col in 0..<(size - 1) {
                let color = modules[row][col]
                if modules[row][col + 1] == color &&
                   modules[row + 1][col] == color &&
                   modules[row + 1][col + 1] == color {
                    lostPoint += 3
                }
            }
        }

        // Rule 3: 1:1:3:1:1 pattern with 4 light modules on either side
        for row in 0..<size {
            for col in 0..<(size - 10) {
                let p1 = modules[row][col + 0] && !modules[row][col + 1] && modules[row][col + 2] &&
                         modules[row][col + 3] && modules[row][col + 4] && !modules[row][col + 5] &&
                         modules[row][col + 6] && !modules[row][col + 7] && !modules[row][col + 8] &&
                         !modules[row][col + 9] && !modules[row][col + 10]
                let p2 = !modules[row][col + 0] && !modules[row][col + 1] && !modules[row][col + 2] &&
                         !modules[row][col + 3] && modules[row][col + 4] && !modules[row][col + 5] &&
                         modules[row][col + 6] && modules[row][col + 7] && modules[row][col + 8] &&
                         !modules[row][col + 9] && modules[row][col + 10]
                if p1 || p2 {
                    lostPoint += 40
                }
            }
        }
        for col in 0..<size {
            for row in 0..<(size - 10) {
                let p1 = modules[row + 0][col] && !modules[row + 1][col] && modules[row + 2][col] &&
                         modules[row + 3][col] && modules[row + 4][col] && !modules[row + 5][col] &&
                         modules[row + 6][col] && !modules[row + 7][col] && !modules[row + 8][col] &&
                         !modules[row + 9][col] && !modules[row + 10][col]
                let p2 = !modules[row + 0][col] && !modules[row + 1][col] && !modules[row + 2][col] &&
                         !modules[row + 3][col] && modules[row + 4][col] && !modules[row + 5][col] &&
                         modules[row + 6][col] && modules[row + 7][col] && modules[row + 8][col] &&
                         !modules[row + 9][col] && modules[row + 10][col]
                if p1 || p2 {
                    lostPoint += 40
                }
            }
        }

        // Rule 4: Proportion of dark modules
        var darkCount = 0
        for row in 0..<size {
            for col in 0..<size {
                if modules[row][col] { darkCount += 1 }
            }
        }
        let total = size * size
        let percent = Double(darkCount) * 100.0 / Double(total)
        let rating = Int(abs(percent - 50.0) / 5.0)
        lostPoint += rating * 10

        return lostPoint
    }
}
