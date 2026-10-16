// Tim's only explicit Pi extension. These tools publish data, never write source.
import { resolve, relative, isAbsolute } from 'node:path';
const string = (description, maxLength = 262144) => ({ type: 'string', minLength: 1, maxLength, description });
const schema = (properties, required) => ({ type: 'object', properties, required, additionalProperties: false });
function result(id, kind, params) {
  return { content: [{ type: 'text', text: JSON.stringify({ id: kind === 'comment' ? (params.comment_id || id) : 'tool:' + id, status: 'published for editor validation', applied: false }) }],
    details: { tim: { version: 1, id, kind, ...params } } };
}
export default function (pi) {
  pi.registerTool({ name: 'editor_comment', label: 'Leave editor comment',
    description: 'Publish or update a review finding in Tim. Returns its stable comment ID. Use this instead of formatting a comment in chat. No source edits.',
    parameters: schema({ path: string('Project-relative file', 4096), line_start: { type: 'integer', minimum: 1 },
      line_end: { type: 'integer', minimum: 1 }, body: string('Finding or explanation', 16384),
      comment_id: string('Existing comment ID, only when refreshing that finding', 512) }, ['path', 'line_start', 'body']),
    async execute(id, params, _signal, _update, ctx) {
      const path = relative(ctx.cwd, resolve(ctx.cwd, params.path));
      if (isAbsolute(params.path) || path === '..' || path.startsWith('../') || !path || /[\r\n]/.test(params.path)) throw new Error('Use a file inside this project');
      if ((params.line_end ?? params.line_start) < params.line_start) throw new Error('Invalid line range');
      return result(id, 'comment', params);
    },
  });
  pi.registerTool({ name: 'editor_propose_diff', label: 'Propose changes',
    description: 'Publish a complete unified diff in Tim’s Diffs view. Link comment_id to the finding it fixes. The user must approve Apply; this tool never edits files.',
    parameters: schema({ title: string('Short description of the fix', 160), diff: string('Unified diff, exact current buffer context; existing files only'),
      comment_id: string('Comment ID returned by editor_comment or provided by Tim', 512) }, ['title', 'diff']),
    async execute(id, params) {
      if (!/^--- a\/.+\n\+\+\+ b\/.+\n@@ /m.test(params.diff)) throw new Error('Expected complete unified diff with --- a/path, +++ b/path and @@ headers');
      return result(id, 'proposal', params);
    },
  });
  // A protocol-only smoke check can verify registration without a model call.
  pi.registerCommand('tim-editor-tools', { description: 'Tim editor protocol v1', handler: async () => {} });
}
