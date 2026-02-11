import { SkillItem, ToolSchema } from '../model/Models';

/**
 * Static skill catalogue + tool schema definitions.
 * In ClawdBot these are dynamically loaded plugins; here we ship built-in
 * skills and let users toggle them on/off.
 */

// ---------- JSON Schema helper interfaces for ArkTS ----------
interface JsonSchemaProperty {
  type: string;
  description?: string;
}

interface JsonSchemaObj {
  type: string;
  properties: Record<string, JsonSchemaProperty>;
  required?: string[];
}

// ---------- tool schemas sent to the LLM ----------

export function getEnabledToolSchemas(skills: SkillItem[]): ToolSchema[] {
  let schemas: ToolSchema[] = [];
  for (let skill of skills) {
    if (!skill.enabled) continue;
    let defs = TOOL_SCHEMAS.get(skill.id);
    if (defs) {
      for (let d of defs) {
        schemas.push(d);
      }
    }
  }
  // always add save_memory
  let memProps: Record<string, JsonSchemaProperty> = {};
  memProps['mem_type'] = { type: 'string', description: 'fact | preference | instruction' };
  memProps['content'] = { type: 'string', description: 'What to remember' };
  let memSchema: JsonSchemaObj = {
    type: 'object',
    properties: memProps,
    required: ['mem_type', 'content']
  };
  let saveMem: ToolSchema = {
    name: 'save_memory',
    description: 'Save important information to persistent memory (facts, preferences, instructions)',
    input_schema: memSchema
  };
  schemas.push(saveMem);
  return schemas;
}

export function getSkillSystemPrompt(skills: SkillItem[]): string {
  let parts: string[] = [];
  for (let skill of skills) {
    if (!skill.enabled) continue;
    let prompt = SKILL_PROMPTS.get(skill.id);
    if (prompt) parts.push(prompt);
  }
  return parts.join('\n');
}

// ---------- catalogue ----------

export function getDefaultSkills(): SkillItem[] {
  return [
    new SkillItem('skill_system', 'System Tools',
      'File access, search, command execution, location, and device operations',
      'automation', true, true, 7),
    new SkillItem('skill_web', 'Web Search',
      'Search the web and fetch page contents',
      'productivity', true, true, 2),
    new SkillItem('skill_smart_home', 'Smart Home',
      'Control HarmonyOS-connected IoT devices',
      'smart_home', true, true, 2),
    new SkillItem('skill_calendar', 'Calendar & Reminders',
      'Manage events and set reminders',
      'productivity', true, true, 3),
    new SkillItem('skill_media', 'Media Tools',
      'Capture photos, record audio',
      'media', true, true, 2),
  ];
}

// ---------- private helper ----------
function makeSchema(props: Record<string, JsonSchemaProperty>, required?: string[]): JsonSchemaObj {
  let schema: JsonSchemaObj = {
    type: 'object',
    properties: props,
  };
  if (required && required.length > 0) {
    schema.required = required;
  }
  return schema;
}

function makeTool(name: string, description: string, schema: JsonSchemaObj): ToolSchema {
  let tool: ToolSchema = { name: name, description: description, input_schema: schema };
  return tool;
}

// ---------- private data ----------

const SKILL_PROMPTS: Map<string, string> = new Map([
  ['skill_system',
    'You can execute commands, manage files, and get device location via system tools. This is a HarmonyOS device. File paths are sandbox-based — use list_files with empty path first to discover available directories. Do NOT use Linux paths like /home/. You can get the user\'s current GPS location using get_location.'],
  ['skill_web',
    'You can search the web and fetch page contents for up-to-date information.'],
  ['skill_smart_home',
    'You can list and control smart home devices connected via HarmonyOS distributed capabilities.'],
  ['skill_calendar',
    'You can list calendar events, create events, and set reminders.'],
  ['skill_media',
    'You can capture photos and record audio on the device.'],
]);

