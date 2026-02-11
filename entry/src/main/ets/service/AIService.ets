import { http } from '@kit.NetworkKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { media } from '@kit.MediaKit';
import { geoLocationManager } from '@kit.LocationKit';
import { ChatMessage, ApiMessage, ToolSchema, SettingsData } from '../model/Models';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';
import { I18n } from '../common/I18n';

/**
 * AI interaction service.
 * Supports Anthropic, OpenAI, and local Ollama backends.
 * Handles the full tool-use loop: send -> receive -> execute tools -> re-send.
 */

// --------- helper interfaces for ArkTS typed object literals ---------
interface RoleContent {
  role: string;
  content: string;
}

interface AnthropicToolUseBlock {
  type: string;
  id: string;
  name: string;
  input: Object;
}

interface AnthropicToolResultBlock {
  type: string;
  tool_use_id: string;
  content: string;
}

interface OpenAIToolDef {
  type: string;
  function: OpenAIFuncDef;
}

interface OpenAIFuncDef {
  name: string;
  description: string;
  parameters: object;
}

interface AnthropicToolSchemaDef {
  name: string;
  description: string;
  input_schema: object;
}

interface ToolResultObj {
  note?: string;
  stdout?: string;
  exitCode?: number;
  path?: string;
  query?: string;
  url?: string;
  devices?: DeviceObj[];
  result?: string;
  device?: string;
  events?: Object[];
  created?: boolean;
  title?: string;
  set?: boolean;
  message?: string;
  saved?: boolean;
  type?: string;
  content?: string;
  error?: string;
  command?: string;
  lat?: number;
  lon?: number;
  accuracyMeters?: number;
  timestamp?: string;
  isPrecise?: boolean;
  altitudeMeters?: number;
  speedMps?: number;
}

interface DeviceObj {
  id: string;
  name: string;
  status: string;
}

// --------- result type ---------
export class AIResult {
  messages: ChatMessage[] = [];
  error: string = '';
}

export class AIService {
  private static instance: AIService | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'AIService';

  static getInstance(): AIService {
    if (!AIService.instance) {
      AIService.instance = new AIService();
    }
    return AIService.instance;
  }

