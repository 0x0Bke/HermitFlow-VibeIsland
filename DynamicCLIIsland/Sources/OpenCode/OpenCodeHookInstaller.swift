//
//  OpenCodeHookInstaller.swift
//  HermitFlow
//
//  Installs HermitFlow's managed OpenCode plugin.
//

import Foundation

struct OpenCodeHookInstaller: HookInstaller {
    private let pluginDirectory: URL
    private let pluginURL: URL
    private let configURL: URL
    private let packageURL: URL
    private let bridge: OpenCodeHookBridge
    private let fileManager: FileManager
    private let marker = "HERMITFLOW_MANAGED_OPENCODE_PLUGIN"

    init(
        pluginDirectory: URL = FilePaths.openCodePluginsDirectory,
        configURL: URL = FilePaths.openCodeConfigFile,
        bridge: OpenCodeHookBridge = .shared,
        fileManager: FileManager = .default
    ) {
        self.pluginDirectory = pluginDirectory
        self.pluginURL = pluginDirectory.appendingPathComponent("hermitflow.js", isDirectory: false)
        self.configURL = configURL
        self.packageURL = configURL.deletingLastPathComponent().appendingPathComponent("package.json", isDirectory: false)
        self.bridge = bridge
        self.fileManager = fileManager
    }

    func install() throws {
        try fileManager.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try managedPluginSource().write(to: pluginURL, atomically: true, encoding: .utf8)
        try upsertPluginPackageDependencies()
        try upsertPluginConfig()
    }

    func uninstall() throws {
        guard fileManager.fileExists(atPath: pluginURL.path) else {
            return
        }

        let existing = try String(contentsOf: pluginURL, encoding: .utf8)
        guard existing.contains(marker) else {
            return
        }

        try fileManager.removeItem(at: pluginURL)
    }

    func resync() throws {
        try install()
    }

    func healthReport() -> SourceHealthReport {
        var issues = bridge.healthIssues()

        if !fileManager.fileExists(atPath: pluginURL.path) {
            issues.append(
                SourceErrorMapper.issue(
                    source: "OpenCode",
                    severity: .warning,
                    message: "The managed OpenCode plugin is missing.",
                    recoverySuggestion: "Restart HermitFlow or resync integrations to recreate the plugin.",
                    isRepairable: true
                )
            )
        } else if let existing = try? String(contentsOf: pluginURL, encoding: .utf8),
                  !existing.contains(marker) {
            issues.append(
                SourceErrorMapper.issue(
                    source: "OpenCode",
                    severity: .warning,
                    message: "The OpenCode HermitFlow plugin file is not managed by this app.",
                    recoverySuggestion: "Move the custom file aside and restart HermitFlow to install the managed plugin.",
                    isRepairable: true
                )
            )
        }

        return SourceHealthReport(sourceName: "OpenCode", issues: issues)
    }

