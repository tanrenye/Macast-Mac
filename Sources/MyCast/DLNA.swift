import Foundation
import Network
import OSLog

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var xml: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// DLNA 描述、SOAP 和 DIDL-Lite 共用的小型 XML 树，拒绝 DTD 和外部实体。
final class XMLTree: NSObject, XMLParserDelegate {
    let name: String
    let namespace: String?
    let attributes: [String: String]
    var text = ""
    var children: [XMLTree] = []
    private weak var parent: XMLTree?
    private var current: XMLTree?
    private var depth = 0

    init(_ name: String, namespace: String? = nil, attributes: [String: String] = [:]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }

    static func parse(_ data: Data) -> XMLTree? {
        guard let document = String(data: data, encoding: .utf8),
              !document.contains("<!DOCTYPE"), !document.utf8.contains(0) else { return nil }
        let holder = XMLTree("")
        holder.current = holder
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = holder
        let parsed = parser.parse()
        holder.current = nil
        return parsed ? holder.children.first : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard depth < 32 else { parser.abortParsing(); return }
        let node = XMLTree(name, namespace: namespaceURI, attributes: attributes)
        current?.children.append(node)
        node.parent = current
        current = node
        depth += 1
    }

    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
        current = current?.parent
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current?.text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { current?.text += String(decoding: data, as: UTF8.self) }
}

enum DLNAService: String, CaseIterable {
    case transport = "AVTransport"
    case rendering = "RenderingControl"
    case connection = "ConnectionManager"

    var urn: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
    var declaration: String {
        """
        <service><serviceType>\(urn)</serviceType><serviceId>urn:upnp-org:serviceId:\(rawValue)</serviceId>
        <controlURL>\(rawValue)/action</controlURL><eventSubURL>\(rawValue)/event</eventSubURL>
        <SCPDURL>dlna/\(rawValue).xml</SCPDURL></service>
        """
    }

    // 描述文件和实际请求校验共用动作定义，防止声明了未实现的动作。
    var actions: [String: (input: [String], output: [String])] {
        switch self {
        case .transport:
            return [
                "SetAVTransportURI": (["InstanceID", "CurrentURI", "CurrentURIMetaData"], []),
                "SetNextAVTransportURI": (["InstanceID", "NextURI", "NextURIMetaData"], []),
                "Play": (["InstanceID", "Speed"], []), "Pause": (["InstanceID"], []), "Stop": (["InstanceID"], []),
                "Seek": (["InstanceID", "Unit", "Target"], []), "Next": (["InstanceID"], []),
                "Previous": (["InstanceID"], []), "SetPlayMode": (["InstanceID", "NewPlayMode"], []),
                "GetTransportInfo": (["InstanceID"], ["CurrentTransportState", "CurrentTransportStatus", "CurrentSpeed"]),
                "GetPositionInfo": (["InstanceID"], ["Track", "TrackDuration", "TrackMetaData", "TrackURI",
                                                      "RelTime", "AbsTime", "RelCount", "AbsCount"]),
                "GetMediaInfo": (["InstanceID"], ["NrTracks", "MediaDuration", "CurrentURI", "CurrentURIMetaData",
                                                  "NextURI", "NextURIMetaData", "PlayMedium", "RecordMedium", "WriteStatus"]),
                "GetTransportSettings": (["InstanceID"], ["PlayMode", "RecQualityMode"]),
                "GetDeviceCapabilities": (["InstanceID"], ["PlayMedia", "RecMedia", "RecQualityModes"]),
                "GetCurrentTransportActions": (["InstanceID"], ["Actions"])
            ]
        case .rendering:
            return [
                "GetVolume": (["InstanceID", "Channel"], ["CurrentVolume"]),
                "SetVolume": (["InstanceID", "Channel", "DesiredVolume"], []),
                "GetVolumeDB": (["InstanceID", "Channel"], ["CurrentVolume"]),
                "SetVolumeDB": (["InstanceID", "Channel", "DesiredVolume"], []),
                "GetVolumeDBRange": (["InstanceID", "Channel"], ["MinValue", "MaxValue"]),
                "GetMute": (["InstanceID", "Channel"], ["CurrentMute"]),
                "SetMute": (["InstanceID", "Channel", "DesiredMute"], []),
                "ListPresets": (["InstanceID"], ["CurrentPresetNameList"]),
                "SelectPreset": (["InstanceID", "PresetName"], [])
            ]
        case .connection:
            return [
                "GetProtocolInfo": ([], ["Source", "Sink"]),
                "GetCurrentConnectionIDs": ([], ["ConnectionIDs"]),
                "GetCurrentConnectionInfo": (["ConnectionID"], ["RcsID", "AVTransportID", "ProtocolInfo",
                                                                  "PeerConnectionManager", "PeerConnectionID", "Direction", "Status"])
            ]
        }
    }

