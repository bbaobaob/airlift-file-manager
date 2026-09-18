import XCTest
@testable import AirLiftFileManager

/// Tests for the in-app pairing cryptography. BigUInt and SRP vectors come
/// from an independent Python oracle (never from this implementation);
/// the OPACK fixture was generated from the format spec the same way.
final class PairingCryptoTests: XCTestCase {
    // MARK: - SRPBigUInt basics

    func testConversionsRoundTrip() {
        let bytes = Data([0x00, 0x01, 0x02, 0xAB, 0xCD])
        let value = SRPBigUInt(bytesBE: Array(bytes))
        XCTAssertEqual(value.bytesBE, [0x01, 0x02, 0xAB, 0xCD])
        XCTAssertEqual(SRPBigUInt.zero.bytesBE, [])
        XCTAssertEqual(SRPBigUInt(0).bytesBE, [])
        XCTAssertEqual(SRPBigUInt(255).fixedBE(4), [0, 0, 0, 255])
        XCTAssertNil(SRPBigUInt(256).fixedBE(1))
    }

    func testCompare() {
        XCTAssertTrue(SRPBigUInt.zero < SRPBigUInt.one)
        XCTAssertFalse(SRPBigUInt.one < SRPBigUInt.one)
        XCTAssertTrue(SRPBigUInt(0x100) < SRPBigUInt(0x10000))
        XCTAssertTrue(SRPBigUInt(bytesBE: [0x01, 0x00]) < SRPBigUInt(bytesBE: [0x01, 0x01]))
    }

    func testSmallArithmetic() {
        let thousand = SRPBigUInt(1000)
        XCTAssertEqual((thousand - SRPBigUInt(1)).bytesBE, [0x03, 0xE7])
        // Borrow chain across limbs.
        let big = SRPBigUInt(bytesBE: [0x01] + [UInt8](repeating: 0, count: 8))
        XCTAssertEqual((big - SRPBigUInt.one).bytesBE,
                       [UInt8](repeating: 0xFF, count: 8))
        // (a + b) - b == a with limb carry.
        let a = SRPBigUInt(bytesBE: [UInt8](repeating: 0xFF, count: 20))
        let b = SRPBigUInt(bytesBE: [0x01])
        XCTAssertEqual(((a + b) - b), a)
    }

    // MARK: - Oracle vectors (3072-bit)

    private func big(_ hex: String) -> SRPBigUInt {
        SRPBigUInt(bytesBE: SRP3072.hexBytes(hex))
    }

    private static let sharedReducer = SRPBigUInt.BarrettReducer(modulus: SRP3072.modulus)
    private var reducer: SRPBigUInt.BarrettReducer { Self.sharedReducer }

