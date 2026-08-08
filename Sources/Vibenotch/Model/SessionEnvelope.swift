struct SessionEnvelope: Codable, Sendable {
    let schema: Int
    let id: String
    let agent: String
    let pid: Int?
    let project: String?
    let cwd: String?
    let status: SessionStatus
    let detail: String?
    let task: String?
    let prompt: String?
    let toolLine: String?
    let model: String?
    let updated: String
    let started: String?
    let seq: Int
    let terminal: TerminalIdentity?
    let source: String?

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case agent
        case pid
        case project
        case cwd
        case status
        case detail
        case task
        case prompt
        case toolLine
        case model
        case updated
        case started
        case seq
        case terminal
        case source
    }

    init(
        schema: Int,
        id: String,
        agent: String,
        pid: Int? = nil,
        project: String? = nil,
        cwd: String? = nil,
        status: SessionStatus,
        detail: String? = nil,
        task: String? = nil,
        prompt: String? = nil,
        toolLine: String? = nil,
        model: String? = nil,
        updated: String,
        started: String? = nil,
        seq: Int,
        terminal: TerminalIdentity? = nil,
        source: String? = nil
    ) {
        self.schema = schema
        self.id = id
        self.agent = agent
        self.pid = pid
        self.project = project
        self.cwd = cwd
        self.status = status
        self.detail = detail
        self.task = task
        self.prompt = prompt
        self.toolLine = toolLine
        self.model = model
        self.updated = updated
        self.started = started
        self.seq = seq
        self.terminal = terminal
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        id = try container.decode(String.self, forKey: .id)
        agent = try container.decode(String.self, forKey: .agent)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        status = try container.decode(SessionStatus.self, forKey: .status)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        toolLine = try container.decodeIfPresent(String.self, forKey: .toolLine)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        updated = try container.decode(String.self, forKey: .updated)
        started = try container.decodeIfPresent(String.self, forKey: .started)
        seq = try container.decode(Int.self, forKey: .seq)
        terminal = try container.decodeIfPresent(TerminalIdentity.self, forKey: .terminal)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}
