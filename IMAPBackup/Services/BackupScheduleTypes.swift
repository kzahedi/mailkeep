import Foundation

/// Days of the week for scheduling
enum Weekday: Int, Codable, CaseIterable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }

    var fullName: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}

/// Custom schedule interval units
enum ScheduleIntervalUnit: String, Codable, CaseIterable {
    case hours = "hours"
    case days = "days"
    case weeks = "weeks"

    var displayName: String {
        rawValue.capitalized
    }

    func toSeconds(_ value: Int) -> TimeInterval {
        switch self {
        case .hours: return TimeInterval(value * 3600)
        case .days: return TimeInterval(value * 86400)
        case .weeks: return TimeInterval(value * 604800)
        }
    }
}

/// Backup schedule configuration
struct ScheduleConfiguration: Codable, Equatable {
    var weekday: Weekday = .monday
    var customInterval: Int = 1
    var customUnit: ScheduleIntervalUnit = .days
}

/// Backup schedule options
enum BackupSchedule: String, Codable, CaseIterable {
    case manual = "Manual"
    case hourly = "Every Hour"
    case daily = "Daily"
    case weekly = "Weekly"
    case custom = "Custom"

    var interval: TimeInterval? {
        switch self {
        case .manual: return nil
        case .hourly: return 3600
        case .daily: return 86400
        case .weekly: return 604800
        case .custom: return nil // Calculated from configuration
        }
    }

    var needsTimeSelection: Bool {
        switch self {
        case .daily, .weekly, .custom: return true
        default: return false
        }
    }

    var needsWeekdaySelection: Bool {
        self == .weekly
    }

    var needsCustomConfiguration: Bool {
        self == .custom
    }
}