function buildSystemToolSchemas(): ToolSchema[] {
  let commandProps: Record<string, JsonSchemaProperty> = {};
  commandProps['command'] = { type: 'string', description: 'The command to run' };

  let pathProps: Record<string, JsonSchemaProperty> = {};
  pathProps['path'] = { type: 'string', description: 'Absolute file path' };

  let writeProps: Record<string, JsonSchemaProperty> = {};
  writeProps['path'] = { type: 'string', description: 'File path' };
  writeProps['content'] = { type: 'string', description: 'Content to write' };

  let listProps: Record<string, JsonSchemaProperty> = {};
  listProps['path'] = { type: 'string', description: 'Directory path. Leave empty to list the app sandbox root directory.' };

  let searchProps: Record<string, JsonSchemaProperty> = {};
  searchProps['path'] = { type: 'string', description: 'Directory to search in. Defaults to app sandbox filesDir if empty.' };
  searchProps['pattern'] = { type: 'string', description: 'Filename pattern to match (case-insensitive substring match). e.g. ".txt", "config"' };
  searchProps['content'] = { type: 'string', description: 'Text content to search inside files (exact match). Only searches files < 256KB.' };

  let pickProps: Record<string, JsonSchemaProperty> = {};
  pickProps['purpose'] = { type: 'string', description: 'Brief reason for picking a file (shown to user)' };

  let locationProps: Record<string, JsonSchemaProperty> = {};

  return [
    makeTool('execute_command', 'Execute a shell command on the device (sandboxed)',
      makeSchema(commandProps, ['command'])),
    makeTool('read_file', 'Read the text contents of a file (sandbox only)',
      makeSchema(pathProps, ['path'])),
    makeTool('write_file', 'Write text content to a file (sandbox only)',
      makeSchema(writeProps, ['path', 'content'])),
    makeTool('list_files', 'List files in a directory. Defaults to the app sandbox root if path is empty. This is a HarmonyOS device — use sandbox paths returned by this tool, NOT Linux paths.',
      makeSchema(listProps)),
    makeTool('search_files', 'Search for files recursively by filename pattern and/or content. Searches up to 5 levels deep, max 50 results. Defaults to app sandbox if path is empty.',
      makeSchema(searchProps)),
    makeTool('pick_file', 'Open system file picker for user to select a file. Returns the file content. Use this to access files outside the app sandbox.',
      makeSchema(pickProps)),
    makeTool('get_location', 'Get the device current GPS location (latitude, longitude, accuracy). Use this when the user asks where they are or needs location info.',
      makeSchema(locationProps)),
  ];
}

function buildWebToolSchemas(): ToolSchema[] {
  let searchProps: Record<string, JsonSchemaProperty> = {};
  searchProps['query'] = { type: 'string', description: 'Search query' };

  let fetchProps: Record<string, JsonSchemaProperty> = {};
  fetchProps['url'] = { type: 'string', description: 'URL to fetch' };

  return [
    makeTool('web_search', 'Search the web', makeSchema(searchProps, ['query'])),
    makeTool('web_fetch', 'Fetch and extract content from a URL', makeSchema(fetchProps, ['url'])),
  ];
}

function buildSmartHomeToolSchemas(): ToolSchema[] {
  let emptyProps: Record<string, JsonSchemaProperty> = {};
  let actionProps: Record<string, JsonSchemaProperty> = {};
  actionProps['device_id'] = { type: 'string', description: 'Device ID' };
  actionProps['action'] = { type: 'string', description: 'on / off / set' };
  actionProps['params'] = { type: 'string', description: 'JSON params' };

  return [
    makeTool('list_devices', 'List discoverable smart home devices', makeSchema(emptyProps)),
    makeTool('device_action', 'Send an action to a smart home device',
      makeSchema(actionProps, ['device_id', 'action'])),
  ];
}

function buildCalendarToolSchemas(): ToolSchema[] {
  let daysProps: Record<string, JsonSchemaProperty> = {};
  daysProps['days'] = { type: 'number', description: 'Days ahead' };

  let eventProps: Record<string, JsonSchemaProperty> = {};
  eventProps['title'] = { type: 'string' };
  eventProps['start'] = { type: 'string', description: 'ISO 8601' };
  eventProps['end'] = { type: 'string', description: 'ISO 8601' };

  let reminderProps: Record<string, JsonSchemaProperty> = {};
  reminderProps['message'] = { type: 'string' };
  reminderProps['time'] = { type: 'string', description: 'ISO 8601' };

  return [
    makeTool('list_events', 'List upcoming calendar events', makeSchema(daysProps)),
    makeTool('create_event', 'Create a calendar event',
      makeSchema(eventProps, ['title', 'start', 'end'])),
    makeTool('set_reminder', 'Set a timed reminder',
      makeSchema(reminderProps, ['message', 'time'])),
  ];
}

function buildMediaToolSchemas(): ToolSchema[] {
  let cameraProps: Record<string, JsonSchemaProperty> = {};
  cameraProps['camera'] = { type: 'string', description: 'front | back' };

  let audioProps: Record<string, JsonSchemaProperty> = {};
  audioProps['seconds'] = { type: 'number', description: 'Duration in seconds' };

  return [
    makeTool('capture_photo', 'Take a photo with the device camera', makeSchema(cameraProps)),
    makeTool('record_audio', 'Record audio from the microphone',
      makeSchema(audioProps, ['seconds'])),
  ];
}

const TOOL_SCHEMAS: Map<string, ToolSchema[]> = new Map([
  ['skill_system', buildSystemToolSchemas()],
  ['skill_web', buildWebToolSchemas()],
  ['skill_smart_home', buildSmartHomeToolSchemas()],
  ['skill_calendar', buildCalendarToolSchemas()],
  ['skill_media', buildMediaToolSchemas()],
]);