    func testOracleAddMul() {
        let red = reducer
        let a = big("7412b29347294739614ff3d719db3ad0ddd1dfb23b982ef8daf61a26146d3f31fc377a4c4a15544dc5e7ce8a3a578a8ea9488d990bbb259911ce5dd2b45ed1f03139d32c93cd59bf5c941cf0dc98d2c1e2acf72f9e574f7aa0ee89aed453dd324b0dbb418d5288f1142c3fe860e7a113ec1b8ca1f91e1d4c1ff49b7889463e85759cde66bacfb3d00b1f9163ce9ff57f43b7a3a69a8dca03580d7b71d8f564135be6128e18c267976142ea7d17be31111a2a73ed562b0f79c37459eef50bea63371ecd7b27cd813047229389571aa8766c307511b2b9437a28df6ec4ce4a2bbdc241330b01a9e71fde8a774bcf36d58b4737819096da1dac72ff5d2a386ecbe06b65a6a48b8148f6b38a088ca65ed389b74d0fb132e706298fadc1a606cb0fb39a1de644815ef6d13b8faa1837f8a88b17fc695a07a0ca6e0822e8f36c031199972a846916419f828b9d2434e465e150bd9c66b3ad3c2d6d1a3d1fa7bc8960a923b8c1e9392456de3eb13b9046685257bdd640fb06671ad11c80317fa3b1799d")
        let b = big("988c24c961b1cd2262801c4510435a1098ae43346c12ace8ae340454cac5b68c28f49481a0a04dc427209bdf1c11f735dc713d960c0fd195c17af08a1745d6d87e570ddf827050a82369b584ff5e9ff0ff50bde4382567b85cabcc97663f1c97956269f0e5d7b8756dadd6c795a76d79bf3c4c06434308bc89fa6a688fb5d27bbeb799193f22faf823bed01d43cf2fde24933b83757750a9a491f0b2ea1fca65e27a984d654821d07fcd9eb1a7cad415366eb16f508ebad7b7c93acfe059a0ee9132b63ef16287e4e9c349e03602f8ac10f1bc81448aaa9e66b2bc5b50c187fcce177b4e0837b8a3d261a7ab3aa2e4f90e51f30dc6a7ee39c4b032ccd7c524a55304317faf42e12f3838b3268e944239b02b61c4a3d70628ece66fa2fd5166e6451b4cf36123fdf77656af7229d4beef3eabedcbbaa80dd488bd64072bcfbe01a28defe39bf0027312476f57a5e5a5abaefcfad8efc89849b3aa7efe4458a885ab9099a435a240ae5af305535ec42e0829a3b2e95d65a441d58842dea2bc372f")
        let sum = red.reduce(a + b)
        XCTAssertEqual(sum.bytesBE.map { String(format: "%02x", $0) }.joined(),
                       "0c9ed75ca8db145bfac0357a08b5d2acb1b9c05b26cebf106027d07254cb294a23205027afa206ef9bbe61efc8357ce69624b17b4a90b413a31e43eed94594915fafab9ea8ebe8219b781cff7998f3ebedb1722a3044c9c7f19af98f468c41dbf237b93718a0a1c0d33af29e7a43eea7622f72564f7ccacae7ee8928779851fb9b7a2f49dd9cdb2dc5c821d8154a55fde4e5820633616d16e03c78cea28fdbbd9f8b81d40d73f2fa7a0453e074cc6d215f24b953dca1a8d548ad3678a72ebd15e4b30c8e0121831195be59c6a115fe92c75cd3a287f79b4eb1665f2989b39ca256c364dc1f4c34de9b19f8de70dfb5744016e643d2d747b88a7c78ea0be376521614b6785ba76fc0fec736aedc1726b8dc8e001e79b7ffd4c8fd21c35d3a91d2334384ab0779c0f19359c4aa17a805dc87c484ffa775e9d69fb052f3be48c736614271d9736937914bc5687472d066efb0b84a3522a3684a56de15e54608c24cc6670becf9e0ec5b55c8e4e6c42f6fd19bf722c3ba91ec47f208745e466db0cd")
        let product = a.modMul(b, modulus: SRP3072.modulus, reducer: red)
        XCTAssertEqual(product.bytesBE.map { String(format: "%02x", $0) }.joined(),
                       "41ef40fa0999dbbd17331cd0744f72a32e54514fac3e2682bec2b3662628a02ebaa4a2f87d0219f562b2ea4363d2d45943d3069a50f52cbb83e3d2aa240c0991d7a7c946735259c08e0e0f4e575070aeee055ac7e95dc66218222a68e1d2c94ee1b606b88a13708b2ba4d929de2c7f722d35d207d755427d3dacd1e449a5c21a2559cf3e7d976534a6211ee12cd79d38df607505189cc6da9a274a9a0e9fb0c113d7bc899bb309f5cccc7135c2a99e80fcc3f0377c38b73bb0758168b27c7f50ac5d5e0034ab0e1b048db9f6544379e810a236367b7b5ef02a31428528eef8dd094c95cd6f52b5f219bd2274d7d50db38097edf6643abaafdbd505304ed9c7c071a8f3a6480c911cd30bc67812714ea4336883986c9a6f43f2ade77bf0c63837a5f4f9c7d43c25ba3c8a7eed2b438451042e96df46ff0969a9419e9e481d3fc7cdca27f53fbfe4e41f11c93d2b20db934747715fabcdbc41fd59a305fd3f4b7cb67806f2881d2bfdb39fb5942a378e0229b3eed70cde0807a6ee2e45030b5f25")
    }

