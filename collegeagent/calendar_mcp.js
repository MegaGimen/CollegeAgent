#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { google } from 'googleapis';
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import 'dotenv/config';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DATA_FILE = path.join(__dirname, 'data.json');

const server = new Server({ name: 'collegeagent-calendar', version: '1.0.0' }, { capabilities: { tools: {} } });

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'add_calendar_event',
        description: 'Create a new event in the current user personal Google Calendar.',
        inputSchema: {
          type: 'object',
          properties: {
            summary: { type: 'string', description: 'Title of the event' },
            description: { type: 'string', description: 'Description of the event' },
            startTime: { type: 'string', description: 'Start time in ISO format with timezone (e.g. 2026-08-26T09:00:00-07:00 for Pacific Time PDT or 2026-08-26T09:00:00+08:00)' },
            endTime: { type: 'string', description: 'End time in ISO format with timezone (e.g. 2026-08-26T10:00:00-07:00 for Pacific Time PDT or 2026-08-26T10:00:00+08:00)' },
            userId: { type: 'string', description: 'The userId (injected by system)' }
          },
          required: ['summary', 'startTime', 'endTime', 'userId']
        }
      },
      {
        name: 'get_calendar_events',
        description: 'Query upcoming events from the current user personal Google Calendar. Use this to check the user schedule or find an event ID for deletion.',
        inputSchema: {
          type: 'object',
          properties: {
            timeMin: { type: 'string', description: 'Start of the time range in ISO format (e.g., 2026-08-25T00:00:00Z). Optional, defaults to now.' },
            timeMax: { type: 'string', description: 'End of the time range in ISO format. Optional.' },
            maxResults: { type: 'number', description: 'Maximum number of events to return (default 10, max 50).' },
            userId: { type: 'string', description: 'The userId (injected by system)' }
          },
          required: ['userId']
        }
      },
      {
        name: 'delete_calendar_event',
        description: 'Delete a specific event from the current user personal Google Calendar using its event ID.',
        inputSchema: {
          type: 'object',
          properties: {
            eventId: { type: 'string', description: 'The ID of the event to delete. You must first use get_calendar_events to find the ID.' },
            userId: { type: 'string', description: 'The userId (injected by system)' }
          },
          required: ['eventId', 'userId']
        }
      }
    ]
  };
});

async function getCalendarClient(userId) {
  if (!existsSync(DATA_FILE)) throw new Error('data.json not found');
  
  const data = JSON.parse(readFileSync(DATA_FILE, 'utf-8'));
  let user = null;
  
  if (data.users && data.users[userId]) {
      user = data.users[userId];
  } else if (data.users) {
      user = Object.values(data.users).find(u => u.userId === userId || u.username === userId);
  }
  
  if (!user || !user.google_refresh_token) {
    throw new Error('User has not linked their Google Calendar. Please ask the user to click the Calendar button in the top left to bind it.');
  }
  
  const oauth2Client = new google.auth.OAuth2(
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_CLIENT_SECRET
  );
  oauth2Client.setCredentials({ refresh_token: user.google_refresh_token });
  
  return google.calendar({ version: 'v3', auth: oauth2Client });
}

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  
  try {
    const calendar = await getCalendarClient(args.userId);
    
    if (name === 'add_calendar_event') {
      const response = await calendar.events.insert({
        calendarId: 'primary',
        requestBody: {
          summary: args.summary,
          description: args.description,
          start: { dateTime: args.startTime },
          end: { dateTime: args.endTime },
        }
      });
      return { content: [{ type: 'text', text: `Event created successfully: ${args.summary}. ID: ${response.data.id}, Link: ${response.data.htmlLink}` }] };
    }
    
    if (name === 'get_calendar_events') {
      const response = await calendar.events.list({
        calendarId: 'primary',
        timeMin: args.timeMin || (new Date()).toISOString(),
        timeMax: args.timeMax,
        maxResults: args.maxResults || 10,
        singleEvents: true,
        orderBy: 'startTime',
      });
      
      const items = response.data.items || [];
      const text = items.map(ev => `- [ID: ${ev.id}] ${ev.summary} (Start: ${ev.start.dateTime || ev.start.date}, End: ${ev.end.dateTime || ev.end.date})`).join('\\n') || 'No upcoming events found.';
      return { content: [{ type: 'text', text: text }] };
    }
    
    if (name === 'delete_calendar_event') {
      await calendar.events.delete({
        calendarId: 'primary',
        eventId: args.eventId
      });
      return { content: [{ type: 'text', text: `Event ${args.eventId} deleted successfully.` }] };
    }
    
    throw new Error(`Tool not found: ${name}`);
  } catch (e) {
    return { content: [{ type: 'text', text: `Error: ${e.message}` }] };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
