import Foundation
import SQLite3

/// SQLite C API 的薄封装：供各 Store 复用此前逐字重复的 bind/column 样板。
enum SQL {

    static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    static func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bind(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func column(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        optionalColumn(stmt, index) ?? ""
    }

    static func optionalColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }
}
