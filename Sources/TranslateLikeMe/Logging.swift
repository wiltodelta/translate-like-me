import os

extension Logger {
    // One subsystem for every log line: /usr/bin/log stream --predicate
    // 'subsystem == "com.wiltodelta.translatelikeme"'.
    static func app(_ category: String) -> Logger {
        Logger(subsystem: "com.wiltodelta.translatelikeme", category: category)
    }
}