    func testOraclePowmod() {
        // (V0_A ^ V0_B) % N — full oracle value asserted.
        let red = reducer
        let a = big("7412b29347294739614ff3d719db3ad0ddd1dfb23b982ef8daf61a26146d3f31fc377a4c4a15544dc5e7ce8a3a578a8ea9488d990bbb259911ce5dd2b45ed1f03139d32c93cd59bf5c941cf0dc98d2c1e2acf72f9e574f7aa0ee89aed453dd324b0dbb418d5288f1142c3fe860e7a113ec1b8ca1f91e1d4c1ff49b7889463e85759cde66bacfb3d00b1f9163ce9ff57f43b7a3a69a8dca03580d7b71d8f564135be6128e18c267976142ea7d17be31111a2a73ed562b0f79c37459eef50bea63371ecd7b27cd813047229389571aa8766c307511b2b9437a28df6ec4ce4a2bbdc241330b01a9e71fde8a774bcf36d58b4737819096da1dac72ff5d2a386ecbe06b65a6a48b8148f6b38a088ca65ed389b74d0fb132e706298fadc1a606cb0fb39a1de644815ef6d13b8faa1837f8a88b17fc695a07a0ca6e0822e8f36c031199972a846916419f828b9d2434e465e150bd9c66b3ad3c2d6d1a3d1fa7bc8960a923b8c1e9392456de3eb13b9046685257bdd640fb06671ad11c80317fa3b1799d")
        let b = big("988c24c961b1cd2262801c4510435a1098ae43346c12ace8ae340454cac5b68c28f49481a0a04dc427209bdf1c11f735dc713d960c0fd195c17af08a1745d6d87e570ddf827050a82369b584ff5e9ff0ff50bde4382567b85cabcc97663f1c97956269f0e5d7b8756dadd6c795a76d79bf3c4c06434308bc89fa6a688fb5d27bbeb799193f22faf823bed01d43cf2fde24933b83757750a9a491f0b2ea1fca65e27a984d654821d07fcd9eb1a7cad415366eb16f508ebad7b7c93acfe059a0ee9132b63ef16287e4e9c349e03602f8ac10f1bc81448aaa9e66b2bc5b50c187fcce177b4e0837b8a3d261a7ab3aa2e4f90e51f30dc6a7ee39c4b032ccd7c524a55304317faf42e12f3838b3268e944239b02b61c4a3d70628ece66fa2fd5166e6451b4cf36123fdf77656af7229d4beef3eabedcbbaa80dd488bd64072bcfbe01a28defe39bf0027312476f57a5e5a5abaefcfad8efc89849b3aa7efe4458a885ab9099a435a240ae5af305535ec42e0829a3b2e95d65a441d58842dea2bc372f")
        let result = a.modPow(b, modulus: SRP3072.modulus, reducer: red)
        XCTAssertEqual(result.bytesBE.map { String(format: "%02x", $0) }.joined(),
                       "10966b0c21722c2aa755009f67efd5422f414ff809e7ba2f59a5f7e12ec94e8dd6df57756149da1c07e6ddea94c49cb0aa30572d297e473acd8a36d1ec68397c5e4da0f824ae9b3a842e695cf490bfb6d487ba3caee663f978bd6a7c60096cb5cc860efa581875c191c34b021ac378ff7b92b3c5f56858d91e09344d8f42828e49d18dc352b704187628bab115a408ac36a7bd3bfe3f87f5a55898026ccf90b00cdc9032c6c2a92ad8629bbcddc6bda3803ad864214b0fa5ac97fa45933bfd2661f6323bf7e0bf65a5c4e2813ee52681f5052587c340f64d2be82fb3f768cff7c7d55094e6ddc96a93ab3d885d004f94a5f08fe4cbfc5a8995a77587714cd9411990761dd2a210f8c8671042ddc7c1fa9243916fcd8de7093c32c6ac911756620d7f3504cc39594ec58cd4c76735b4200b0062782822e8ea0bceee90846b3edd58ac5d46e16e001d84314606cd881f56ac047da748b00f34cb61f6566f5afc9c4f88ead051f4f0e83e876e003a0a10bc95b3d227d2747d9ba88bfcbc5f13ded4")
    }

