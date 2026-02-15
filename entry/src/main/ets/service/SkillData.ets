import { SkillItem, ToolSchema, CustomSkillDef } from '../model/Models';

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
  // always add skill management tools
  let skillMgmtDefs = TOOL_SCHEMAS.get('skill_management');
  if (skillMgmtDefs) {
    for (let d of skillMgmtDefs) {
      schemas.push(d);
    }
  }
  return schemas;
}

export function getSkillSystemPrompt(skills: SkillItem[], customSkills?: CustomSkillDef[]): string {
  let parts: string[] = [];
  for (let skill of skills) {
    if (!skill.enabled) continue;
    let prompt = SKILL_PROMPTS.get(skill.id);
    if (prompt) parts.push(prompt);
  }
  // Append custom skill prompts
  if (customSkills && customSkills.length > 0) {
    let customParts: string[] = [];
    for (let cs of customSkills) {
      if (cs.enabled) {
        customParts.push(`[Custom Skill: ${cs.name}]\n${cs.prompt}`);
      }
    }
    if (customParts.length > 0) {
      parts.push('\n## Custom Skills\nThe user has created the following custom skills. When the user references a skill by name or describes a matching task, follow its prompt instructions.\n' + customParts.join('\n\n'));
    }
  }
  return parts.join('\n');
}

// ---------- filtered tool/prompt selection for intent classification ----------