    private func variable(_ name: String, action: String) -> (String, String) {
        let mapped: [String: String] = [
            "InstanceID": "A_ARG_TYPE_InstanceID", "Channel": "A_ARG_TYPE_Channel",
            "CurrentVolume": "Volume", "DesiredVolume": "Volume", "CurrentMute": "Mute", "DesiredMute": "Mute",
            "CurrentTransportState": "TransportState", "CurrentTransportStatus": "TransportStatus",
            "CurrentSpeed": "TransportPlaySpeed", "Speed": "TransportPlaySpeed", "Track": "CurrentTrack",
            "TrackDuration": "CurrentTrackDuration", "TrackMetaData": "CurrentTrackMetaData", "TrackURI": "CurrentTrackURI",
            "RelTime": "RelativeTimePosition", "AbsTime": "AbsoluteTimePosition", "RelCount": "RelativeCounterPosition",
            "AbsCount": "AbsoluteCounterPosition", "NrTracks": "NumberOfTracks", "MediaDuration": "CurrentMediaDuration",
            "CurrentURI": "AVTransportURI", "CurrentURIMetaData": "AVTransportURIMetaData",
            "NextURI": "NextAVTransportURI", "NextURIMetaData": "NextAVTransportURIMetaData",
            "PlayMode": "CurrentPlayMode", "NewPlayMode": "CurrentPlayMode", "PlayMedium": "PlaybackStorageMedium",
            "RecordMedium": "RecordStorageMedium", "WriteStatus": "RecordMediumWriteStatus", "Actions": "CurrentTransportActions",
            "PlayMedia": "PossiblePlaybackStorageMedia", "RecMedia": "PossibleRecordStorageMedia",
            "RecQualityMode": "CurrentRecordQualityMode", "RecQualityModes": "PossibleRecordQualityModes",
            "Unit": "A_ARG_TYPE_SeekMode", "Target": "A_ARG_TYPE_SeekTarget",
            "PresetName": "A_ARG_TYPE_PresetName", "Source": "SourceProtocolInfo", "Sink": "SinkProtocolInfo",
            "CurrentPresetNameList": "PresetNameList",
            "ConnectionIDs": "CurrentConnectionIDs", "ConnectionID": "A_ARG_TYPE_ConnectionID",
            "RcsID": "A_ARG_TYPE_RcsID", "AVTransportID": "A_ARG_TYPE_AVTransportID",
            "ProtocolInfo": "A_ARG_TYPE_ProtocolInfo", "PeerConnectionManager": "A_ARG_TYPE_ConnectionManager",
            "PeerConnectionID": "A_ARG_TYPE_ConnectionID", "Direction": "A_ARG_TYPE_Direction",
            "Status": "A_ARG_TYPE_ConnectionStatus", "MinValue": "VolumeDB", "MaxValue": "VolumeDB"
        ]
        var state = mapped[name] ?? name
        if state == "Volume" && action.hasSuffix("DB") { state = "VolumeDB" }
        let types = ["Volume": "ui2", "VolumeDB": "i2", "Mute": "boolean", "A_ARG_TYPE_InstanceID": "ui4",
                     "CurrentTrack": "ui4", "NumberOfTracks": "ui4", "RelativeCounterPosition": "i4",
                     "AbsoluteCounterPosition": "i4", "A_ARG_TYPE_ConnectionID": "i4", "A_ARG_TYPE_RcsID": "i4",
                     "A_ARG_TYPE_AVTransportID": "i4"]
        return (state, types[state] ?? "string")
    }

