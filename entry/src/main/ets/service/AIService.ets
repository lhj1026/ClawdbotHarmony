import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util, buffer } from '@kit.ArkTS';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
// camera, cameraPicker no longer used — auto-capture is in CameraCapability
import { media } from '@kit.MediaKit';
import { geoLocationManager } from '@kit.LocationKit';
import { ChatMessage, ApiMessage, ToolSchema, SettingsData, CronTask, CronParseResult } from '../model/Models';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';
import { I18n } from '../common/I18n';
import { calendarManager } from '@kit.CalendarKit';
import { CalendarCapability } from './gateway/CalendarCapability';
import { MemoryService } from './MemoryService';
import { CanvasCapability } from './gateway/CanvasCapability';
import { ScreenCapability } from './gateway/ScreenCapability';
import { Command } from './gateway/GatewayProtocol';
import { ImapService, EmailSummary, EmailBody } from './ImapService';
import { EmailCapability } from './gateway/EmailCapability';
import { CameraCapability } from './gateway/CameraCapability';
import { CustomSkillService, CreateSkillInput, UpdateSkillInput } from './CustomSkillService';
import { CustomSkillDef } from '../model/Models';

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

interface AutoDispatchResult {
  tool: string;
  input: string;
}

interface ImageSaveResult {
  path: string;
  summary: string;
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

interface EmailConfig {
  host: string;
  port: number;
  user: string;
  pass: string;
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
  private _recordingListeners: ((recording: boolean, durationSec: number) => void)[] = [];

  addRecordingListener(listener: (recording: boolean, durationSec: number) => void): void {
    this._recordingListeners.push(listener);
  }

  removeRecordingListener(listener: (recording: boolean, durationSec: number) => void): void {
    let idx = this._recordingListeners.indexOf(listener);
    if (idx >= 0) this._recordingListeners.splice(idx, 1);
  }

