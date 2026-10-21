import Foundation

/// Una línea recibida de CloudWatch Logs (Live Tail no entrega `eventId`;
/// se construye uno estable en `AWSEventStreamDecoder`).
struct LiveTailEvent: Sendable {
    let event: CloudWatchLogEvent
}
/// Evento decodificado del *event stream* de AWS.
enum LiveTailStreamEvent: Sendable {
    case started(sessionID: String, requestID: String)
    case events([CloudWatchLogEvent])
    case heartbeat
}

/// Decodificador del *event stream* de AWS (`application/vnd.amazon.event-stream`).
///
/// Cada mensaje tiene la forma:
///
/// ```text
/// [longitud preludio][longitud total][CRC preludio][CRC mensaje]
/// [longitud cabeceras][cabeceras][cuerpo][CRC mensaje]
/// ```
///
/// y los mensajes se separan con `\r\n\r\n`. Se implementa a mano para no
/// añadir el SDK de AWS a una app de escritorio: solo se usan las cabeceras de
/// texto, que es lo que necesita `sessionUpdate`.
enum AWSEventStreamDecoder {
    static let preludeLength = 12

    /// `Data.dropFirst` conserva los índices originales del slice, así que
    /// `.count` seguiría siendo el del buffer completo. Siempre se reindexa.
    private static func dropBytes(_ data: Data, _ count: Int) -> Data {
        Data(data.dropFirst(count))
    }

    /// CRC-32 (polinomio CRC-32/ISO-HDLC) que AWS usa en el preludio y en el
    /// cierre de cada mensaje del event stream.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Corta el buffer en mensajes **válidos** y devuelve lo que no llegó
    /// entero o lo que quedó desalineado.
    ///
    /// Un preludio corrupto no se puede resincronizar con certeza: se descarta
    /// el buffer y se espera a la siguiente trama completa, en lugar de
    /// interpretar bytes del cuerpo como si fueran longitudes.
    static func decode(_ buffer: Data) -> (messages: [Data], remainder: Data) {
        var messages: [Data] = []
        var remaining = buffer
        // AWS separa los mensajes con `\r\n\r\n`, que NO forma parte de
        // `total-length`.
        let boundary = Data([0x0D, 0x0A, 0x0D, 0x0A])
        while true {
            if remaining.starts(with: boundary) {
                remaining = dropBytes(remaining, 4)
                continue
            }
            guard remaining.count >= preludeLength else { break }
            let totalLength = Int(readUInt32(remaining, at: 4))
            guard totalLength >= preludeLength + 4, totalLength <= 16 * 1024 * 1024 else {
                remaining = dropBytes(remaining, 1)
                continue
            }
            guard remaining.count >= totalLength else { break }
            messages.append(Data(remaining.prefix(totalLength)))
            remaining = dropBytes(remaining, totalLength)
        }
        return (messages, remaining)
    }

    /// Extrae el tipo de evento y el JSON del cuerpo de un mensaje.
    static func parse(_ frame: Data) -> LiveTailStreamEvent? {
        guard frame.count >= preludeLength + 4 else { return nil }
        let headersLength = Int(readUInt32(frame, at: 8))
        let headersStart = preludeLength
        let headersEnd = headersStart + headersLength
        guard headersEnd + 4 <= frame.count else { return nil }

        let headers = parseHeaders(frame.subdata(in: headersStart..<headersEnd))
        let body = frame.subdata(in: headersEnd..<(frame.count - 4))
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        guard let event = headers[":event-type"] else { return nil }

        switch event {
        case "sessionStart":
            return .started(
                sessionID: payload["sessionId"] as? String ?? "",
                requestID: payload["requestId"] as? String ?? ""
            )
        case "sessionUpdate":
            return .events(events(fromSessionUpdate: payload))
        default:
            return .heartbeat
        }
    }

    /// Convierte el payload de `sessionUpdate` en líneas de log.
    static func events(fromSessionUpdate payload: [String: Any]) -> [CloudWatchLogEvent] {
        guard let results = payload["sessionResults"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let message = item["message"] as? String else { return nil }
            let timestamp = int64(item["timestamp"]) ?? int64(item["ingestionTime"]) ?? 0
            let stream = item["logStreamName"] as? String
            let eventID = item["eventId"] as? String
                ?? eventIdentifier(stream: stream, timestamp: timestamp, message: message)
            return CloudWatchLogEvent(
                eventId: eventID,
                ingestionTime: int64(item["ingestionTime"]),
                logStreamName: stream,
                message: message,
                timestamp: timestamp
            )
        }
    }

    /// Live Tail no devuelve `eventId`: se construye uno estable para que el
    /// flujo en vivo y el sondeo de respaldo no dupliquen la misma línea.
    static func eventIdentifier(stream: String?, timestamp: Int64, message: String) -> String {
        let digest = AWSSigner.sha256Hex(Data(message.utf8))
        return "lt-\(stream ?? "-")-\(timestamp)-\(digest.prefix(20))"
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let string as String: return Int64(string)
        default: return nil
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let start = data.startIndex + offset
        return data[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func parseHeaders(_ data: Data) -> [String: String] {
        var headers: [String: String] = [:]
        var index = data.startIndex
        let end = data.endIndex
        while index < end {
            let nameLength = Int(data[index])
            index += 1
            guard data.distance(from: index, to: end) >= nameLength else { break }
            let nameEnd = index + nameLength
            let name = String(decoding: data[index..<nameEnd], as: UTF8.self)
            index = nameEnd
            guard index < end else { break }
            let type = data[index]
            index += 1
            let available = data.distance(from: index, to: end)
            switch type {
            case 7:
                guard available >= 2 else { return headers }
                let length = Int((UInt16(data[index]) << 8) | UInt16(data[index + 1]))
                index += 2
                guard data.distance(from: index, to: end) >= length else { return headers }
                let valueEnd = index + length
                headers[name] = String(decoding: data[index..<valueEnd], as: UTF8.self)
                index = valueEnd
            case 0, 1:
                headers[name] = type == 0 ? "true" : "false"
            case 2:
                guard available >= 1 else { return headers }
                headers[name] = String(Int8(bitPattern: data[index]))
                index += 1
            case 3:
                guard available >= 2 else { return headers }
                headers[name] = String(Int16(bitPattern: (UInt16(data[index]) << 8) | UInt16(data[index + 1])))
                index += 2
            case 4:
                guard available >= 4 else { return headers }
                headers[name] = String(readUInt32(data, at: data.distance(from: data.startIndex, to: index)))
                index += 4
            default:
                return headers
            }
        }
        return headers
    }
}