    var description: String {
        var states: [String: String] = self == .connection ? [:] : ["LastChange": "string"]
        if self == .transport {
            states["CurrentTrackTitle"] = "string"
            states["DisplayCurrentSubtitle"] = "boolean"
        }
        let actionList = actions.keys.sorted().map { action in
            let arguments = actions[action]!
            let list = [(arguments.input, "in"), (arguments.output, "out")].flatMap { names, direction in
                names.map { name in
                    let (state, type) = variable(name, action: action)
                    states[state] = type
                    return "<argument><name>\(name)</name><direction>\(direction)</direction><relatedStateVariable>\(state)</relatedStateVariable></argument>"
                }
            }
            let argumentsXML = list.isEmpty ? "" : "<argumentList>\(list.joined())</argumentList>"
            return "<action><name>\(action)</name>\(argumentsXML)</action>"
        }.joined()
        let stateList = states.keys.sorted().map { name in
            let event = ["LastChange", "SourceProtocolInfo", "SinkProtocolInfo", "CurrentConnectionIDs"].contains(name)
            let allowed: [String: [String]] = [
                "A_ARG_TYPE_Channel": ["Master"], "A_ARG_TYPE_PresetName": ["FactoryDefaults"], "PresetNameList": ["FactoryDefaults"],
                "A_ARG_TYPE_SeekMode": ["ABS_TIME", "REL_TIME", "TRACK_NR"], "CurrentPlayMode": ["NORMAL"],
                "A_ARG_TYPE_Direction": ["Input", "Output"],
                "A_ARG_TYPE_ConnectionStatus": ["OK", "ContentFormatMismatch", "InsufficientBandwidth", "UnreliableChannel", "Unknown"],
                "TransportStatus": ["OK", "ERROR_OCCURRED"],
                "PlaybackStorageMedium": ["NONE", "NETWORK"], "PossiblePlaybackStorageMedia": ["NETWORK"],
                "TransportState": ["STOPPED", "PLAYING", "TRANSITIONING", "PAUSED_PLAYBACK", "NO_MEDIA_PRESENT"]
            ]
            let defaults = ["CurrentPlayMode": "NORMAL", "TransportStatus": "OK", "TransportPlaySpeed": "1"]
            var constraints = defaults[name].map { "<defaultValue>\($0)</defaultValue>" } ?? ""
            if let values = allowed[name] {
                constraints += "<allowedValueList>" + values.map { "<allowedValue>\($0)</allowedValue>" }.joined() + "</allowedValueList>"
            } else if name == "Volume" {
                constraints += "<allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange>"
            }
            return "<stateVariable sendEvents=\"\(event ? "yes" : "no")\"><name>\(name)</name><dataType>\(states[name]!)</dataType>\(constraints)</stateVariable>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
        <actionList>\(actionList)</actionList><serviceStateTable>\(stateList)</serviceStateTable></scpd>
        """
    }
}

private struct SOAPError: Error {
    let code: Int
    let message: String
    init(_ code: Int, _ message: String) { self.code = code; self.message = message }
}

/// 对外公布设备和服务，将 SOAP 动作转给同一个播放器实例。
final class DLNA {
    static let xmlType = "text/xml; charset=utf-8"
    static let soapNS = "http://schemas.xmlsoap.org/soap/envelope/"
    static let protocols = (
        ["video/mp4", "video/mpeg", "video/quicktime", "video/x-matroska", "video/webm",
         "application/vnd.apple.mpegurl", "application/x-mpegURL", "audio/mpeg", "audio/mp4", "audio/aac",
         "audio/flac", "audio/wav", "audio/ogg", "image/jpeg", "image/png", "image/gif", "*"]
            .map { "http-get:*:\($0):*" }
        + ["http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG", "http-get:*:audio/mpeg:DLNA.ORG_PN=MP3"]
    ).joined(separator: ",")

    let playback: Playback
    let settings: Settings
    private let events = GENA()
    private let logger = Logger(subsystem: "local.mycast.receiver", category: "DLNA")
    private(set) var lastAction: String?
    private var eventSnapshot: [DLNAService: String] = [:]
    private var serviceDocuments: [DLNAService: String] = [:]

    init(playback: Playback, settings: Settings) {
        self.playback = playback
        self.settings = settings
        for service in DLNAService.allCases { serviceDocuments[service] = service.description }
    }

    func reset() {
        events.reset()
        eventSnapshot.removeAll()
        lastAction = nil
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.target.split(separator: "?", maxSplits: 1)[0]
        let pieces = path.split(separator: "/")
        if request.method == "GET" || request.method == "HEAD" {
            if path == "/" { return HTTPResponse(body: "MyCast DLNA Media Renderer\n") }
            if path == "/description.xml" { return HTTPResponse(type: Self.xmlType, body: deviceDescription) }
            if pieces.count == 2, pieces[0] == "dlna", pieces[1].hasSuffix(".xml"),
               let service = DLNAService(rawValue: String(pieces[1].dropLast(4))),
               let document = serviceDocuments[service] {
                return HTTPResponse(type: Self.xmlType, body: document)
            }
        } else if pieces.count == 2, let service = DLNAService(rawValue: String(pieces[0])) {
            if request.method == "POST", pieces[1] == "action" { return soap(request, service: service) }
            if pieces[1] == "event" {
                return events.handle(request, service: service) { [weak self] in self?.eventBody(service) ?? "" }
            }
        }
        return HTTPResponse(status: 404)
    }

    func publishChanges() {
        for service in DLNAService.allCases {
            let body = eventBody(service)
            if eventSnapshot[service] != body {
                eventSnapshot[service] = body
                events.publish(body, service: service)
            }
        }
    }

    private var deviceDescription: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <device><deviceType>\(SSDP.device)</deviceType><friendlyName>\(settings.name.xml)</friendlyName>
          <manufacturer>MyCast</manufacturer><modelDescription>DLNA AVTransport Media Renderer</modelDescription>
          <modelName>MyCast</modelName><modelNumber>1.0</modelNumber><UDN>uuid:\(settings.uuid)</UDN>
          <dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>
          <serviceList>\(DLNAService.allCases.map(\.declaration).joined())</serviceList>
          <presentationURL>/</presentationURL></device>
        </root>
        """
    }

    private func soap(_ request: HTTPRequest, service: DLNAService) -> HTTPResponse {
        var actionName = service.rawValue
        do {
            guard let root = XMLTree.parse(request.body), root.name == "Envelope", root.namespace == Self.soapNS,
                  let body = root.child("Body"), body.namespace == Self.soapNS, body.children.count == 1,
                  let action = body.children.first, action.namespace == service.urn,
                  let definition = service.actions[action.name] else { throw SOAPError(401, "Invalid Action") }
            actionName = action.name
            if let header = request.headers["soapaction"],
               header.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) != "\(service.urn)#\(action.name)" {
                throw SOAPError(401, "Invalid Action")
            }
            var args: [String: String] = [:]
            for argument in action.children {
                guard argument.children.isEmpty, args[argument.name] == nil else { throw SOAPError(402, "Invalid Args") }
                args[argument.name] = argument.text
            }
            guard definition.input.allSatisfy({ args[$0] != nil || $0.hasSuffix("MetaData") }) else {
                throw SOAPError(402, "Invalid Args")
            }
            if let instance = args["InstanceID"], instance != "0" {
                throw SOAPError(service == .transport ? 718 : 702, "Invalid InstanceID")
            }
            if let channel = args["Channel"], channel != "Master" { throw SOAPError(402, "Invalid Channel") }
            let values = try execute(action.name, args: args)
            if ["SetAVTransportURI", "SetNextAVTransportURI", "Play", "Pause", "Stop", "Seek"].contains(action.name) {
                lastAction = "\(action.name) · 已接收"
                logger.notice("\(action.name, privacy: .public) accepted")
            }
            let output = definition.output.map { "<\($0)>\((values[$0] ?? "").xml)</\($0)>" }.joined()
            return envelope("<u:\(action.name)Response xmlns:u=\"\(service.urn)\">\(output)</u:\(action.name)Response>")
        } catch {
            let fault = error as? SOAPError ?? SOAPError(501, "Action Failed")
            lastAction = "\(actionName) · UPnP \(fault.code) \(fault.message)"
            logger.error("\(actionName, privacy: .public) rejected: UPnP \(fault.code) \(fault.message, privacy: .public)")
            return envelope("""
            <s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
            <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(fault.code)</errorCode>
            <errorDescription>\(fault.message.xml)</errorDescription></UPnPError></detail></s:Fault>
            """, status: 500)
        }
    }