    private func upsertPluginConfig() throws {
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var object: [String: Any] = [:]
        if fileManager.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            if !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(
                        domain: "HermitFlow.OpenCodeHookInstaller",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "OpenCode config is not a JSON object."]
                    )
                }
                object = parsed
            }
        }

        let pluginPath = pluginURL.path
        var plugins = object["plugin"] as? [Any] ?? []
        let alreadyConfigured = plugins.contains { item in
            if let string = item as? String {
                return string == pluginPath
                    || string == pluginURL.path(percentEncoded: false)
                    || string.hasSuffix("/plugins/hermitflow.js")
            }
            if let pair = item as? [Any], let string = pair.first as? String {
                return string == pluginPath
                    || string == pluginURL.path(percentEncoded: false)
                    || string.hasSuffix("/plugins/hermitflow.js")
            }
            return false
        }

        if !alreadyConfigured {
            plugins.append(pluginPath)
            object["plugin"] = plugins
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: [.atomic])
        }
    }

    private func upsertPluginPackageDependencies() throws {
        try fileManager.createDirectory(at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var object: [String: Any] = [:]
        if fileManager.fileExists(atPath: packageURL.path) {
            let data = try Data(contentsOf: packageURL)
            if !data.isEmpty,
               let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = parsed
            }
        }

        var dependencies = object["dependencies"] as? [String: Any] ?? [:]
        if dependencies["@opencode-ai/plugin"] == nil {
            dependencies["@opencode-ai/plugin"] = "^1.14.0"
        }
        object["dependencies"] = dependencies
        if object["private"] == nil {
            object["private"] = true
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: packageURL, options: [.atomic])
    }

    private func managedPluginSource() -> String {
        """
        // \(marker)
        // This file is managed by HermitFlow. Local custom OpenCode plugins should use a different filename.
        import { tool } from "@opencode-ai/plugin";

        const CALLBACK_URL = process.env.HERMITFLOW_OPENCODE_CALLBACK_URL || "http://127.0.0.1:\(bridge.listenerPort)/opencode/event";
        const DECISION_URL = CALLBACK_URL.replace(/\\/opencode\\/event$/, "/opencode/approval-decision");
        const QUESTION_DECISION_URL = CALLBACK_URL.replace(/\\/opencode\\/event$/, "/opencode/question-decision");
        const alwaysAllowedPermissions = new Set();

        const EVENT_TYPES = new Set([
          "server.connected",
          "session.created",
          "session.updated",
          "session.status",
          "session.idle",
          "session.error",
          "message.updated",
          "message.part.updated",
          "tool.execute.before",
          "tool.execute.after",
          "permission.asked",
          "permission.replied",
          "question.asked",
          "question.replied",
          "question.dismissed",
          "hermitflow.debug",
        ]);

        function safe(value) {
          try {
            return JSON.parse(JSON.stringify(value));
          } catch {
            return String(value);
          }
        }

        async function send(type, input, output, context) {
          if (!type || !EVENT_TYPES.has(type)) return;
          const event = input?.event ?? input;
          const properties = event?.properties ?? {};
          const host = properties.hostname ?? properties.host ?? context?.hostname ?? context?.host;
          const port = properties.port ?? context?.port;
          const serverURL = context?.server?.url
            ?? context?.serverURL
            ?? context?.serverUrl
            ?? properties.url
            ?? properties.serverURL
            ?? properties.serverUrl
            ?? (host && port ? `http://${host}:${port}` : undefined);
          const payload = {
            source: "opencode",
            plugin: "hermitflow",
            version: 1,
            type,
            input: safe(input),
            output: safe(output),
            context: safe(context),
            event: safe(event),
            sessionID: event?.sessionID ?? event?.sessionId ?? event?.session_id ?? properties.sessionID ?? properties.sessionId ?? properties.session_id ?? input?.sessionID ?? input?.sessionId ?? input?.session_id,
            permissionID: event?.permissionID ?? event?.permissionId ?? event?.permission_id ?? properties.id ?? properties.permissionID ?? properties.permissionId ?? properties.permission_id ?? input?.permissionID ?? input?.permissionId ?? input?.permission_id,
            serverURL,
            at: new Date().toISOString(),
          };

          try {
            await fetch(CALLBACK_URL, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify(payload),
            });
          } catch {
            // HermitFlow may not be running. OpenCode should continue normally.
          }
        }

        async function debug(stage, input, context, message) {
          await send(
            "hermitflow.debug",
            {
              stage,
              message,
              permissionID: requestIDFrom(input),
              requestID: requestIDFrom(input),
              sessionID: sessionIDFrom(input),
            },
            null,
            context
          );
        }

        function sleep(ms) {
          return new Promise((resolve) => setTimeout(resolve, ms));
        }

        function eventFrom(input) {
          return input?.event ?? input;
        }

        function propertiesFrom(input) {
          return eventFrom(input)?.properties ?? {};
        }

        function requestIDFrom(input) {
          const event = eventFrom(input);
          const properties = propertiesFrom(input);
          return properties.id
            ?? properties.requestID
            ?? properties.requestId
            ?? properties.permissionID
            ?? properties.permissionId
            ?? properties.permission_id
            ?? event?.id
            ?? event?.requestID
            ?? event?.requestId
            ?? event?.permissionID
            ?? event?.permissionId
            ?? event?.permission_id
            ?? input?.id
            ?? input?.requestID
            ?? input?.requestId
            ?? input?.permissionID
            ?? input?.permissionId
            ?? input?.permission_id;
        }

        function sessionIDFrom(input) {
          const event = eventFrom(input);
          const properties = propertiesFrom(input);
          return properties.sessionID
            ?? properties.sessionId
            ?? properties.session_id
            ?? event?.sessionID
            ?? event?.sessionId
            ?? event?.session_id
            ?? input?.sessionID
            ?? input?.sessionId
            ?? input?.session_id;
        }

        function permissionPatterns(input) {
          const pattern = input?.pattern ?? input?.patterns;
          if (Array.isArray(pattern)) return pattern;
          return pattern ? [String(pattern)] : [];
        }

        function permissionKey(input) {
          const permission = input?.type ?? input?.permission ?? input?.title ?? "permission";
          return `${permission}:${JSON.stringify(permissionPatterns(input))}`;
        }

        function permissionAskEvent(input) {
          return {
            type: "permission.asked",
            properties: {
              id: input?.id,
              requestID: input?.id,
              permissionID: input?.id,
              sessionID: input?.sessionID,
              permission: input?.type ?? input?.permission ?? input?.title,
              title: input?.title,
              patterns: permissionPatterns(input),
              metadata: input?.metadata ?? {},
              tool: {
                messageID: input?.messageID,
                callID: input?.callID,
              },
            },
          };
        }

        function permissionReplyEvent(input, decision) {
          return {
            type: "permission.replied",
            properties: {
              sessionID: sessionIDFrom(input),
              requestID: requestIDFrom(input),
              permissionID: requestIDFrom(input),
              reply: decision,
              response: decision,
            },
          };
        }

        function statusFromDecision(decision) {
          return decision === "reject" ? "deny" : "allow";
        }

        function serverBaseURL(context) {
          return context?.serverUrl
            ?? context?.serverURL
            ?? context?.server?.url
            ?? undefined;
        }

        async function requestSucceeded(request) {
          const result = await request;
          if (result?.error) return false;
          if (result?.response?.status && result.response.status >= 400) return false;
          return true;
        }

        async function replyWithFetch(baseURL, requestID, sessionID, decision, message) {
          if (!baseURL || !requestID) return false;

          try {
            const response = await fetch(new URL(`/permission/${encodeURIComponent(requestID)}/reply`, baseURL), {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify(message ? { reply: decision, message } : { reply: decision }),
            });
            if (response.ok) return true;
          } catch {}

          if (!sessionID) return false;

          try {
            const response = await fetch(
              new URL(`/session/${encodeURIComponent(sessionID)}/permissions/${encodeURIComponent(requestID)}`, baseURL),
              {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ response: decision }),
              }
            );
            return response.ok;
          } catch {
            return false;
          }
        }

        async function replyToOpenCode(input, context, decisionBody) {
          const requestID = requestIDFrom(input);
          const sessionID = sessionIDFrom(input);
          const decision = decisionBody?.decision;
          const message = decisionBody?.message;
          if (!requestID || !decision) return false;

          try {
            if (context?.client?.permission?.reply) {
              if (await requestSucceeded(context.client.permission.reply({
                requestID,
                reply: decision,
                ...(message ? { message } : {}),
              }))) {
                await debug("api.reply.v2.ok", input, context);
                return true;
              }
            }
          } catch {}

          try {
            if (context?.client?.postSessionIdPermissionsPermissionId && sessionID) {
              if (await requestSucceeded(context.client.postSessionIdPermissionsPermissionId({
                path: { id: sessionID, permissionID: requestID },
                body: { response: decision },
              }))) {
                await debug("api.reply.legacy.ok", input, context);
                return true;
              }
            }
          } catch {}

          const fetched = await replyWithFetch(serverBaseURL(context), requestID, sessionID, decision, message);
          await debug(fetched ? "api.reply.fetch.ok" : "api.reply.failed", input, context);
          return fetched;
        }

        async function handlePermissionAskedFallback(input, output, context) {
          const requestID = requestIDFrom(input);
          if (!requestID) {
            await debug("permission.asked.no-request-id", input, context);
            return;
          }

          await debug("permission.asked.wait", input, context);
          const decision = await waitForHermitFlowDecision(requestID, sessionIDFrom(input));
          if (!decision?.decision) {
            await debug("permission.asked.no-decision", input, context);
            return;
          }

          await debug(`permission.asked.decision.${decision.decision}`, input, context);
          await replyToOpenCode(input, context, decision);
        }

        async function waitForHermitFlowDecision(requestID, sessionID) {
          if (!requestID) return undefined;

          const deadline = Date.now() + 120_000;
          while (Date.now() < deadline) {
            try {
              const url = new URL(DECISION_URL);
              url.searchParams.set("requestID", requestID);
              url.searchParams.set("permissionID", requestID);
              if (sessionID) url.searchParams.set("sessionID", sessionID);

              const response = await fetch(url.toString(), {
                method: "GET",
                headers: { accept: "application/json" },
              });
              if (response.ok) {
                const body = await response.json();
                if (body?.decision) return body;
              }
            } catch {
              return undefined;
            }

            await sleep(500);
          }

          return undefined;
        }

        function questionIDFor(args, context) {
          return `opencode-question:${context?.sessionID ?? "opencode-live"}:${context?.messageID ?? Date.now()}:${Math.random().toString(36).slice(2)}`;
        }

        function normalizeQuestions(args) {
          const questions = Array.isArray(args?.questions) ? args.questions : [];
          return questions.map((question) => ({
            header: question?.header,
            question: question?.question ?? "",
            multiple: question?.multiple ?? question?.multiSelect ?? false,
            options: Array.isArray(question?.options) ? question.options.map((option) => ({
              label: typeof option === "string" ? option : option?.label ?? option?.title ?? option?.value ?? "",
              description: typeof option === "string" ? undefined : option?.description ?? option?.detail,
              value: typeof option === "string" ? option : option?.value ?? option?.label ?? option?.title,
            })) : [],
          }));
        }

        function questionAskEvent(args, context, questionID) {
          const questions = normalizeQuestions(args);
          return {
            type: "question.asked",
            questionID,
            requestID: questionID,
            sessionID: context?.sessionID,
            messageID: context?.messageID,
            properties: {
              questionID,
              requestID: questionID,
              sessionID: context?.sessionID,
              messageID: context?.messageID,
              title: questions[0]?.header,
              question: questions[0]?.question,
              questions,
            },
          };
        }

        function questionReplyEvent(args, context, questionID, decision) {
          return {
            type: decision?.status === "dismissed" ? "question.dismissed" : "question.replied",
            questionID,
            requestID: questionID,
            sessionID: context?.sessionID,
            messageID: context?.messageID,
            properties: {
              questionID,
              requestID: questionID,
              sessionID: context?.sessionID,
              messageID: context?.messageID,
              status: decision?.status,
              answers: decision?.answers,
            },
          };
        }

        async function waitForHermitFlowQuestionDecision(questionID, sessionID) {
          if (!questionID) return undefined;

          const deadline = Date.now() + 120_000;
          while (Date.now() < deadline) {
            try {
              const url = new URL(QUESTION_DECISION_URL);
              url.searchParams.set("questionID", questionID);
              url.searchParams.set("requestID", questionID);
              if (sessionID) url.searchParams.set("sessionID", sessionID);

              const response = await fetch(url.toString(), {
                method: "GET",
                headers: { accept: "application/json" },
              });
              if (response.ok) {
                const body = await response.json();
                if (body?.status) return body;
              }
            } catch {
              return undefined;
            }

            await sleep(500);
          }

          return undefined;
        }

        function fallbackQuestionOutput(args, decision) {
          const questions = normalizeQuestions(args);
          const answer = decision?.answers?.[0]?.[0] ?? "";
          const question = questions[0]?.question ?? questions[0]?.header ?? "question";
          return `User has answered your questions: "${question}"="${answer}". You can now continue with the user's answers in mind.`;
        }

        async function executeHermitFlowQuestion(args, context) {
          const questionID = questionIDFor(args, context);
          await send("question.asked", questionAskEvent(args, context, questionID), null, context);
          const decision = await waitForHermitFlowQuestionDecision(questionID, context?.sessionID);
          if (!decision || decision.status === "dismissed") {
            await send("question.dismissed", questionReplyEvent(args, context, questionID, decision), null, context);
            throw new Error("The user dismissed this question");
          }

          await send("question.replied", questionReplyEvent(args, context, questionID, decision), null, context);
          return decision.output ?? fallbackQuestionOutput(args, decision);
        }

        async function handlePermissionAsk(input, output, context) {
          output = output ?? {};
          const requestID = requestIDFrom(input);
          if (!requestID) {
            await debug("permission.ask.no-request-id", input, context);
            return output;
          }

          await debug("permission.ask.enter", input, context, `status=${output?.status ?? "unknown"}`);

          const key = permissionKey(input);
          if (alwaysAllowedPermissions.has(key)) {
            output.status = "allow";
            await debug("permission.ask.always-allow", input, context);
            return output;
          }

          await send("permission.asked", permissionAskEvent(input), output, context);
          const decision = await waitForHermitFlowDecision(requestID, sessionIDFrom(input));
          if (!decision?.decision) {
            await debug("permission.ask.no-decision", input, context);
            return output;
          }

          await debug(`permission.ask.decision.${decision.decision}`, input, context);

          if (decision.decision === "always") {
            alwaysAllowedPermissions.add(key);
          }
          output.status = statusFromDecision(decision.decision);
          replyToOpenCode(input, context, decision).catch(() => {});
          await send("permission.replied", permissionReplyEvent(input, decision.decision), output, context);
          await debug("permission.ask.output", input, context, `status=${output.status}`);
          return output;
        }

        export const HermitFlowPlugin = async (context) => {
          return {
            tool: {
              question: tool({
                description: "Ask the user one or more structured questions and wait for their answer.",
                args: {
                  questions: tool.schema.array(tool.schema.object({
                    header: tool.schema.string().optional(),
                    question: tool.schema.string(),
                    multiple: tool.schema.boolean().optional(),
                    multiSelect: tool.schema.boolean().optional(),
                    options: tool.schema.array(tool.schema.object({
                      label: tool.schema.string(),
                      description: tool.schema.string().optional(),
                      value: tool.schema.string().optional(),
                    })).optional(),
                  })),
                },
                execute: executeHermitFlowQuestion,
              }),
            },
            event: async (input) => {
              const event = input?.event ?? input;
              await send(event?.type, event, null, context);
              if (event?.type === "permission.asked") {
                handlePermissionAskedFallback(event, null, context).catch(() => {});
              }
            },
            "tool.execute.before": async (input, output) => {
              await send("tool.execute.before", input, output, context);
            },
            "tool.execute.after": async (input, output) => {
              await send("tool.execute.after", input, output, context);
            },
            "permission.asked": async (input, output) => {
              await send("permission.asked", input, output, context);
              handlePermissionAskedFallback(input, output, context).catch(() => {});
            },
            "permission.replied": async (input, output) => {
              await send("permission.replied", input, output, context);
            },
            "permission.ask": async (input, output) => {
              await handlePermissionAsk(input, output, context);
            },
          };
        };

        export const server = HermitFlowPlugin;
        export default HermitFlowPlugin;
        """
    }
}