    // MARK: - SRP-6a goldens (fixed PIN 123456, salt 00..0f)

    private let testSalt = Data((0..<16).map { UInt8($0) })
    private let testA = "4e4ce5934647bb9ee3cc2a6aba8a1f8518df0ab565b3809b657742d53f5f661cba6c6c6c40a2180db427bbdbbcecbc96cdcd546aca014a49cf8737c637819a5d82241256dd0be1115e9ec8f247ea054e7252a904568ac1c9cd7127d60b7cba87fe7f03538cc38735b5fbd89da400f1b606861af31095d1da22975b638b5cf8e489bbda926dfa63ab6b7301dec487332553185c23eb7b2a71bfd7acb86e9a60c4dd709a120717a87e92fcd6622c4a4c4da34f639a30cc6a97488fdbe8a83534b94694b87c776a95405bd10c47c3a3ff3fa0c661458867c691e8b4148845eef6d19420488ed4b804405b3f2d4cc28c93ee5c166049dda36c06dce27bffb512a2bb5aa7e5be8b9d6cb527567bc0bac950544210ed2394d16ca2d4722a59810aa7b2ff07a9f37b1070fe9d3d0b3eebd7b137de76db9befc8b1557285cc2f775f914a3d53a008578e21ab51946f8f40432a758c45713666d09aa6cdcd87c071a3aac2fb2272e4727e47f22d033811904b8659250b638918e4d59700759274f6c576ea"
    private let testB = "3c3f3944897764e9947d9692f8add83e1fee90bbedc16ef218d545038e58dc292bda74e7f6e8484da0498e1fad03eb9f56cbf7d1c7bfd4367ff3018c239f628dce7dcaa1ffc4e558c295b3267eca77a561c6ceab15ff8bf31eb8c31d00af32a3e601e8481e28e054f726d0b2dc2579973dc5cd1bfbfe13cb524818978d4578c7eb2ca3e7c61016c7b2358baca645ecbd1ed89cf881c4098719329d38adb6e144cd0e82eb0b6a9c2429b7a0aeab815121ec57973cad0122af58875fd4dca838eb677e2de4ec756afdc479f169fc17e158cd4bd534c742243f417ec4e1867cb29d657ce21bf92b837f5a0474a202bda476dae08dea0cd0d96505cdc84acb80e029626d783c341d4aefc367e249591f89495b326bb99b6045d408f186bb1d34631362fd45126f7151e092ecc6e7f77d0e209ee5495bdd4af119e47c671165ada57e52640c4d192162078b6df36a04acb5a5f9f7afc7e2a282ee4ba4c522d3b3262d2d2e3a3bed0196d09ca9bf0e36e2bc53bc8bf60453ef2019dd2a2a8387b44826"

    func testSRPVerifierAndPublic() {
        let red = reducer
        let x = SRP3072.x(salt: testSalt, password: Data("123456".utf8))
        let v = SRP3072.verifier(x: x, reducer: red)
        let k = SRP3072.k()
        // B recomputed from fixed b=0x42*32 must be 384 bytes starting 3c3f...
        let b = big(String(repeating: "42", count: 32))
        let B = SRP3072.serverPublic(b: b, v: v, k: k, reducer: red)
        XCTAssertEqual(B.fixedBE(384)?.map { String(format: "%02x", $0) }.joined(),
                       testB)
    }

