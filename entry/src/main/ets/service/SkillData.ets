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
  // always add memory tools
  let memDefs = TOOL_SCHEMAS.get('skill_memory');
  if (memDefs) {
    for (let d of memDefs) {
      schemas.push(d);
    }
  }
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
    new SkillItem('skill_scheduler', 'Scheduler',
      'Create and manage scheduled/recurring tasks',
      'automation', true, true, 3),
    new SkillItem('skill_email', 'Email',
      'Read emails from inbox via IMAP',
      'productivity', true, true, 3),
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
  ['skill_scheduler',
    'You can create, list, and cancel scheduled tasks. Tasks can be one-shot (run once at a specific time) or recurring (run periodically). Schedule formats: "every 30m", "every 2h", "daily 09:00", or ISO 8601 datetime for one-shot. When the user says things like "remind me every 30 minutes to drink water" or "check the weather every morning at 9", use create_scheduled_task.'],
  ['skill_email',
    'You have access to the user\'s email inbox via IMAP. When the user mentions 邮件/邮箱/email/inbox/mail, use these email tools:\n- list_emails: list recent emails (NOT calendar events)\n- read_email: read email body by sequence number\n- search_emails: search emails by subject\nIMPORTANT: Do NOT use list_events for email requests. list_events is for calendar only.'],
]);

function buildSystemToolSchemas(): ToolSchema[] {
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

function buildMemoryToolSchemas(): ToolSchema[] {
  let saveProps: Record<string, JsonSchemaProperty> = {};
  saveProps['mem_type'] = { type: 'string', description: 'Category: fact | preference | instruction' };
  saveProps['content'] = { type: 'string', description: 'The information to remember' };

  let searchProps: Record<string, JsonSchemaProperty> = {};
  searchProps['query'] = { type: 'string', description: 'Search keywords (space-separated, matches any keyword)' };
  searchProps['mem_type'] = { type: 'string', description: 'Optional filter: fact | preference | instruction' };

  return [
    makeTool('save_memory',
      'Save important information to persistent memory. Use this when the user shares personal facts, preferences, or instructions they want you to remember across conversations.',
      makeSchema(saveProps, ['mem_type', 'content'])),
    makeTool('search_memory',
      'Search saved memories using semantic similarity. Can find related memories even when exact keywords don\'t match. For example, searching "drink preference" can find "I like coffee".',
      makeSchema(searchProps, ['query'])),
  ];
}

function buildSchedulerToolSchemas(): ToolSchema[] {
  let createProps: Record<string, JsonSchemaProperty> = {};
  createProps['prompt'] = { type: 'string', description: 'The AI prompt to execute when the task triggers' };
  createProps['schedule'] = { type: 'string', description: 'Schedule expression: "every 30m", "every 2h", "daily 09:00", or ISO 8601 datetime for one-shot (e.g. "2026-02-12T14:00:00")' };

  let emptyProps: Record<string, JsonSchemaProperty> = {};

  let cancelProps: Record<string, JsonSchemaProperty> = {};
  cancelProps['task_id'] = { type: 'string', description: 'The ID of the scheduled task to cancel' };

  return [
    makeTool('create_scheduled_task', 'Create a scheduled or recurring task that automatically runs an AI prompt at specified times',
      makeSchema(createProps, ['prompt', 'schedule'])),
    makeTool('list_scheduled_tasks', 'List all active scheduled tasks',
      makeSchema(emptyProps)),
    makeTool('cancel_scheduled_task', 'Cancel a scheduled task by its ID',
      makeSchema(cancelProps, ['task_id'])),
  ];
}

function buildEmailToolSchemas(): ToolSchema[] {
  let listProps: Record<string, JsonSchemaProperty> = {};
  listProps['count'] = { type: 'number', description: 'Number of recent emails to fetch (default 10, max 30)' };

  let readProps: Record<string, JsonSchemaProperty> = {};
  readProps['id'] = { type: 'string', description: 'Email sequence number (from list_emails result)' };

  let searchProps: Record<string, JsonSchemaProperty> = {};
  searchProps['query'] = { type: 'string', description: 'Search keyword (matches subject)' };

  return [
    makeTool('list_emails', 'List recent emails from the user email inbox (IMAP). Use this when user asks about 邮件/邮箱/email/mail. Returns sender, subject, and date.',
      makeSchema(listProps)),
    makeTool('read_email', 'Read the full body of a specific email by its sequence number.',
      makeSchema(readProps, ['id'])),
    makeTool('search_emails', 'Search emails by subject keyword. Returns matching email summaries.',
      makeSchema(searchProps, ['query'])),
  ];
}

const TOOL_SCHEMAS: Map<string, ToolSchema[]> = new Map([
  ['skill_system', buildSystemToolSchemas()],
  ['skill_web', buildWebToolSchemas()],
  ['skill_smart_home', buildSmartHomeToolSchemas()],
  ['skill_calendar', buildCalendarToolSchemas()],
  ['skill_media', buildMediaToolSchemas()],
  ['skill_memory', buildMemoryToolSchemas()],
  ['skill_scheduler', buildSchedulerToolSchemas()],
  ['skill_email', buildEmailToolSchemas()],
]);