/** Return tool schemas for specific skill IDs only (+ memory, always included). */
export function getToolSchemasForSkills(skillIds: string[]): ToolSchema[] {
  let schemas: ToolSchema[] = [];
  for (let id of skillIds) {
    let defs = TOOL_SCHEMAS.get(id);
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

/** Return skill system prompt for specific skill IDs only. */
export function getSkillSystemPromptForIds(skills: SkillItem[], skillIds: string[], customSkills?: CustomSkillDef[]): string {
  let parts: string[] = [];
  for (let skill of skills) {
    if (!skill.enabled) continue;
    if (!skillIds.includes(skill.id)) continue;
    let prompt = SKILL_PROMPTS.get(skill.id);
    if (prompt) parts.push(prompt);
  }
  if (customSkills && customSkills.length > 0) {
    let customParts: string[] = [];
    for (let cs of customSkills) {
      if (cs.enabled) {
        customParts.push(`[Custom Skill: ${cs.name}]\n${cs.prompt}`);
      }
    }
    if (customParts.length > 0) {
      parts.push('\n## Custom Skills\nThe user has created the following custom skills. When the user references a skill by name or describes a matching task, follow its prompt instructions.\n' + customParts.join('\n\n'));
    }
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
    'You can execute commands, manage files, get device location, and take screenshots via system tools. This is a HarmonyOS device. File paths are sandbox-based — use list_files with empty path first to discover available directories. Do NOT use Linux paths like /home/. You can get the user\'s current GPS location using get_location. You can take a screenshot of the app screen using screen_capture.'],
  ['skill_web',
    'You can search the web and fetch page contents. You have a full WebView browser on the device:\n- open_webpage: open a URL in full-screen WebView\n- navigate_webpage: go to a new URL in the open WebView\n- eval_webpage: run JavaScript (click buttons, fill forms, extract text via document.body.innerText, etc.)\n- snapshot_webpage: screenshot the current page (returns base64 JPEG)\n- close_webpage: close the WebView\nUse open_webpage when the user wants to browse. Use eval_webpage to interact with or extract content from the page. Use snapshot_webpage to see what the page looks like.'],
  ['skill_smart_home',
    'You can list and control smart home devices connected via HarmonyOS distributed capabilities.'],
  ['skill_calendar',
    'You can list calendar events, create events, and set reminders.'],
  ['skill_media',
    'You can capture photos and record audio on the device.'],
  ['skill_scheduler',
    'You can create, list, and cancel scheduled tasks. Tasks can be one-shot (run once at a specific time) or recurring (run periodically). Schedule formats: "every 30m", "every 2h", "daily 09:00", or ISO 8601 datetime for one-shot. When the user says things like "remind me every 30 minutes to drink water" or "check the weather every morning at 9", use create_scheduled_task.'],
  ['skill_email',
    'You have access to the user\'s email via IMAP and SMTP. When the user mentions 邮件/邮箱/email/inbox/mail, use these email tools:\n- list_emails: list recent emails (NOT calendar events)\n- read_email: read email body by sequence number\n- search_emails: search emails by subject\n- send_email: send an email (发邮件/写邮件)\nIMPORTANT: Do NOT use list_events for email requests. list_events is for calendar only.'],
  ['skill_management',
    'You can create, list, update, and delete custom skills for the user. A custom skill is a saved prompt workflow that tells you how to combine existing tools to accomplish a specific task.\nWhen creating a skill, write a detailed prompt that explains HOW to accomplish the task using existing tools (web_search, create_event, screen_capture, speaker.speak, etc). Be specific about the workflow steps.\nExample: A "Morning Briefing" skill prompt might be: "1. Use web_search to find today\'s weather for the user\'s location. 2. Use list_events with days=1 to get today\'s calendar events. 3. Compose a brief morning summary combining weather and schedule. 4. Return the summary to the user."\nWhen the user says 创建技能/create skill/添加技能, use create_skill. When they say 我的技能/list skills/技能列表, use list_custom_skills.'],
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
    makeTool('screen_capture', 'Take a screenshot of the current app screen and return it as a base64 JPEG image. Use this when the user asks you to take a screenshot (截屏/截图/screenshot).',
      makeSchema(locationProps)),
  ];
}

function buildWebToolSchemas(): ToolSchema[] {
  let searchProps: Record<string, JsonSchemaProperty> = {};
  searchProps['query'] = { type: 'string', description: 'Search query' };

  let fetchProps: Record<string, JsonSchemaProperty> = {};
  fetchProps['url'] = { type: 'string', description: 'URL to fetch' };

  let openProps: Record<string, JsonSchemaProperty> = {};
  openProps['url'] = { type: 'string', description: 'URL to open in the WebView' };

  let closeProps: Record<string, JsonSchemaProperty> = {};

  let navProps: Record<string, JsonSchemaProperty> = {};
  navProps['url'] = { type: 'string', description: 'New URL to navigate to in the already-open WebView' };

  let evalProps: Record<string, JsonSchemaProperty> = {};
  evalProps['javascript'] = { type: 'string', description: 'JavaScript code to execute in the WebView. Returns the evaluation result as a string.' };

  let snapProps: Record<string, JsonSchemaProperty> = {};
  snapProps['quality'] = { type: 'string', description: 'JPEG quality 1-100. Default 80.' };

  return [
    makeTool('web_search', 'Search the web', makeSchema(searchProps, ['query'])),
    makeTool('web_fetch', 'Fetch and extract content from a URL', makeSchema(fetchProps, ['url'])),
    makeTool('open_webpage', 'Open a URL in a full-screen WebView on the device. Use this when the user wants to view a website, read an article, or interact with a web page visually.',
      makeSchema(openProps, ['url'])),
    makeTool('close_webpage', 'Close the currently open WebView page.',
      makeSchema(closeProps)),
    makeTool('navigate_webpage', 'Navigate the already-open WebView to a new URL. The WebView must be open first via open_webpage.',
      makeSchema(navProps, ['url'])),
    makeTool('eval_webpage', 'Execute JavaScript code in the currently open WebView and return the result. Use this to interact with web pages: click buttons, fill forms, extract text content, scroll, etc. The WebView must be open first via open_webpage.',
      makeSchema(evalProps, ['javascript'])),
    makeTool('snapshot_webpage', 'Take a screenshot of the currently open WebView and return it as a base64 JPEG image. Use this to see what the webpage looks like. The WebView must be open first via open_webpage.',
      makeSchema(snapProps)),
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

  let sendProps: Record<string, JsonSchemaProperty> = {};
  sendProps['to'] = { type: 'string', description: 'Recipient email address (comma-separated for multiple)' };
  sendProps['subject'] = { type: 'string', description: 'Email subject' };
  sendProps['body'] = { type: 'string', description: 'Email body text' };
  sendProps['cc'] = { type: 'string', description: 'CC recipients (optional, comma-separated)' };

  return [
    makeTool('list_emails', 'List recent emails from the user email inbox (IMAP). Use this when user asks about 邮件/邮箱/email/mail. Returns sender, subject, and date.',
      makeSchema(listProps)),
    makeTool('read_email', 'Read the full body of a specific email by its sequence number.',
      makeSchema(readProps, ['id'])),
    makeTool('search_emails', 'Search emails by subject keyword. Returns matching email summaries.',
      makeSchema(searchProps, ['query'])),
    makeTool('send_email', 'Send an email via SMTP. Use this when user asks to send/write/compose an email (发邮件/写邮件/发送邮件).',
      makeSchema(sendProps, ['to', 'subject', 'body'])),
  ];
}

function buildSkillManagementToolSchemas(): ToolSchema[] {
  let createProps: Record<string, JsonSchemaProperty> = {};
  createProps['name'] = { type: 'string', description: 'Skill display name (unique)' };
  createProps['description'] = { type: 'string', description: 'Brief description of what this skill does' };
  createProps['prompt'] = { type: 'string', description: 'Detailed instructions for how to accomplish the task using existing tools (web_search, create_event, screen_capture, etc). Be specific about workflow steps.' };

  let listProps: Record<string, JsonSchemaProperty> = {};

  let updateProps: Record<string, JsonSchemaProperty> = {};
  updateProps['id'] = { type: 'string', description: 'Skill ID (from list_custom_skills)' };
  updateProps['name'] = { type: 'string', description: 'New name (optional)' };
  updateProps['description'] = { type: 'string', description: 'New description (optional)' };
  updateProps['prompt'] = { type: 'string', description: 'New prompt instructions (optional)' };
  updateProps['enabled'] = { type: 'string', description: 'true or false (optional)' };

  let deleteProps: Record<string, JsonSchemaProperty> = {};
  deleteProps['id'] = { type: 'string', description: 'Skill ID to delete (from list_custom_skills)' };

  return [
    makeTool('create_skill', 'Create a custom skill. A skill is a saved workflow that combines existing tools to accomplish a specific task. Write a detailed prompt explaining HOW to do it step by step using available tools.',
      makeSchema(createProps, ['name', 'description', 'prompt'])),
    makeTool('list_custom_skills', 'List all user-created custom skills with their IDs, names, and status.',
      makeSchema(listProps)),
    makeTool('update_skill', 'Update an existing custom skill (name, description, prompt, or enabled status).',
      makeSchema(updateProps, ['id'])),
    makeTool('delete_skill', 'Delete a custom skill by its ID.',
      makeSchema(deleteProps, ['id'])),
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
  ['skill_management', buildSkillManagementToolSchemas()],
]);