  private notifyRecording(recording: boolean, durationSec: number): void {
    for (let l of this._recordingListeners) {
      try { l(recording, durationSec); } catch { /* ignore */ }
    }
  }

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
    context?: common.UIAbilityContext,
    onDelta?: (text: string) => void
  ): Promise<AIResult> {
    let result = new AIResult();
    if (!settings.apiKey && settings.provider !== 'local') {
      result.error = 'Please set your API Key in Settings.';
      return result;
    }

    let allMessages = this.buildApiMessages(history);
    let loopCount = 0;
    let lastImagePath = ''; // track captured image path across loop iterations

    while (loopCount < Constants.MAX_TOOL_LOOPS) {
      loopCount++;
      let response: RawResponse;
      try {
        if (settings.provider === 'anthropic') {
          response = await this.callAnthropic(allMessages, settings, systemPrompt, tools);
        } else if (settings.provider === 'local' && (!settings.apiKey || settings.apiKey.length === 0)) {
          // Truly local model (Ollama) — no tool support
          response = await this.callLocal(allMessages, settings, systemPrompt);
        } else if (onDelta && loopCount === 1) {
          // First iteration with streaming — use SSE streaming for responsive output
          response = await this.callOpenAIStream(allMessages, settings, systemPrompt, tools, onDelta);
        } else {
          // OpenAI-compatible providers (openai, openrouter, siliconflow, etc.) — full tool support
          response = await this.callOpenAI(allMessages, settings, systemPrompt, tools);
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
      // Skip trivial text (like "{}") when tool calls are present — it's likely
      // an artifact from the model, not meaningful content for the user.
      let hasToolCalls = response.toolCalls.length > 0;
      let textToShow = response.text.trim();
      if (hasToolCalls) {
        // Strip JSON-like artifacts that some models emit alongside tool calls
        let stripped = textToShow.replace(/^\{[\s]*\}$/, '').trim();
        if (stripped.length > 0) {
          textToShow = stripped;
        } else {
          textToShow = '';
        }
      }
      if (textToShow.length > 0) {
        let msg = new ChatMessage('assistant', textToShow);
        result.messages.push(msg);
      }

      // No tool calls -> check auto-dispatch, then done
      if (!hasToolCalls) {
        // Auto-dispatch: if model failed to call a tool but user clearly wants one,
        // inject the tool call automatically (works around weak tool-calling models)
        if (loopCount === 1 && context) {
          let intentMode = await this.getIntentMode(context);
          let dispatch = intentMode !== 'cloud'
            ? this.detectAutoDispatch(history, textToShow)
            : { tool: '', input: '{}' } as AutoDispatchResult;
          if (dispatch.tool.length > 0) {
            this.log.info(this.TAG, `Auto-dispatch: ${dispatch.tool} input=${dispatch.input}`);
            let autoOutput = '';
            try {
              autoOutput = await this.executeTool(dispatch.tool, dispatch.input, context);
            } catch (e) {
              autoOutput = JSON.stringify({ error: (e as Error).message });
            }
            // Remove the hallucinated text response
            if (result.messages.length > 0) {
              result.messages = [];
            }

            // For image-producing tools, save to file and strip base64 before sending to model
            let summaryForModel = autoOutput;
            let savedImagePath = '';
            if (dispatch.tool === 'screen_capture' || dispatch.tool === 'capture_photo') {
              let saveResult = this.saveImageToolResult(autoOutput, dispatch.tool, context);
              summaryForModel = saveResult.summary;
              savedImagePath = saveResult.path;
            }
            // Fallback: extract path from tool output (capture_photo returns {path} without base64)
            if (savedImagePath.length === 0) {
              try {
                let parsed = JSON.parse(autoOutput) as Record<string, Object>;
                let pp = (parsed['path'] ?? '') as string;
                if (pp.length > 0) savedImagePath = pp;
              } catch { /* ignore */ }
            }
            if (savedImagePath.length > 0) {
              lastImagePath = savedImagePath;
            }

            // Extract audio path for record_audio (shown on tool result bubble with play button)
            let savedAudioPath = '';
            if (dispatch.tool === 'record_audio') {
              try {
                let parsed = JSON.parse(autoOutput) as Record<string, Object>;
                let pp = (parsed['path'] ?? '') as string;
                if (pp.length > 0) savedAudioPath = pp;
              } catch { /* ignore */ }
            }

            // Show tool call + result (image will be shown on the final assistant message instead)
            let callMsg = new ChatMessage('assistant', '');
            callMsg.isToolCall = true;
            callMsg.toolName = dispatch.tool;
            callMsg.toolInput = dispatch.input;
            result.messages.push(callMsg);
            let resultMsg = new ChatMessage('tool', summaryForModel);
            resultMsg.toolName = dispatch.tool;
            resultMsg.toolOutput = summaryForModel;
            if (savedAudioPath.length > 0) {
              resultMsg.audioPath = savedAudioPath;
            }
            result.messages.push(resultMsg);
            // Feed tool result back to AI for summarization
            allMessages.push({ role: 'assistant', content: `Calling ${dispatch.tool}...` });
            allMessages.push({ role: 'user', content: `Tool ${dispatch.tool} returned:\n${summaryForModel}\n\nSummarize the result concisely in the user's language.` });
            continue; // re-enter the loop for AI to summarize
          }
        }
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
        // For image-producing tools, save to file and strip base64 before sending to model
        let outputForModel = output;
        let imgPath = '';
        if (tc.name === 'screen_capture' || tc.name === 'capture_photo') {
          let saveResult = this.saveImageToolResult(output, tc.name, context);
          outputForModel = saveResult.summary;
          imgPath = saveResult.path;
        }
        toolOutputs.push(outputForModel);

        // Show the result in chat
        let resultMsg = new ChatMessage('tool', outputForModel);
        resultMsg.toolName = tc.name;
        resultMsg.toolOutput = outputForModel;
        // Track image path for the final assistant message (not shown on tool result to avoid duplicates)
        if (imgPath.length > 0) {
          lastImagePath = imgPath;
        } else if (tc.name === 'capture_photo') {
          try {
            let parsed = JSON.parse(output) as Record<string, string>;
            if (parsed['path'] && parsed['path'].length > 0) {
              lastImagePath = parsed['path'];
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

    // Attach captured image to the last assistant message for inline display
    if (lastImagePath.length > 0) {
      for (let i = result.messages.length - 1; i >= 0; i--) {
        if (result.messages[i].role === 'assistant' && !result.messages[i].isToolCall) {
          result.messages[i].imagePath = lastImagePath;
          break;
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
    // Build messages with multimodal support for Anthropic
    let msgJsonParts: string[] = [];
    for (let m of messages) {
      if (m.role === 'user' && m.imageBase64 && m.imageBase64.length > 0) {
        let contentArr = `[{"type":"text","text":${JSON.stringify(m.content)}},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":${JSON.stringify(m.imageBase64)}}}]`;
        msgJsonParts.push(`{"role":"user","content":${contentArr}}`);
      } else {
        msgJsonParts.push(`{"role":${JSON.stringify(m.role)},"content":${JSON.stringify(m.content)}}`);
      }
    }
    let messagesJson = `[${msgJsonParts.join(',')}]`;

    // Build body as JSON string directly to avoid untyped object literal issues
    let bodyParts: string = `"model":${JSON.stringify(settings.model)},"max_tokens":${Constants.MAX_TOKENS},"temperature":${settings.temperature},"system":${JSON.stringify(systemPrompt)},"messages":${messagesJson}`;

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
        let blockText = block.text ?? '';
        if (blockText.length > 0) {
          if (raw.text.length > 0) {
            raw.text += '\n\n';
          }
          raw.text += blockText;
        }
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
        let contentPart = m.content.length > 0 ? JSON.stringify(m.content) : 'null';
        msgJsonParts.push(`{"role":"assistant","content":${contentPart},"tool_calls":${m.toolCalls}}`);
      } else if (m.toolCallId !== undefined && m.toolCallId.length > 0) {
        msgJsonParts.push(`{"role":"tool","tool_call_id":${JSON.stringify(m.toolCallId)},"content":${JSON.stringify(m.content)}}`);
      } else if (m.role === 'user' && m.imageBase64 && m.imageBase64.length > 0) {
        // Multimodal user message with image (OpenAI vision format)
        let contentArr = `[{"type":"text","text":${JSON.stringify(m.content)}},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,${m.imageBase64}"}}]`;
        msgJsonParts.push(`{"role":"user","content":${contentArr}}`);
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

    let defaultUrl = settings.provider === 'openrouter' ? Constants.OPENROUTER_URL
      : settings.provider === 'siliconflow' ? Constants.SILICONFLOW_URL : Constants.OPENAI_URL;
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

    this.log.info(this.TAG, `callOpenAI raw response (first 500): ${resp.substring(0, 500)}`);
    let data = JSON.parse(resp) as OpenAIResp;
    if (!data.choices || data.choices.length === 0) {
      throw new Error(`Invalid response: no choices. Raw: ${resp.substring(0, 200)}`);
    }
    let choice = data.choices[0];
    if (!choice.message) {
      throw new Error(`Invalid response: no message in choice`);
    }
    this.log.info(this.TAG, `callOpenAI: hasContent=${!!choice.message.content} hasToolCalls=${!!(choice.message.tool_calls && choice.message.tool_calls.length > 0)} contentLen=${(choice.message.content ?? '').length}`);
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
    // Fallback: some models output tool calls as JSON in text content
    if (raw.toolCalls.length === 0 && raw.text.length > 0) {
      this.log.info(this.TAG, `callOpenAI: no tool_calls in response, trying text extraction. text="${raw.text.substring(0, 200)}"`);
      this.extractToolCallsFromText(raw);
    }
    this.log.info(this.TAG, `callOpenAI: final toolCalls=${raw.toolCalls.length} textLen=${raw.text.length}`);
    return raw;
  }

  // --------- OpenAI Streaming (SSE) ---------
  private async callOpenAIStream(
    messages: ApiMessage[], settings: SettingsData,
    systemPrompt: string, tools: ToolSchema[],
    onDelta: (text: string) => void
  ): Promise<RawResponse> {
    // Build messages JSON (same as callOpenAI, with multimodal support)
    let msgJsonParts: string[] = [];
    msgJsonParts.push(`{"role":"system","content":${JSON.stringify(systemPrompt)}}`);
    for (let m of messages) {
      if (m.toolCalls !== undefined && m.toolCalls.length > 0) {
        let contentPart = m.content.length > 0 ? JSON.stringify(m.content) : 'null';
        msgJsonParts.push(`{"role":"assistant","content":${contentPart},"tool_calls":${m.toolCalls}}`);
      } else if (m.toolCallId !== undefined && m.toolCallId.length > 0) {
        msgJsonParts.push(`{"role":"tool","tool_call_id":${JSON.stringify(m.toolCallId)},"content":${JSON.stringify(m.content)}}`);
      } else if (m.role === 'user' && m.imageBase64 && m.imageBase64.length > 0) {
        let contentArr = `[{"type":"text","text":${JSON.stringify(m.content)}},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,${m.imageBase64}"}}]`;
        msgJsonParts.push(`{"role":"user","content":${contentArr}}`);
      } else {
        msgJsonParts.push(`{"role":${JSON.stringify(m.role)},"content":${JSON.stringify(m.content)}}`);
      }
    }
    let messagesJson = `[${msgJsonParts.join(',')}]`;

    let bodyParts: string = `"model":${JSON.stringify(settings.model)},"max_tokens":${Constants.MAX_TOKENS},"temperature":${settings.temperature},"stream":true,"messages":${messagesJson}`;

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

    let defaultUrl = settings.provider === 'openrouter' ? Constants.OPENROUTER_URL
      : settings.provider === 'siliconflow' ? Constants.SILICONFLOW_URL : Constants.OPENAI_URL;
    let url = defaultUrl;
    if (settings.baseUrl.length > 0) {
      if (settings.provider === 'openrouter' && !settings.baseUrl.includes('openrouter')) {
        this.log.warn(this.TAG, `Ignoring non-OpenRouter baseUrl: ${settings.baseUrl}`);
      } else {
        url = settings.baseUrl;
      }
    }
    this.log.info(this.TAG, `callOpenAIStream: url=${url} model=${settings.model} bodyLen=${bodyStr.length}`);

    let raw = new RawResponse();
    let accText = '';
    let sseBuffer = '';
    // Tool call accumulation for streaming tool_calls
    let tcAccum = new Map<number, StreamToolCallAccum>();

    return new Promise<RawResponse>((resolve, reject) => {
      let req = http.createHttp();
      let resolved = false;

      req.on('dataReceive', (data: ArrayBuffer) => {
        let chunk = '';
        try {
          let decoder = new util.TextDecoder();
          chunk = decoder.decodeWithStream(new Uint8Array(data));
        } catch {
          return;
        }
        sseBuffer += chunk;

        // Process complete SSE lines
        let lines = sseBuffer.split('\n');
        sseBuffer = lines[lines.length - 1]; // keep incomplete last line
        for (let i = 0; i < lines.length - 1; i++) {
          let line = lines[i].trim();
          if (!line.startsWith('data: ')) continue;
          let payload = line.substring(6).trim();
          if (payload === '[DONE]') continue;

          try {
            let obj = JSON.parse(payload) as StreamChunk;
            if (obj.choices && obj.choices.length > 0) {
              let delta = obj.choices[0].delta;
              if (delta) {
                // Text content
                if (delta.content) {
                  accText += delta.content;
                  onDelta(delta.content);
                }
                // Tool calls (streaming)
                if (delta.tool_calls) {
                  for (let dtc of delta.tool_calls) {
                    let idx = dtc.index ?? 0;
                    let existing = tcAccum.get(idx);
                    if (!existing) {
                      existing = { id: '', name: '', args: '' };
                      tcAccum.set(idx, existing);
                    }
                    if (dtc.id) existing.id = dtc.id;
                    if (dtc.function?.name) existing.name = dtc.function.name;
                    if (dtc.function?.arguments) existing.args += dtc.function.arguments;
                  }
                }
              }
              // Check finish_reason
              let finish = obj.choices[0].finish_reason;
              if (finish === 'stop' || finish === 'tool_calls') {
                // Done
              }
            }
          } catch { /* skip malformed JSON */ }
        }
      });

      req.on('dataEnd', () => {
        if (resolved) return;
        resolved = true;
        // Strip <think>...</think> blocks
        let text = accText;
        let thinkStart = text.indexOf('<think>');
        while (thinkStart >= 0) {
          let thinkEnd = text.indexOf('</think>', thinkStart);
          if (thinkEnd >= 0) {
            text = text.substring(0, thinkStart) + text.substring(thinkEnd + 8);
          } else {
            text = text.substring(0, thinkStart);
            break;
          }
          thinkStart = text.indexOf('<think>');
        }
        raw.text = text.trim();

        // Collect accumulated tool calls
        let sortedKeys: number[] = [];
        tcAccum.forEach((_v: StreamToolCallAccum, k: number) => { sortedKeys.push(k); });
        sortedKeys.sort();
        for (let k of sortedKeys) {
          let acc = tcAccum.get(k);
          if (acc && acc.name.length > 0) {
            let rtc = new RawToolCall();
            rtc.id = acc.id;
            rtc.name = acc.name;
            rtc.input = acc.args;
            raw.toolCalls.push(rtc);
          }
        }

        // Fallback: extract tool calls from text if none found
        if (raw.toolCalls.length === 0 && raw.text.length > 0) {
          this.extractToolCallsFromText(raw);
        }
        this.log.info(this.TAG, `callOpenAIStream: done textLen=${raw.text.length} toolCalls=${raw.toolCalls.length}`);
        req.destroy();
        resolve(raw);
      });

      req.on('dataReceiveProgress', () => { /* ignore progress events */ });

      req.requestInStream(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: bodyStr,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 30000,
        readTimeout: 120000
      }).then((code: number) => {
        if (code !== 200) {
          if (!resolved) {
            resolved = true;
            req.destroy();
            reject(new Error(`HTTP ${code} from streaming request`));
          }
        }
      }).catch((err: Error) => {
        if (!resolved) {
          resolved = true;
          req.destroy();
          reject(err);
        }
      });
    });
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

  // --------- Fallback: extract tool calls from text ---------
  private extractToolCallsFromText(raw: RawResponse): void {
    let text = raw.text;
    // Pattern 1: {"name": "tool_name", "arguments": {...}}
    // Pattern 2: {"name": "tool_name", "parameters": {...}}
    let patterns: RegExp[] = [
      /\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"arguments"\s*:\s*(\{[\s\S]*?\})\s*\}/g,
      /\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"parameters"\s*:\s*(\{[\s\S]*?\})\s*\}/g,
    ];
    for (let re of patterns) {
      let match: RegExpExecArray | null = re.exec(text);
      while (match !== null) {
        let name = match[1];
        let args = match[2];
        try {
          JSON.parse(args); // validate JSON
          let rtc = new RawToolCall();
          rtc.id = `fallback_${Date.now()}_${raw.toolCalls.length}`;
          rtc.name = name;
          rtc.input = args;
          raw.toolCalls.push(rtc);
          this.log.info(this.TAG, `Extracted tool call from text: ${name}`);
          // Remove the tool call JSON from displayed text
          raw.text = text.substring(0, match.index).trim() +
            (match.index + match[0].length < text.length ? '\n' + text.substring(match.index + match[0].length).trim() : '');
          raw.text = raw.text.trim();
        } catch { /* invalid JSON, skip */ }
        match = re.exec(text);
      }
      if (raw.toolCalls.length > 0) break;
    }
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

  /**
   * Simple one-shot chat: send a system prompt + user message, return text only.
   * Used for memory extraction, conversation compression, etc.
   */
  async simpleChat(systemPrompt: string, userMessage: string, settings: SettingsData): Promise<string> {
    let messages: ApiMessage[] = [];
    let msg: ApiMessage = { role: 'user', content: userMessage };
    messages.push(msg);
    let response: RawResponse;
    if (settings.provider === 'anthropic') {
      response = await this.callAnthropic(messages, settings, systemPrompt, []);
    } else {
      response = await this.callOpenAI(messages, settings, systemPrompt, []);
    }
    return response.text;
  }

  // --------- Tool execution ---------
  private async executeTool(name: string, inputJson: string, context?: common.UIAbilityContext): Promise<string> {
    this.log.info(this.TAG, `executeTool: ${name} input=${inputJson.substring(0, 200)}`);
    try {
      let input = JSON.parse(inputJson) as Record<string, string>;
      switch (name) {
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
            // // Request file access permissions at runtime
            // let atManager = abilityAccessCtrl.createAtManager();
            // await atManager.requestPermissionsFromUser(context, [
            //   'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
            //   'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY'
            // ]);
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
          let query = input['query'] ?? '';
          if (query.length === 0) {
            let r: ToolResultObj = { error: 'No query provided' };
            return JSON.stringify(r);
          }
          try {
            let encoded = encodeURIComponent(query);
            let searchUrl = `https://html.duckduckgo.com/html/?q=${encoded}`;
            this.log.info(this.TAG, `web_search: query="${query}" url=${searchUrl}`);
            let req = http.createHttp();
            let resp = await req.request(searchUrl, {
              method: http.RequestMethod.GET,
              header: {
                'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                'Accept': 'text/html,application/xhtml+xml',
                'Accept-Language': 'en-US,en;q=0.9',
              },
              expectDataType: http.HttpDataType.STRING,
              connectTimeout: 10000,
              readTimeout: 15000
            });
            req.destroy();
            let html = (resp.result as string) ?? '';
            this.log.info(this.TAG, `web_search: HTTP ${resp.responseCode} htmlLen=${html.length}`);
            if (html.length < 200) {
              this.log.warn(this.TAG, `web_search: short response: ${html}`);
            } else {
              this.log.info(this.TAG, `web_search: html preview: ${html.substring(0, 300)}`);
            }
            // Try multiple extraction strategies
            let results: string[] = [];
            let links: string[] = [];
            // Strategy 1: DuckDuckGo snippet class
            let re1 = /class="result__snippet"[^>]*>([\s\S]*?)<\/(?:a|span|div)>/g;
            let m1: RegExpExecArray | null = re1.exec(html);
            while (m1 !== null && results.length < 5) {
              let snippet = m1[1].replace(/<[^>]*>/g, '').replace(/&amp;/g, '&')
                .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
                .replace(/&#x27;/g, "'").replace(/&nbsp;/g, ' ').trim();
              if (snippet.length > 0) results.push(snippet);
              m1 = re1.exec(html);
            }
            // Strategy 2: result__a links
            let linkRe = /class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g;
            let lm: RegExpExecArray | null = linkRe.exec(html);
            while (lm !== null && links.length < 5) {
              let title = lm[2].replace(/<[^>]*>/g, '').trim();
              let href = lm[1];
              if (title.length > 0) links.push(title + ': ' + href);
              lm = linkRe.exec(html);
            }
            this.log.info(this.TAG, `web_search: strategy1 results=${results.length} links=${links.length}`);
            // Strategy 3: fallback - extract any text between result divs
            if (results.length === 0) {
              let re3 = /class="result[^"]*"[\s\S]*?<a[^>]*href="(https?:\/\/[^"]*)"[^>]*>([\s\S]*?)<\/a>/g;
              let m3: RegExpExecArray | null = re3.exec(html);
              while (m3 !== null && links.length < 5) {
                let title = m3[2].replace(/<[^>]*>/g, '').trim();
                if (title.length > 0) {
                  links.push(title + ': ' + m3[1]);
                }
                m3 = re3.exec(html);
              }
              this.log.info(this.TAG, `web_search: strategy3 fallback links=${links.length}`);
            }
            // Strategy 4: last resort - just strip all HTML and return text
            if (results.length === 0 && links.length === 0) {
              let plainText = html.replace(/<script[\s\S]*?<\/script>/gi, '')
                .replace(/<style[\s\S]*?<\/style>/gi, '')
                .replace(/<[^>]*>/g, ' ')
                .replace(/\s+/g, ' ').trim();
              if (plainText.length > 2000) plainText = plainText.substring(0, 2000);
              this.log.info(this.TAG, `web_search: strategy4 plainText len=${plainText.length}`);
              results.push(plainText);
            }
            return JSON.stringify({ query: query, results: results, links: links });
          } catch (e) {
            this.log.error(this.TAG, `web_search error: ${(e as Error).message}`);
            let r: ToolResultObj = { error: 'Search failed: ' + (e as Error).message, query: query };
            return JSON.stringify(r);
          }
        }
        case 'web_fetch': {
          let url = input['url'] ?? '';
          if (url.length === 0) {
            let r: ToolResultObj = { error: 'No URL provided' };
            return JSON.stringify(r);
          }
          try {
            let req = http.createHttp();
            let resp = await req.request(url, {
              method: http.RequestMethod.GET,
              header: { 'User-Agent': 'Mozilla/5.0' },
              expectDataType: http.HttpDataType.STRING,
              connectTimeout: 10000,
              readTimeout: 15000
            });
            req.destroy();
            let html = (resp.result as string) ?? '';
            // Strip HTML tags for plain text
            let text = html.replace(/<script[\s\S]*?<\/script>/gi, '')
              .replace(/<style[\s\S]*?<\/style>/gi, '')
              .replace(/<[^>]*>/g, ' ')
              .replace(/\s+/g, ' ')
              .trim();
            if (text.length > 8000) {
              text = text.substring(0, 8000) + '...[truncated]';
            }
            return JSON.stringify({ url: url, status: resp.responseCode, content: text });
          } catch (e) {
            let r: ToolResultObj = { error: 'Fetch failed: ' + (e as Error).message, url: url };
            return JSON.stringify(r);
          }
        }
        case 'open_webpage': {
          let url = input['url'] ?? '';
          if (url.length === 0) {
            let r: ToolResultObj = { error: 'No URL provided' };
            return JSON.stringify(r);
          }
          try {
            let canvasCap = CanvasCapability.getInstance();
            let result = await canvasCap.execute(Command.CANVAS_PRESENT, JSON.stringify({ url: url }));
            return result;
          } catch (e) {
            let r: ToolResultObj = { error: 'Open webpage failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'close_webpage': {
          try {
            let canvasCap = CanvasCapability.getInstance();
            let result = await canvasCap.execute(Command.CANVAS_HIDE, undefined);
            return result;
          } catch (e) {
            let r: ToolResultObj = { error: 'Close webpage failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'navigate_webpage': {
          let url = input['url'] ?? '';
          if (url.length === 0) {
            let r: ToolResultObj = { error: 'No URL provided' };
            return JSON.stringify(r);
          }
          try {
            let canvasCap = CanvasCapability.getInstance();
            let result = await canvasCap.execute(Command.CANVAS_NAVIGATE, JSON.stringify({ url: url }));
            return result;
          } catch (e) {
            let r: ToolResultObj = { error: 'Navigate failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'eval_webpage': {
          let js = input['javascript'] ?? input['js'] ?? '';
          if (js.length === 0) {
            let r: ToolResultObj = { error: 'No JavaScript code provided' };
            return JSON.stringify(r);
          }
          try {
            let canvasCap = CanvasCapability.getInstance();
            let result = await canvasCap.execute(Command.CANVAS_EVAL, JSON.stringify({ javaScript: js }));
            return result;
          } catch (e) {
            let r: ToolResultObj = { error: 'Eval failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'snapshot_webpage': {
          try {
            let quality = input['quality'] ?? '80';
            let canvasCap = CanvasCapability.getInstance();
            let result = await canvasCap.execute(Command.CANVAS_SNAPSHOT, JSON.stringify({ quality: parseInt(quality) || 80 }));
            return result;
          } catch (e) {
            let r: ToolResultObj = { error: 'Snapshot failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'screen_capture': {
          try {
            let screenCap = ScreenCapability.getInstance();
            let result = await screenCap.execute(Command.SCREEN_CAPTURE, undefined);
            return result;
          } catch (e) {
            let r: ToolResultObj = { error: 'Screenshot failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
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
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available for calendar' };
            return JSON.stringify(r);
          }
          try {
            let atManager = abilityAccessCtrl.createAtManager();
            await atManager.requestPermissionsFromUser(context,
              ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR']);
            let calMgr = calendarManager.getCalendarManager(context);
            let daysStr = input['days'] ?? '7';
            let days = parseInt(daysStr) || 7;
            let now = Date.now();
            let endTime = now + days * 24 * 60 * 60 * 1000;
            let filter = calendarManager.EventFilter.filterByTime(now, endTime);
            this.log.info(this.TAG, `list_events: days=${days} now=${now} end=${endTime}`);
            // Query ALL calendars, not just the default one
            interface EventSummary {
              title: string;
              start: string;
              end: string;
              location: string;
              description: string;
            }
            let summaries: EventSummary[] = [];
            try {
              let allCals: calendarManager.Calendar[] = await calMgr.getAllCalendars();
              this.log.info(this.TAG, `list_events: found ${allCals.length} calendars`);
              for (let cal of allCals) {
                let calAccount: calendarManager.CalendarAccount = cal.getAccount();
                this.log.info(this.TAG, `list_events: querying calendar name=${calAccount.name} type=${calAccount.type}`);
                let events: calendarManager.Event[] = await cal.getEvents(filter);
                this.log.info(this.TAG, `list_events: calendar ${calAccount.name} has ${events.length} events`);
                for (let ev of events) {
                  if (summaries.length >= 20) break;
                  let s: EventSummary = {
                    title: ev.title ?? '',
                    start: new Date(ev.startTime).toISOString(),
                    end: new Date(ev.endTime).toISOString(),
                    location: ev.location?.location ?? '',
                    description: ev.description ?? ''
                  };
                  summaries.push(s);
                }
              }
            } catch (e1) {
              this.log.warn(this.TAG, `getAllCalendars failed: ${(e1 as Error).message}, trying default calendar`);
              // Fallback to default calendar
              let cal = await calMgr.getCalendar();
              let events: calendarManager.Event[] = await cal.getEvents(filter);
              this.log.info(this.TAG, `list_events: default calendar has ${events.length} events`);
              for (let ev of events) {
                if (summaries.length >= 20) break;
                let s: EventSummary = {
                  title: ev.title ?? '',
                  start: new Date(ev.startTime).toISOString(),
                  end: new Date(ev.endTime).toISOString(),
                  location: ev.location?.location ?? '',
                  description: ev.description ?? ''
                };
                summaries.push(s);
              }
            }
            this.log.info(this.TAG, `list_events: returning ${summaries.length} events total`);
            return JSON.stringify({ days: days, count: summaries.length, events: summaries });
          } catch (e) {
            this.log.error(this.TAG, `list_events error: ${(e as Error).message}`);
            let r: ToolResultObj = { error: 'List events failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'create_event': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available for calendar' };
            return JSON.stringify(r);
          }
          try {
            let title = input['title'] ?? '';
            let startStr = input['start'] ?? '';
            let endStr = input['end'] ?? '';
            let startMs = startStr.length > 0 ? new Date(startStr).getTime() : Date.now();
            let endMs = endStr.length > 0 ? new Date(endStr).getTime() : (startMs + 60 * 60 * 1000);
            let calCap = new CalendarCapability();
            calCap.setContext(context);
            let calParams = JSON.stringify({
              title: title,
              startTime: startMs,
              endTime: endMs,
              reminderTime: [5]
            });
            let calResult = await calCap.execute(calParams);
            return calResult;
          } catch (e) {
            let r: ToolResultObj = { error: 'Calendar create failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'set_reminder': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available for calendar' };
            return JSON.stringify(r);
          }
          try {
            let msg = input['message'] ?? '';
            let timeStr = input['time'] ?? '';
            let reminderMs = timeStr.length > 0 ? new Date(timeStr).getTime() : (Date.now() + 10 * 60 * 1000);
            let calCap = new CalendarCapability();
            calCap.setContext(context);
            let calParams = JSON.stringify({
              title: msg,
              startTime: reminderMs,
              endTime: reminderMs + 15 * 60 * 1000,
              reminderTime: [0]
            });
            let calResult = await calCap.execute(calParams);
            return calResult;
          } catch (e) {
            let r: ToolResultObj = { error: 'Reminder set failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'capture_photo': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available for camera' };
            return JSON.stringify(r);
          }
          let camFacing: string = (input['camera'] ?? 'back') as string;
          // Save to persistent filesDir/photos (not cacheDir which gets cleaned up)
          let photoDir = context.filesDir + '/photos';
          try { fileIo.mkdirSync(photoDir); } catch { /* may already exist */ }
          let camSavePath = `${photoDir}/snap_${Date.now()}.jpg`;
          try {
            let cameraCap = new CameraCapability();
            cameraCap.setContext(context);
            await cameraCap.autoCapture(camFacing, camSavePath);
            let camStat = fileIo.statSync(camSavePath);
            let r: ToolResultObj = {
              note: `Photo captured (${camStat.size} bytes)`,
              path: camSavePath,
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
            this.notifyRecording(true, recSeconds);
            await new Promise<void>((resolve) => {
              setTimeout(() => { resolve(); }, recSeconds * 1000);
            });
            await recorder.stop();
            await recorder.release();
            this.notifyRecording(false, 0);
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
            if (context) {
              let atManager = abilityAccessCtrl.createAtManager();
              await atManager.requestPermissionsFromUser(context, [
                'ohos.permission.APPROXIMATELY_LOCATION',
                'ohos.permission.LOCATION'
              ]);
            }
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
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          let memType = input['mem_type'] ?? 'fact';
          let content = input['content'] ?? '';
          if (content.length === 0) {
            let r: ToolResultObj = { error: 'No content to save' };
            return JSON.stringify(r);
          }
          try {
            let memSvc = MemoryService.getInstance();
            let item = await memSvc.addIfNew(context, memType, content, 0.8);
            if (item) {
              // add() already triggers embedAndStore + generateMemoryMd async
              return JSON.stringify({ saved: true, id: item.id, type: memType, content: content });
            } else {
              return JSON.stringify({ saved: false, note: 'Already exists', type: memType, content: content });
            }
          } catch (e) {
            let r: ToolResultObj = { error: 'Save memory failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'search_memory': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          let query = input['query'] ?? '';
          if (query.length === 0) {
            let r: ToolResultObj = { error: 'No query provided' };
            return JSON.stringify(r);
          }
          try {
            let memSvc = MemoryService.getInstance();
            let filterType = input['mem_type'] ?? '';
            // Use hybrid search (vector + keyword fusion, OpenClaw-inspired)
            let apiKey = await memSvc.getEmbeddingApiKey(context);
            let hybridResults = await memSvc.hybridSearch(context, query, apiKey, 5, filterType);
            let searchMethod = 'hybrid';
            let items: Record<string, string | number>[];
            if (hybridResults.length > 0) {
              items = hybridResults.map((r): Record<string, string | number> => {
                let obj: Record<string, string | number> = {};
                obj['type'] = r.item.memType;
                obj['content'] = r.item.content;
                obj['score'] = Math.round(r.score * 100);
                obj['method'] = r.method;
                obj['source'] = r.citation;
                obj['created'] = new Date(r.item.createdAt).toLocaleDateString();
                return obj;
              });
            } else {
              // Fallback to keyword search
              let kwResults = await memSvc.search(context, query, filterType);
              searchMethod = 'keyword';
              items = kwResults.map((m): Record<string, string | number> => {
                let obj: Record<string, string | number> = {};
                obj['type'] = m.memType;
                obj['content'] = m.content;
                obj['created'] = new Date(m.createdAt).toLocaleDateString();
                return obj;
              });
            }
            return JSON.stringify({ query: query, found: items.length, method: searchMethod, items: items });
          } catch (e) {
            let r: ToolResultObj = { error: 'Search memory failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'create_scheduled_task': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          let prompt = input['prompt'] ?? '';
          let schedule = input['schedule'] ?? '';
          if (prompt.length === 0 || schedule.length === 0) {
            let r: ToolResultObj = { error: 'Both prompt and schedule are required' };
            return JSON.stringify(r);
          }
          let parsed = this.parseCronExpression(schedule);
          if (parsed.error.length > 0) {
            let r: ToolResultObj = { error: parsed.error };
            return JSON.stringify(r);
          }
          let taskId = `cron_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
          let task: CronTask = {
            id: taskId,
            prompt: prompt,
            cronExpr: schedule,
            intervalMs: parsed.intervalMs,
            nextRunTime: parsed.nextRunTime,
            lastRunTime: 0,
            enabled: true,
            oneShot: parsed.oneShot
          };
          try {
            let store = await preferences.getPreferences(context, Constants.PREFS_CRON);
            let raw = (await store.get('tasks', '[]')) as string;
            let tasks = JSON.parse(raw) as CronTask[];
            tasks.push(task);
            await store.put('tasks', JSON.stringify(tasks));
            await store.flush();
            this.log.info(this.TAG, `Cron task created: id=${taskId} schedule=${schedule} nextRun=${new Date(parsed.nextRunTime).toISOString()}`);
            return JSON.stringify({
              created: true,
              id: taskId,
              schedule: schedule,
              oneShot: parsed.oneShot,
              nextRunTime: new Date(parsed.nextRunTime).toISOString()
            });
          } catch (e) {
            let r: ToolResultObj = { error: 'Failed to save task: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'list_scheduled_tasks': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          try {
            let store = await preferences.getPreferences(context, Constants.PREFS_CRON);
            let raw = (await store.get('tasks', '[]')) as string;
            let tasks = JSON.parse(raw) as CronTask[];
            let active = tasks.filter((t: CronTask): boolean => t.enabled);
            if (active.length === 0) {
              return JSON.stringify({ count: 0, message: 'No active scheduled tasks' });
            }
            interface TaskSummary {
              id: string;
              prompt: string;
              schedule: string;
              nextRun: string;
              oneShot: boolean;
            }
            let summaries: TaskSummary[] = active.map((t: CronTask): TaskSummary => {
              let s: TaskSummary = {
                id: t.id,
                prompt: t.prompt.length > 80 ? t.prompt.substring(0, 80) + '...' : t.prompt,
                schedule: t.cronExpr,
                nextRun: new Date(t.nextRunTime).toISOString(),
                oneShot: t.oneShot
              };
              return s;
            });
            return JSON.stringify({ count: active.length, tasks: summaries });
          } catch (e) {
            let r: ToolResultObj = { error: 'Failed to load tasks: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'cancel_scheduled_task': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          let cancelId = input['task_id'] ?? '';
          if (cancelId.length === 0) {
            let r: ToolResultObj = { error: 'task_id is required' };
            return JSON.stringify(r);
          }
          try {
            let store = await preferences.getPreferences(context, Constants.PREFS_CRON);
            let raw = (await store.get('tasks', '[]')) as string;
            let tasks = JSON.parse(raw) as CronTask[];
            let found = false;
            let remaining: CronTask[] = [];
            for (let t of tasks) {
              if (t.id === cancelId) {
                found = true;
              } else {
                remaining.push(t);
              }
            }
            if (!found) {
              let r: ToolResultObj = { error: 'Task not found: ' + cancelId };
              return JSON.stringify(r);
            }
            await store.put('tasks', JSON.stringify(remaining));
            await store.flush();
            this.log.info(this.TAG, `Cron task cancelled: ${cancelId}`);
            return JSON.stringify({ cancelled: true, id: cancelId });
          } catch (e) {
            let r: ToolResultObj = { error: 'Failed to cancel task: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'list_emails': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          try {
            let emailConfig = await this.loadEmailConfig(context);
            if (!emailConfig.host || emailConfig.host.length === 0) {
              let r: ToolResultObj = { error: 'Email not configured. Please set up IMAP in Settings.' };
              return JSON.stringify(r);
            }
            let countStr = input['count'] ?? '10';
            let count = parseInt(countStr) || 10;
            if (count > 30) count = 30;
            let imap = new ImapService();
            await imap.connect(emailConfig.host, emailConfig.port);
            await imap.login(emailConfig.user, emailConfig.pass);
            await imap.selectMailbox('INBOX');
            let emails: EmailSummary[] = await imap.fetchRecentEmails(count);
            await imap.logout();
            interface EmailListResult {
              count: number;
              emails: EmailSummary[];
            }
            let result: EmailListResult = { count: emails.length, emails: emails };
            return JSON.stringify(result);
          } catch (e) {
            let r: ToolResultObj = { error: 'List emails failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'read_email': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          try {
            let emailConfig = await this.loadEmailConfig(context);
            if (!emailConfig.host || emailConfig.host.length === 0) {
              let r: ToolResultObj = { error: 'Email not configured. Please set up IMAP in Settings.' };
              return JSON.stringify(r);
            }
            let idStr = input['id'] ?? '';
            let seq = parseInt(idStr);
            if (isNaN(seq) || seq <= 0) {
              let r: ToolResultObj = { error: 'Invalid email id (sequence number)' };
              return JSON.stringify(r);
            }
            let imap = new ImapService();
            await imap.connect(emailConfig.host, emailConfig.port);
            await imap.login(emailConfig.user, emailConfig.pass);
            await imap.selectMailbox('INBOX');
            let email: EmailBody = await imap.fetchEmailBody(seq);
            await imap.logout();
            return JSON.stringify(email);
          } catch (e) {
            let r: ToolResultObj = { error: 'Read email failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'search_emails': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          try {
            let emailConfig = await this.loadEmailConfig(context);
            if (!emailConfig.host || emailConfig.host.length === 0) {
              let r: ToolResultObj = { error: 'Email not configured. Please set up IMAP in Settings.' };
              return JSON.stringify(r);
            }
            let query = input['query'] ?? '';
            if (query.length === 0) {
              let r: ToolResultObj = { error: 'No query provided' };
              return JSON.stringify(r);
            }
            let imap = new ImapService();
            await imap.connect(emailConfig.host, emailConfig.port);
            await imap.login(emailConfig.user, emailConfig.pass);
            await imap.selectMailbox('INBOX');
            let seqNums = await imap.searchEmails(query);
            // Fetch summaries for found messages (up to 20)
            let emails: EmailSummary[] = [];
            if (seqNums.length > 0) {
              let fetchIds = seqNums.slice(-20); // last 20
              for (let seq of fetchIds) {
                try {
                  // Use FETCH for individual messages
                  let summaries = await imap.fetchRecentEmails(1);
                  // Actually, we need individual fetch - use fetchEmailBody but only grab envelope
                  let body = await imap.fetchEmailBody(seq);
                  let summary: EmailSummary = {
                    seq: body.seq,
                    from: body.from,
                    subject: body.subject,
                    date: body.date
                  };
                  emails.push(summary);
                } catch { /* skip individual failures */ }
              }
            }
            await imap.logout();
            return JSON.stringify({ query: query, found: seqNums.length, emails: emails });
          } catch (e) {
            let r: ToolResultObj = { error: 'Search emails failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'send_email': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          try {
            let emailCap = new EmailCapability();
            emailCap.setContext(context);
            let paramsJson = JSON.stringify({
              to: input['to'] ?? '',
              subject: input['subject'] ?? '',
              body: input['body'] ?? '',
              cc: input['cc'] ?? '',
              bcc: input['bcc'] ?? ''
            });
            let result = await emailCap.execute(paramsJson);
            return result;
          } catch (e) {
            let r: ToolResultObj = { error: 'Send email failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'create_skill': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          let skillName = input['name'] ?? '';
          let skillDesc = input['description'] ?? '';
          let skillPrompt = input['prompt'] ?? '';
          if (skillName.length === 0 || skillPrompt.length === 0) {
            let r: ToolResultObj = { error: 'name and prompt are required' };
            return JSON.stringify(r);
          }
          try {
            let svc = CustomSkillService.getInstance();
            let createInput: CreateSkillInput = { name: skillName, description: skillDesc, prompt: skillPrompt };
            let skill: CustomSkillDef = await svc.create(context, createInput);
            return JSON.stringify({ created: true, id: skill.id, name: skill.name });
          } catch (e) {
            let r: ToolResultObj = { error: 'Create skill failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'list_custom_skills': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          try {
            let svc = CustomSkillService.getInstance();
            let skills: CustomSkillDef[] = await svc.loadAll(context);
            if (skills.length === 0) {
              return JSON.stringify({ count: 0, message: 'No custom skills yet' });
            }
            interface SkillSummary { id: string; name: string; description: string; enabled: boolean; }
            let summaries: SkillSummary[] = skills.map((s: CustomSkillDef): SkillSummary => {
              let summary: SkillSummary = {
                id: s.id,
                name: s.name,
                description: s.description,
                enabled: s.enabled
              };
              return summary;
            });
            return JSON.stringify({ count: skills.length, skills: summaries });
          } catch (e) {
            let r: ToolResultObj = { error: 'List skills failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'update_skill': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          let updateId = input['id'] ?? '';
          if (updateId.length === 0) {
            let r: ToolResultObj = { error: 'id is required' };
            return JSON.stringify(r);
          }
          try {
            let svc = CustomSkillService.getInstance();
            let updateInput: UpdateSkillInput = { id: updateId };
            if (input['name'] && input['name'].length > 0) updateInput.name = input['name'];
            if (input['description'] && input['description'].length > 0) updateInput.description = input['description'];
            if (input['prompt'] && input['prompt'].length > 0) updateInput.prompt = input['prompt'];
            if (input['enabled'] && input['enabled'].length > 0) updateInput.enabled = input['enabled'] === 'true';
            let skill: CustomSkillDef = await svc.update(context, updateInput);
            return JSON.stringify({ updated: true, id: skill.id, name: skill.name });
          } catch (e) {
            let r: ToolResultObj = { error: 'Update skill failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
        }
        case 'delete_skill': {
          if (!context) {
            let r: ToolResultObj = { error: 'No UI context available' };
            return JSON.stringify(r);
          }
          let deleteId = input['id'] ?? '';
          if (deleteId.length === 0) {
            let r: ToolResultObj = { error: 'id is required' };
            return JSON.stringify(r);
          }
          try {
            let svc = CustomSkillService.getInstance();
            await svc.delete(context, deleteId);
            return JSON.stringify({ deleted: true, id: deleteId });
          } catch (e) {
            let r: ToolResultObj = { error: 'Delete skill failed: ' + (e as Error).message };
            return JSON.stringify(r);
          }
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

  // --------- image tool result: save base64 to file, return summary for model ---------

  private saveImageToolResult(toolOutput: string, toolName: string, context?: common.UIAbilityContext): ImageSaveResult {
    let empty: ImageSaveResult = { path: '', summary: toolOutput };
    try {
      let parsed = JSON.parse(toolOutput) as Record<string, Object>;
      let base64Str = parsed['base64'] as string;
      if (!base64Str || base64Str.length === 0) return empty;

      let dir = (context?.filesDir ?? '') + '/screenshots';
      try { fileIo.mkdirSync(dir); } catch { /* may exist */ }
      let filePath = `${dir}/${toolName}_${Date.now()}.jpg`;

      let decoded = buffer.from(base64Str, 'base64');
      let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, decoded.buffer);
      fileIo.closeSync(file);

      let width = parsed['width'] ?? '';
      let height = parsed['height'] ?? '';
      let size = parsed['size'] ?? decoded.length;
      let summary = `{"ok":true,"format":"jpeg","width":${width},"height":${height},"size":${size},"note":"Screenshot saved and displayed to user"}`;
      this.log.info(this.TAG, `saveImageToolResult: saved ${filePath} (${decoded.length} bytes)`);
      let result: ImageSaveResult = { path: filePath, summary: summary };
      return result;
    } catch (e) {
      this.log.error(this.TAG, `saveImageToolResult failed: ${(e as Error).message}`);
      return empty;
    }
  }

  private async getIntentMode(context: Context): Promise<string> {
    try {
      let store = await preferences.getPreferences(context, Constants.PREFS_SETTINGS);
      return (await store.get('intent_mode', 'auto')) as string;
    } catch {
      return 'auto';
    }
  }

  // --------- auto-dispatch: detect user intent when model fails to call tools ---------
  private detectAutoDispatch(history: ChatMessage[], modelText: string): AutoDispatchResult {
    let empty: AutoDispatchResult = { tool: '', input: '{}' };

    // Find the last user message
    let lastUserMsg = '';
    for (let i = history.length - 1; i >= 0; i--) {
      if (history[i].role === 'user' && history[i].content.length > 0) {
        lastUserMsg = history[i].content.toLowerCase();
        break;
      }
    }
    if (lastUserMsg.length === 0) return empty;

    // Location keywords
    let locationKeywords = ['我在哪', '在哪里', '我的位置', '当前位置', '定位', '经纬度', '坐标',
      'where am i', 'my location', 'current location', 'gps', 'coordinates'];
    for (let kw of locationKeywords) {
      if (lastUserMsg.includes(kw)) {
        return { tool: 'get_location', input: '{}' };
      }
    }

    // Webpage keywords — extract URL from model response or user message
    let webKeywords = ['打开网页', '打开网站', '帮我打开', '打开一下', '浏览', '访问网站',
      'open website', 'open webpage', 'open the page', 'browse to', 'visit'];
    let hasWebIntent = false;
    for (let kw of webKeywords) {
      if (lastUserMsg.includes(kw)) {
        hasWebIntent = true;
        break;
      }
    }
    // Also check if user message starts with "打开" + a site name
    if (!hasWebIntent && lastUserMsg.startsWith('打开')) {
      hasWebIntent = true;
    }
    if (hasWebIntent) {
      // Try to extract URL from model text or user message
      let url = this.extractUrl(modelText) || this.extractUrl(lastUserMsg);
      if (url.length > 0) {
        return { tool: 'open_webpage', input: JSON.stringify({ url: url }) };
      }
      // Try common site name mapping from user message
      let siteUrl = this.mapSiteName(lastUserMsg);
      if (siteUrl.length > 0) {
        return { tool: 'open_webpage', input: JSON.stringify({ url: siteUrl }) };
      }
    }

    // Screenshot keywords
    let screenKeywords = ['截屏', '截图', '屏幕截图', '截个屏', '截个图', '拍屏幕', '屏幕快照',
      'screenshot', 'screen capture', 'take a screenshot', 'capture screen'];
    for (let kw of screenKeywords) {
      if (lastUserMsg.includes(kw)) {
        return { tool: 'screen_capture', input: '{}' };
      }
    }

    // Send email keywords (check before list)
    let sendEmailKeywords = ['发邮件', '写邮件', '发送邮件', '发一封', 'send email', 'send mail', 'compose email'];
    for (let kw of sendEmailKeywords) {
      if (lastUserMsg.includes(kw)) {
        return empty; // Let model handle send_email with proper params
      }
    }

    // Email keywords (read/list)
    let emailKeywords = ['邮件', '邮箱', '收件箱', '未读邮件', '新邮件', '查邮件', '看邮件',
      'email', 'inbox', 'mail', 'unread', 'check email', 'read email', 'list email'];
    for (let kw of emailKeywords) {
      if (lastUserMsg.includes(kw)) {
        return { tool: 'list_emails', input: '{"count":"10"}' };
      }
    }

    // Camera keywords
    let cameraKeywords = ['拍照', '拍张照', '照相', '拍个照', '自拍', '拍一张',
      'take photo', 'take a photo', 'capture photo', 'take picture', 'take a picture', 'selfie'];
    for (let kw of cameraKeywords) {
      if (lastUserMsg.includes(kw)) {
        let cam = lastUserMsg.includes('前置') || lastUserMsg.includes('自拍') ||
          lastUserMsg.includes('front') || lastUserMsg.includes('selfie') ? 'front' : 'back';
        return { tool: 'capture_photo', input: JSON.stringify({ camera: cam }) };
      }
    }

    // Close webpage keywords
    let closeWebKeywords = ['关闭网页', '关掉网页', '关闭页面', '关掉页面',
      'close webpage', 'close the page', 'close website', 'hide webpage'];
    for (let kw of closeWebKeywords) {
      if (lastUserMsg.includes(kw)) {
        return { tool: 'close_webpage', input: '{}' };
      }
    }

    // Record audio keywords
    let recordKeywords = ['录音', '录一段', '录个音', '录制', '录5秒', '录10秒',
      'record audio', 'record sound', 'start recording'];
    for (let kw of recordKeywords) {
      if (lastUserMsg.includes(kw)) {
        let seconds = '5';
        let secMatch = /(\d+)\s*[秒s]/i.exec(lastUserMsg);
        if (secMatch) seconds = secMatch[1];
        return { tool: 'record_audio', input: JSON.stringify({ seconds: seconds }) };
      }
    }

    // Smart device keywords
    let deviceKeywords = ['设备列表', '智能设备', '智能家居', '家电',
      'list devices', 'smart devices', 'smart home', 'iot devices'];
    for (let kw of deviceKeywords) {
      if (lastUserMsg.includes(kw)) {
        return { tool: 'list_devices', input: '{}' };
      }
    }

    // Calendar keywords — create event with best-effort time parsing
    let calendarKeywords = ['开会', '会议', '日程', '创建日历', '添加日历', '日历事件',
      'create event', 'add event', 'schedule meeting', 'add to calendar'];
    for (let kw of calendarKeywords) {
      if (lastUserMsg.includes(kw)) {
        let title = lastUserMsg;
        // Extract start time — best effort
        let start = new Date();
        if (lastUserMsg.includes('明天')) {
          start.setDate(start.getDate() + 1);
        } else if (lastUserMsg.includes('后天')) {
          start.setDate(start.getDate() + 2);
        }
        let hourMatch = /(\d{1,2})\s*[点时:：]/i.exec(lastUserMsg);
        if (hourMatch) {
          let h = parseInt(hourMatch[1]);
          if (lastUserMsg.includes('下午') || lastUserMsg.includes('晚上')) {
            if (h < 12) h += 12;
          }
          start.setHours(h, 0, 0, 0);
        } else {
          // Default: next hour
          start.setHours(start.getHours() + 1, 0, 0, 0);
        }
        let end = new Date(start.getTime() + 60 * 60 * 1000);
        return {
          tool: 'create_event',
          input: JSON.stringify({ title: title, start: start.toISOString(), end: end.toISOString() })
        };
      }
    }

    return empty;
  }

  private extractUrl(text: string): string {
    let match = /https?:\/\/[^\s"'<>\]）》]+/i.exec(text);
    if (match) return match[0];
    // Also match www. without protocol
    let wwwMatch = /www\.[^\s"'<>\]）》]+/i.exec(text);
    if (wwwMatch) return 'https://' + wwwMatch[0];
    return '';
  }

  private mapSiteName(text: string): string {
    let sites: Record<string, string> = {
      '百度': 'https://www.baidu.com',
      'baidu': 'https://www.baidu.com',
      '谷歌': 'https://www.google.com',
      'google': 'https://www.google.com',
      '微博': 'https://m.weibo.cn',
      'weibo': 'https://m.weibo.cn',
      '知乎': 'https://www.zhihu.com',
      'zhihu': 'https://www.zhihu.com',
      'github': 'https://github.com',
      '淘宝': 'https://m.taobao.com',
      '京东': 'https://m.jd.com',
      'bilibili': 'https://m.bilibili.com',
      'b站': 'https://m.bilibili.com',
      'youtube': 'https://m.youtube.com',
      'twitter': 'https://x.com',
      'reddit': 'https://www.reddit.com',
    };
    let lower = text.toLowerCase();
    let keys = Object.keys(sites);
    for (let key of keys) {
      if (lower.includes(key)) {
        return sites[key];
      }
    }
    return '';
  }

  // --------- email config helper ---------
  private async loadEmailConfig(context: common.UIAbilityContext): Promise<EmailConfig> {
    let store = await preferences.getPreferences(context, Constants.PREFS_EMAIL);
    let config: EmailConfig = {
      host: (await store.get('imapHost', '')) as string,
      port: parseInt((await store.get('imapPort', '993')) as string) || 993,
      user: (await store.get('imapUser', '')) as string,
      pass: (await store.get('imapPass', '')) as string,
    };
    return config;
  }

  // --------- cron expression parser ---------
  parseCronExpression(expr: string): CronParseResult {
    let result: CronParseResult = { intervalMs: 0, nextRunTime: 0, oneShot: false, error: '' };
    let trimmed = expr.trim().toLowerCase();
    let now = Date.now();

    // Pattern: "every Xm" or "every X minutes"
    let minMatch = /^every\s+(\d+)\s*m(?:in(?:ute)?s?)?$/i.exec(trimmed);
    if (minMatch) {
      let mins = parseInt(minMatch[1]);
      if (mins <= 0 || mins > 1440) {
        result.error = 'Minutes must be between 1 and 1440';
        return result;
      }
      result.intervalMs = mins * 60 * 1000;
      result.nextRunTime = now + result.intervalMs;
      result.oneShot = false;
      return result;
    }

    // Pattern: "every Xh" or "every X hours"
    let hourMatch = /^every\s+(\d+)\s*h(?:ours?)?$/i.exec(trimmed);
    if (hourMatch) {
      let hours = parseInt(hourMatch[1]);
      if (hours <= 0 || hours > 24) {
        result.error = 'Hours must be between 1 and 24';
        return result;
      }
      result.intervalMs = hours * 60 * 60 * 1000;
      result.nextRunTime = now + result.intervalMs;
      result.oneShot = false;
      return result;
    }

    // Pattern: "daily HH:MM"
    let dailyMatch = /^daily\s+(\d{1,2}):(\d{2})$/i.exec(trimmed);
    if (dailyMatch) {
      let hour = parseInt(dailyMatch[1]);
      let minute = parseInt(dailyMatch[2]);
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        result.error = 'Invalid time format (HH:MM, 00:00-23:59)';
        return result;
      }
      result.intervalMs = 24 * 60 * 60 * 1000; // 24 hours
      let today = new Date();
      today.setHours(hour, minute, 0, 0);
      let targetMs = today.getTime();
      if (targetMs <= now) {
        targetMs += result.intervalMs; // next day
      }
      result.nextRunTime = targetMs;
      result.oneShot = false;
      return result;
    }

    // Pattern: ISO 8601 datetime (one-shot)
    try {
      let isoMs = new Date(expr.trim()).getTime();
      if (!isNaN(isoMs) && isoMs > now) {
        result.intervalMs = 0;
        result.nextRunTime = isoMs;
        result.oneShot = true;
        return result;
      } else if (!isNaN(isoMs) && isoMs <= now) {
        result.error = 'Scheduled time is in the past';
        return result;
      }
    } catch { /* not ISO format */ }

    result.error = `Unsupported schedule format: "${expr}". Use "every 30m", "every 2h", "daily 09:00", or ISO 8601 datetime.`;
    return result;
  }

  // --------- message conversion ---------
  private buildApiMessages(history: ChatMessage[]): ApiMessage[] {
    let out: ApiMessage[] = [];
    for (let msg of history) {
      if (msg.role === 'user') {
        let apiMsg: ApiMessage = { role: 'user', content: msg.content };
        // Attach image base64 if user sent an image
        if (msg.userImagePath.length > 0) {
          try {
            let imgFile = fileIo.openSync(msg.userImagePath, fileIo.OpenMode.READ_ONLY);
            let imgStat = fileIo.statSync(imgFile.fd);
            let imgBuf = new ArrayBuffer(imgStat.size);
            fileIo.readSync(imgFile.fd, imgBuf);
            fileIo.closeSync(imgFile);
            let b64 = buffer.from(imgBuf).toString('base64');
            apiMsg.imageBase64 = b64;
          } catch (e) {
            this.log.warn(this.TAG, `Failed to read user image: ${(e as Error).message ?? ''}`);
          }
        }
        out.push(apiMsg);
      } else if (msg.role === 'assistant' && !msg.isToolCall && msg.content.length > 0) {
        out.push({ role: 'assistant', content: msg.content });
      }
    }

    // Trim old messages to avoid exceeding token limits
    // Rough estimate: 1 token ≈ 3 chars (conservative for Chinese)
    const MAX_CHARS = 60000; // ~20k tokens, leaving room for system prompt + tools
    let totalChars = 0;
    for (let m of out) {
      totalChars += m.content.length;
    }
    while (totalChars > MAX_CHARS && out.length > 4) {
      let removed = out.splice(0, 1);
      totalChars -= removed[0].content.length;
    }
    // Ensure first message is from user (required by Anthropic API)
    while (out.length > 0 && out[0].role !== 'user') {
      let removed = out.splice(0, 1);
      totalChars -= removed[0].content.length;
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

// SSE streaming types
interface StreamChunk {
  choices: StreamChoice[];
}

interface StreamChoice {
  delta?: StreamDelta;
  finish_reason?: string;
}

interface StreamDelta {
  content?: string;
  tool_calls?: StreamDeltaToolCall[];
}

interface StreamDeltaToolCall {
  index?: number;
  id?: string;
  function?: StreamDeltaFunc;
}

interface StreamDeltaFunc {
  name?: string;
  arguments?: string;
}

interface StreamToolCallAccum {
  id: string;
  name: string;
  args: string;
}
