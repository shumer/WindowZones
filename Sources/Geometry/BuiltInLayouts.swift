import Foundation

public enum BuiltInLayouts {
    // These identifiers are part of the preset contract and must survive relaunches.
    private static func id(_ suffix: String) -> UUID {
        UUID(uuidString: "575A0000-0000-4000-8000-\(suffix)")!
    }

    private static func zone(_ suffix: String, _ name: String) -> LayoutNode {
        .zone(id: id(suffix), name: name)
    }

    public static let halves = Layout(id: id("000000000001"), name: "Пополам",
        root: .split(axis: .vertical, ratio: 0.5,
                     first: zone("000000000101", "Слева"), second: zone("000000000102", "Справа")))

    public static let thirds = Layout(id: id("000000000002"), name: "Три колонки",
        root: .split(axis: .vertical, ratio: 1.0 / 3,
                     first: zone("000000000201", "Слева"),
                     second: .split(axis: .vertical, ratio: 0.5,
                                    first: zone("000000000202", "Центр"), second: zone("000000000203", "Справа"))))

    public static let focused = Layout(id: id("000000000003"), name: "Широкий центр",
        root: .split(axis: .vertical, ratio: 0.25,
                     first: zone("000000000301", "Слева"),
                     second: .split(axis: .vertical, ratio: 2.0 / 3,
                                    first: zone("000000000302", "Центр"), second: zone("000000000303", "Справа"))))

    public static let focusedWithStack = Layout(id: id("000000000004"), name: "Центр и две справа",
        root: .split(axis: .vertical, ratio: 0.25,
                     first: zone("000000000401", "Слева"),
                     second: .split(axis: .vertical, ratio: 2.0 / 3,
                                    first: zone("000000000402", "Центр"),
                                    second: .split(axis: .horizontal, ratio: 0.5,
                                                   first: zone("000000000403", "Справа сверху"),
                                                   second: zone("000000000404", "Справа снизу")))))

    public static let wideLeft = Layout(id: id("000000000005"), name: "75 / 25",
        root: .split(axis: .vertical, ratio: 0.75,
                     first: zone("000000000501", "Слева"), second: zone("000000000502", "Справа")))

    public static let rows = Layout(id: id("000000000006"), name: "Верх и низ",
        root: .split(axis: .horizontal, ratio: 0.5,
                     first: zone("000000000601", "Сверху"), second: zone("000000000602", "Снизу")))

    public static let quarters = Layout(id: id("000000000007"), name: "Четыре четверти",
        root: .split(axis: .horizontal, ratio: 0.5,
                     first: .split(axis: .vertical, ratio: 0.5,
                                   first: zone("000000000701", "Слева сверху"), second: zone("000000000702", "Справа сверху")),
                     second: .split(axis: .vertical, ratio: 0.5,
                                    first: zone("000000000703", "Слева снизу"), second: zone("000000000704", "Справа снизу"))))

    public static let twoThirdsLeft = Layout(id: id("000000000008"), name: "Две трети слева",
        root: .split(axis: .vertical, ratio: 2.0 / 3,
                     first: zone("000000000801", "Слева"), second: zone("000000000802", "Справа")))

    public static let leftHalfRightStack = Layout(id: id("000000000009"), name: "Половина и две справа",
        root: .split(axis: .vertical, ratio: 0.5,
                     first: zone("000000000901", "Слева"),
                     second: .split(axis: .horizontal, ratio: 0.5,
                                    first: zone("000000000902", "Справа сверху"),
                                    second: zone("000000000903", "Справа снизу"))))

    public static let threeRows = Layout(id: id("000000000010"), name: "Три ряда",
        root: .split(axis: .horizontal, ratio: 1.0 / 3,
                     first: zone("000000001001", "Сверху"),
                     second: .split(axis: .horizontal, ratio: 0.5,
                                    first: zone("000000001002", "Центр"), second: zone("000000001003", "Снизу"))))

    // Thresholds use logical points so display scaling affects usable space.
    public static func suggested(in area: CGRect) -> [Layout] {
        if area.height > area.width { return [rows, threeRows, quarters] }
        if area.width >= 1440 && area.width / max(1, area.height) >= 1.5 { return landscape }
        return [halves, twoThirdsLeft, leftHalfRightStack, quarters]
    }

    // Preserve the old definitions solely for lossless preset migration.
    public static let legacy: [Layout] = [halves, thirds, focused, focusedWithStack]
    public static let previousStandard: [Layout] = [halves, wideLeft, thirds, rows, quarters]
    public static let landscape: [Layout] = [halves, twoThirdsLeft, thirds, leftHalfRightStack, quarters, focused]
    public static let all: [Layout] = landscape + [rows, threeRows]
}
