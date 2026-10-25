import XCTest
@testable import RescueMate
import CoreLocation

final class LogicTests: XCTestCase {

    // MARK: - 救援助手

    func testAssistantMatch() {
        let matches = RescueAssistant.match("车子爆胎了，在高速上")
        XCTAssertEqual(matches.first?.scenario.title, "爆胎 / 轮胎漏气")

        let electric = RescueAssistant.match("电车没电了，找不到充电桩")
        XCTAssertEqual(electric.first?.scenario.searchKeyword, "充电桩")

        let injured = RescueAssistant.match("有人受伤流血")
        XCTAssertEqual(injured.first?.scenario.callNumber, "120")
    }

    func testAssistantReplyContents() {
        let reply = RescueAssistant.reply(for: "电瓶打不着火")
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertTrue(reply.text.contains("电瓶亏电"))
        XCTAssertTrue(reply.text.contains("1. "))
        XCTAssertTrue(reply.actions.contains(.search("汽车维修")))
        XCTAssertFalse(reply.actions.contains(.call("120")))

        let fallback = RescueAssistant.reply(for: "今天天气怎么样")
        XCTAssertTrue(fallback.actions.contains(.search("汽车维修")))
    }

    // MARK: - 位置历史

    func testLocationHistoryAppendAndCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_history_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(LocationHistoryStore.load(from: url).isEmpty)

        let entry = LastKnownLocation(latitude: 39.9, longitude: 116.4,
                                      horizontalAccuracy: 10, timestamp: Date(), address: nil)
        LocationHistoryStore.append(entry, to: url)
        XCTAssertEqual(LocationHistoryStore.load(from: url).count, 1)

        // 超过容量上限时丢弃最旧记录
        for i in 0..<(LocationHistoryStore.maxEntries + 10) {
            var e = entry
            e.latitude = Double(i)
            LocationHistoryStore.append(e, to: url)
        }
        let entries = LocationHistoryStore.load(from: url)
        XCTAssertEqual(entries.count, LocationHistoryStore.maxEntries)
        XCTAssertEqual(entries.first?.latitude, 10) // 最早的 10 条被丢弃

        let first = LocationHistoryStore.load(from: url)[0]
        LocationHistoryStore.delete(at: 0, from: url)
        XCTAssertEqual(LocationHistoryStore.load(from: url).count, LocationHistoryStore.maxEntries - 1)
        XCTAssertNotEqual(LocationHistoryStore.load(from: url).first?.latitude, first.latitude)

