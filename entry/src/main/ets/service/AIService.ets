import { http } from '@kit.NetworkKit';
import { ChatMessage, ApiMessage, ToolSchema, SettingsData } from '../model/Models';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';

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
    tools: ToolSchema[]
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
        } else if (settings.provider === 'openai') {
          response = await this.callOpenAI(allMessages, settings, systemPrompt, tools);
        } else {
          response = await this.callLocal(allMessages, settings, systemPrompt);
        }
      } catch (e) {
        result.error = `API error: ${(e as Error).message ?? String(e)}`;
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

      // Process tool calls
      for (let tc of response.toolCalls) {
        // Show the tool call
        let callMsg = new ChatMessage('assistant', '');
        callMsg.isToolCall = true;
        callMsg.toolName = tc.name;
        callMsg.toolInput = tc.input;
        result.messages.push(callMsg);

        // Execute
        let output = this.executeTool(tc.name, tc.input);

        // Show the result
        let resultMsg = new ChatMessage('tool', output);
        resultMsg.toolName = tc.name;
        resultMsg.toolOutput = output;
        result.messages.push(resultMsg);

        // Append to API messages for next loop iteration
        if (settings.provider === 'anthropic') {
          let toolUseBlock: AnthropicToolUseBlock = {
            type: 'tool_use',
            id: tc.id,
            name: tc.name,
            input: JSON.parse(tc.input)
          };
          let assistantApiMsg: ApiMessage = {
            role: 'assistant',
            content: JSON.stringify([toolUseBlock])
          };
          allMessages.push(assistantApiMsg);

          let toolResultBlock: AnthropicToolResultBlock = {
            type: 'tool_result',
            tool_use_id: tc.id,
            content: output
          };
          let userApiMsg: ApiMessage = {
            role: 'user',
            content: JSON.stringify([toolResultBlock])
          };
          allMessages.push(userApiMsg);
        } else {
          let assistantApiMsg: ApiMessage = { role: 'assistant', content: `[Tool call: ${tc.name}]\n${tc.input}` };
          allMessages.push(assistantApiMsg);
          let userApiMsg: ApiMessage = { role: 'user', content: `[Tool result: ${tc.name}]\n${output}` };
          allMessages.push(userApiMsg);
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
    let apiMsgs: RoleContent[] = [];
    let sysMsg: RoleContent = { role: 'system', content: systemPrompt };
    apiMsgs.push(sysMsg);
    for (let m of messages) {
      let msg: RoleContent = { role: m.role, content: m.content };
      apiMsgs.push(msg);
    }

    let bodyParts: string = `"model":${JSON.stringify(settings.model)},"max_tokens":${Constants.MAX_TOKENS},"temperature":${settings.temperature},"messages":${JSON.stringify(apiMsgs)}`;

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

    let resp = await this.httpPost(
      settings.baseUrl || Constants.OPENAI_URL,
      bodyStr,
      headers
    );

    let data = JSON.parse(resp) as OpenAIResp;
    let raw = new RawResponse();
    let choice = data.choices[0];
    if (choice.message.content) {
      raw.text = choice.message.content;
    }
    if (choice.message.tool_calls) {
      for (let tc of choice.message.tool_calls) {
        let rtc = new RawToolCall();
        rtc.id = tc.id;
        rtc.name = tc.function.name;
        rtc.input = tc.function.arguments;
        raw.toolCalls.push(rtc);
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

  // --------- Tool execution (local stubs) ---------
  private executeTool(name: string, inputJson: string): string {
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
          let r: ToolResultObj = { note: 'File read stub', path: input['path'] ?? '' };
          return JSON.stringify(r);
        }
        case 'write_file': {
          let r: ToolResultObj = { note: 'File write stub', path: input['path'] ?? '' };
          return JSON.stringify(r);
        }
        case 'list_files': {
          let r: ToolResultObj = { note: 'List stub', path: input['path'] ?? '' };
          return JSON.stringify(r);
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
          let r: ToolResultObj = { note: 'Camera requires UI interaction' };
          return JSON.stringify(r);
        }
        case 'record_audio': {
          let r: ToolResultObj = { note: 'Microphone requires UI interaction' };
          return JSON.stringify(r);
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
