import Foundation

/// Messages Parley writes to Claude Code's stdin (`--input-format stream-json`).
public enum Outgoing {
    /// A user turn.
    public static func user(_ text: String) -> JSON {
        ["type": "user", "message": ["role": "user", "content": .string(text)]]
    }

    /// Asks Claude Code to start its control protocol. Its response lists the slash commands.
    public static func initialize(requestId: String) -> JSON {
        controlRequest(requestId: requestId, ["subtype": "initialize"])
    }

    /// Stops the turn in progress, as Escape does in the terminal.
    public static func interrupt(requestId: String) -> JSON {
        controlRequest(requestId: requestId, ["subtype": "interrupt"])
    }

    /// Changes the permission mode for the rest of the session.
    public static func setPermissionMode(requestId: String, mode: String) -> JSON {
        controlRequest(requestId: requestId, ["subtype": "set_permission_mode", "mode": .string(mode)])
    }

    /// Answers a `can_use_tool` request: run the tool with this input. `rules` are permission
    /// updates to keep, taken from the request's own suggestions, for "always allow".
    public static func allow(requestId: String, input: JSON, rules: [JSON] = []) -> JSON {
        var response: [String: JSON] = ["behavior": "allow", "updatedInput": input]
        if !rules.isEmpty {
            response["updatedPermissions"] = .array(rules)
        }
        return controlResponse(requestId: requestId, .object(response))
    }

    /// Answers a `can_use_tool` request: don't run the tool. Claude reads `message`.
    /// Text every refusal from Parley carries, so a replayed transcript can tell a refusal
    /// from a tool that failed.
    public static let refusalMarker = "declined in Parley"

    public static func deny(requestId: String, message: String) -> JSON {
        controlResponse(requestId: requestId, ["behavior": "deny", "message": .string(message)])
    }

    /// Answers a control request Parley doesn't handle, so Claude Code isn't left waiting.
    public static func controlError(requestId: String, message: String) -> JSON {
        [
            "type": "control_response",
            "response": [
                "subtype": "error",
                "request_id": .string(requestId),
                "error": .string(message),
            ],
        ]
    }

    private static func controlRequest(requestId: String, _ request: JSON) -> JSON {
        ["type": "control_request", "request_id": .string(requestId), "request": request]
    }

    private static func controlResponse(requestId: String, _ response: JSON) -> JSON {
        [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": .string(requestId),
                "response": response,
            ],
        ]
    }
}