    func testSRPProofsMatchOracle() {
        let red = reducer
        let A = big(testA)
        let B = big(testB)
        let u = SRP3072.u(clientPublic: A, serverPublic: B)
        // K from fixed b=0x42*32 and the oracle A.
        let b = big(String(repeating: "42", count: 32))
        let x = SRP3072.x(salt: testSalt, password: Data("123456".utf8))
        let v = SRP3072.verifier(x: x, reducer: red)
        let S = A.modMul(v.modPow(u, modulus: SRP3072.modulus, reducer: red),
                         modulus: SRP3072.modulus, reducer: red)
            .modPow(b, modulus: SRP3072.modulus, reducer: red)
        let K = SRP3072.sha512(Data(S.bytesBE))
        XCTAssertEqual(K.map { String(format: "%02x", $0) }.joined(),
                       "601d2e39edbf9fe0337b0354bc4018c63077e6b9785612a2b17126a0acf490f67da4a21e60739591d086fc8ff1dce6f57bb924d5a35017747676bd1c238c98f2")
        let M1 = SRP3072.m1(clientPublic: A, serverPublic: B, key: K, salt: testSalt)
        XCTAssertEqual(M1.map { String(format: "%02x", $0) }.joined(),
                       "6830de801be74c0e05f316e7f88be80dc748cbab4eaf3a2b817bd74aef9342be0fa35520f0eb757249de453c984908566fe65722497c870d35ecebafaa30c4c5")
        let M2 = SRP3072.m2(clientPublic: A, m1: M1, key: K)
        XCTAssertEqual(M2.map { String(format: "%02x", $0) }.joined(),
                       "c653ad27cd1f01a7c6b49f3188288dbd703e6638c47bd8c3804c9cf63e6383970c056c578ba5d4707b4004c7b9d6dfcc974518bbf8fec5ffc96c204587c655d0")
    }

    // MARK: - OPACK

    func testOPACKDecodePythonFixture() throws {
        // Generated from the format spec with an independent script.
        let hex = "e4496163636f756e7449444c746573742d69642d3132333446616c7449524b80abababababababababababababababab456d6f64656c4a6950686f6e6531342c34446e616d654b4c6976696e6720526f6f6d"
        var bytes: [UInt8] = []
        var chars = hex.makeIterator()
        while let high = chars.next(), let low = chars.next() {
            bytes.append(UInt8(String([high, low]), radix: 16) ?? 0)
        }
        let decoded = try OPACK.decode(Data(bytes))
        guard case .dictionary(let dict) = decoded else {
            XCTFail("expected dictionary"); return
        }
        func value(_ key: String) -> OPACK.Value? {
            dict.first { $0.0 == key }?.1
        }
        XCTAssertEqual(value("accountID").flatMap {
            if case .string(let text) = $0 { return text } else { return nil }
        }, "test-id-1234")
        XCTAssertEqual(value("model").flatMap {
            if case .string(let text) = $0 { return text } else { return nil }
        }, "iPhone14,4")
        XCTAssertEqual(value("name").flatMap {
            if case .string(let text) = $0 { return text } else { return nil }
        }, "Living Room")
        if case .data(let irk) = value("altIRK") {
            XCTAssertEqual(irk, Data(repeating: 0xAB, count: 16))
        } else {
            XCTFail("altIRK must decode as 16-byte data")
        }
    }

    func testOPACKEncodeDecodeRoundTrip() throws {
        let value = OPACK.Value.dictionary([
            ("identifier", .string("ec05a22f-7737-3e64-8a49-fa856b07a84e")),
            ("flags", .int(1)),
            ("enabled", .bool(true)),
            ("blob", .data(Data([0x01, 0x02, 0x03]))),
            ("list", .array([.int(7), .string("seven")])),
        ])
        let decoded = try OPACK.decode(OPACK.encode(value))
        XCTAssertTrue(OPACK.isEqual(decoded, value))
    }