  /**
   * Main entry: send the conversation history and get back new messages
   * (including any tool call / result pairs).
   */
  async chat(
    history: ChatMessage[],
    settings: SettingsData,
    systemPrompt: string,
    tools: ToolSchema[],
    context?: common.UIAbilityContext
  ): Promise<AIResult> {
    let result = new AIResult();
    if (!settings.apiKey && settings.provider !== 'local') {
      result.error = 'Please set your API Key in Settings.';
      return result;
    }

    let allMessages = this.buildApiMessages(history);
    let loopCount = 0;

    while (loopCount < Constants.MAX_TOOL_LOOPS) {
      loopCount++;
      let response: RawResponse;
      try {
        if (settings.provider === 'anthropic') {
          response = await this.callAnthropic(allMessages, settings, systemPrompt, tools);
        } else if (settings.provider === 'openai' || settings.provider === 'openrouter') {
          response = await this.callOpenAI(allMessages, settings, systemPrompt, tools);
        } else {
          response = await this.callLocal(allMessages, settings, systemPrompt);
        }
      } catch (e) {
        let errMsg = (e as Error).message ?? String(e);
        // Friendly message for rate limit errors
        if (errMsg.includes('429')) {
          result.error = I18n.t('chat.rateLimited');
        } else {
          result.error = `API error: ${errMsg}`;
        }
        return result;
      }

      // Add assistant text if present
      if (response.text.length > 0) {
        let msg = new ChatMessage('assistant', response.text);
        result.messages.push(msg);
      }

      // No tool calls -> done
      if (response.toolCalls.length === 0) {
        break;
      }

      // Execute all tool calls and collect results
      let toolOutputs: string[] = [];
      for (let tc of response.toolCalls) {
        // Show the tool call in chat
        let callMsg = new ChatMessage('assistant', '');
        callMsg.isToolCall = true;
        callMsg.toolName = tc.name;
        callMsg.toolInput = tc.input;
        result.messages.push(callMsg);

        // Execute with error protection
        let output: string = '';
        try {
          output = await this.executeTool(tc.name, tc.input, context);
        } catch (toolErr) {
          output = JSON.stringify({ error: `Tool execution failed: ${(toolErr as Error).message ?? String(toolErr)}` });
        }
        toolOutputs.push(output);

        // Show the result in chat
        let resultMsg = new ChatMessage('tool', output);
        resultMsg.toolName = tc.name;
        resultMsg.toolOutput = output;
        // Extract media paths from tool results
        if (tc.name === 'capture_photo') {
          try {
            let parsed = JSON.parse(output) as Record<string, string>;
            if (parsed['path'] && parsed['path'].length > 0) {
              resultMsg.imagePath = parsed['path'];
            }
          } catch { /* ignore */ }
        }
        if (tc.name === 'record_audio') {
          try {
            let parsed = JSON.parse(output) as Record<string, string>;
            if (parsed['path'] && parsed['path'].length > 0) {
              resultMsg.audioPath = parsed['path'];
            }
          } catch { /* ignore */ }
        }
        result.messages.push(resultMsg);
      }

      // Append to API messages for next loop iteration
      if (settings.provider === 'anthropic') {
        for (let i = 0; i < response.toolCalls.length; i++) {
          let tc = response.toolCalls[i];
          let toolUseBlock: AnthropicToolUseBlock = {
            type: 'tool_use',
            id: tc.id,
            name: tc.name,
            input: JSON.parse(tc.input.length > 0 ? tc.input : '{}')
          };
          let assistantApiMsg: ApiMessage = {
            role: 'assistant',
            content: JSON.stringify([toolUseBlock])
          };
          allMessages.push(assistantApiMsg);

          let toolResultBlock: AnthropicToolResultBlock = {
            type: 'tool_result',
            tool_use_id: tc.id,
            content: toolOutputs[i]
          };
          let userApiMsg: ApiMessage = {
            role: 'user',
            content: JSON.stringify([toolResultBlock])
          };
          allMessages.push(userApiMsg);
        }
      } else {
        // OpenAI/OpenRouter: proper tool_calls format
        let tcJsonParts: string[] = [];
        for (let tc of response.toolCalls) {
          tcJsonParts.push(`{"id":${JSON.stringify(tc.id)},"type":"function","function":{"name":${JSON.stringify(tc.name)},"arguments":${JSON.stringify(tc.input)}}}`);
        }
        let assistantApiMsg: ApiMessage = {
          role: 'assistant',
          content: response.text,
          toolCalls: `[${tcJsonParts.join(',')}]`
        };
        allMessages.push(assistantApiMsg);

        for (let i = 0; i < response.toolCalls.length; i++) {
          let toolApiMsg: ApiMessage = {
            role: 'tool',
            content: toolOutputs[i],
            toolCallId: response.toolCalls[i].id
          };
          allMessages.push(toolApiMsg);
        }
      }
    }
    return result;
  }

  // --------- Anthropic ---------
  private async callAnthropic(
    messages: ApiMessage[], settings: SettingsData,
    systemPrompt: string, tools: ToolSchema[]
  ): Promise<RawResponse> {
    let msgArr: RoleContent[] = messages.map((m): RoleContent => {
      let rc: RoleContent = { role: m.role, content: m.content };
      return rc;
    });

    // Build body as JSON string directly to avoid untyped object literal issues
    let bodyParts: string = `"model":${JSON.stringify(settings.model)},"max_tokens":${Constants.MAX_TOKENS},"temperature":${settings.temperature},"system":${JSON.stringify(systemPrompt)},"messages":${JSON.stringify(msgArr)}`;

    if (tools.length > 0) {
      let toolDefs: AnthropicToolSchemaDef[] = tools.map((t): AnthropicToolSchemaDef => {
        let def: AnthropicToolSchemaDef = {
          name: t.name,
          description: t.description,
          input_schema: t.input_schema
        };
        return def;
      });
      bodyParts += `,"tools":${JSON.stringify(toolDefs)}`;
    }

    let bodyStr = `{${bodyParts}}`;
    let targetUrl = settings.baseUrl || Constants.ANTHROPIC_URL;
    let maskedKey = settings.apiKey.length > 8
      ? settings.apiKey.substring(0, 8) + '...' + settings.apiKey.substring(settings.apiKey.length - 4)
      : '(too short)';
    this.log.info(this.TAG, `callAnthropic: url=${targetUrl} model=${settings.model} key=${maskedKey} keyLen=${settings.apiKey.length}`);
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'x-api-key': settings.apiKey,
      'anthropic-version': '2023-06-01'
    };