    private func envelope(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, type: Self.xmlType, headers: ["EXT": ""], body: """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="\(Self.soapNS)" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>\(body)</s:Body></s:Envelope>
        """)
    }

    private func execute(_ action: String, args: [String: String]) throws -> [String: String] {
        let media = playback.media
        let unavailable = SOAPError(701, "Transition not available")
        let zero = "NOT_IMPLEMENTED"
        switch action {
        case "SetAVTransportURI", "SetNextAVTransportURI":
            let current = action == "SetAVTransportURI"
            let key = current ? "CurrentURI" : "NextURI"
            let uri = args[key] ?? ""
            let item = CastMedia(uri: uri, metadata: args[key + "MetaData"] ?? "")
            guard uri.isEmpty || item != nil else { throw SOAPError(714, "Illegal MIME-type or URI") }
            if current {
                playback.setMedia(item)
                if item != nil { playback.play() }
            } else {
                guard media != nil || item == nil else { throw unavailable }
                playback.next = item
                publishChanges()
            }
        case "Play":
            guard media != nil else { throw SOAPError(716, "Resource not found") }
            let raw = args["Speed"] ?? ""
            let terms = raw.split(separator: "/")
            let rate = terms.count == 2 ? (Double(terms[0]) ?? 0) / (Double(terms[1]) ?? 0) : Double(raw) ?? 0
            guard (0.25...4).contains(rate) else { throw SOAPError(717, "Play speed not supported") }
            playback.play(speed: rate)
        case "Pause":
            guard playback.state == .playing || playback.state == .loading || playback.state == .paused else { throw unavailable }
            playback.pause()
        case "Stop": playback.stop()
        case "Seek":
            guard media != nil else { throw unavailable }
            switch args["Unit"] {
            case "TRACK_NR":
                guard args["Target"] == "1" else { throw SOAPError(711, "Illegal seek target") }
                playback.seek(0)
            case "ABS_TIME", "REL_TIME":
                guard let target = args["Target"], let time = Self.parseTime(target) else {
                    throw SOAPError(711, "Illegal seek target")
                }
                playback.seek(time)
            default: throw SOAPError(710, "Seek mode not supported")
            }
        case "Next":
            guard playback.next != nil else { throw unavailable }
            playback.advance()
        case "Previous":
            guard media != nil else { throw unavailable }
            playback.seek(0)
        case "SetPlayMode":
            guard args["NewPlayMode"] == "NORMAL" else { throw SOAPError(712, "Play mode not supported") }
        case "GetTransportInfo":
            return ["CurrentTransportState": playback.state.rawValue, "CurrentTransportStatus": playback.status,
                    "CurrentSpeed": String(format: "%g", playback.speed)]
        case "GetPositionInfo":
            let position = Self.time(playback.position)
            return ["Track": media == nil ? "0" : "1", "TrackDuration": Self.time(playback.duration),
                    "TrackMetaData": media?.metadata ?? "", "TrackURI": media?.url.absoluteString ?? "",
                    "RelTime": position, "AbsTime": position, "RelCount": "2147483647", "AbsCount": "2147483647"]
        case "GetMediaInfo":
            return ["NrTracks": media == nil ? "0" : "1", "MediaDuration": Self.time(playback.duration),
                    "CurrentURI": media?.url.absoluteString ?? "", "CurrentURIMetaData": media?.metadata ?? "",
                    "NextURI": playback.next?.url.absoluteString ?? "", "NextURIMetaData": playback.next?.metadata ?? "",
                    "PlayMedium": media == nil ? "NONE" : "NETWORK", "RecordMedium": zero, "WriteStatus": zero]
        case "GetTransportSettings": return ["PlayMode": "NORMAL", "RecQualityMode": zero]
        case "GetDeviceCapabilities": return ["PlayMedia": "NETWORK", "RecMedia": zero, "RecQualityModes": zero]
        case "GetCurrentTransportActions": return ["Actions": availableActions]
        case "GetVolume": return ["CurrentVolume": String(playback.volume)]
        case "SetVolume":
            guard let value = Int(args["DesiredVolume"] ?? ""), (0...100).contains(value) else {
                throw SOAPError(601, "Argument Value Out of Range")
            }
            playback.setVolume(value)
        case "GetVolumeDB": return ["CurrentVolume": String((playback.volume - 100) * 15360 / 100)]
        case "SetVolumeDB":
            guard let value = Int(args["DesiredVolume"] ?? ""), (-15360...0).contains(value) else {
                throw SOAPError(601, "Argument Value Out of Range")
            }
            playback.setVolume(100 + value * 100 / 15360)
        case "GetVolumeDBRange": return ["MinValue": "-15360", "MaxValue": "0"]
        case "GetMute": return ["CurrentMute": playback.muted ? "1" : "0"]
        case "SetMute":
            switch args["DesiredMute"]?.lowercased() {
            case "1", "true", "yes": playback.setMute(true)
            case "0", "false", "no": playback.setMute(false)
            default: throw SOAPError(600, "Argument Value Invalid")
            }
        case "ListPresets": return ["CurrentPresetNameList": "FactoryDefaults"]
        case "SelectPreset":
            guard args["PresetName"] == "FactoryDefaults" else { throw SOAPError(701, "Invalid Preset Name") }
            playback.setVolume(100)
            playback.setMute(false)
        case "GetProtocolInfo": return ["Source": "", "Sink": Self.protocols]
        case "GetCurrentConnectionIDs": return ["ConnectionIDs": "0"]
        case "GetCurrentConnectionInfo":
            guard args["ConnectionID"] == "0" else { throw SOAPError(706, "Invalid Connection Reference") }
            return ["RcsID": "0", "AVTransportID": "0", "ProtocolInfo": "http-get:*:*:*", "PeerConnectionManager": "",
                    "PeerConnectionID": "-1", "Direction": "Input", "Status": "OK"]
        default: throw SOAPError(401, "Invalid Action")
        }
        return [:]
    }

    private var availableActions: String {
        var actions: [String]
        switch playback.state {
        case .empty: return ""
        case .stopped: actions = ["Play", "Seek", "Previous"]
        case .playing, .loading: actions = ["Pause", "Stop", "Seek", "Previous"]
        case .paused: actions = ["Play", "Stop", "Seek", "Previous"]
        }
        if playback.next != nil { actions.append("Next") }
        return actions.joined(separator: ",")
    }

    private func eventBody(_ service: DLNAService) -> String {
        let props: String
        switch service {
        case .connection:
            props = "<e:property><SourceProtocolInfo></SourceProtocolInfo></e:property>"
                + "<e:property><SinkProtocolInfo>\(Self.protocols.xml)</SinkProtocolInfo></e:property>"
                + "<e:property><CurrentConnectionIDs>0</CurrentConnectionIDs></e:property>"
        case .transport, .rendering:
            let inner: String
            if service == .transport {
                let media = playback.media
                let time = Self.time(playback.duration)
                inner = """
                <TransportState val="\(playback.state.rawValue)"/><TransportStatus val="\(playback.status)"/>
                <TransportPlaySpeed val="\(String(format: "%g", playback.speed))"/><CurrentTransportActions val="\(availableActions)"/>
                <CurrentTrack val="\(media == nil ? 0 : 1)"/><NumberOfTracks val="\(media == nil ? 0 : 1)"/>
                <CurrentTrackDuration val="\(time)"/><CurrentMediaDuration val="\(time)"/>
                <AVTransportURI val="\((media?.url.absoluteString ?? "").xml)"/>
                <AVTransportURIMetaData val="\((media?.metadata ?? "").xml)"/>
                <NextAVTransportURI val="\((playback.next?.url.absoluteString ?? "").xml)"/>
                """
            } else {
                inner = """
                <Volume channel="Master" val="\(playback.volume)"/><Mute channel="Master" val="\(playback.muted ? 1 : 0)"/>
                """
            }
            let namespace = service == .transport ? "AVT" : "RCS"
            let lastChange = "<Event xmlns=\"urn:schemas-upnp-org:metadata-1-0/\(namespace)/\"><InstanceID val=\"0\">\(inner)</InstanceID></Event>"
            props = "<e:property><LastChange>\(lastChange.xml)</LastChange></e:property>"
        }
        return "<e:propertyset xmlns:e=\"urn:schemas-upnp-org:event-1-0\">\(props)</e:propertyset>"
    }

    static func time(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(min(3_599_999, max(0, seconds))) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func parseTime(_ time: String) -> Double? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hours = Int(parts[0]), (0...999).contains(hours),
              let minutes = Int(parts[1]), (0..<60).contains(minutes),
              let seconds = Double(parts[2]), (0..<60).contains(seconds) else { return nil }
        return Double(hours * 3600 + minutes * 60) + seconds
    }
}