    // MARK: - Pair-setup wire helpers

    func testTLVChunking() {
        let big = Data(repeating: 0xCC, count: 384)
        var entries: [TLV8.Entry] = []
        var offset = big.startIndex
        while offset < big.endIndex {
            let end = big.index(offset, offsetBy: 255, limitedBy: big.endIndex) ?? big.endIndex
            entries.append(TLV8.Entry(.publicKey, Data(big[offset..<end])))
            offset = end
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].data.count, 255)
        XCTAssertEqual(entries[1].data.count, 129)
        // collect_component_data concatenates same-type entries (fragmentation).
        XCTAssertEqual(entries.filter { $0.component == .publicKey }
            .reduce(Data(), { $0 + $1.data }), big)
    }

    func testHostTXTAuthTagSelfValidates() {
        let identity = PairingHost.HostIdentity(
            seed: Data(repeating: 0x11, count: 32),
            publicKey: Data(repeating: 0x22, count: 32),
            identifier: "EC05A22F-7737-3E64-8A49-FA856B07A84E",
            altIrk: Data((0..<16).map { UInt8($0) }),
            name: "AirLift", model: "Mac17,7")
        let records = Dictionary(uniqueKeysWithValues: PairingHost.txtRecords(identity: identity))
        XCTAssertEqual(records["ver"], "26")
        XCTAssertEqual(records["minVer"], "17")
        XCTAssertEqual(records["flags"], "1")
        XCTAssertEqual(records["identifier"], identity.identifier)
        // The advertised authTag must validate against our own alt_irk.
        XCTAssertTrue(RemotePairingAuth.validates(
            authTagBase64: records["authTag"] ?? "",
            altIrk: identity.altIrk,
            serviceIdentifier: identity.identifier))
    }

    func testHostIdentityRoundTrip() {
        let identity = PairingHost.HostIdentity.generate()
        let restored = PairingHost.HostIdentity.from(plist: identity.plist())
        XCTAssertEqual(restored, identity)
    }

    func testM6IdentityStructure() throws {
        // Accessory sign-buffer layout: AccessoryX(32) || identifier || LTPK(32).
        let signbuf = PairingAcceptor.accessorySignBuffer(
            accessoryX: Data(repeating: 0xAA, count: 32),
            identifier: "ID",
            ltpk: Data(repeating: 0xBB, count: 32))
        XCTAssertEqual(signbuf.count, 66)
        XCTAssertEqual(signbuf.prefix(32), Data(repeating: 0xAA, count: 32))
        XCTAssertEqual(signbuf.dropFirst(32).prefix(2), Data("ID".utf8))
        XCTAssertEqual(signbuf.suffix(32), Data(repeating: 0xBB, count: 32))
    }
}

extension PairingCryptoTests {
    func testChunkedPublicKeyReassembles() {
        // A 384-byte client ephemeral arrives as 255 + 129 byte entries;
        // the acceptor must concatenate, not take the first chunk.
        // (First byte nonzero so the value is a full 384 bytes.)
        let full = Data((1...384).map { UInt8($0 & 0xff) })
        var entries: [TLV8.Entry] = []
        var offset = full.startIndex
        while offset < full.endIndex {
            let end = full.index(offset, offsetBy: 255, limitedBy: full.endIndex) ?? full.endIndex
            entries.append(TLV8.Entry(.publicKey, Data(full[offset..<end])))
            offset = end
        }
        XCTAssertEqual(entries.count, 2)
        let reassembled = entries.filter { $0.component == .publicKey }
            .reduce(Data(), { $0 + $1.data })
        XCTAssertEqual(reassembled, full)
        XCTAssertEqual(SRPBigUInt(bytesBE: Array(reassembled)).bytesBE.count, 384)
    }
}