        LocationHistoryStore.clear(fileURL: url)
        XCTAssertTrue(LocationHistoryStore.load(from: url).isEmpty)
    }

    // MARK: - Key 校验

    func testKeyFormatValidation() {
        XCTAssertTrue(AMapConfig.isValidKeyFormat("0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(AMapConfig.isValidKeyFormat("  0123456789ABCDEF0123456789ABCDEF  "))
        XCTAssertTrue(AMapConfig.isValidKeyFormat("a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6"))
        XCTAssertFalse(AMapConfig.isValidKeyFormat("short-key"))
        XCTAssertFalse(AMapConfig.isValidKeyFormat("0123456789abcdef0123456789abcde-"))
        XCTAssertFalse(AMapConfig.isValidKeyFormat("0123456789abcdef0123456789abcde中"))
        XCTAssertFalse(AMapConfig.isValidKeyFormat(""))
    }

    // MARK: - POI 解析（含高德空字段返回 [] 的情况）

    func testParsePOI() {
        let dict: [String: Any] = [
            "id": "B000A8UIN8",
            "name": "某某汽车维修",
            "address": [], // 高德空字段
            "location": "116.481028,39.989643",
            "type": "汽车服务;汽车维修;修理厂",
            "tel": [],
            "distance": "1234",
            "business": ["tel": "010-88886666"],
        ]
        let poi = AMapSearchClient.parsePOI(dict)
        XCTAssertNotNil(poi)
        XCTAssertEqual(poi?.id, "B000A8UIN8")
        XCTAssertEqual(poi?.address, "")
        XCTAssertEqual(poi?.tel, "010-88886666")
        XCTAssertEqual(poi?.distanceMeters, 1234)
        XCTAssertEqual(poi?.latitude ?? 0, 39.989643, accuracy: 0.000001)
    }

    func testEmergencyDetection() {
        let general = POI(id: "1", name: "某某人民医院", address: "", tel: nil, type: "医疗保健;综合医院",
                          latitude: 39.9, longitude: 116.4, distanceMeters: nil, fetchedAt: Date())
        let er = POI(id: "2", name: "某某急救中心", address: "", tel: nil, type: nil,
                     latitude: 39.9, longitude: 116.4, distanceMeters: nil, fetchedAt: Date())
        let clinic = POI(id: "3", name: "某某口腔门诊部", address: "", tel: nil, type: "医疗保健;口腔医院",
                         latitude: 39.9, longitude: 116.4, distanceMeters: nil, fetchedAt: Date())
        XCTAssertTrue(general.hasEmergency)   // 综合医院视为有急诊
        XCTAssertTrue(er.hasEmergency)
        XCTAssertFalse(clinic.hasEmergency)   // 专科不标
    }

    // MARK: - 离线缓存

    func testPOICacheSaveAndNearest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_cache_\(UUID().uuidString)", isDirectory: true)
        let cache = POICache(directory: dir)

        let poi = POI(id: "P1", name: "附近修理店", address: "某路1号", tel: "010-12345678", type: nil,
                      latitude: 39.900, longitude: 116.400, distanceMeters: nil, fetchedAt: Date())
        let entry = POICacheEntry(categoryID: "car_repair", keyword: "汽车维修",
                                  centerLatitude: 39.9005, centerLongitude: 116.4005,
                                  pois: [poi], fetchedAt: Date())
        cache.save(entry)

        // 同位置能命中
        let hit = cache.nearest(categoryID: "car_repair", latitude: 39.9001, longitude: 116.4001)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.pois.first?.id, "P1")

        // 相距 30km 的位置不应命中（超出 8km 复用半径）
        let miss = cache.nearest(categoryID: "car_repair", latitude: 39.63, longitude: 116.65)
        XCTAssertNil(miss)

        // 其他品类不串数据
        let other = cache.nearest(categoryID: "hospital", latitude: 39.9001, longitude: 116.4001)
        XCTAssertNil(other)
    }

    func testGridValueStable() {
        XCTAssertEqual(POICache.gridValue(39.989643), POICache.gridValue(39.98967))
        XCTAssertNotEqual(POICache.gridValue(39.98), POICache.gridValue(39.99))
    }

    // MARK: - 最后联网定位落盘

    func testLastLocationRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_last_\(UUID().uuidString).json")
        let entry = LastKnownLocation(latitude: 39.9, longitude: 116.4,
                                      horizontalAccuracy: 15, timestamp: Date(),
                                      address: "北京市海淀区某路")
        LastLocationFileStore.save(entry, to: url)
        let loaded = LastLocationFileStore.load(from: url)
        XCTAssertEqual(loaded, entry)
        XCTAssertEqual(loaded?.address, "北京市海淀区某路")
    }

    // MARK: - 离线记录

    @MainActor
    func testRecordStorePersistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_records_\(UUID().uuidString).json")
        let store = RecordStore(fileURL: url)
        let record = RescueRecord(categoryID: "car_repair", categoryLabel: "汽修救援",
                                  note: "高速抛锚", latitude: 39.9, longitude: 116.4)
        store.add(record)
        XCTAssertEqual(store.records.count, 1)

        let reloaded = RecordStore(fileURL: url)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.note, "高速抛锚")

        reloaded.delete(record)
        XCTAssertEqual(reloaded.records.count, 0)
        let afterDelete = RecordStore(fileURL: url)
        XCTAssertEqual(afterDelete.records.count, 0)
    }

    // MARK: - 排序

    func testSortedByDistance() {
        let center = CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4)
        let near = POI(id: "n", name: "近", address: "", tel: nil, type: nil,
                       latitude: 39.901, longitude: 116.401, distanceMeters: nil, fetchedAt: Date())
        let far = POI(id: "f", name: "远", address: "", tel: nil, type: nil,
                      latitude: 39.99, longitude: 116.5, distanceMeters: nil, fetchedAt: Date())
        let sorted = HomeView.sorted([far, near], near: center)
        XCTAssertEqual(sorted.first?.id, "n")
        XCTAssertNotNil(sorted[0].distanceMeters)
    }

    // MARK: - 错误映射

    func testAPIErrorMapping() {
        if case .keyInvalid = RescueAPIError.from(infocode: "10001", info: "KEY不正确") {} else {
            XCTFail("10001 应映射为 keyInvalid")
        }
        if case .quotaExceeded = RescueAPIError.from(infocode: "10003", info: "超限") {} else {
            XCTFail("10003 应映射为 quotaExceeded")
        }
        if case .serviceUnsupported = RescueAPIError.from(infocode: "10004", info: "不支持") {} else {
            XCTFail("10004 应映射为 serviceUnsupported")
        }
    }
}