    let resp = await this.httpPost(
      targetUrl,
      bodyStr,
      headers
    );

    let data = JSON.parse(resp) as AnthropicResp;
    let raw = new RawResponse();
    for (let block of data.content) {
      if (block.type === 'text') {
        raw.text += block.text ?? '';
      } else if (block.type === 'tool_use') {
        let tc = new RawToolCall();
        tc.id = block.id ?? '';
        tc.name = block.name ?? '';
        tc.input = JSON.stringify(block.input ?? {});
        raw.toolCalls.push(tc);
      }
    }
    return raw;
  }

  // --------- OpenAI ---------
  private async callOpenAI(
    messages: ApiMessage[], settings: SettingsData,
    systemPrompt: string, tools: ToolSchema[]
  ): Promise<RawResponse> {
    // Build messages JSON with proper tool_calls / role:tool support
    let msgJsonParts: string[] = [];
    msgJsonParts.push(`{"role":"system","content":${JSON.stringify(systemPrompt)}}`);
    for (let m of messages) {
      if (m.toolCalls !== undefined && m.toolCalls.length > 0) {
        // Assistant message with tool_calls — content must always be present (null if empty)
        let contentPart = m.content.length > 0 ? JSON.stringify(m.content) : 'null';
        msgJsonParts.push(`{"role":"assistant","content":${contentPart},"tool_calls":${m.toolCalls}}`);
      } else if (m.toolCallId !== undefined && m.toolCallId.length > 0) {
        // Tool result message
        msgJsonParts.push(`{"role":"tool","tool_call_id":${JSON.stringify(m.toolCallId)},"content":${JSON.stringify(m.content)}}`);
      } else {
        msgJsonParts.push(`{"role":${JSON.stringify(m.role)},"content":${JSON.stringify(m.content)}}`);
      }
    }
    let messagesJson = `[${msgJsonParts.join(',')}]`;

    let bodyParts: string = `"model":${JSON.stringify(settings.model)},"max_tokens":${Constants.MAX_TOKENS},"temperature":${settings.temperature},"messages":${messagesJson}`;

    if (tools.length > 0) {
      let toolDefs: OpenAIToolDef[] = tools.map((t): OpenAIToolDef => {
        let funcDef: OpenAIFuncDef = { name: t.name, description: t.description, parameters: t.input_schema };
        let def: OpenAIToolDef = { type: 'function', function: funcDef };
        return def;
      });
      bodyParts += `,"tools":${JSON.stringify(toolDefs)}`;
    }

    let bodyStr = `{${bodyParts}}`;
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${settings.apiKey}`
    };

    let defaultUrl = settings.provider === 'openrouter' ? Constants.OPENROUTER_URL : Constants.OPENAI_URL;
    // Use baseUrl only if it matches the provider; prevents stale cross-provider URLs
    let url = defaultUrl;
    if (settings.baseUrl.length > 0) {
      if (settings.provider === 'openrouter' && !settings.baseUrl.includes('openrouter')) {
        this.log.warn(this.TAG, `Ignoring non-OpenRouter baseUrl: ${settings.baseUrl}`);
      } else {
        url = settings.baseUrl;
      }
    }
    let maskedKey = settings.apiKey.length > 8
      ? settings.apiKey.substring(0, 4) + '...' + settings.apiKey.substring(settings.apiKey.length - 4)
      : '(short)';
    this.log.info(this.TAG, `callOpenAI: provider=${settings.provider} url=${url} model=${settings.model} key=${maskedKey} baseUrl="${settings.baseUrl}"`);
    let resp = await this.httpPost(
      url,
      bodyStr,
      headers
    );

    let raw = new RawResponse();

    // Check for API error response
    if (resp.includes('"error"')) {
      let errCheck = JSON.parse(resp) as Record<string, Object>;
      if (errCheck['error']) {
        throw new Error(`HTTP 400: ${resp.substring(0, 500)}`);
      }
    }

    let data = JSON.parse(resp) as OpenAIResp;
    if (!data.choices || data.choices.length === 0) {
      throw new Error(`Invalid response: no choices. Raw: ${resp.substring(0, 200)}`);
    }
    let choice = data.choices[0];
    if (!choice.message) {
      throw new Error(`Invalid response: no message in choice`);
    }
    if (choice.message.content) {
      // Strip <think>...</think> blocks from thinking models (openrouter/free may route to them)
      let text = choice.message.content;
      let thinkStart = text.indexOf('<think>');
      while (thinkStart >= 0) {
        let thinkEnd = text.indexOf('</think>', thinkStart);
        if (thinkEnd >= 0) {
          text = text.substring(0, thinkStart) + text.substring(thinkEnd + 8);
        } else {
          // Unclosed <think> — remove everything from <think> onward
          text = text.substring(0, thinkStart);
          break;
        }
        thinkStart = text.indexOf('<think>');
      }
      raw.text = text.trim();
    }
    if (choice.message.tool_calls && choice.message.tool_calls.length > 0) {
      for (let tc of choice.message.tool_calls) {
        if (tc.function) {
          let rtc = new RawToolCall();
          rtc.id = tc.id ?? '';
          rtc.name = tc.function.name ?? '';
          rtc.input = tc.function.arguments ?? '{}';
          raw.toolCalls.push(rtc);
        }
      }
    }
    return raw;
  }

  // --------- Local / Ollama ---------
  private async callLocal(
    messages: ApiMessage[], settings: SettingsData,
    systemPrompt: string
  ): Promise<RawResponse> {
    let apiMsgs: RoleContent[] = [];
    let sysMsg: RoleContent = { role: 'system', content: systemPrompt };
    apiMsgs.push(sysMsg);
    for (let m of messages) {
      let msg: RoleContent = { role: m.role, content: m.content };
      apiMsgs.push(msg);
    }

    let bodyStr = `{"model":${JSON.stringify(settings.model)},"messages":${JSON.stringify(apiMsgs)},"stream":false,"temperature":${settings.temperature}}`;
    let headers: Record<string, string> = { 'Content-Type': 'application/json' };
    // If an API key is provided, include Bearer auth (for OpenAI-compatible proxies like SiliconFlow)
    if (settings.apiKey && settings.apiKey.length > 0) {
      headers['Authorization'] = `Bearer ${settings.apiKey}`;
    }
    let targetUrl = settings.baseUrl || 'http://localhost:11434/api/chat';
    this.log.info(this.TAG, `callLocal: url=${targetUrl} model=${settings.model} hasKey=${settings.apiKey.length > 0}`);

    let resp = await this.httpPost(targetUrl, bodyStr, headers);

    // Try OpenAI-compatible format first, fallback to Ollama format
    let raw = new RawResponse();
    try {
      let oaiData = JSON.parse(resp) as OpenAIResp;
      if (oaiData.choices && oaiData.choices.length > 0) {
        let choice = oaiData.choices[0];
        if (choice.message && choice.message.content) {
          raw.text = choice.message.content;
        }
        return raw;
      }
    } catch { /* not OpenAI format, try Ollama */ }
    let data = JSON.parse(resp) as OllamaResp;
    raw.text = data.message?.content ?? '';
    return raw;
  }

  // --------- HTTP helper ---------
  private async httpPost(url: string, body: string,
    headers: Record<string, string>): Promise<string> {
    this.log.info(this.TAG, `httpPost: ${url} bodyLen=${body.length}`);
    let req = http.createHttp();
    try {
      let resp = await req.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 30000,
        readTimeout: 120000
      });
      this.log.info(this.TAG, `httpPost response: code=${resp.responseCode} resultLen=${((resp.result as string) ?? '').length}`);
      if (resp.responseCode !== 200) {
        let errBody = (resp.result as string) ?? '';
        this.log.error(this.TAG, `httpPost ERROR: HTTP ${resp.responseCode} body=${errBody.substring(0, 500)}`);
        throw new Error(`HTTP ${resp.responseCode}: ${errBody.substring(0, 200)}`);
      }
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  // --------- Tool execution ---------
  private async executeTool(name: string, inputJson: string, context?: common.UIAbilityContext): Promise<string> {
    try {
      let input = JSON.parse(inputJson) as Record<string, string>;
      switch (name) {
        case 'execute_command': {
          let r: ToolResultObj = {
            note: 'Sandboxed. Command: ' + (input['command'] ?? ''),
            stdout: '[command would execute here]',
            exitCode: 0
          };
          return JSON.stringify(r);
        }
        case 'read_file': {
          let filePath = input['path'] ?? '';
          if (filePath.length === 0) {
            let r: ToolResultObj = { error: 'No path provided' };
            return JSON.stringify(r);
          }
          // Resolve relative paths to app sandbox filesDir
          if (!filePath.startsWith('/') && context) {
            filePath = context.filesDir + '/' + filePath;
          }
          try {
            let stat = fileIo.statSync(filePath);
            if (!stat.isFile()) {
              let r: ToolResultObj = { error: 'Not a file: ' + filePath };
              return JSON.stringify(r);
            }
            if (stat.size > 512 * 1024) {
              let r: ToolResultObj = { error: 'File too large: ' + stat.size + ' bytes (max 512KB)', path: filePath };
              return JSON.stringify(r);
            }
            let file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
            let buf = new ArrayBuffer(stat.size);
            fileIo.readSync(file.fd, buf);
            fileIo.closeSync(file);
            let decoder = util.TextDecoder.create('utf-8');
            let text = decoder.decodeWithStream(new Uint8Array(buf));
            let r: ToolResultObj = { content: text, path: filePath };
            return JSON.stringify(r);
          } catch (e) {
            let r: ToolResultObj = { error: 'Failed to read: ' + (e as Error).message, path: filePath };
            return JSON.stringify(r);
          }
        }
        case 'write_file': {
          let wPath = input['path'] ?? '';
          let wContent = input['content'] ?? '';
          if (wPath.length === 0) {
            let r: ToolResultObj = { error: 'No path provided' };
            return JSON.stringify(r);
          }
          // Resolve relative paths to app sandbox filesDir
          if (!wPath.startsWith('/') && context) {
            wPath = context.filesDir + '/' + wPath;
          }
          try {
            let encoder = new util.TextEncoder();
            let encoded = encoder.encodeInto(wContent);
            let file = fileIo.openSync(wPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
            fileIo.writeSync(file.fd, encoded.buffer);
            fileIo.closeSync(file);
            let r: ToolResultObj = { note: 'Written ' + encoded.length + ' bytes', path: wPath };
            return JSON.stringify(r);
          } catch (e) {
            let r: ToolResultObj = { error: 'Failed to write: ' + (e as Error).message, path: wPath };
            return JSON.stringify(r);
          }
        }
        case 'list_files': {
          let lPath = input['path'] ?? '';
          // Default to app sandbox root directory
          if (lPath.length === 0 && context) {
            let dirs: string[] = [];
            dirs.push('filesDir: ' + context.filesDir);
            dirs.push('cacheDir: ' + context.cacheDir);
            dirs.push('tempDir: ' + context.tempDir);
            dirs.push('bundleCodeDir: ' + context.bundleCodeDir);
            // List filesDir contents as default
            try {
              let entries = fileIo.listFileSync(context.filesDir);
              let r: ToolResultObj = {
                content: 'App sandbox directories:\n' + dirs.join('\n') + '\n\nContents of filesDir:\n' + entries.join('\n'),
                path: context.filesDir,
                note: 'Showing app sandbox. Use these paths for file operations.'
              };
              return JSON.stringify(r);
            } catch (e) {
              let r: ToolResultObj = {
                content: 'App sandbox directories:\n' + dirs.join('\n'),
                note: 'Use these paths for file operations.'
              };
              return JSON.stringify(r);
            }
          }
          if (lPath.length === 0) {
            let r: ToolResultObj = { error: 'No path provided and no context available' };
            return JSON.stringify(r);
          }
          // Resolve relative paths to app sandbox filesDir
          if (!lPath.startsWith('/') && context) {
            lPath = context.filesDir + '/' + lPath;
          }
          try {
            let entries = fileIo.listFileSync(lPath);
            let r: ToolResultObj = { content: entries.join('\n'), path: lPath, note: entries.length + ' entries' };
            return JSON.stringify(r);
          } catch (e) {
            // Provide helpful error with available directories
            let errMsg = 'Failed to list: ' + (e as Error).message;
            if (context) {
              errMsg += '. Available app directories: filesDir=' + context.filesDir + ', cacheDir=' + context.cacheDir + ', tempDir=' + context.tempDir;
            }
            let r: ToolResultObj = { error: errMsg, path: lPath };
            return JSON.stringify(r);
          }
        }
        case 'search_files': {
          let sPath = input['path'] ?? '';
          let sPattern = input['pattern'] ?? '';
          let sContent = input['content'] ?? '';
          if (sPath.length === 0 && context) {
            sPath = context.filesDir;
          } else if (!sPath.startsWith('/') && context) {
            sPath = context.filesDir + '/' + sPath;
          }
          if (sPath.length === 0) {
            let r: ToolResultObj = { error: 'No path provided and no context available' };
            return JSON.stringify(r);
          }
          if (sPattern.length === 0 && sContent.length === 0) {
            let r: ToolResultObj = { error: 'Provide "pattern" (filename pattern) or "content" (text to search inside files)' };
            return JSON.stringify(r);
          }
          try {
            let results: string[] = [];
            this.searchFilesRecursive(sPath, sPattern, sContent, results, 0, 5);
            if (results.length === 0) {
              let r: ToolResultObj = { content: 'No files found', path: sPath, note: `pattern="${sPattern}" content="${sContent}"` };
              return JSON.stringify(r);
            }
            let r: ToolResultObj = {
              content: results.join('\n'),
              path: sPath,
              note: results.length + ' matches'
            };
            return JSON.stringify(r);
          } catch (e) {
            let r: ToolResultObj = { error: 'Search failed: ' + (e as Error).message, path: sPath };
            return JSON.stringify(r);
          }
        }
        case 'pick_file': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available for file picker' };
            return JSON.stringify(r);
          }
          try {
            // Request file access permissions at runtime
            let atManager = abilityAccessCtrl.createAtManager();
            await atManager.requestPermissionsFromUser(context, [
              'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
              'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY'
            ]);
            let options = new picker.DocumentSelectOptions();
            let documentPicker = new picker.DocumentViewPicker(context);
            let uris = await documentPicker.select(options);
            if (uris.length === 0) {
              let r: ToolResultObj = { note: 'User cancelled file selection' };
              return JSON.stringify(r);
            }
            let uri = uris[0];
            // Try to read the selected file
            let file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
            let stat = fileIo.statSync(file.fd);
            if (stat.size > 512 * 1024) {
              fileIo.closeSync(file);
              let r: ToolResultObj = { note: 'File selected but too large to read (' + stat.size + ' bytes)', path: uri };
              return JSON.stringify(r);
            }
            let buf = new ArrayBuffer(stat.size);
            fileIo.readSync(file.fd, buf);
            fileIo.closeSync(file);
            let decoder = util.TextDecoder.create('utf-8');
            let text = decoder.decodeWithStream(new Uint8Array(buf));
            let r: ToolResultObj = { content: text, path: uri, note: stat.size + ' bytes' };
            return JSON.stringify(r);
          } catch (e) {
            let r: ToolResultObj = { error: 'File pick failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'web_search': {
          let r: ToolResultObj = { note: 'Connect a search API', query: input['query'] ?? '' };
          return JSON.stringify(r);
        }
        case 'web_fetch': {
          let r: ToolResultObj = { note: 'URL fetch stub', url: input['url'] ?? '' };
          return JSON.stringify(r);
        }
        case 'list_devices': {
          let d1: DeviceObj = { id: 'light1', name: 'Living Room Light', status: 'on' };
          let d2: DeviceObj = { id: 'thermo1', name: 'Thermostat', status: '22C' };
          let devices: DeviceObj[] = [d1, d2];
          return `{"devices":${JSON.stringify(devices)}}`;
        }
        case 'device_action': {
          let r: ToolResultObj = { result: 'ok', device: input['device_id'] ?? '' };
          return JSON.stringify(r);
        }
        case 'list_events': {
          let r: ToolResultObj = { events: [], note: 'Calendar API not connected' };
          return JSON.stringify(r);
        }
        case 'create_event': {
          let r: ToolResultObj = { created: true, title: input['title'] ?? '' };
          return JSON.stringify(r);
        }
        case 'set_reminder': {
          let r: ToolResultObj = { set: true, message: input['message'] ?? '' };
          return JSON.stringify(r);
        }
        case 'capture_photo': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available for camera' };
            return JSON.stringify(r);
          }
          let camFacing = input['camera'] ?? 'back';
          // Save to persistent filesDir/photos (not cacheDir which gets cleaned up)
          let photoDir = context.filesDir + '/photos';
          try { fileIo.mkdirSync(photoDir); } catch { /* may already exist */ }
          let camSavePath = `${photoDir}/snap_${Date.now()}.jpg`;
          let camSaveUri = `file://${camSavePath}`;
          let camPos: camera.CameraPosition = camFacing === 'front'
            ? camera.CameraPosition.CAMERA_POSITION_FRONT
            : camera.CameraPosition.CAMERA_POSITION_BACK;
          let pickerProfile: cameraPicker.PickerProfile = {
            cameraPosition: camPos,
            saveUri: camSaveUri,
          };
          try {
            let camResult: cameraPicker.PickerResult =
              await cameraPicker.pick(context,
                [cameraPicker.PickerMediaType.PHOTO], pickerProfile);
            if (camResult.resultCode !== 0) {
              let r: ToolResultObj = { error: `Camera cancelled (code=${camResult.resultCode})` };
              return JSON.stringify(r);
            }
            // Find the photo using multiple strategies (same as CameraCapability)
            let foundPath = '';
            let tryPaths: string[] = [camSavePath];
            if (camResult.resultUri.length > 0) {
              tryPaths.push(camResult.resultUri);
              if (camResult.resultUri.startsWith('file://')) {
                tryPaths.push(camResult.resultUri.substring(7));
              }
            }
            for (let p of tryPaths) {
              try {
                fileIo.statSync(p);
                foundPath = p;
                break;
              } catch { /* try next */ }
            }
            if (foundPath.length === 0) {
              let r: ToolResultObj = { error: 'Photo file not found after capture' };
              return JSON.stringify(r);
            }
            // Copy to our persistent path if needed
            if (foundPath !== camSavePath) {
              try {
                let srcFile = fileIo.openSync(foundPath, fileIo.OpenMode.READ_ONLY);
                let dstFile = fileIo.openSync(camSavePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
                let stat = fileIo.statSync(foundPath);
                let buf = new ArrayBuffer(stat.size);
                fileIo.readSync(srcFile.fd, buf);
                fileIo.writeSync(dstFile.fd, buf);
                fileIo.closeSync(srcFile);
                fileIo.closeSync(dstFile);
                foundPath = camSavePath;
              } catch { /* use original path */ }
            }
            let camStat = fileIo.statSync(foundPath);
            let r: ToolResultObj = {
              note: `Photo captured (${camStat.size} bytes)`,
              path: foundPath,
            };
            return JSON.stringify(r);
          } catch (e) {
            let r: ToolResultObj = { error: 'Camera failed: ' + ((e as Error).message ?? String(e)) };
            return JSON.stringify(r);
          }
        }
        case 'record_audio': {
          if (!context) {
            let r: ToolResultObj = { error: 'No context available for microphone' };
            return JSON.stringify(r);
          }
          let recSeconds = 5;
          let secStr = input['seconds'] ?? '';
          if (secStr.length > 0) {
            let parsed = parseInt(secStr);
            if (!isNaN(parsed) && parsed > 0) {
              recSeconds = Math.min(parsed, 60);
            }
          }
          try {
            // Save to persistent filesDir/audio
            let audioDir = context.filesDir + '/audio';
            try { fileIo.mkdirSync(audioDir); } catch { /* may exist */ }
            let audioPath = `${audioDir}/rec_${Date.now()}.m4a`;
            let audioFile = fileIo.openSync(audioPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
            let recorder: media.AVRecorder = await media.createAVRecorder();
            let recConfig: media.AVRecorderConfig = {
              audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
              profile: {
                audioBitrate: 128000,
                audioChannels: 1,
                audioCodec: media.CodecMimeType.AUDIO_AAC,
                audioSampleRate: 44100,
                fileFormat: media.ContainerFormatType.CFT_MPEG_4,
              },
              url: `fd://${audioFile.fd}`,
            };
            await recorder.prepare(recConfig);
            await recorder.start();
            await new Promise<void>((resolve) => {
              setTimeout(() => { resolve(); }, recSeconds * 1000);
            });
            await recorder.stop();
            await recorder.release();
            fileIo.closeSync(audioFile);
            let audioStat = fileIo.statSync(audioPath);
            let r: ToolResultObj = {
              note: `Audio recorded: ${recSeconds}s, ${audioStat.size} bytes`,
              path: audioPath,
            };
            return JSON.stringify(r);
          } catch (e) {
            let r: ToolResultObj = { error: 'Recording failed: ' + ((e as Error).message ?? String(e)) };
            return JSON.stringify(r);
          }
        }
        case 'get_location': {
          try {
            let locRequest: geoLocationManager.SingleLocationRequest = {
              locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_LOCATING_SPEED,
              locatingTimeoutMs: 10000,
            };
            let loc = await geoLocationManager.getCurrentLocation(locRequest);
            let r: ToolResultObj = {
              lat: loc.latitude,
              lon: loc.longitude,
              accuracyMeters: loc.accuracy,
              timestamp: new Date(loc.timeStamp).toISOString(),
              isPrecise: loc.accuracy < 50,
              altitudeMeters: (loc.altitude !== undefined && loc.altitude !== 0) ? loc.altitude : undefined,
              speedMps: (loc.speed !== undefined && loc.speed > 0) ? loc.speed : undefined,
            };
            return JSON.stringify(r);
          } catch (e) {
            let r: ToolResultObj = { error: 'Location failed: ' + ((e as Error).message ?? String(e)) };
            return JSON.stringify(r);
          }
        }
        case 'save_memory': {
          let r: ToolResultObj = {
            saved: true,
            type: input['mem_type'] ?? 'fact',
            content: input['content'] ?? ''
          };
          return JSON.stringify(r);
        }
        default: {
          let r: ToolResultObj = { error: 'Unknown tool: ' + name };
          return JSON.stringify(r);
        }
      }
    } catch (e) {
      let r: ToolResultObj = { error: String(e) };
      return JSON.stringify(r);
    }
  }

  // --------- file search helper ---------
  private searchFilesRecursive(dir: string, pattern: string, content: string, results: string[], depth: number, maxDepth: number): void {
    if (depth > maxDepth || results.length >= 50) return;
    let entries: string[];
    try {
      entries = fileIo.listFileSync(dir);
    } catch {
      return;
    }
    let patternLower = pattern.toLowerCase();
    for (let entry of entries) {
      if (results.length >= 50) break;
      let fullPath = dir.endsWith('/') ? dir + entry : dir + '/' + entry;
      try {
        let stat = fileIo.statSync(fullPath);
        if (stat.isDirectory()) {
          // Recurse into subdirectory
          this.searchFilesRecursive(fullPath, pattern, content, results, depth + 1, maxDepth);
        } else if (stat.isFile()) {
          let nameMatch = pattern.length === 0 || entry.toLowerCase().includes(patternLower);
          if (nameMatch && content.length > 0 && stat.size < 256 * 1024) {
            // Search file content
            try {
              let file = fileIo.openSync(fullPath, fileIo.OpenMode.READ_ONLY);
              let buf = new ArrayBuffer(stat.size);
              fileIo.readSync(file.fd, buf);
              fileIo.closeSync(file);
              let decoder = util.TextDecoder.create('utf-8');
              let text = decoder.decodeWithStream(new Uint8Array(buf));
              if (text.includes(content)) {
                results.push(fullPath + ' (' + stat.size + ' bytes) [content match]');
              }
            } catch { /* skip unreadable files */ }
          } else if (nameMatch && content.length === 0) {
            results.push(fullPath + ' (' + stat.size + ' bytes)');
          }
        }
      } catch { /* skip inaccessible entries */ }
    }
  }

  // --------- message conversion ---------
  private buildApiMessages(history: ChatMessage[]): ApiMessage[] {
    let out: ApiMessage[] = [];
    for (let msg of history) {
      if (msg.role === 'user') {
        out.push({ role: 'user', content: msg.content });
      } else if (msg.role === 'assistant' && !msg.isToolCall && msg.content.length > 0) {
        out.push({ role: 'assistant', content: msg.content });
      }
    }
    return out;
  }
}

// --------- response types ---------
class RawResponse {
  text: string = '';
  toolCalls: RawToolCall[] = [];
}

class RawToolCall {
  id: string = '';
  name: string = '';
  input: string = '';
}

interface AnthropicResp {
  content: AnthropicBlock[];
}

interface AnthropicBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: object;
}

interface OpenAIResp {
  choices: OpenAIChoice[];
}

interface OpenAIChoice {
  message: OpenAIMsg;
}

interface OpenAIMsg {
  content?: string;
  tool_calls?: OpenAIToolCall[];
}

interface OpenAIToolCall {
  id: string;
  function: OpenAIFunc;
}

interface OpenAIFunc {
  name: string;
  arguments: string;
}

interface OllamaResp {
  message?: OllamaMessage;
}

interface OllamaMessage {
  content: string;
}
